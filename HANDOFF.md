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
