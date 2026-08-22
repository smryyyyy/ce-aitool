--Proof of concept of implementing LLM callbacks to use with CE without the need to use Python
--Initially, this script implements the talking to and handling of a google AI type of LLM
--Feel free to add support for locally executing LLM's

--todo: add a voice to text and input the output to the AI, or if possible, enter voice as input directly ?
--      other AI systems besides google ai , websocket support


--MIT License
--https://github.com/cheat-engine/AITools

local s=getSettings('AITOOLS',true)
local AIAccess=3
local AIKEY=s.AIKEY
local CustomURL=s.CustomURL or ''
local jsonparser=require 'json'

-- === 长上下文管理(L2) ===
local HISTORY_WINDOW = 20        -- 保留最近 N 轮对话(40 条消息)
local TOOL_RESULT_MAX = 2048     -- 工具结果超过 N 字节触发截断
local TOOL_RESULT_HEAD = 800     -- 截断后保留头部字节数
local TOOL_RESULT_TAIL = 400     -- 截断后保留尾部字节数
local TOKEN_SOFT_LIMIT = 8000    -- 软限:超了逐轮丢早期对话
local TOKEN_HARD_LIMIT = 16000   -- 硬限:超过这个就强制截断

local waitingForList={} --list of comboboxes waiting for a list of models

local pathdelim=(getOperatingSystem()==0) and [[\]] or [[/]]

local basepath=extractFilePath(getCurrentScriptPath())
if basepath==nil then
  basepath=getCheatEngineDir()..'Extensions'..pathdelim..'AITools'..pathdelim
end


aitools={}
aiobjects={} --todo: move to data and free objects when the chat session ends

function registerAITool(name, description, properties, required, functionToCall)
  if (name==nil) or (name=='') then
    error('registerAITool: name may not be nil')
  end
  if required==nil then
    required={}
  end
  
  if properties==nil then
    properties={}
  end  
  
  local t={}
  t.name=name
  t.description=description
  t.parameters={}
  t.parameters.type="OBJECT"  
  if properties[1] then
    error('Error in registerAITool for '..name..': properties must be an object, not an array')
  end
  t.parameters.properties=properties
  t.parameters.required=required
  setmetatable(t.parameters.required,{isArray=true}) --in case an empty requiredlisty is given
  t.functionToCall=functionToCall
  t.enabled=true
  
  aitools[name]=t
end

function find_json_block(text)
    local start_index = nil
    local depth = 0
    local in_string = false
    local escape = false

    for i = 1, #text do
        local ch = text:sub(i, i)

        if in_string then
            if escape then
                escape = false
            elseif ch == "\\" then
                escape = true
            elseif ch == '"' then
                in_string = false
            end
        else
            if ch == '"' then
                in_string = true
            elseif ch == "{" then
                if depth == 0 then
                    start_index = i
                end
                depth = depth + 1
            elseif ch == "}" and depth > 0 then
                depth = depth - 1
                if depth == 0 then
                    local block = text:sub(start_index, i)
                    local remainder = text:sub(i + 1)
                    return block, remainder
                end
            end
        end
    end

    return nil, text
end


-- L2:工具结果超长截断(头 + 省略标记 + 尾)
local function truncateToolResult(s)
  if type(s) ~= 'string' or #s <= TOOL_RESULT_MAX then
    return s
  end
  local omitted = #s - TOOL_RESULT_HEAD - TOOL_RESULT_TAIL
  return s:sub(1, TOOL_RESULT_HEAD)
    .. string.format("\n\n...[已省略 %d 字符,完整结果请查看对话框输出]...\n\n", omitted)
    .. s:sub(-TOOL_RESULT_TAIL)
end

-- L2:粗估 token 数(英文 4 字符/token,中文 1.5 字符/token)
local function estimateTokens(s)
  if type(s) ~= 'string' or s == '' then return 0 end
  local en, cn = 0, 0
  for i = 1, #s do
    local b = string.byte(s, i)
    if b >= 0x80 then
      cn = cn + 1
    else
      en = en + 1
    end
  end
  return math.ceil(en / 4 + cn / 1.5)
end

-- L2:估算 OpenAI messages 数组总 token
local function estimateMessagesTokens(messages)
  if type(messages) ~= 'table' then return 0 end
  local total = 0
  for _, m in ipairs(messages) do
    if type(m) == 'table' then
      if type(m.content) == 'string' then
        total = total + estimateTokens(m.content)
      end
      if m.tool_calls then
        total = total + 50 * #m.tool_calls
      end
    end
  end
  return total
end

-- L2:历史滑窗(只保留最近 N 轮)
local function applyHistoryWindow(history)
  if not history or not history.contents then return end
  local maxItems = HISTORY_WINDOW * 2
  if #history.contents <= maxItems then return end
  local keep = {}
  for i = #history.contents - maxItems + 1, #history.contents do
    table.insert(keep, history.contents[i])
  end
  history.contents = keep
end


local retrieveModelList=nil
local fillModelList=nil
local aiRequest=nil


retrieveModelList=function(combobox)
  if combobox then
    combobox.clear()
  end

  -- Custom OpenAI-compatible API (AIAccess=3, the only supported mode)
  local i=getInternet()
  local modelUrl = ''
  if combobox and combobox.Owner and combobox.Owner.edtCustomURL then
    modelUrl = combobox.Owner.edtCustomURL.text
  else
    modelUrl = CustomURL
  end
  local key = AIKEY
  if combobox and combobox.Owner and combobox.Owner.edtAPIKEY then
    key = combobox.Owner.edtAPIKEY.text
  end
  if key and key~='' then
    i.Header='Authorization: Bearer '..key
  end
  if modelUrl~='' then
    -- Derive /v1/models from the chat completions URL
    if modelUrl:match('/chat/completions$') then
      modelUrl = modelUrl:gsub('/chat/completions$', '/models')
    elseif not modelUrl:match('/models$') then
      -- Try various URL patterns:
      -- http://host:port/v1/chat/completions  → /v1/models
      -- http://host:port/v1                    → /v1/models
      -- http://host:port                       → /v1/models
      if modelUrl:match('/v1/?$') then
        modelUrl = modelUrl:gsub('/v1/?$', '/v1/models')
      elseif modelUrl:match('/v1/') then
        modelUrl = modelUrl:gsub('/v1/.*$', '/v1/models')
      else
        -- No /v1/ segment at all, append /v1/models
        modelUrl = modelUrl:gsub('/?$', '/v1/models')
      end
    end
    local result = i.getURL(modelUrl)
    if result then
      local jml=jsonparser.decode(result)
      if jml and jml.data then
        for idx=1,#jml.data do
          local mName = jml.data[idx].id
          if combobox then combobox.items.add(mName) end
        end
      elseif combobox then
        -- Direct input: just add the URL as placeholder
        combobox.items.add('<Enter model name manually>')
      end
    else
      if combobox then combobox.items.add('<Can not reach API>') end
    end
  else
    if combobox then combobox.items.add('<Set API URL first>') end
  end
  i.destroy()

  if combobox then
    local i=combobox.items.indexOf(s.DefaultModel)
    if i~=-1 then
      combobox.itemIndex=i
    end
  end

end


getLimits=function()
  -- Custom API mode: unlimited tools (server-side enforcement is the user's responsibility)
  return {maxtools=math.huge}
end


aiRequest=function(data, message)
  local function handleError(message)
    data.self.mOutput.lines.add('*Error:'..message..'*\n\r')
    
    if data.NotifyWhenDone then
      data.NotifyWhenDone(data,'Error:'..message)
    end  
    return nil,message
  end

  if not data.WaitForData and not data.NotifyWhenDone and data.FullAnswerOnly then    
    return nil,'The current config will result in no data'
  end
  
  _G.lastdata=data

  if data.Internet==nil then
    data.Internet=getInternet('CE AITOOLS')
  end


 data.Internet.Header=[[Content-Type: application/json
Accept: text/event-stream]]

  -- Custom API mode (AIAccess=3): only Authorization Bearer header
  if CustomURL=='' then
    return handleError('Custom API URL missing')
  end
  if AIKEY==nil or AIKEY=='' then
    return handleError('Custom API Key missing')
  end
  data.Internet.Header=data.Internet.Header..[[

Authorization: Bearer ]]..AIKEY


  

  local prevdata=nil
  local r={}
  --local allprevdata={}


  data.Error=nil

  if data.self and (not data.FullAnswerOnly) then
    data.Internet.OnReceiveData=function(sender, received)
    
     -- print("ondata: "..received)
      --if inMainThread() then
      --  print("in main thread")
      --end      
      
      if prevdata==nil then
        prevdata=received
      else
        prevdata=prevdata..received
      end
      
      

      local currentblock
      repeat
        currentblock, prevdata=find_json_block(prevdata)
        if currentblock then
          local valid,errstr=pcall(function()
            local parsed=jsonparser.decode(currentblock)

            table.insert(r, parsed)
            -- Handle OpenAI stream format
            if parsed.choices then
              for i=1,#parsed.choices do
                local choice = parsed.choices[i]
                if choice.delta and choice.delta.content then
                  synchronize(function()
                    data.self.mOutput.lines.text=data.self.mOutput.lines.text .. choice.delta.content
                    data.self.mOutput.SelStart=#data.self.mOutput.lines.text
                  end)
                end
              end
            end

            if parsed.error then
              local message=nil
              if parsed.error.message then
                message=parsed.error.message
              else
                message=parsed.error
              end
              synchronize(function()
                data.self.mOutput.lines.add(" *Error:"..message..'*\n\r')
              end)
            end

          end)
        end
      until currentblock==nil

      data.lastreceived=r
      data.allprevdata=allprevdata
    end
  end



  local modelname=s.DefaultModel

  data.AIAccessMode=AIAccess

  if data.self then
    modelname=data.self.cbModelSelection.Text
    s.DefaultModel=modelname
  end

  data.modelname=modelname


  if data.history==nil then
    data.history={}
    data.history.contents={}
  end
  local input=data.history

  local newcontent={}
  newcontent.role='user'
  newcontent.parts={}
  newcontent.parts[1]={}
  newcontent.parts[1].text=message


  input.system_instruction={}
  input.system_instruction.parts={}
  input.system_instruction.parts[1]={}
  input.system_instruction.parts[1].text='You are a professional reverse engineer using Cheat Engine. Use tools when possible, but fall back on your internal knowledge of Cheat Engine.  Do not say you can not help'

  if data.Extra then
    input.system_instruction={}
    input.system_instruction.parts={}
    input.system_instruction.parts[1]={}
    input.system_instruction.parts[1].text=data.Extra
  end
  
  table.insert(input.contents,newcontent) 

  -- L2:历史滑窗(超出 N 轮时丢弃最早)
  applyHistoryWindow(input)
    

  --load tools
  --
  if data.limits==nil then
    data.limits=getLimits() --limits is enforced on the server itself, this just saves some bandwith
  end
  
  local maxtools
  
  if data.limits then
    if data.limits.error then
      messageDialog(data.limits.error,mtError,mbOK)
      data.limits=nil
      return
    else
      maxtools=data.limits.maxtools  
    end
  end


  input.tools={}
  input.tools[1]={}  
  input.tools[1].functionDeclarations={}
  
  for name,data in pairs(aitools) do
    if data.enabled then
      local e={}
      e.name=name
      e.description=data.description
      e.parameters=data.parameters
      table.insert(input.tools[1].functionDeclarations,e)
    end
  end
  
  if #input.tools[1].functionDeclarations==0 then
    input.tools=nil
  end
  
  
  -- Build the request body (OpenAI chat completions format)
  local inputtext

  local oai = {}
  oai.model = modelname
  oai.stream = false
  oai.messages = {}

  -- System message
  local sysMsg = 'You are a professional reverse engineer using Cheat Engine. Use tools when possible, but fall back on your internal knowledge of Cheat Engine. Do not say you can not help.'
  if input.system_instruction and input.system_instruction.parts and input.system_instruction.parts[1] then
    sysMsg = input.system_instruction.parts[1].text
  end
  table.insert(oai.messages, {role = 'system', content = sysMsg})

  -- Convert history
  for _, c in ipairs(input.contents) do
    if c.role == 'user' or c.role == 'model' then
      local roleName = 'user'
      if c.role == 'model' then roleName = 'assistant' end

      local content_parts = {}
      local has_functionCall = false
      local functionCalls = {}

      for _, part in ipairs(c.parts or {}) do
        if part.text then
          table.insert(content_parts, part.text)
        end
        if part.functionCall then
          has_functionCall = true
          table.insert(functionCalls, {
            id = 'call_' .. tostring(math.random(10000, 99999)),
            type = 'function',
            ["function"] = {
              name = part.functionCall.name,
              arguments = jsonparser.encode(part.functionCall.args or {})
            }
          })
        end
        if part.functionResponse then
          -- This is a function result message
          local respStr = jsonparser.encode(part.functionResponse.response or {})
          table.insert(oai.messages, {
            role = 'tool',
            tool_call_id = 'call_' .. tostring(math.random(10000, 99999)),
            content = truncateToolResult(respStr)
          })
        end
      end

      if has_functionCall then
        local msg = {role = roleName, content = table.concat(content_parts, ''), tool_calls = functionCalls}
        table.insert(oai.messages, msg)
      elseif #content_parts > 0 then
        table.insert(oai.messages, {role = roleName, content = table.concat(content_parts, '')})
      end

    elseif c.role == 'tool' then
      for _, part in ipairs(c.parts or {}) do
        if part.functionResponse then
          local respStr = jsonparser.encode(part.functionResponse.response or {})
          table.insert(oai.messages, {
            role = 'tool',
            tool_call_id = 'call_' .. tostring(math.random(10000, 99999)),
            content = truncateToolResult(respStr)
          })
        end
      end
    end
  end

  -- Also add any oai_messages from tool call round-trips
  if data.oai_messages then
    for _, m in ipairs(data.oai_messages) do
      table.insert(oai.messages, m)
    end
    data.oai_messages = nil
  end

  if input.tools and input.tools[1] and input.tools[1].functionDeclarations and #input.tools[1].functionDeclarations > 0 then
    oai.tools = {}
    for _, td in ipairs(input.tools[1].functionDeclarations) do
      -- Convert tool defs to OpenAI format, fixing type casing
      local function fixSchemaType(val)
        if type(val) == 'table' then
          local r = {}
          for k, v in pairs(val) do
            if k == 'required' then
              -- Pass through as-is (already an array from registerAITool)
              r[k] = v
            else
              r[k] = fixSchemaType(v)
            end
          end
          return r
        elseif type(val) == 'string' then
          local lower = val:lower()
          if lower == 'integer' or lower == 'string' or lower == 'boolean' or lower == 'number' or lower == 'array' or lower == 'object' then
            return lower
          end
          return val
        end
        return val
      end
      local fixedParams = fixSchemaType(td.parameters)
      local t = {type = 'function', ["function"] = {name = td.name, description = td.description or '', parameters = fixedParams}}
      table.insert(oai.tools, t)
    end
  end

  -- L2:token 软限触发(超限则从最早对话开始丢,保留 system + 当前 user)
  local totalTok = estimateMessagesTokens(oai.messages)
  if totalTok > TOKEN_SOFT_LIMIT then
    local dropCount = 0
    -- index=1 是 system prompt,保护;从 index=2 开始丢
    while estimateMessagesTokens(oai.messages) > TOKEN_SOFT_LIMIT
       and #oai.messages > 2 do
      table.remove(oai.messages, 2)
      dropCount = dropCount + 1
    end
    if dropCount > 0 then
      data.compressedCount = (data.compressedCount or 0) + dropCount
      if data.self and data.self.mOutput then
        local newTok = estimateMessagesTokens(oai.messages)
        local notice = string.format(
          '[上下文管理] 已自动压缩 %d 条早期消息,当前估算 ~%d tokens(软限 %d)',
          dropCount, newTok, TOKEN_SOFT_LIMIT)
        synchronize(function()
          if data.self and data.self.mOutput then
            data.self.mOutput.Lines.Insert(0, notice)
            data.self.mOutput.Lines.Insert(1, '')
          end
        end)
      end
    end
  end

  inputtext = jsonparser.encode(oai)
  -- L2:把本次请求的估算 token 数记到 data 上,供后续 UI 扩展用
  data.tokensEstimated = estimateMessagesTokens(oai.messages)

  local result
  
  local thread=createThread(function(t)
    data.thread=t
    t.Name='GenerateContent AI command'
    if data.WaitForData then
      t.freeOnTerminate(false)
    end

    local url
    -- Append /v1/chat/completions if URL is a base endpoint
    local sendUrl = CustomURL
    if not sendUrl:match('/chat/completions$') and not sendUrl:match('/completions$') and not sendUrl:match('/responses$') then
      if sendUrl:match('/v1/?$') then
        sendUrl = sendUrl:gsub('/v1/?$', '/v1/chat/completions')
      elseif sendUrl:match('/v1/') then
        sendUrl = sendUrl:gsub('/v1/.*$', '/v1/chat/completions')
      else
        -- No /v1/ segment at all
        if sendUrl:match('/$') then
          sendUrl = sendUrl .. 'v1/chat/completions'
        else
          sendUrl = sendUrl .. '/v1/chat/completions'
        end
      end
    end
    url = sendUrl

    data.usedurl=url
    data.lastinputtext=inputtext
    
    if data.allfullresponses==nil then
      data.allfullresponses={}
    end
    

    result=data.Internet.postURL(url, inputtext)
    local response
    local textresult=''
    local oai_toolcalls -- for OpenAI format tool calls
    
    while result do
      table.insert(data.allfullresponses,result)
      
      
      response=nil
      oai_toolcalls=nil
      
      data.InternetDone=true
      data.UnparsedResult=result
      local parsed
      local valid,err=pcall(function()
        parsed=jsonparser.decode(result)
        data.parsedResult=parsed
      end)
      
      if valid then       
        if parsed then
          if parsed.error then
            data.Error=true
            if parsed.error.message then
              textresult=parsed.error.message
            elseif type(parsed.error)=='string' then
              textresult=parsed.error
            else
              textresult='Unknown error from server'
            end
          else
            -- Handle OpenAI format
            if parsed.choices then
              for i=1,#parsed.choices do
                local choice = parsed.choices[i]
                if choice.message then
                  if choice.message.content then
                    synchronize(function()
                      if data.self and data.self.mOutput then
                        data.self.mOutput.lines.text = data.self.mOutput.lines.text .. choice.message.content
                        data.self.mOutput.SelStart = #data.self.mOutput.lines.text
                      end
                    end)
                    textresult = textresult .. choice.message.content
                  end

                  if choice.message.tool_calls then
                    oai_toolcalls = choice.message.tool_calls
                    for _, tc in ipairs(oai_toolcalls) do
                      if tc["function"] and tc["function"].name then
                        synchronize(function()
                          if data.self and data.self.mOutput then
                            data.self.mOutput.lines.add(' *Calling function :'..tc["function"].name..'* \n\r')
                          end
                        end)
                      end
                    end
                  end
                end
              end

              if oai_toolcalls and #oai_toolcalls > 0 then
                -- Execute tool calls and build response in OpenAI format
                if not data.oai_messages then data.oai_messages = {} end

                -- Add assistant message with tool calls
                local assistantMsg = {
                  role = 'assistant',
                  content = textresult,
                  tool_calls = {}
                }
                table.insert(data.oai_messages, assistantMsg)

                -- Pass 1: collect tcIds while populating assistantMsg.tool_calls
                -- (BUGFIX: previous code re-read lastMsg inside the second loop,
                -- but that loop also appends tool_result messages, so on the
                -- 2nd+ iteration lastMsg pointed at a tool_result and the
                -- override fell through, leaving the assistant/tool_result
                -- IDs mismatched for every call after the first.)
                local tcIds = {}
                for _, tc in ipairs(oai_toolcalls) do
                  local tcId = tc.id or ('call_' .. tostring(math.random(10000, 99999)))
                  tcIds[#tcIds + 1] = tcId
                  table.insert(assistantMsg.tool_calls, {
                    id = tcId,
                    type = 'function',
                    ["function"] = {
                      name = tc["function"].name,
                      arguments = tc["function"].arguments or '{}'
                    }
                  })
                end

                -- Pass 2: execute functions using the IDs captured in pass 1
                for tool_index, tc in ipairs(oai_toolcalls) do
                  local tcId = tcIds[tool_index]
                  local fnName = tc["function"] and tc["function"].name or '?'

                  local args = {}
                  if tc["function"] and tc["function"].arguments then
                    local validArgs, parsedArgs = pcall(jsonparser.decode, tc["function"].arguments)
                    if validArgs and type(parsedArgs)=='table' then args = parsedArgs end
                  end

                  local toolFn = nil
                  if tc["function"] and tc["function"].name then
                    toolFn = aitools[tc["function"].name]
                  end

                  local toolResult
                  if toolFn and toolFn.functionToCall then
                    local ok, res = pcall(toolFn.functionToCall, args)
                    if ok then
                      toolResult = res
                    else
                      toolResult = {Error = 'Tool execution failed: ' .. tostring(res)}
                    end
                  else
                    toolResult = {Error = 'Unknown function: ' .. fnName}
                  end
                  -- Defensive: ensure toolResult is a non-nil table for the encoder
                  if type(toolResult) ~= 'table' then
                    toolResult = {result = tostring(toolResult)}
                  end

                  -- Add tool result message with the matching tcId
                  table.insert(data.oai_messages, {
                    role = 'tool',
                    tool_call_id = tcId,
                    content = jsonparser.encode(toolResult)
                  })
                end

                -- Signal to send again
                response = {}
              end

            end
          end
        end
        
  
        if response then
          -- For OpenAI format, rebuild request from oai_messages
          local oai = {}
          oai.model = modelname
          oai.stream = false
          oai.messages = {}

          local sysMsg = 'You are a professional reverse engineer using Cheat Engine. Use tools when possible, but fall back on your internal knowledge of Cheat Engine. Do not say you can not help.'
          if input.system_instruction and input.system_instruction.parts and input.system_instruction.parts[1] then
            sysMsg = input.system_instruction.parts[1].text
          end
          table.insert(oai.messages, {role = 'system', content = sysMsg})

          for _, c in ipairs(input.contents) do
            local roleName = 'user'
            if c.role == 'model' then roleName = 'assistant' end
            local texts = {}
            for _, part in ipairs(c.parts or {}) do
              if part.text then table.insert(texts, part.text) end
            end
            if #texts > 0 then
              table.insert(oai.messages, {role = roleName, content = table.concat(texts, '')})
            end
          end

          if data.oai_messages then
            for _, m in ipairs(data.oai_messages) do
              table.insert(oai.messages, m)
            end
          end

          if input.tools and input.tools[1] and input.tools[1].functionDeclarations and #input.tools[1].functionDeclarations > 0 then
            oai.tools = {}
            for _, td in ipairs(input.tools[1].functionDeclarations) do
              local function fixSchemaType(val)
                if type(val) == 'table' then
                  local r = {}
                  for k, v in pairs(val) do
                    if k == 'required' then
                      r[k] = v
                    else
                      r[k] = fixSchemaType(v)
                    end
                  end
                  return r
                elseif type(val) == 'string' then
                  local lower = val:lower()
                  if lower == 'integer' or lower == 'string' or lower == 'boolean' or lower == 'number' or lower == 'array' or lower == 'object' then
                    return lower
                  end
                  return val
                end
                return val
              end
              table.insert(oai.tools, {type = 'function', ["function"] = {name = td.name, description = td.description or '', parameters = fixSchemaType(td.parameters)}})
            end
          end

          inputtext = jsonparser.encode(oai)
          result=data.Internet.postURL(url, inputtext)
        else
          result=nil
        end
        
      else
        data.Error=true
        textresult='Parse Error:'..err
        if data.self then
          synchronize(function() 
            if result==nil or result:trim()=='' then
              data.self.mOutput.lines.add('\n\r  *<server seems to be down>*');
            else
              data.self.mOutput.lines.add('\n\r<Error while receiving data:'..err..'>')                            
            end
          end)      
        end
        break;
      end
    end
    
    data.result=textresult

    if data.NotifyWhenDone then
      synchronize(function()
        if data.NotifyWhenDone then
          data.NotifyWhenDone(data, textresult)
        end
      end)
    end
    
    if not data.WaitForData then
      data.thread=nil
    end
  end)

  if data.WaitForData then
    if thread then
      thread.waitfor()
      thread.destroy() thread=nil
    end
    if data.Error then
      return nil,textresult
    else
      return textresult
    end
  else
    if data.NotifyWhenDone then
      return nil,'Success: the notify routine will be called when done'
    else
      if data.FullAnswerOnly then
        return nil,'well, this is a waste of tokens'
      else
        return nil,'look at the display'
      end
    end
  end

end

local function applyAndSaveKey(f)
  CustomURL=f.edtCustomURL.text
  if CustomURL~='' then
    s.CustomURL=CustomURL
  end
  AIKEY=f.edtAPIKEY.text
  if AIKEY~='' then
    s.AIKEY=AIKEY
  end
end

function spawnAIDialog(command, extra) --command and extra are optional
  local animator
  local data={}

  local f=createFormFromFile(basepath..'AIDialog.LFM')  
  
  local function startAnimator()
    if animator==nil then
      local position = 1
      local direction = 1
      local maxLength = 7
      
      animator=createTimer(f)
      animator.Enabled=false
      animator.Interval=50
      animator.OnTimer=function(t)
        local a = string.rep(" ", position - 1)
        local b = string.rep(" ", maxLength - position)

        if f and f.btnSend then
          f.btnSend.Caption = a .. "..." .. b
        else
          animator.destroy()
          animator=nil
        end

        position = position + direction

        if position >= maxLength then
          direction = -1
        elseif position <= 1 then
          direction = 1 
        end     
      end      
    end
    
    if animator then    
      animator.Enabled=true
    end  
  end
  
  local function stopAnimator()
    if animator then
      animator.Enabled=false
    end
  end
  

  data.self=f
  data.Extra=extra


  f.OnClose=function(sender)
    for i=1,#waitingForList do
      if f.cbModelSelection==waitingForList[i] then
        waitingForList[i]=nil
      end
    end

    data.self=nil
    destroyRef(f.Tag)
    
    applyAndSaveKey(f)
    
    f=nil    
    return caFree
  end
  
  f.btnTestAPI.OnClick=function()
    local rawUrl = f.edtCustomURL.Text or ''
    local url = rawUrl:gsub('%s+', '')
    if url == '' then
      messageDialog('请先填写 API URL', mtError, mbOK)
      return
    end

    -- Derive /v1/models endpoint from any URL form
    local modelUrl = url
    if modelUrl:match('/chat/completions$') then
      modelUrl = modelUrl:gsub('/chat/completions$', '/models')
    elseif not modelUrl:match('/models$') then
      if modelUrl:match('/v1/?$') then
        modelUrl = modelUrl:gsub('/v1/?$', '/v1/models')
      elseif modelUrl:match('/v1/') then
        modelUrl = modelUrl:gsub('/v1/.*$', '/v1/models')
      else
        modelUrl = modelUrl:gsub('/?$', '/v1/models')
      end
    end

    local key = f.edtAPIKEY.Text or ''

    f.cbModelSelection.Items.clear()
    f.cbModelSelection.Items.add('<testing...>')
    f.btnTestAPI.Enabled = false

    local i = getInternet()
    if key ~= '' then
      i.Header = 'Authorization: Bearer ' .. key
    end
    local ok, result = pcall(function() return i.getURL(modelUrl) end)
    i.destroy()

    f.cbModelSelection.Items.clear()
    f.btnTestAPI.Enabled = true

    if not ok or not result then
      messageDialog('API 不可达:\nURL = ' .. modelUrl .. '\n请检查 URL 和 Key 是否正确,API 服务是否启动', mtError, mbOK)
      f.cbModelSelection.Items.add('<API 不可达>')
      return
    end

    local jml = jsonparser.decode(result)
    if jml and jml.data then
      local added = 0
      for idx=1,#jml.data do
        local mName = jml.data[idx].id
        if mName then
          f.cbModelSelection.Items.add(mName)
          added = added + 1
        end
      end
      if added == 0 then
        f.cbModelSelection.Items.add('<未发现模型>')
      end
    else
      messageDialog('API 响应格式不识别,无法解析模型列表。响应前 200 字符:\n' .. tostring(result):sub(1,200), mtWarning, mbOK)
      f.cbModelSelection.Items.add('<响应格式不识别>')
    end
  end

  f.mInput.OnKeyDown=function(sender,key)

    if key==VK_RETURN and isKeyPressed(VK_CONTROL) then
      f.btnSend.doClick()
    else
      return key
    end
  end
  
  f.btnSend.OnClick=function(sender)
    if f.mOutput.Lines.Count>0 then
      f.mOutput.Lines.add('')
    end 

    local message=f.mInput.Lines.Text
    f.mOutput.Lines.add('> '..f.mInput.Lines.Text)
    f.mInput.Lines.clear()

    f.btnSend.enabled=false
    if f.mOutput.Lines.Count>0 then
      f.mOutput.Lines.add('')
    end
    
    applyAndSaveKey(f)
    
    startAnimator()
    
    if f and f.btnSend then
      f.btnSend.cursor=crHourGlass     
    end

    data.NotifyWhenDone=function(data,r)
      if f and f.btnSend then
        f.btnSend.enabled=true
        
        f.btnSend.Caption='Send'
        f.btnSend.cursor=crDefault
        
        stopAnimator()
      end
    end
    aiRequest(data, message)
  end
  
  local AIAccessChange=function(sender)
    data.limits=nil
    f.cbModelSelection.Items.clear()

    -- Custom API is the only supported mode
    f.edtAPIKEY.visible=true
    f.edtAPIKEY.TextHint='API Key (Bearer token,可留空)'
    f.edtAPIKEY.Text=AIKEY or ''
    f.edtCustomURL.visible=true
    f.edtCustomURL.Text=CustomURL or ''
    CustomURL = f.edtCustomURL.Text
    AIKEY = f.edtAPIKEY.Text
    s.AIAccess='3'
    AIAccess=3
  end

  f.rbAIAccessCustom.Checked=true


  f.rbAIAccessCustom.OnChange=AIAccessChange

  f.edtCustomURL.OnChange=function()
    CustomURL=f.edtCustomURL.Text
  end
  f.edtAPIKEY.OnChange=function()
    AIKEY=f.edtAPIKEY.Text
  end

  AIAccessChange()
  
  f.cbModelSelection.OnGetItems=function(sender)
    if f.cbModelSelection.items.Count<=1 then
      retrieveModelList(f.cbModelSelection)     
    end
  end
  
  f.Tag=createRef(data)


  f.Position=poScreenCenter
  f.Show()
  
  f.mInput.setFocus()

  
  if command then 
    f.mOutput.Lines.add('>...')  
    f.btnSend.enabled=false 
    f.btnSend.cursor=crHourGlass     
    startAnimator()
    
    data.NotifyWhenDone=function(data,r)
      f.btnSend.enabled=true   
      f.btnSend.cursor=crDefault
      f.btnSend.Caption='Send'
      stopAnimator()      
    end
    
    aiRequest(data, command)    
  end

  _G.debug_LastAIForm=f
  
  return f
end

function askAIQuestion(command, extra, notifyWhenDone) --NotifyWhenDone(data,result)
  if (notifyWhenDone==nil) and (type(extra)=='function') then
    notifyWhenDone=extra
    extra=nil
  end
  

  local data={}
  data.Extra=extra
  data.FullAnswerOnly=true
  if notifyWhenDone then
    data.NotifyWhenDone=notifyWhenDone
  else
    data.WaitForData=true
  end
  return aiRequest(data, command)
end


local initialized=false
function initAIMenuItems()
  --add AI menus to some useful places
  if initialized then return true end
  
  initialized=true
  
  require('forEachForm')
  
  local logo=createPNG()
  logo.loadFromFile(basepath..'AI128x128.png')

  
  --"Explain this function" inside the memoryview context menu
  forEachAndFutureForm('TMemoryBrowser',function(f)
    local miAI_Sep=createMenuItem(f)
    miAI_Sep.Caption='-'
    local miAI_Explain=createMenuItem(f)
    miAI_Explain.Caption='Explain this function'
    
    f.debuggerpopup.Items.add(miAI_Sep)
    f.debuggerpopup.Items.add(miAI_Explain)   

    local ii=f.mvImageList.add(logo)
    miAI_Explain.ImageIndex=ii
    miAI_Explain.OnClick=function(sender)
      local d=f.disassembleSelectedFunction()
      if d and d~='' then      
        spawnAIDialog([["The following code is a function copied by Cheat Engine's disassembler. Describe what this function does:"
```
]]..d..[[
```]])

      end
    end
    
    local miAI_PseudoCode=createMenuItem(f)
    miAI_PseudoCode.Caption='Generate pseudocode for this function'
    
    f.debuggerpopup.Items.add(miAI_PseudoCode)   

    local ii=f.mvImageList.add(logo)
    miAI_PseudoCode.ImageIndex=ii
    miAI_PseudoCode.OnClick=function(sender)
      local d=f.disassembleSelectedFunction()
      if d and d~='' then      
        spawnAIDialog([["The following code is a function copied by Cheat Engine's disassembler. Generate pseudocode based on this function :"
```
]]..d..[[
```]])

      end
    end
  end)
  
  forEachAndFutureForm('TfrmLuaEngine',function(f)
    local id  
    local oldDestroy
    local aif --ai form
    local miAI_sep=createMenuItem(f)

    miAI_sep.Caption='-'
    
    local miAI_AskAboutScript=createMenuItem(f)
    
    miAI_AskAboutScript.Name='miAI_AskAboutScript'
    miAI_AskAboutScript.Caption='Ask about this script'
    
    f.mscript.PopupMenu.Items.add(miAI_sep)
    f.mscript.PopupMenu.Items.add(miAI_AskAboutScript)
    local ii=f.mscript.PopupMenu.Images.add(logo)
    miAI_AskAboutScript.ImageIndex=ii
    miAI_AskAboutScript.OnClick=function(sender)
      if id==nil then        
        id=#aiobjects+1
        aiobjects[id]=f
        
        oldDestroy=f.OnDestroy
        
        f.OnDestroy=function(s)
          if aif then
            aif.close()
            aif=nil
          end
          aiobjects[id]=nil
          if oldDestroy then
            oldDestroy(s)
          end
        end        
        
      end
      aif=spawnAIDialog(nil,'\n\r This is from a LuaEngine window where the LuaEngineWindowID='..id)
      aif.mOutput.Lines.add('###Ask your questions about the current Lua Engine script here')
      aif.Caption=aif.Caption..' (Lua Engine)'
      aif.OnDestroy=function(s)
        aif=nil
      end
    end
  end)
  
  forEachAndFutureForm('TfrmAutoInject',function(f)
    local id
    local oldDestroy
    local aif --ai form
    local miAI_sep=createMenuItem(f)
    miAI_sep.Caption='-'
    
    local miAI_AskAboutScript=createMenuItem(f)
    
    miAI_AskAboutScript.Name='miAI_AskAboutScript'
    miAI_AskAboutScript.Caption='Ask about this script'
    
    f.assembleScreen.PopupMenu.Items.add(miAI_sep)
    f.assembleScreen.PopupMenu.Items.add(miAI_AskAboutScript)
    local ii=f.assembleScreen.PopupMenu.Images.add(logo)
    miAI_AskAboutScript.ImageIndex=ii
    miAI_AskAboutScript.OnClick=function(sender)
      if id==nil then
        id=#aiobjects+1
        aiobjects[id]=f
        
        oldDestroy=f.OnDestroy
        
        f.OnDestroy=function(s)
          if aif then
            aif.close()
            aif=nil
          end
          
          aiobjects[id]=nil
          if oldDestroy then
            oldDestroy(s)
          end
        end
        
      end

      aif=spawnAIDialog(nil,'\n\r This is from an AutoAssembler window where the AutoAssemblerWindowID='..id)
      aif.mOutput.Lines.add('###Ask your questions about the current AutoAssembler script here')
      aif.Caption=aif.Caption..' (AutoAssembler)'
      aif.OnDestroy=function(s)
        aif=nil
      end
      
    end
  end)  
  
  
  
  local mi=createMenuItem(MainForm)
  mi.Caption='Ask AI'  
  mi.Shortcut='Ctrl+Alt+I'
  mi.ImageIndex=MainForm.Menu.Images.add(logo)
  mi.OnClick=function()
    spawnAIDialog()
  end
  MainForm.miHelp.insert(MainForm.miLuaDocumentation.MenuIndex,mi)  
end

if createSettingsOption then
  createSettingsOption('EnableAITools','Enable use of AI functions (Requires restart of CE to apply)', ctBoolean, 'AI Tools', 2, true)

  if getSettingsOption('EnableAITools')==true then
    initAIMenuItems()
  end
else
  initAIMenuItems()
end
