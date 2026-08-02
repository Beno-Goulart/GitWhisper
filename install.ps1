$ErrorActionPreference = "Stop"

$gitWhisperDir = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not (Test-Path "$gitWhisperDir\gitwhisper.ps1")) {
    Write-Host "Error: gitwhisper.ps1 not found in $gitWhisperDir" -ForegroundColor Red
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
function gitwhisper { & "$gitWhisperDir\gitwhisper.ps1" @args }
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
Write-Host "    gitwhisper            " -ForegroundColor Cyan -NoNewline
Write-Host "- unified command (commit, undo, changelog, release, pr)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Usage: gitwhisper [commit|undo|amend|changelog|release|pr|help]" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Restart your terminal or run:" -ForegroundColor Yellow
Write-Host "    . `$PROFILE" -ForegroundColor White
