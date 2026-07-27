$ErrorActionPreference = "Stop"

$gitWhisperDir = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not (Test-Path "$gitWhisperDir\commit-msg.ps1")) {
    Write-Host "Error: commit-msg.ps1 not found in $gitWhisperDir" -ForegroundColor Red
    exit 1
}

$profilePath = $PROFILE
$profileDir = Split-Path -Parent $profilePath

if (-not (Test-Path $profileDir)) {
    New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
}

if (-not (Test-Path $profilePath)) {
    New-Item -ItemType File -Path $profilePath -Force | Out-Null
}

$marker = "# >>> GitWhisper >>>"
$existing = Get-Content $profilePath -Raw -ErrorAction SilentlyContinue

if ($existing -and $existing.Contains($marker)) {
    Write-Host "GitWhisper is already installed in your profile." -ForegroundColor Yellow
    Write-Host "Restart your terminal or run: . `$PROFILE" -ForegroundColor Cyan
    exit 0
}

$block = @"

$marker
function commit-msg { & "$gitWhisperDir\commit-msg.ps1" @args }
function commit-msg-undo { & "$gitWhisperDir\commit-msg.ps1" -Undo }
function changelog { & "$gitWhisperDir\changelog.ps1" @args }
# <<< GitWhisper <<<
"@

Add-Content -Path $profilePath -Value $block

Write-Host ""
Write-Host "=== GitWhisper installed ===" -ForegroundColor Green
Write-Host ""
Write-Host "  Functions added to:" -ForegroundColor White
Write-Host "  $profilePath" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Available commands:" -ForegroundColor White
Write-Host "    commit-msg        " -ForegroundColor Cyan -NoNewline
Write-Host "- generate commit message" -ForegroundColor DarkGray
Write-Host "    commit-msg-undo   " -ForegroundColor Cyan -NoNewline
Write-Host "- undo last commit" -ForegroundColor DarkGray
Write-Host "    changelog         " -ForegroundColor Cyan -NoNewline
Write-Host "- generate changelog" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Restart your terminal or run:" -ForegroundColor Yellow
Write-Host "    . `$PROFILE" -ForegroundColor White
Write-Host ""
