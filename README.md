<h1 align="center">Cheat Engine AITools — Custom API 增强版</h1>

<p align="center">
  <img src="https://img.shields.io/badge/Lua-000000?style=flat-square&logo=lua&logoColor=white" alt="Lua">
  <img src="https://img.shields.io/badge/Cheat_Engine-7.7+-0078D8?style=flat-square&logo=microsoftvisualstudio&logoColor=white" alt="CE 7.7+">
  <img src="https://img.shields.io/badge/OpenAI_Comp_API-FF6F00?style=flat-square&logo=openai&logoColor=white" alt="OpenAI Compatible">
  <img src="https://img.shields.io/badge/Windows-0078D8?style=flat-square&logo=windows&logoColor=white" alt="Windows">
  <img src="https://img.shields.io/badge/License-MIT-green?style=flat-square" alt="MIT License">
</p>

<p align="center">
  Cheat Engine AI 调试助手 — 支持任意 OpenAI 兼容 API。<br>
  <b>在 CE 内置 AI 对话窗口中直接调用逆向工具，自动分析进程、内存、汇编代码。</b><br>
  <i>已在 Cheat Engine 7.7 测试通过，理论 7.5+ 均可使用，请自行测试。</i>
</p>

---

## 功能特点

- **Custom API 模式**：新增第 4 种访问方式，填入任意 OpenAI 兼容 API 的 URL 和 Key，不再依赖 Google Gemini
- **本地模型支持**：可配合 LM Studio / Ollama / vLLM，完全离线运行，无需联网
- **逆向工具集成**：自动注册 30+ 个 Cheat Engine 专用工具（进程枚举、内存扫描、反汇编、模块管理等）
- **流式响应**：支持 SSE 流式输出，实时显示 AI 回复
- **工具调用（Function Calling）**：AI 自动选择并调用 CE 工具函数，返回结构化结果
- **多轮对话**：保留完整上下文，支持连续问答和工具调用轮次
- **模型自动发现**：从 `/v1/models` 端点自动获取可用模型列表
- **URL 智能推导**：自动识别 `http://host:port` / `http://host:port/v1` / `http://host:port/v1/chat/completions` 三种格式

## 快速开始

### 1、安装

1. 将 `AITools` 文件夹整体复制到 Cheat Engine 的 Extensions 目录下：
   ```
   ~\Cheat Engine 7.7\Extensions\AITools\
   ```
2. 启动 Cheat Engine → **设置** → **ai工具** → **启用ai功能**<img width="1202" height="890" alt="image" src="https://github.com/user-attachments/assets/4b4917a9-7307-4bb1-8851-327b08e2ae57" />

3. 菜单栏 → **帮助** → **询问ai**（或按快捷键）<img width="774" height="783" alt="image" src="https://github.com/user-attachments/assets/5ab81b82-e9b0-453f-a4fb-06e95e786ca2" />

<img width="1234" height="510" alt="image" src="https://github.com/user-attachments/assets/065413a2-0913-4952-8611-a19f604bb264" />


### 2、配置 API

AI Dialog 窗口顶部有四种访问模式：

| 模式 | 说明 |
|------|------|
| Public CE API | CE 官方公共 API（有限额，Gemini 2.5 Flash） |
| Patreon CE API | Patreon 支持者专属 API（限额更高） |
| Personal Google AI Key | 使用自己的 Google AI Studio API Key（推荐） |
| **Custom API** | **填入任意支持 OpenAI 格式 API 的地址** |

选择 **Custom API** 后填写：

- **API URL**：任意支持 OpenAI 格式 API 的地址
- **API Key**：Bearer Token
### 3、使用

- 在输入框中输入问题（如"分析这段汇编代码"）
- 点击 **Send** 发送
- AI 会自动调用 CE 工具获取信息并给出回答
- 支持多轮对话，AI 会记住上下文

## 项目结构

```bash
.
├── aibase.lua              # 核心引擎：API 路由、消息转换、流式响应解析
├── aibase.lua.bak          # 原始版本（Google Gemini 模式）
├── AIDialog.LFM            # AI 对话窗口 UI 布局
├── loadorder.txt           # Lua 文件加载顺序
├── AI128x128.png           # 扩展图标
├── LICENSE                 # MIT License
├── README.md               # 本文件
└── tools/
    └── aitools.lua         # CE 逆向工具注册（30+ 函数）
```

## 技术栈

| 组件 | 用途 |
|------|------|
| Lua (Cheat Engine Runtime) | AI 对话引擎、工具调度、网络请求 |
| OpenAI Compatible API | 支持 OpenAI 格式 API 的任意本地推理后端|
| SSE (Server-Sent Events) | 流式响应传输 |
| Google Gemini → OpenAI 转换 | 消息格式、工具定义、流式响应的双向适配 |

## 修改说明

相比原版 Cheat Engine AITools（[cheat-engine/AITools](https://github.com/cheat-engine/AITools)），主要改动：

1. **新增 AIAccess=3（Custom API）**：独立的 OpenAI 兼容 API 分支
2. **消息格式转换**：Google `contents/parts` → OpenAI `messages/choices`
3. **工具定义转换**：Google `functionDeclarations` → OpenAI `tools/functions`，含 schema 类型大小写修正
4. **流式响应解析**：支持 OpenAI SSE `data: {...}` 格式
5. **URL 智能推导**：自动补全 `/v1/chat/completions` 和 `/v1/models` 路径
6. **UI 增强**：Custom API 单选按钮 + 双输入框（URL + Key）

## 常见问题

### 模型列表显示 `<Set API URL first>`

需要先选择 Custom API 并填写 API URL，然后切换到模型选择下拉框触发自动获取。

### API 返回 400 错误

检查：
- API URL 是否正确
- API Key 是否需要（某些模型不需要，可以留空或填 `sk-xxx`）
- 模型是否支持 function calling（需要支持 OpenAI tools 格式）

### 工具调用失败

确保使用的模型支持 function calling（如 `qwen2.5-coder`、`gemma3`、`llama3` 等）。不支持工具调用的模型会直接返回文本。

### 可以在 Mac/Linux 上用吗

CE 本身只在 Windows 上运行（Wine 下可用）。AITools 是纯 Lua 脚本，理论上可移植到其他平台。

## 许可证

MIT License

---

*基于 [cheat-engine/AITools](https://github.com/cheat-engine/AITools) 修改，增加 Custom API 支持。*
