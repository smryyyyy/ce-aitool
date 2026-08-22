<h1 align="center">Cheat Engine AITools — Custom API 增强版</h1>

<p align="center">
  <img src="https://img.shields.io/badge/Lua-000000?style=flat-square&logo=lua&logoColor=white" alt="Lua">
  <img src="https://img.shields.io/badge/Cheat_Engine-7.7+-0078D8?style=flat-square&logo=microsoftvisualstudio&logoColor=white" alt="CE 7.7+">
  <img src="https://img.shields.io/badge/OpenAI_Comp_API-FF6F00?style=flat-square&logo=openai&logoColor=white" alt="OpenAI Compatible">
  <img src="https://img.shields.io/badge/Windows-0078D8?style=flat-square&logo=windows&logoColor=white" alt="Windows">
  <img src="https://img.shields.io/badge/License-MIT-green?style=flat-square" alt="MIT License">
</p>

<p align="center">
  Cheat Engine 内嵌的 AI 调试助手 — 接入任意 OpenAI 兼容 API。<br>
  <b>在 CE 对话窗口中直接调用 30+ 个逆向工具，自动分析进程、内存、汇编代码与模块结构。</b><br>
  <i>已在 Cheat Engine 7.7 验证通过，理论 7.5+ 均可使用，请自行测试。</i>
</p>

---

## 项目简介

基于 [cheat-engine/AITools](https://github.com/cheat-engine/AITools) 二次开发，统一接入 **单一 Custom API 模式** —— 任意 OpenAI 兼容后端（云端服务、LM Studio、Ollama、vLLM 等）填入 URL + Key 即可使用，不再依赖任何云端默认模型。

整个扩展用纯 Lua 写成，UI 由 Lazarus 表单 (`AIDialog.LFM`) 定义，请求与消息格式转换集中在 `aibase.lua`，30+ 个 CE 逆向工具在 `tools/aitools.lua` 中注册并以 OpenAI `tools` 协议暴露给模型。

## 功能特点

- **单一 Custom API 模式**：所有请求走 OpenAI 兼容协议，告别多套账号体系
- **本地模型支持**：可配合 LM Studio / Ollama / vLLM 完全离线运行，无需联网、无需 API Key
- **测试 API 按钮**：一键 `GET /v1/models` 探测服务，解析后自动填充模型下拉框
- **模型自动发现**：从 `/v1/models` 端点动态拉取模型列表，无需手动输入
- **URL 智能推导**：自动识别 `http://host:port`、`http://host:port/v1`、`http://host:port/v1/chat/completions` 三种写法
- **逆向工具集成**：自动注册 30+ 个 Cheat Engine 工具（进程枚举、内存扫描、反汇编、模块管理等）
- **工具调用（Function Calling）**：模型自动选择并调用 CE 工具函数，返回结构化结果
- **多轮对话**：保留上下文，支持连续问答与多轮工具调用
- **流式响应**：支持 OpenAI SSE (`data: {...}`) 格式，实时显示 AI 回复
- **L2 长上下文管理**：自动滑窗、工具结果截断、token 软限压缩（详见下文）

## 快速开始

### 1、安装

将 `AITools` 文件夹整体复制到 Cheat Engine 的 Extensions 目录下：

```
~\Cheat Engine 7.7\Extensions\AITools\
```

### 2、启用

启动 Cheat Engine → **设置** → **ai 工具** → 勾选 **启用 ai 功能**。

### 3、启动

菜单栏 → **帮助** → **询问 ai**（或使用快捷键），打开 AI Dialog 窗口。

## 配置 API

AI Dialog 顶部 `gbAPIKey` 区域只有一个 **自定义 API** 单选项（默认勾选），下方两个输入框：

| 字段 | 说明 |
|------|------|
| **API URL** | 任意 OpenAI 兼容 API 的地址，例如 `http://localhost:1234/v1/chat/completions`（LM Studio）或 `https://api.minimaxi.com/v1/chat/completions` |
| **API Key** | Bearer Token；本地模型可留空，云端服务填对应平台的 Key |

填好 URL 与 Key 后，点击 `gbModelSelection` 区域内的 **测试 API** 按钮：

1. 规范化 URL（自动补全 `/v1/models` 端点）
2. `GET /v1/models` 探测服务连通性
3. 解析返回的 JSON，提取模型 `id` 列表
4. 成功：自动填充下方模型下拉框；失败：弹窗显示具体错误

模型下拉框填充后即可正常对话；切换模型时直接选中新项即可。

## 长上下文管理 (L2)

针对本地小模型和长会话场景，内置 4 套自动压缩机制，无需用户干预：

- **历史滑窗**：保留最近 20 轮对话（40 条消息），超出自动丢弃最早一轮
- **工具结果截断**：单次工具调用返回 > 2 KB 时，只保留头部 800 字节 + 省略标记 + 尾部 400 字节送入上下文；完整结果在 `mOutput` 中仍可查看
- **Token 软限**：累计估算 > 8K tokens 时，从最早对话开始成对丢弃，直到 ≤ 8K；硬限 16K 作为兜底
- **状态提示**：发生压缩时在 `mOutput` 顶部插入一行 `[上下文管理] 已自动压缩 N 条早期消息，当前估算 ~XXX tokens（软限 8000）`

> **token 估算实现说明**：CE 嵌入式 Lua 没有外部 tokenizer，使用经验值 —— 英文按 4 字符 / token、中文按 1.5 字符 / token 估算。估算值偏保守，实际超限时机可能略晚于 8K 阈值。

## 项目结构

```text
.
├── aibase.lua              # 核心引擎：API 路由、消息转换、流式响应解析、L2 长上下文管理
├── AIDialog.LFM            # AI 对话窗口 UI 布局（Lazarus 表单）
├── loadorder.txt           # Lua 文件加载顺序
├── AI128x128.png           # 扩展图标
├── LICENSE                 # MIT License
├── README.md               # 本文件
└── tools/
    └── aitools.lua         # CE 逆向工具注册（30+ 个 function calling 接口）
```

## 技术栈

| 组件 | 用途 |
|------|------|
| Lua (Cheat Engine Runtime) | AI 对话引擎、工具调度、网络请求 |
| OpenAI Compatible API | 统一对外协议，支持任意兼容后端 |
| SSE (Server-Sent Events) | 流式响应传输 |
| Lazarus Forms (`.LFM`) | AI Dialog 窗口布局定义 |

## 修改说明

相比原版 Cheat Engine AITools，主要改动：

1. **Custom API 单模式**：整合为单一 Custom API 入口，新增 **测试 API** 按钮（`GET /v1/models`）一键探测模型列表
2. **URL 智能推导**：支持 `http://host:port`、`http://host:port/v1`、`http://host:port/v1/chat/completions` 三种格式自动补全 `/v1/chat/completions` 和 `/v1/models`
3. **消息格式转换**：Google `contents/parts` → OpenAI `messages/choices`，仅在 `tools.functionResponse` 序列化处保留兼容代码
4. **工具定义转换**：Google `functionDeclarations` → OpenAI `tools/functions`，含 schema 类型大小写修正
5. **流式响应解析**：支持 OpenAI SSE `data: {...}` 格式，逐 chunk 实时渲染
6. **Bug 修复**：修复 15+ 处已知 bug（变量名错误、函数注册错配、读取函数错用、返回值结构错误等）
7. **L2 长上下文管理**：历史滑窗 20 轮 + 工具结果截断 2 KB + token 软限 8 K + 状态提示

## 常见问题

### 测试 API 失败

检查：

- API URL 是否能直接访问（粘贴到浏览器看 `/v1/models` 是否返回 JSON）
- API Key 是否正确（云端服务必填，本地推理可留空）
- 本地推理服务是否启动（LM Studio 需开启 `OpenAI Compatible Server`）

### 模型下拉框是空的

先点击 **测试 API** 按钮，成功后会自动填充。如果仍为空，说明服务返回的 JSON 格式与 OpenAI `/v1/models` 不一致。

### 工具调用失败 / 模型不调用工具

使用的模型需要支持 function calling（OpenAI `tools` 格式）。已知可用：`qwen2.5-coder`、`gemma3`、`llama3.1` 等；不支持工具调用的模型会直接返回纯文本。

### 长对话会被截断吗

不会突然失败。L2 自动管理历史滑窗、工具结果、token 数量，超限会丢弃最早内容并在 `mOutput` 顶部提示。详见上文「长上下文管理 (L2)」一节。

## 许可证

[MIT License](LICENSE)

---

*基于 [cheat-engine/AITools](https://github.com/cheat-engine/AITools) 修改，强化 Custom API 并加入 L2 长上下文管理。*
