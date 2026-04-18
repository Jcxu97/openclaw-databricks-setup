# OpenClaw × Databricks × Telegram 部署交接文档

最后更新：2026-04-18 · 环境：Windows 10 (win32 10.0.19045) · PowerShell

本文档记录在本机把 **OpenClaw** 接入 **Databricks AI Gateway**（Claude Opus 4.7 主 / Sonnet 4.6 备）并通过 **Telegram Bot** 对话的完整配置，重点保留 **代理相关的所有踩坑与最终方案**，方便以后换机、重装、排障时直接照抄。

## 组件版本与路径

| 组件 | 版本 / 位置 |
| --- | --- |
| Node.js | 24.15.0 LTS（`winget` 安装，`C:\Program Files\nodejs`） |
| Git | 2.53（`winget` 安装，`C:\Program Files\Git\cmd`） |
| OpenClaw CLI | 全局 npm 安装，入口 `C:\Users\AMD\AppData\Roaming\npm\openclaw.cmd` |
| OpenClaw 配置 | `C:\Users\AMD\.openclaw\openclaw.json` |
| 代理客户端 | Clash Verge（混合端口 `7897`，支持 TUN 模式 + 系统代理） |
| Telegram Bot | `@Jcxu_claude_bot` |

## 代理配置（重点，踩坑最多的部分）

### 背景结论

Node.js v24+ **不再默认读取** `HTTP_PROXY` / `HTTPS_PROXY` 环境变量。必须同时满足以下两条，OpenClaw 才能从本机正确访问 Telegram / Databricks：

1. 设置 `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` 指向 Clash Verge 的混合端口。
2. 设置 `NODE_OPTIONS=--use-env-proxy`，让 Node 显式读取上述变量。

仅靠 Clash Verge 的"系统代理"开关不够，因为系统代理走的是 WinINet，Node 的 `undici`（fetch 实现）不经过它。

### 最终落地：系统级持久化变量

我们最后用 `setx` 把代理写进用户级 Windows 环境变量，**所有新开的 PowerShell / CMD / Cursor 会话都会自动继承**：

```powershell
setx HTTPS_PROXY "http://127.0.0.1:7897"
setx HTTP_PROXY  "http://127.0.0.1:7897"
setx NO_PROXY    "localhost,127.0.0.1,::1"
setx NODE_OPTIONS "--use-env-proxy"
```

验证（**必须开一个新 PowerShell 窗口**，`setx` 不影响当前会话）：

```powershell
$env:HTTPS_PROXY
$env:NODE_OPTIONS
```

### Clash Verge 路由规则

系统代理模式下，某些域名可能走直连。为了强制 Telegram 走代理，需要在 Clash Verge 的 profile 里把 Telegram 域名放进 `prepend`（优先级最高）：

```yaml
prepend:
  - 'DOMAIN-SUFFIX,telegram.org,Proxies'
  - 'DOMAIN-SUFFIX,t.me,Proxies'
  - 'DOMAIN-SUFFIX,tdesktop.com,Proxies'
  - 'DOMAIN-SUFFIX,cdn-telegram.org,Proxies'
  # 之后保留原有 Cursor、GitHub 等规则
```

改完后 **点 Clash Verge 的 "重载配置"** 才会生效。

### TUN 模式 vs 系统代理

| 模式 | 是否需要为 OpenClaw 单独设环境变量 | 适用场景 |
| --- | --- | --- |
| TUN 模式（虚拟网卡） | 不需要，所有流量被内核接管 | 懒人模式，开机即用 |
| 系统代理 | 需要 `HTTP_PROXY` + `NODE_OPTIONS=--use-env-proxy` | 现在我们用的就是这个 |

TUN 模式更省心，但对其他网络程序影响更大。我们最终选的是 **系统代理 + 环境变量持久化** 的组合。

## Databricks AI Gateway 接入

### Endpoint

完整聊天补全端点：

```
https://5678659344564033.3.ai-gateway.azuredatabricks.net/mlflow/v1/chat/completions
```

OpenClaw 里填的 `baseUrl` 只写到 `/mlflow/v1`，OpenClaw 会自动拼 `/chat/completions`。

### 模型

- **主模型**：`databricks-claude-opus-4-7`
- **应急备用**：`databricks-claude-sonnet-4-6`
- **多模态**：支持文本 + 图像输入；声音、视频不支持。

### `openclaw.json` 关键片段

```json
{
  "gateway": { "mode": "local", "port": 18789 },
  "models": {
    "mode": "merge",
    "providers": {
      "databricks": {
        "baseUrl": "https://5678659344564033.3.ai-gateway.azuredatabricks.net/mlflow/v1",
        "apiKey": "<DATABRICKS_PAT>",
        "api": "openai-completions",
        "models": [
          {
            "id": "databricks-claude-opus-4-7",
            "name": "Claude Opus 4.7 (primary)",
            "contextWindow": 200000,
            "maxTokens": 8192,
            "input": ["text", "image"],
            "compat": {
              "supportsTools": false,
              "supportsStrictMode": false,
              "supportsStore": false,
              "supportsPromptCacheKey": false,
              "supportsDeveloperRole": false,
              "supportsReasoningEffort": false,
              "supportsUsageInStreaming": false
            }
          },
          {
            "id": "databricks-claude-sonnet-4-6",
            "name": "Claude Sonnet 4.6 (fallback)",
            "contextWindow": 200000,
            "maxTokens": 8192,
            "input": ["text", "image"],
            "compat": {
              "supportsTools": true,
              "supportsStrictMode": false,
              "supportsStore": false,
              "supportsPromptCacheKey": false,
              "supportsDeveloperRole": false,
              "supportsReasoningEffort": false,
              "supportsUsageInStreaming": false
            }
          }
        ]
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "databricks/databricks-claude-opus-4-7",
        "fallbacks": ["databricks/databricks-claude-sonnet-4-6"]
      }
    }
  },
  "channels": {
    "telegram": {
      "enabled": true,
      "botToken": "<TELEGRAM_BOT_TOKEN>",
      "dmPolicy": "open"
    }
  }
}
```

真实凭据存在本机，**未上传仓库**。文档里统一用 `<DATABRICKS_PAT>` / `<TELEGRAM_BOT_TOKEN>` 占位。

## 启动命令

新开 PowerShell（环境变量已持久化，正常情况下直接跑即可）：

```powershell
openclaw gateway --port 18789 --verbose
```

如果某天 PATH 出问题，用绝对路径兜底：

```powershell
$env:Path = "C:\Program Files\Git\cmd;C:\Program Files\nodejs;C:\Users\AMD\AppData\Roaming\npm;" + $env:Path
& "C:\Users\AMD\AppData\Roaming\npm\openclaw.cmd" gateway --port 18789 --verbose
```

## 踩过的坑 · 速查表

| 现象 | 原因 | 解决 |
| --- | --- | --- |
| `npm not found` | `node` 解析到 Cursor 内嵌 runtime，没带 npm | `winget install OpenJS.NodeJS.LTS` |
| `npm error syscall spawn git` | OpenClaw 依赖从 Git 源码安装 | `winget install Git.Git` |
| `Permission denied (publickey)` 拉 `libsignal-node` | 依赖用 SSH URL | `git config --global url."https://github.com/".insteadOf "git@github.com:"` |
| `Failed to connect to github.com:443` | 没开代理 | 启动 Clash Verge |
| `config validate: Unrecognized key: "apiAdapter"` | 字段名错了 | 改成 `api` |
| Databricks 返回 `400 (no body)` | `compat` 里把 Databricks 不支持的请求参数标成了 `true` | 把 `supportsStrictMode` / `supportsStore` / `supportsPromptCacheKey` / `supportsDeveloperRole` / `supportsReasoningEffort` / `supportsUsageInStreaming` 都置 `false` |
| `gateway start blocked: missing gateway.mode` | 配置里没 `gateway` 段 | 加 `"gateway": { "mode": "local", "port": 18789 }` |
| `UND_ERR_CONNECT_TIMEOUT` 连 Telegram | Node 24 不读 `HTTP_PROXY` | 设 `NODE_OPTIONS=--use-env-proxy` |
| `Blocked unauthorized telegram sender` | `dmPolicy: allowlist` 下 allowFrom 路径配错 | 临时改为 `dmPolicy: "open"` |
| Telegram 域名走直连没被代理 | Clash Verge 规则里 Telegram 不在代理组 | 在 profile `prepend` 里加 Telegram 四个域名并重载 |

## 2026-04-18 扩展能力

在基础 Telegram × Databricks 能通之后，给这台 OpenClaw 追加了三类能力：**联网搜索**、**长期记忆**、**语音转写**。下文只记最终落地方案与踩坑。

### 1. 联网搜索 — Serper MCP（已上线）

没用浏览器自动化，选了 Serper 的 Google Search API（每月 2500 次免费，够用），以 **MCP server** 形式挂到 OpenClaw，模型通过 **native tool calling** 触发。

```powershell
npm i -g serper-search-scrape-mcp-server
setx SERPER_API_KEY "472d************"
```

`openclaw.json` 里加的 MCP 配置（**注意坑**：`env` 的值不能写 `"env:SERPER_API_KEY"` 字面量，OpenClaw 当前版本不解析这个引用语法，会把字符串原样塞给子进程，结果 Serper 返回 403。**直接把 key inline 到 env 里**。文件已在 `.gitignore`）：

```json
"mcp": {
  "servers": {
    "serper": {
      "command": "C:\\Users\\AMD\\AppData\\Roaming\\npm\\serper-mcp.cmd",
      "args": [],
      "env": { "SERPER_API_KEY": "472d************" }
    }
  }
}
```

配合这一步把主模型的 `supportsTools` 从 `false` 改成 `true`，否则 Claude Opus 4.7 不会发起 tool call。实测 Telegram 里直接问"现在比特币多少钱"，模型会调 `serper__google_search` 返回实时结果。

### 2. 长期记忆 — 本地 embedding + sqlite-vec（已上线）

走 OpenClaw 原生 `memorySearch`，embedding 用 **embeddinggemma 300M（Q8_0 GGUF）** 完全本地推理，向量库是自带的 `sqlite-vec`，无需远程 API。

`openclaw.json` 加：

```json
"agents": {
  "defaults": {
    "memorySearch": {
      "enabled": true,
      "sources": ["memory", "sessions"],
      "provider": "local",
      "fallback": "none"
    }
  }
}
```

本地 embedding 依赖 `node-llama-cpp`，OpenClaw 不自带，要**手动挂进去**（global 装好之后用 directory junction 让 OpenClaw 的 `require` 能找到；symlink 需要管理员，junction 不需要）：

```powershell
npm install -g node-llama-cpp
cmd /c "mklink /J `
  `"C:\Users\AMD\AppData\Roaming\npm\node_modules\openclaw\node_modules\node-llama-cpp`" `
  `"C:\Users\AMD\AppData\Roaming\npm\node_modules\node-llama-cpp`""
```

首次 `openclaw memory index` 会从 Hugging Face 下载 328 MB 模型到 `~\.node-llama-cpp\models\`，之后全本地。记忆内容写在 `C:\Users\AMD\.openclaw\workspace\MEMORY.md`，每次 index 后 `openclaw memory search "xx"` 能跨会话召回。

验证状态：`openclaw memory status` 应该输出 `Provider: local` / `Vector: ready` / `FTS: ready`。

### 3. 语音转写 — 本地 whisper.cpp（已上线）

原计划用 Groq 的 whisper-large-v3-turbo 云端转写，但 **OpenClaw 2026.4.15 的 Groq media-understanding provider 有 bug**：`dist/shared-Csk0T9PR.js` 里 `postTranscriptionRequest` 往 headers 里塞了 `Content-Type: application/json`，覆盖了 FormData 的自动 `multipart/form-data`，Groq 稳定返回：

```
HTTP 400: request Content-Type isn't multipart/form-data
```

Key 没错、proxy 没错，纯 OpenClaw 上游 bug。**换路线走本地 whisper.cpp**，CPU 推理，完全离线，零 token 成本。

下载 whisper.cpp Windows BLAS 版 + ggml-base 多语言模型（含中文）：

```powershell
gh release download v1.8.4 --repo ggerganov/whisper.cpp `
  --pattern "whisper-blas-bin-x64.zip" `
  --dir "C:\Users\AMD\.openclaw\whisper"
Expand-Archive "C:\Users\AMD\.openclaw\whisper\whisper-blas-bin-x64.zip" `
  -DestinationPath "C:\Users\AMD\.openclaw\whisper\bin" -Force
Invoke-WebRequest `
  -Uri "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin" `
  -OutFile "C:\Users\AMD\.openclaw\whisper\ggml-base.bin"
```

`whisper-cli.exe` 落在 `C:\Users\AMD\.openclaw\whisper\bin\Release\`，模型 148 MB。

OpenClaw 的 config 路径是 **`tools.media.audio.models`**（`audio.transcription` 是 legacy，会被 doctor 自动迁移），显式写进 `openclaw.json`：

```json
"tools": {
  "media": {
    "audio": {
      "enabled": true,
      "echoTranscript": true,
      "language": "zh",
      "models": [
        {
          "type": "cli",
          "command": "C:\\Users\\AMD\\.openclaw\\whisper\\bin\\Release\\whisper-cli.exe",
          "args": [
            "-m", "C:\\Users\\AMD\\.openclaw\\whisper\\ggml-base.bin",
            "-otxt", "-of", "{{OutputBase}}",
            "-np", "-nt",
            "{{MediaPath}}"
          ],
          "timeoutSeconds": 120
        }
      ]
    }
  }
}
```

模板占位符由 OpenClaw runtime 注入：`{{MediaPath}}` 是输入音频临时路径，`{{OutputBase}}` 是输出文件无扩展名基名（whisper-cli 用 `-otxt -of xxx` 写出 `xxx.txt`，OpenClaw 再读回来）。`-np` 压掉进度、`-nt` 去掉时间戳，保证输出是纯文本。

**额外加持**：OpenClaw 还支持环境变量自动发现——只要 `whisper-cli` 在 PATH 里 + `WHISPER_CPP_MODEL` 指向模型，无需显式配置也会自动挂上（见 `dist/runner-GjYg-C-v.js` 的 `resolveLocalWhisperCppEntry`）。我们两条路都配了，双保险：

```powershell
setx WHISPER_CPP_MODEL "C:\Users\AMD\.openclaw\whisper\ggml-base.bin"
# Path 追加 C:\Users\AMD\.openclaw\whisper\bin\Release
```

验证：

```powershell
openclaw infer audio transcribe --file "C:\Windows\Media\tada.wav" --json
# → outputs[0].text = "[MUSIC PLAYING]"
```

Telegram 语音消息（`.ogg/.oga`）通过 `tools.media.audio.enabled=true` 自动触发此 pipeline，`echoTranscript=true` 会把识别文本先回显给用户再喂给 agent。

### `.gitignore` 约束

```gitignore
.pat
.ghuser
*.token
*.key
.env
.env.*
openclaw.json
node_modules/
.DS_Store
Thumbs.db
```

`openclaw.json` 整个文件不上传，因为里面内联了 Databricks PAT、Telegram Bot Token、Serper Key、Groq Key。

## 验收

Telegram 里 `@Jcxu_claude_bot` 可以：

1. 回答常规问题（Opus 4.7 主模型）。
2. 自动联网搜索（Serper MCP，tool call）。
3. 读取/写入跨会话记忆（`memory_search` / `MEMORY.md`）。
4. 语音消息自动转写（本地 whisper.cpp，中文默认，先 echo 转写文本再进 agent）。
5. 操作本机文件、跑命令（`read` / `write` / `edit` / `exec` / `process` 工具全挂）。

### 文件操作 / 代码执行现状

Agent 注册的工具里已经有 `read` / `write` / `edit` / `exec` / `process` / `canvas`。执行策略在 `~/.openclaw/exec-approvals.json`：

```
Effective Policy
  tools.exec: security=full, ask=off, askFallback=full
```

也就是 agent 能**不弹审批**直接跑任意命令。在单人 DM + 已锁 allowlist 的前提下，风险可控。如果后面要开给别人用，务必降到 `security=allowlist` 并维护白名单。

CLI 端（`openclaw agent --agent main -m "..."`）喂指令时，Opus 4.7 会把 **没有 Telegram metadata 的注入命令一律拒掉**，即使自称 "I am Leo"。这是 OpenClaw 内置的 prompt injection 防御，正常现象。**真要跑命令，直接在 Telegram 对话里说。**

### Telegram 访问控制

从 `dmPolicy: "open"` 收紧到 **`"allowlist"`**，只允许 Leo（TG user id `8217237051`）DM：

```json
"channels": {
  "telegram": {
    "enabled": true,
    "botToken": "<TELEGRAM_BOT_TOKEN>",
    "dmPolicy": "allowlist",
    "allowFrom": ["8217237051"]
  }
}
```

这样即使 bot 被别人发现，陌生人 DM 也无法触发 agent（以及其身后的 exec 权限）。换机器人或换账号时记得同步改 `allowFrom`。

## 开机自启

Gateway 现在通过 **Windows 计划任务** 在登录后 30 秒自动启动，不用每次手动开终端。

### 任务定义

任务名 `OpenClawGateway`，触发器 `AtLogOn`（延迟 30 秒，等 Clash Verge 自己起来），执行脚本 `~\.openclaw\start-gateway.ps1`。

启动脚本做的事情按顺序：注入 PATH 和全部环境变量（代理、whisper model、Serper/Groq key）、杀掉可能残留的 openclaw node 进程、**TCP 探测 127.0.0.1:7897 最多 2 分钟等代理就绪**、启动 `openclaw gateway --port 18789 --verbose`、把 stdout/stderr 写到 `~\.openclaw\logs\gateway-<timestamp>.log`、只保留最近 10 份日志。

### 手动管理

```powershell
# 立刻启一次（比如改完 config 想重启）
Get-Process node | Stop-Process -Force
Start-ScheduledTask -TaskName OpenClawGateway

# 看最新日志
Get-ChildItem ~\.openclaw\logs\gateway-*.log |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1 |
  ForEach-Object { Get-Content $_.FullName -Tail 20 }

# 临时禁用（出差不想后台跑）
Disable-ScheduledTask -TaskName OpenClawGateway
Enable-ScheduledTask  -TaskName OpenClawGateway

# 彻底删掉
Unregister-ScheduledTask -TaskName OpenClawGateway -Confirm:$false
```

## 运维 Checklist（坏了怎么救）

| 症状 | 先看 | 常见原因 | 处理 |
| --- | --- | --- | --- |
| Telegram bot 不回话 | `Get-ScheduledTask OpenClawGateway` 状态 | 任务被禁用 / node 被杀 | `Start-ScheduledTask -TaskName OpenClawGateway` |
| Gateway 启动成功但 Telegram 连不上 | 最新 `gateway-*.log` 有没有 `[telegram] ok` | 代理没起 | 确认 Clash Verge 跑着，`Test-NetConnection 127.0.0.1 -Port 7897` |
| 启动日志 `Config invalid` | `openclaw config validate` | 改 config 时字段写错 | 回滚到 `~/.openclaw/openclaw.json.bak*`，或按报错字段修 |
| 记忆搜不到东西 | `openclaw memory status` 的 `Indexed: x/y` | `MEMORY.md` 变了没重建索引 | `openclaw memory index` |
| 语音转写失败 | `openclaw infer audio transcribe --file ...` 报错 | whisper-cli 不在 PATH / 模型丢失 | 确认 `WHISPER_CPP_MODEL` + `where whisper-cli` |
| Serper tool 返回 403 | `SERPER_API_KEY` 用量用完或 key 错 | 月度 2500 次打爆 | 到 serper.dev 看 dashboard，换 key 直接改 `openclaw.json` 里的 inline 值 |
| Databricks 400 / 401 | 最新 log 里的 HTTP body | PAT 过期 / workspace 搬家 | Databricks 控制台重发 PAT，改 `models.providers.databricks.apiKey` 后重启 |
| Prompt injection 被错误拒绝 | agent 返回 "不是 Leo 发的" | CLI 喂指令会被当注入 | 直接从 Telegram 发 |

### 一键体检

仓库里的 `health-check.ps1` 一次性扫 12 个关键点：Clash Verge、Gateway 端口、Scheduled Task、node 进程、config schema、memory index（`vector=ready`）、whisper 二进制 + 模型、Serper key、Databricks TCP、Gateway control UI、exec policy、Git 仓库状态。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File health-check.ps1
```

正常应该只剩一条 WARN（`Exec policy: security=full ask=off`），那是刻意的——Telegram 白名单做了边界，所以 full policy 是可以接受的。其他任何 FAIL/WARN 直接对应上面那张症状表。

### Telegram 远程运维命令

BotFather 侧已经注册了 5 个 slash command（Telegram 客户端输入框左下角 `/` 菜单可以直接点选）：`/status` `/logs` `/restart` `/mem` `/ip`。OpenClaw 本身不支持用户自定义 slash command 路由，所以这些命令的"语义"是靠两层机制保证的：

1. **AGENTS.md 里的硬绑定**（`C:\Users\AMD\.openclaw\workspace\AGENTS.md` 的 "Leo Operator Commands (binding)" 段）。OpenClaw 每次 session startup 都会整文件加载 `AGENTS.md` 到 system context，所以这段规则在上下文里是"始终存在"，不依赖向量检索命中。文件里同时写死了"只在 Telegram DM 且发件人是 Leo 时"才执行，避免在群聊、CLI、hooks 等路径上被触发。
2. **MEMORY.md 里的软规则**（`C:\Users\AMD\.openclaw\workspace\MEMORY.md` 的 "Telegram 操作约定" 段）。作为语义检索的回退，方便未来 agent 被注入到别的 workspace 时仍能通过 memory search 召回。

改命令表：直接编辑 `AGENTS.md` 的 Leo Operator Commands 段（不必 reindex，下次对话就生效）；同步改 `MEMORY.md` 并 `openclaw memory index` 让软规则保持一致。改客户端菜单要直接调 Telegram API：

```powershell
# 查看当前注册的命令
Invoke-RestMethod "https://api.telegram.org/bot<TOKEN>/getMyCommands"

# 覆盖式更新（完整替换）
$body = @{ commands = @(
    @{ command = "status"; description = "系统体检" },
    @{ command = "logs";   description = "最近日志" }
) } | ConvertTo-Json -Depth 4
Invoke-RestMethod "https://api.telegram.org/bot<TOKEN>/setMyCommands" -Method Post -ContentType "application/json" -Body $body
```

### 图片理解（2026-04-18 上线）

在 `openclaw.json` 的 `tools.media.image` 打开了图片理解，用 agent 的主模型（Opus 4.7 的 `input: ["text", "image"]`）跑。Telegram 收到图片后自动进 pipeline：中文 prompt 强制说明"有文字就 OCR、有场景就简要描述、有人物只给可见视觉特征不做身份猜测"，结果注入到对话上下文。

关键字段（`openclaw config get tools.media.image` 查看）：

| 字段 | 值 | 说明 |
| --- | --- | --- |
| `enabled` | `true` | 开关 |
| `scope.default` | `allow` | 所有消息源都允许；细粒度要走 `scope.rules` |
| `language` | `"zh"` | 中文输出 |
| `maxBytes` | 10 MiB | 超过这个尺寸的附件直接跳过 |
| `maxChars` | 4000 | 单次理解输出字符上限，防止 prompt 膨胀 |
| `timeoutSeconds` | 60 | 请求超时 |

**没配 `tools.media.image.models`**，所以会 fallback 到 `agents.defaults.model`（Opus → Sonnet）。如果要强制走别的多模态模型（比如接了 Gemini/GPT-4o），在这里按 schema 加 `models: [{ ref: "provider/id" }]`。

### ⚠️ PowerShell 5 终端显示 mojibake（不是数据坏）

PowerShell 5 默认 `$OutputEncoding` 在简体中文系统上是 GBK/936，但 OpenClaw、Node、JSON 文件都用 UTF-8。结果：

1. 在 Shell 里打印 UTF-8 中文字符串，控制台会显示成乱码（例如 `完整 OCR` 被渲染成 `完�?OCR`）。
2. 在 Shell 脚本里写中文字符串字面量，PS5 会按 GBK 解析再传给子进程，子进程按 UTF-8 解码就坏了。

**处理方式**：

1. 判断数据到底坏没坏，不看 `Write-Host` 或 `openclaw config get`——它们是显示层。用 `Get-Content` 读文件时 PS 也会乱码，唯一可靠的方式是 `[System.IO.File]::ReadAllBytes` + `[System.Text.Encoding]::UTF8.GetString`，或者直接在 IDE 里用 Grep / Read（它们按文件 BOM / UTF-8 解码）。
2. 要通过 Shell 传中文给 OpenClaw CLI，把中文先 `Write-Output` 到一个 UTF-8 文件（用 IDE 的 `Write` 工具或 `[System.IO.File]::WriteAllText` 带 `UTF8Encoding($false)`），再让脚本用 `ReadAllText` 读出来传入。不要在 PS 脚本里写中文字面量。
3. `openclaw config set --batch-file` 成功后会打印 `Config write anomaly: size-drop:9434->3881`。**这不是数据丢失**，是文件从 PowerShell 深缩进格式被改写成标准 2 空格 JSON（大小自然缩水），内容完整。用 `openclaw config validate` 或者 IDE 的 Read 工具确认就好。

### ⚠️ Groq / OpenAI-compat 语音转写 HTTP 400（issue #68294 + PR #68318 已提）

**症状**：`openclaw infer audio transcribe ... --model "groq/whisper-large-v3-turbo"` 失败，Groq 返回 `"request Content-Type isn't multipart/form-data"`。

**根因**：Node 24 内置 undici（约 6.x）和 OpenClaw 自带的 `undici@8.0.2` 是两个 realm，各自的 `FormData` class 不互认。`transcribeOpenAiCompatibleAudio` 里 `new FormData()` 用的是 Node 全局（旧 undici），但请求随附的 `init.dispatcher` 是 OpenClaw 绑的 undici 8 的 Agent。Node 原生 fetch 把请求委托给外部 dispatcher 后，undici 8 对 body 做 `instanceof this.FormData` 判断失败，退化为非 multipart 序列化，Groq 拒绝。

**本机现状**：`tools.media.audio.models` 指向本地 `whisper-cli.exe`（whisper.cpp + ggml-base），所以 Telegram 语音入口**不走 provider 路径**，不受这个 bug 影响。日常使用没事。

**upstream 状态**：

| 资源 | 链接 | 内容 |
| --- | --- | --- |
| Issue | https://github.com/openclaw/openclaw/issues/68294 | 完整 trace、跨 realm FormData 验证、修复草案 |
| PR | https://github.com/openclaw/openclaw/pull/68318 | fork `Jcxu97/openclaw`，分支 `fix/audio-transcribe-cross-realm-formdata`，一 commit 含修复 + regression test（2/2 pass，revert-patch 验证可复现原 bug） |

本地 fork 的 clone 在 `C:\Users\AMD\Desktop\oss\openclaw`。要继续改动：`git fetch upstream; git rebase upstream/main`，改完 `git push --force origin fix/audio-transcribe-cross-realm-formdata` 就自动更新 PR。

**等 PR merge + 新版发布后要做的**：`npm i -g openclaw@latest`，把 `tools.media.audio.models` 改回 `[{ "type": "provider", "ref": "groq/whisper-large-v3-turbo" }]`，Telegram 语音就能切到 Groq Turbo（延迟降一个数量级、中文识别更准）。


## 进阶功能（2026-04-18 启用）

这一批功能把 OpenClaw 从"Telegram 聊天机器人"升级成"带后台、会主动干活、能看真网页的 agent 平台"。全部 6 项上线、已验证。

### Control UI Dashboard

浏览器后台，gateway 自带。入口 `openclaw dashboard` 或直接 `http://127.0.0.1:18789/`。首次访问要粘贴 **gateway token**（见下）。Dashboard 里能看 sessions / channels 状态 / agents 活动 / config / memory / logs / cron，比 Telegram 视角完整得多。

**gateway token**：写在 `openclaw.json` 的 `gateway.auth.token` 字段（43 字节 base64url，`__OPENCLAW_REDACTED__` 是 `openclaw config get` 的显示掩码，文件里是明文）。Dashboard 首次访问：密码框留空，token 粘贴到"网关令牌"框。浏览器 Chrome 密码管理器记住后以后免登录。

```powershell
Get-Content "$HOME\.openclaw\openclaw.json" | Select-String 'gateway' -Context 0,5
```

上面这行能看到 token 明文。token 旋转时：`openclaw config set gateway.auth.token <new_token>` 然后重启 gateway。

### Backup / Restore

`openclaw backup create --output <dir> --verify` 做完整快照，含 config + sessions + memory + workspaces + auth，~160 MB。archive tar 格式可以任意拷贝到其他机器，解压到 `~/.openclaw` 就是完整复原。本机快照放在 `~/openclaw-backups/`。

建议**每次动大配置前**先跑一次，恢复只需解 tar 覆盖。`openclaw backup verify <archive>` 可独立校验归档完整性。

### Cron（主动 agent）

`openclaw cron add` 让 agent 按 cron 表达式自动跑。已注册的任务：

| 名字 | 表达式 | 动作 |
| --- | --- | --- |
| `daily-pr-68318-status` | `0 9 * * *` Asia/Shanghai | 调 `gh pr view 68318`，中文总结，发 Telegram DM |

常用命令：`openclaw cron list` / `openclaw cron runs --id <uuid>` / `openclaw cron run <uuid>`（立即执行调试）/ `openclaw cron rm <uuid>`。message 里带中文的坑：PowerShell 5 传中文字面量会 GBK 乱码，**必须先写到 UTF-8 文件再用 `[System.IO.File]::ReadAllText(..., [System.Text.Encoding]::UTF8)` 读出来传给 `--message $var`**，不能直接 `--message "中文"`。

### Browser（真浏览器，CDP）

Agent 能开 Chrome 做网页操作 —— navigate / click / type / fill / screenshot / pdf / console / cookies / trace，完整 Playwright 级别。入口 `openclaw browser status`。本机自动检测到 `C:\Program Files\Google\Chrome\Application\chrome.exe`，transport=CDP，port 18800。Browser 不常驻，agent 用的时候自动启。想让 agent 跑浏览器，在对话里说"用 browser 打开 xxx 并截屏"就行。

### Docs Search（内建文档搜索）

`openclaw docs "<query>"` 秒搜整个 docs.openclaw.ai，命中带 URL。以后问"XX 怎么用"让 agent 先跑这个再回答，不用自己翻官网。

### ClawHub Skills 市场

`openclaw skills search <keyword>` 连 clawhub.com 云端 registry，`openclaw skills install <id>` 装任意社区 skill 到当前 workspace。`openclaw skills list` 看本地已装。本机内置 52 个 bundled skill，其中 ready 的 8 个：`gh-issues` / `github` / `healthcheck` / `skill-creator` / `taskflow` / `taskflow-inbox-triage` / `weather` / `node-connect`。其他 44 个 `needs-setup`（各自需要安装对应 CLI 或 API key）。

### Canvas（交互式画布）

Agent 产出的可视化成品可以渲染成真 React 组件。workspace 根目录 `~/.openclaw/canvas/`，挂载点 `http://127.0.0.1:18789/__openclaw__/canvas/`（token 保护）。Dashboard 里有 Canvas 标签页直接打开。典型用法：让 agent 把 `health-check.ps1` 的输出画成仪表盘；查过去 7 天 Databricks 用量画图。

## 未启用功能（哪天想做再开）

### Mobile Node（手机 App 节点）

OpenClaw 有官方 iOS 和 Android app，装上后手机变成 gateway 的一个 node，摄像头 / 语音 / 通知全部打通。没启用的卡点：gateway 当前 `bind=loopback`（只监听 127.0.0.1），手机连不上。启用步骤：

1. 决定网络方案（三选一）：
   - **LAN**（家庭 WiFi，最省）：`openclaw config set gateway.bind lan`。注意局域网任何设备都能尝试连，靠 token 拦。
   - **Tailscale**（出门也能用，推荐）：`openclaw config set gateway.bind lan` + `openclaw config set gateway.remote.url https://<tailnet-name>.ts.net` + 双端装 Tailscale。
   - **公网 tunnel**：Cloudflare Tunnel 类方案，需要域名。
2. 重启 gateway。
3. `openclaw qr`（terminal 里直接画 ASCII QR），或 `openclaw qr --setup-code-only` 看短配对码。
4. 手机装 OpenClaw App（App Store / Play Store 搜 "OpenClaw"），启动扫 QR 或输入 setup code。
5. 回 PowerShell 跑 `openclaw devices approve <device-id>` 批准配对。

安全提醒：启用 `bind=lan` 等于把 gateway 暴露到同网段。token（43 字节 base64url）是唯一防线，**不要泄漏 `openclaw.json` 或 Dashboard 截图**。

### Sandbox（容器隔离 exec）

本机没装 Docker 或 Podman，跳过。如果以后想开：装 Docker Desktop（Windows 要 WSL2），OpenClaw 会自动检测到，`openclaw sandbox list` 就能管容器。当前 `exec` 直接在宿主机跑，`security=full ask=off` 状态下 agent 运行任意 shell 无询问，日常用但心里要有数。

### 多 Agent / 多 Workspace

当前只有 `main` 一个 agent，所有对话共享一份 `MEMORY.md` 和工具集。OpenClaw 支持拆成多个独立 agent（各自 workspace、memory、默认 model、tool allowlist）。典型拆法：

| Agent 名 | 用途 | Telegram 触发 |
| --- | --- | --- |
| `main` | 通用（现状） | 默认 |
| `code` | 编程、代码 review、PR 操作 | `/code <prompt>` 或单独 bot |
| `journal` | 日记、个人记忆、不被技术事务污染 | `/journal` |

启用大致流程（哪天要拆了再跑）：

1. `openclaw agents add code --workspace $HOME\.openclaw\agents\code\workspace`
2. 各自 `workspace\AGENTS.md` 和 `MEMORY.md` 独立编辑 + `openclaw memory index --agent code`
3. Telegram 绑 slash command 路由（改 AGENTS.md 的 Operator Commands 段，加分流规则）

没有切实的拆分动机就别拆，记忆混不混其实一个主 agent 里用 prefix (`#code` / `#journal`) 区分就行。

## Browser 工具 × Clash 代理踩坑记（2026-04-18）

让 Telegram agent "帮我打开浏览器 huya" 时会失败，错误链路踩了两层，都修掉了。

### 现象

`openclaw browser navigate https://www.huya.com` 依次报：

1. `GatewayClientRequestError: Navigation blocked: strict browser SSRF policy cannot be enforced while env proxy variables are set`
2. 修完一层后：`SsrFBlockedError: Blocked: resolves to private/internal/special-use IP address`

### 根因（两层独立问题叠加）

**第一层：gateway 继承了 proxy env**

`~/.openclaw/start-gateway.ps1` 原本显式 `setx HTTP_PROXY / HTTPS_PROXY = http://127.0.0.1:7897`，这是为了让 **LLM 调用** 和 **Serper MCP** 能走 Clash 出海。但它也污染了**同一个 gateway 进程里的 browser 工具**。Browser 的 SSRF guard 一旦检测到 env 里有 proxy，就没法自己 enforce 目标 IP 检查（流量会被代理劫持），于是 `strict` 策略直接 bail。

**第二层：Clash Verge 的 Fake-IP 劫持 DNS**

Clash Verge 默认用 **Fake-IP 模式** 加速匹配，把任意域名解析成 `198.18.0.0/15` 段的占位 IP（比如 `www.huya.com → 198.18.0.38`）。这个段是 **RFC 2544 benchmarking 保留段**，IANA special-use IP。OpenClaw 的 SSRF guard 看到特殊段地址就拒，不会等到 Clash 接管流量再判断。

### 修法尝试 1（失败 —— 供后人避坑）

初版思路是"把 proxy env 只给需要出海的上游"：gateway env 删 proxy、databricks provider 用 `request.proxy.mode = "explicit-proxy"`、Serper MCP 用 `mcp.servers.serper.env.HTTPS_PROXY` 单独注入。结果 gateway 一重启 Telegram agent 立刻秒回 `⚠️ Something went wrong`，gateway 日志里是 `FailoverError: LLM request failed: network connection error (timeout, status=408)`。

**原因**：OpenClaw 的 `models.providers.<p>.request.proxy` 字段在 schema 里存在但**运行时没有真的生效**（至少在 2026.4.15 版本里 Databricks 这条路径不读它）。gateway env 一删 proxy，LLM fetch 就走直连，GFW 下必 timeout。

**教训**：schema validation 通过 ≠ 功能生效。OpenClaw 有些 config 是"reserved for future"或者某些 provider path 专用的，验证能过不代表路径上真读。以后改 proxy 类配置必须跟一条"最小闭环冒烟测试"（发一条 Telegram 消息看 agent 能不能回），不能只看 `config validate`。

### 修法（实际落地，三步）

回到**最简单稳妥的版本**：gateway env 级别设 proxy 让所有子系统都继承，系统侧关 Fake-IP 让 DNS 正常，browser 工具放开 SSRF 让 proxy env 不阻塞 navigate。

**1. Gateway 启动脚本留 proxy env**（`~/.openclaw/start-gateway.ps1`）：

```powershell
$env:NODE_OPTIONS  = "--use-env-proxy"
$env:HTTPS_PROXY   = "http://127.0.0.1:7897"
$env:HTTP_PROXY    = "http://127.0.0.1:7897"
$env:NO_PROXY      = "localhost,127.0.0.1,::1"
```

**2. Clash Verge 从 Fake-IP 切到 Redir-Host**：

不用开 UI，直接改文件。Verge 的 merge 机制是"订阅 + 全局 Merge.yaml + profile merge.yaml"三层合并。全局 merge 文件在 `%APPDATA%\io.github.clash-verge-rev.clash-verge-rev\profiles\Merge.yaml`，加一行就行：

```yaml
# Profile Enhancement Merge Template for Clash Verge

profile:
  store-selected: true

dns:
  use-system-hosts: false
  enhanced-mode: redir-host    # <-- 这一行
```

然后热重载（Verge external-controller 监听 127.0.0.1:9097）：

```powershell
$cfg = "$env:APPDATA\io.github.clash-verge-rev.clash-verge-rev\clash-verge.yaml"
# 直接改运行时快照（下次 Verge merge 会从 Merge.yaml 重新生成并保持 redir-host）
(Get-Content $cfg) -replace 'enhanced-mode: fake-ip', 'enhanced-mode: redir-host' | Set-Content $cfg -Encoding UTF8
$body = @{ path = $cfg } | ConvertTo-Json -Compress
Invoke-WebRequest -Uri "http://127.0.0.1:9097/configs?force=true" -Method Put -ContentType "application/json" -Body $body -UseBasicParsing
Clear-DnsClientCache
```

验证：`Resolve-DnsName www.bilibili.com -Type A` 应该看到真公网 IP（`116.xxx` / `175.xxx`）而不是 `198.18.x.x`。

**3. Browser SSRF 放开 private-network**（`openclaw.json`）：

```json
"browser": {
  "ssrfPolicy": {
    "dangerouslyAllowPrivateNetwork": true,
    "allowedHostnames": []
  }
}
```

这一步**是 tradeoff**：开了以后 browser 能 navigate 任何地址，包括私有段 / loopback / special-use。prompt injection 下 agent 理论上可以去探你家路由器管理页。你这台机是单人 `security=full ask=off` 模式，本来就是"信任 agent"姿态，多这一档风险可以接受。如果哪天把 gateway 开放给不信任的人，**把 dangerouslyAllowPrivateNetwork 改回 false，维护 allowedHostnames 白名单**。

改完 `openclaw config set --batch-file <patch.json>` 然后 `Stop-Process` + `Start-ScheduledTask OpenClawGateway`。

### 尝试过的失败方案（供后人避坑）

初版想"按子系统拆 proxy"：gateway env 删 proxy，databricks provider 用 `request.proxy.mode = "explicit-proxy"`，Serper MCP 用 `mcp.servers.serper.env.HTTPS_PROXY` 单独注入。结果 gateway 重启后 Telegram agent 秒回 `⚠️ Something went wrong`，日志里是 `FailoverError: LLM request failed: network connection error (timeout, 408)`。

**原因**：OpenClaw `models.providers.<p>.request.proxy` 在 schema 里存在但**运行时没生效**（至少在 2026.4.15 里 Databricks 路径不读它）。gateway env 一删 proxy，LLM fetch 走直连，GFW 下必 timeout。

**教训**：schema validation 通过 ≠ 功能生效。OpenClaw 有些 config 是"reserved for future"或某些 provider path 专用。改 proxy 类配置必须跟一条"最小闭环冒烟测试"（发一条 Telegram 消息验证 agent 回复），不能只看 `config validate`。

### 验证

```powershell
openclaw browser --json navigate "https://www.baidu.com"
# { "ok": true, "targetId": "...", "url": "https://www.baidu.com/" }

openclaw browser --json navigate "https://www.weibo.com"
# { "ok": true, ... }   # 任何国内站、国外站都能开
```

Telegram 里对 agent 说"打开浏览器 XX 站"，agent 调 browser 工具跳转。做网页自动化、Canvas 取数据、截图发群，都基于这条链路。

### 附：`openclaw config set --batch-file` 的坑

`--batch-file` 期望 **JSON array of `{path, value}` 操作**，不是 config subtree。搞错了 CLI 不会报错，而是把当前文件当作"要写入的内容"盖一层（实际是 merge 语义，`"size-drop-vs-last-good"` 警告里那个 8703 基线是虚的，别被吓到）。每次改完先 `openclaw config validate` 再重启。

## 迁移到新机器

仓库里有 **`openclaw.example.json`**（脱敏模板）和 **`bootstrap.ps1`**（一键引导）。新机器上：

1. 装 Clash Verge、Node 24、Git、OpenClaw CLI（`npm i -g openclaw`）、GitHub CLI。
2. `git clone` 本仓库。
3. 跑 `powershell -ExecutionPolicy Bypass -File bootstrap.ps1`。脚本会：
   - `setx` 代理 + Node + Whisper 环境变量；
   - 引导你用 `Read-Host -AsSecureString` 安全录入 Serper/Groq/Google key（不回显、直接写 user env）；
   - 下载 whisper.cpp + ggml-base 模型；
   - 把 `openclaw.example.json` 拷到 `~/.openclaw/openclaw.json`；
   - 把 `node-llama-cpp` junction 到 OpenClaw 的 `node_modules`（本地 embedding 前置条件）；
   - 注册 `OpenClawGateway` 计划任务。
4. 打开 `~/.openclaw/openclaw.json`，把 `<DATABRICKS_PAT>` / `<TELEGRAM_BOT_TOKEN>` / `<TELEGRAM_USER_ID>` / `<SERPER_API_KEY>` 四个占位符替换成真值。
5. **开新** PowerShell（让 `setx` 生效）→ `openclaw config validate` → `openclaw memory index` → 重启或 `Start-ScheduledTask OpenClawGateway`。

## 安全提醒

仓库里只有脱敏模板（`openclaw.example.json`）。**真实 token 只存在本机 `~\.openclaw\openclaw.json`**，该文件在 `.gitignore` 里，不要 commit、不要截图、不要粘贴到任何对话（GitHub 的 secret scanning 会自动吊销 PAT，我们第一次推 repo 时已经被吊销过一次）。

已内联的敏感值：

| 字段 | 前缀（验证用） |
| --- | --- |
| `models.providers.databricks.apiKey` | `dapi****` |
| `channels.telegram.botToken` | `8626****` |
| `mcp.servers.serper.env.SERPER_API_KEY` | `472d****` |
| 环境变量 `GROQ_API_KEY`（未用但已存） | `gsk_****` |

怀疑泄露时：Databricks 控制台吊销 PAT；`@BotFather` 发 `/revoke` 换 Telegram Token；serper.dev dashboard rotate key；改完同步到 `openclaw.json` 并 `Start-ScheduledTask OpenClawGateway` 重启即可。
