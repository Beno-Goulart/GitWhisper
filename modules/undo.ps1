# GitWhisper `undo` command (PowerShell).

function Invoke-Undo {
    $lastMsg = git log -1 --format="%s" 2>$null
    if (-not $lastMsg) {
        Write-Host "Nothing to undo." -ForegroundColor Yellow
        exit 0
    }

    Write-Host ""
    Write-Host "=== Undo last commit ===" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Last commit: $lastMsg" -ForegroundColor White
    Write-Host ""
    Write-Host "  [1] Soft reset  — keeps changes staged" -ForegroundColor White
    Write-Host "  [2] Mixed reset — unstages changes (keeps files)" -ForegroundColor White
    Write-Host "  [0] Cancel" -ForegroundColor DarkGray
    Write-Host ""

    $resetChoice = Read-Host "  Select (0-2)"

    switch ($resetChoice) {
        "1" {
            git reset --soft HEAD~1
            if ($LASTEXITCODE -eq 0) {
                Write-Host ""
                Write-Host "  Undone (soft). Changes are still staged." -ForegroundColor Green
            } else {
                Write-Host ""
                Write-Host "  Undo failed." -ForegroundColor Red
            }
        }
        "2" {
            git reset HEAD~1
            if ($LASTEXITCODE -eq 0) {
                Write-Host ""
                Write-Host "  Undone (mixed). Changes are unstaged." -ForegroundColor Green
            } else {
                Write-Host ""
                Write-Host "  Undo failed." -ForegroundColor Red
            }
        }
        default {
            Write-Host ""
            Write-Host "  Cancelled." -ForegroundColor Yellow
        }
    }
}
