# OpenClaw × Databricks × Telegram 一键引导脚本
# 用法（在新机器上）：
#   1. 装好 Clash Verge / Node 24 / Git / OpenClaw CLI
#   2. 把本仓库 clone 到本地
#   3. 在 PowerShell 里跑： powershell -ExecutionPolicy Bypass -File bootstrap.ps1
#
# 它会做的事：
#   - setx 持久化代理/Node/Whisper/API key 环境变量
#   - 把 openclaw.example.json 复制到 ~/.openclaw/openclaw.json（如果还不存在）
#   - 提醒你替换 <占位符>
#   - 下载 whisper.cpp + ggml-base 模型
#   - 注册开机自启计划任务

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Prompt-Secret([string]$name, [string]$envVarName) {
    Write-Host "`n-- $name --" -ForegroundColor Cyan
    $existing = [Environment]::GetEnvironmentVariable($envVarName, "User")
    if ($existing) {
        Write-Host "$envVarName already set (masked: $($existing.Substring(0, [Math]::Min(4, $existing.Length)))…). Keep? [Y/n]" -NoNewline
        $a = Read-Host
        if ([string]::IsNullOrWhiteSpace($a) -or $a.ToLower() -eq "y") { return }
    }
    $val = Read-Host "Enter value for $envVarName (or leave empty to skip)" -AsSecureString
    $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($val)
    )
    if (-not [string]::IsNullOrWhiteSpace($plain)) {
        setx $envVarName $plain | Out-Null
        Write-Host "  $envVarName persisted (new shells will see it)." -ForegroundColor Green
    }
}

Write-Host "=== OpenClaw bootstrap ===" -ForegroundColor Yellow

# 1. proxy + node
setx HTTPS_PROXY "http://127.0.0.1:7897"  | Out-Null
setx HTTP_PROXY  "http://127.0.0.1:7897"  | Out-Null
setx NO_PROXY    "localhost,127.0.0.1,::1" | Out-Null
setx NODE_OPTIONS "--use-env-proxy"        | Out-Null
Write-Host "Proxy env persisted (Clash Verge 7897)." -ForegroundColor Green

# 2. prompt for secrets
Prompt-Secret "Serper Web Search"  "SERPER_API_KEY"
Prompt-Secret "Groq (optional audio fallback)" "GROQ_API_KEY"
Prompt-Secret "Google AI Studio (optional image gen)" "GOOGLE_API_KEY"

# 3. whisper.cpp
$whisperDir = "$env:USERPROFILE\.openclaw\whisper"
$whisperBin = "$whisperDir\bin\Release\whisper-cli.exe"
$whisperModel = "$whisperDir\ggml-base.bin"
New-Item -ItemType Directory -Force -Path $whisperDir | Out-Null
if (-not (Test-Path $whisperBin)) {
    Write-Host "`nDownloading whisper.cpp binary..." -ForegroundColor Cyan
    gh release download v1.8.4 --repo ggerganov/whisper.cpp `
        --pattern "whisper-blas-bin-x64.zip" --dir $whisperDir --clobber
    Expand-Archive -Path "$whisperDir\whisper-blas-bin-x64.zip" `
        -DestinationPath "$whisperDir\bin" -Force
    Write-Host "  whisper-cli extracted." -ForegroundColor Green
} else {
    Write-Host "whisper-cli already present." -ForegroundColor Green
}
if (-not (Test-Path $whisperModel)) {
    Write-Host "Downloading ggml-base model (148 MB)..." -ForegroundColor Cyan
    Invoke-WebRequest `
        -Uri "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin" `
        -OutFile $whisperModel -UseBasicParsing
    Write-Host "  model downloaded." -ForegroundColor Green
} else {
    Write-Host "ggml-base model already present." -ForegroundColor Green
}

setx WHISPER_CPP_MODEL $whisperModel | Out-Null
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -notlike "*$whisperDir\bin\Release*") {
    [Environment]::SetEnvironmentVariable("Path", "$userPath;$whisperDir\bin\Release", "User")
    Write-Host "Added whisper bin to user PATH." -ForegroundColor Green
}

# 4. openclaw.json
$cfgDst = "$env:USERPROFILE\.openclaw\openclaw.json"
$cfgSrc = Join-Path $PSScriptRoot "openclaw.example.json"
if (-not (Test-Path $cfgDst)) {
    Copy-Item $cfgSrc $cfgDst
    Write-Host "`n==> Copied openclaw.example.json to $cfgDst" -ForegroundColor Yellow
    Write-Host "    REPLACE every <placeholder> before starting gateway:" -ForegroundColor Yellow
    Write-Host "      - DATABRICKS_PAT, workspace host"
    Write-Host "      - TELEGRAM_BOT_TOKEN, TELEGRAM_USER_ID"
    Write-Host "      - SERPER_API_KEY"
    Write-Host "      - Whisper paths if username isn't correct"
} else {
    Write-Host "openclaw.json already exists, not overwriting." -ForegroundColor Green
}

# 5. local memory (node-llama-cpp junction into openclaw)
$npmRoot = "$env:APPDATA\npm\node_modules"
$nllLink = "$npmRoot\openclaw\node_modules\node-llama-cpp"
$nllSrc  = "$npmRoot\node-llama-cpp"
if (-not (Test-Path $nllLink) -and (Test-Path $nllSrc)) {
    cmd /c "mklink /J `"$nllLink`" `"$nllSrc`"" | Out-Null
    Write-Host "Linked node-llama-cpp into OpenClaw (memory embeddings)." -ForegroundColor Green
}

# 6. scheduled task
$taskName = "OpenClawGateway"
$startScript = Join-Path $env:USERPROFILE ".openclaw\start-gateway.ps1"
if (Test-Path $startScript) {
    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if (-not $existing) {
        $action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$startScript`""
        $trigger   = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
        $trigger.Delay = "PT30S"
        $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit (New-TimeSpan -Hours 0)
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
        Write-Host "Scheduled task $taskName registered (logon + 30s)." -ForegroundColor Green
    } else {
        Write-Host "Scheduled task $taskName already exists." -ForegroundColor Green
    }
} else {
    Write-Host "start-gateway.ps1 missing at $startScript, skipping scheduled task." -ForegroundColor DarkYellow
}

Write-Host "`nPinning git HTTP proxy so 'git push' works without Clash TUN mode..." -ForegroundColor Cyan
git config --global http.proxy  "http://127.0.0.1:7897"
git config --global https.proxy "http://127.0.0.1:7897"

# 7. Clash Verge: ensure enable_dns_settings is true so dns_config.yaml takes effect
$vergeYaml = "$env:APPDATA\io.github.clash-verge-rev.clash-verge-rev\verge.yaml"
if (Test-Path $vergeYaml) {
    $content = Get-Content $vergeYaml -Raw
    if ($content -match 'enable_dns_settings:\s*null' -or $content -match 'enable_dns_settings:\s*false') {
        $content = $content -replace 'enable_dns_settings:\s*(null|false)', 'enable_dns_settings: true'
        Set-Content $vergeYaml -Value $content -Encoding UTF8
        Write-Host "Set enable_dns_settings: true in verge.yaml (dns_config.yaml will now take effect)." -ForegroundColor Green
    } else {
        Write-Host "enable_dns_settings already set in verge.yaml." -ForegroundColor Green
    }
} else {
    Write-Host "verge.yaml not found at $vergeYaml, skipping DNS settings check." -ForegroundColor DarkYellow
}

Write-Host "`n=== Bootstrap done ===" -ForegroundColor Yellow
Write-Host "Next steps:"
Write-Host "  1. Edit ~/.openclaw/openclaw.json and fill in the placeholders."
Write-Host "  2. Open a NEW PowerShell (so setx variables load), then run: openclaw config validate"
Write-Host "  3. openclaw memory index"
Write-Host "  4. Start gateway manually (first time): openclaw gateway --port 18789 --verbose"
Write-Host "  5. Reboot or run: Start-ScheduledTask -TaskName OpenClawGateway"
