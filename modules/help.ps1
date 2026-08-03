# GitWhisper `help` command (PowerShell).

function Show-Help {
    Write-Host ""
    Write-Host "=== GitWhisper ===" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Usage:" -ForegroundColor White
    Write-Host "    gitwhisper               - generate commit message" -ForegroundColor Cyan
    Write-Host "    gitwhisper commit        - generate commit message" -ForegroundColor Cyan
    Write-Host "    gitwhisper undo          - undo last commit" -ForegroundColor Cyan
    Write-Host "    gitwhisper amend        - amend last commit" -ForegroundColor Cyan
    Write-Host "    gitwhisper changelog     - generate changelog" -ForegroundColor Cyan
    Write-Host "    gitwhisper release       - create release (changelog + tag)" -ForegroundColor Cyan
    Write-Host "    gitwhisper release --push    - push commit and tag after release" -ForegroundColor Cyan
    Write-Host "    gitwhisper release --github  - also publish a GitHub Release (gh CLI)" -ForegroundColor Cyan
    Write-Host "    gitwhisper release --minor   - force minor bump (major/minor/patch)" -ForegroundColor Cyan
    Write-Host "    gitwhisper release --version 1.2.3 - use explicit version" -ForegroundColor Cyan
    Write-Host "    gitwhisper pr            - generate PR description" -ForegroundColor Cyan
    Write-Host "    gitwhisper pr --base main   - specify base branch" -ForegroundColor Cyan
    Write-Host "    gitwhisper pr create        - generate and create PR" -ForegroundColor Cyan
    Write-Host "    gitwhisper init         - create .gitwhisperconfig and install git hooks" -ForegroundColor Cyan
    Write-Host "    gitwhisper init --force - overwrite existing config and hooks" -ForegroundColor Cyan
    Write-Host "    gitwhisper suggest      - print suggested message (used by hooks)" -ForegroundColor Cyan
    Write-Host "    gitwhisper --dry-run     - show message without committing" -ForegroundColor Cyan
    Write-Host ""
    exit 0
}
