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

## 验收

Telegram 里 `@Jcxu_claude_bot` 已能正常回复，主模型是 `databricks-claude-opus-4-7`，图文都能聊。

## 安全提醒

仓库里的是脱敏模板。**真实 token 只存在本机 `C:\Users\AMD\.openclaw\openclaw.json`**，不要 commit，不要截图发群。

- Databricks PAT：`dapi********`
- Telegram Bot Token：`8626*********`

如果怀疑泄露：Databricks 控制台吊销 PAT，`@BotFather` 发 `/revoke` 换 Token，改完同步到 `openclaw.json` 重启 gateway 即可。
