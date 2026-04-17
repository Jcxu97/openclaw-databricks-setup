# OpenClaw 系统体检脚本
# 一行跑：powershell -ExecutionPolicy Bypass -File health-check.ps1
# 覆盖：代理、gateway、Telegram、Databricks、memory、whisper、Serper、exec policy。
# 只读，不改任何配置。

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$script:pass = 0
$script:fail = 0
$script:warn = 0

function Report {
    param([string]$Name, [string]$Status, [string]$Detail = "")
    $tag = switch ($Status) {
        "OK"   { "[  OK  ]"; $script:pass++ ; "Green" }
        "FAIL" { "[ FAIL ]"; $script:fail++ ; "Red" }
        "WARN" { "[ WARN ]"; $script:warn++ ; "Yellow" }
        default { "[ ???? ]"; "White" }
    }
    $color = switch ($Status) {
        "OK"   { "Green" }
        "FAIL" { "Red" }
        "WARN" { "Yellow" }
        default { "White" }
    }
    $line = "{0,-8} {1,-35} {2}" -f $tag[0], $Name, $Detail
    Write-Host $line -ForegroundColor $color
}

Write-Host ""
Write-Host "=== OpenClaw Health Check ===" -ForegroundColor Cyan
Write-Host ""

# --- 1. Proxy ---
try {
    $tcp = New-Object System.Net.Sockets.TcpClient
    $tcp.Connect("127.0.0.1", 7897)
    $tcp.Close()
    Report "Clash Verge (127.0.0.1:7897)" "OK" "reachable"
} catch {
    Report "Clash Verge (127.0.0.1:7897)" "FAIL" "cannot connect; start Clash Verge"
}

# --- 2. Gateway port ---
$gatewayUp = $false
try {
    $tcp = New-Object System.Net.Sockets.TcpClient
    $tcp.Connect("127.0.0.1", 18789)
    $tcp.Close()
    Report "Gateway (127.0.0.1:18789)" "OK" "listening"
    $gatewayUp = $true
} catch {
    Report "Gateway (127.0.0.1:18789)" "FAIL" "not listening; Start-ScheduledTask OpenClawGateway"
}

# --- 3. Scheduled task ---
$task = Get-ScheduledTask -TaskName "OpenClawGateway" -ErrorAction SilentlyContinue
if ($task) {
    $info = Get-ScheduledTaskInfo -TaskName "OpenClawGateway"
    Report "Scheduled task OpenClawGateway" "OK" "state=$($task.State) lastRun=$($info.LastRunTime)"
} else {
    Report "Scheduled task OpenClawGateway" "WARN" "not registered; bootstrap.ps1 did not run"
}

# --- 4. Node process ---
$node = Get-Process node -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path -like "*nodejs*" }
if ($node) {
    $mem = [Math]::Round(($node | Measure-Object WorkingSet -Sum).Sum / 1MB, 0)
    Report "node.exe (openclaw)" "OK" "$($node.Count) procs, total ${mem}MB RSS"
} else {
    Report "node.exe (openclaw)" "WARN" "no node procs visible; may be fine if gateway is isolated"
}

# --- 5. Config validate ---
$cfgPath = "$env:USERPROFILE\.openclaw\openclaw.json"
if (Test-Path $cfgPath) {
    $cfgOut = & openclaw config validate 2>&1 | Out-String
    if ($cfgOut -match "Config valid") {
        Report "openclaw.json schema" "OK" "validates"
    } else {
        $firstErr = ($cfgOut -split "`n" | Where-Object { $_ -match "×" } | Select-Object -First 1).Trim()
        Report "openclaw.json schema" "FAIL" $firstErr
    }
} else {
    Report "openclaw.json" "FAIL" "missing at $cfgPath"
}

# --- 6. Memory index ---
$memOut = & openclaw memory status 2>&1 | Out-String
if ($memOut -match "Indexed:\s+(\d+)\s*/\s*(\d+)\s+files.*?(\d+)\s+chunks") {
    $files   = $matches[2]
    $chunks  = $matches[3]
    $providerMatch = [regex]::Match($memOut, "Provider:\s+(\w+)")
    $provider = if ($providerMatch.Success) { $providerMatch.Groups[1].Value } else { "?" }
    $vecMatch = [regex]::Match($memOut, "Vector:\s+(\w+)")
    $vec = if ($vecMatch.Success) { $vecMatch.Groups[1].Value } else { "?" }
    if ($files -gt 0 -and $vec -eq "ready") {
        Report "Memory index" "OK" "provider=$provider files=$files chunks=$chunks vector=$vec"
    } else {
        Report "Memory index" "WARN" "provider=$provider files=$files chunks=$chunks (run: openclaw memory index)"
    }
} else {
    Report "Memory index" "FAIL" "memory status unparseable"
}

# --- 7. Whisper ---
$whisperBin   = "$env:USERPROFILE\.openclaw\whisper\bin\Release\whisper-cli.exe"
$whisperModel = [Environment]::GetEnvironmentVariable("WHISPER_CPP_MODEL", "User")
if (-not (Test-Path $whisperBin)) {
    Report "whisper-cli binary" "FAIL" "missing: $whisperBin"
} else {
    Report "whisper-cli binary" "OK" "$whisperBin"
}
if ($whisperModel -and (Test-Path $whisperModel)) {
    $mb = [Math]::Round((Get-Item $whisperModel).Length / 1MB, 0)
    Report "Whisper model (WHISPER_CPP_MODEL)" "OK" "${mb}MB"
} else {
    Report "Whisper model (WHISPER_CPP_MODEL)" "WARN" "env var unset or file missing"
}

# --- 8. Serper key ---
$serper = [Environment]::GetEnvironmentVariable("SERPER_API_KEY", "User")
if ($serper) {
    $prefix = $serper.Substring(0, [Math]::Min(4, $serper.Length))
    Report "SERPER_API_KEY env" "OK" "prefix=$prefix****"
} else {
    Report "SERPER_API_KEY env" "WARN" "not set (web search tool may still work if inlined)"
}

# --- 9. Databricks reachability ---
try {
    $cfg = Get-Content $cfgPath -Raw
    if ($cfg -match '"baseUrl":\s*"([^"]+)"') {
        $baseUrl = $matches[1]
        $uri = [uri]$baseUrl
        $dbHost = $uri.Host
        $env:HTTPS_PROXY = "http://127.0.0.1:7897"
        $env:HTTP_PROXY  = "http://127.0.0.1:7897"
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $iar = $tcp.BeginConnect($dbHost, 443, $null, $null)
            $ok = $iar.AsyncWaitHandle.WaitOne(5000, $false)
            if ($ok -and $tcp.Connected) {
                Report "Databricks endpoint ($dbHost)" "OK" "TCP 443 reachable"
                $tcp.Close()
            } else {
                Report "Databricks endpoint ($dbHost)" "WARN" "TCP 443 timeout (check proxy)"
            }
        } catch {
            Report "Databricks endpoint ($dbHost)" "WARN" "TCP connect failed"
        }
    } else {
        Report "Databricks endpoint" "WARN" "baseUrl not found in config"
    }
} catch {
    Report "Databricks endpoint" "WARN" "unexpected: $($_.Exception.Message)"
}

# --- 10. Gateway control UI ---
if ($gatewayUp) {
    try {
        $resp = Invoke-WebRequest -Uri "http://127.0.0.1:18789/" -TimeoutSec 5 -UseBasicParsing
        if ($resp.StatusCode -eq 200 -and $resp.Content -match "OpenClaw") {
            Report "Gateway control UI" "OK" "HTTP 200, serves UI"
        } else {
            Report "Gateway control UI" "WARN" "HTTP $($resp.StatusCode) without OpenClaw marker"
        }
    } catch {
        Report "Gateway control UI" "WARN" "probe failed"
    }
}

# --- 11. Exec policy ---
$approvalOut = & openclaw approvals get 2>&1 | Out-String
$approvalFlat = ($approvalOut -replace '\s+', ' ')
if ($approvalFlat -match "Effective\s+security=full\s+ask=off" -or $approvalFlat -match "security=full.*ask=off.*Effective") {
    Report "Exec policy" "WARN" "security=full ask=off (ok because Telegram is allowlisted to your ID)"
} elseif ($approvalFlat -match "security=allowlist") {
    Report "Exec policy" "OK" "allowlist mode"
} elseif ($approvalFlat -match "security=full" -and $approvalFlat -match "ask=off") {
    Report "Exec policy" "WARN" "security=full ask=off (ok because Telegram is allowlisted to your ID)"
} else {
    Report "Exec policy" "WARN" "unexpected; run: openclaw approvals get"
}

# --- 12. Git repo (this desktop dir) ---
$gitOut = & git -C "$PSScriptRoot" rev-parse --abbrev-ref HEAD 2>&1
if ($LASTEXITCODE -eq 0) {
    $branch = $gitOut.Trim()
    $aheadBehind = & git -C "$PSScriptRoot" status -sb 2>&1 | Select-Object -First 1
    Report "Git repo ($branch)" "OK" $aheadBehind
} else {
    Report "Git repo" "WARN" "not a git worktree"
}

Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor Cyan
Write-Host ("  OK:   {0}" -f $script:pass) -ForegroundColor Green
Write-Host ("  WARN: {0}" -f $script:warn) -ForegroundColor Yellow
Write-Host ("  FAIL: {0}" -f $script:fail) -ForegroundColor Red
Write-Host ""
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
