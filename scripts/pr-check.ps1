# 一键看 upstream PR #68318（Groq transcribe fix）的 CI / review 状态。
# 用法：.\scripts\pr-check.ps1

$ErrorActionPreference = "Stop"
$PR = 68318
$REPO = "openclaw/openclaw"
$tmp = Join-Path $env:TEMP "pr-$PR.json"

gh pr view $PR --repo $REPO --json state,mergeStateStatus,statusCheckRollup,reviews,comments | Out-File $tmp -Encoding utf8
$j = Get-Content $tmp -Raw | ConvertFrom-Json

Write-Host "PR #$PR  state=$($j.state)  mergeState=$($j.mergeStateStatus)" -ForegroundColor Cyan
Write-Host "URL: https://github.com/$REPO/pull/$PR" -ForegroundColor DarkGray
Write-Host ""

Write-Host "-- checks --" -ForegroundColor Yellow
$bad = $j.statusCheckRollup | Where-Object { $_.conclusion -ne 'SUCCESS' -and $_.conclusion -ne 'SKIPPED' }
if (-not $bad) {
    Write-Host "  all green (or in-progress)" -ForegroundColor Green
} else {
    $bad | ForEach-Object {
        $color = if ($_.conclusion -eq 'FAILURE') { 'Red' } else { 'Yellow' }
        Write-Host ("  {0,-42}  {1,-12}  {2}" -f $_.name, ($_.status + $_.state), $_.conclusion) -ForegroundColor $color
    }
}

Write-Host ""
Write-Host "-- reviews ($($j.reviews.Count)) --" -ForegroundColor Yellow
if ($j.reviews.Count -eq 0) {
    Write-Host "  (none yet)" -ForegroundColor DarkGray
} else {
    $j.reviews | ForEach-Object { Write-Host "  $($_.author.login) [$($_.state)]: $($_.body.Substring(0, [Math]::Min(200, $_.body.Length)))" }
}

Write-Host ""
Write-Host "-- comments ($($j.comments.Count)) --" -ForegroundColor Yellow
$j.comments | ForEach-Object {
    $body = $_.body.Substring(0, [Math]::Min(200, $_.body.Length)).Replace("`n", " ")
    Write-Host "  $($_.author.login): $body" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "To see a specific failed job's log:" -ForegroundColor DarkGray
Write-Host "  gh run view --repo $REPO --job <JOB_ID> --log-failed | Select-String -Pattern 'FAIL|Error' -Context 2" -ForegroundColor DarkGray
