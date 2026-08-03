# GitWhisper `amend` command (PowerShell).

function Invoke-Amend {
    $lastMsg = git log -1 --format="%s" 2>$null
    $lastBody = git log -1 --format="%b" 2>$null
    if (-not $lastMsg) {
        Write-Host "No commits to amend." -ForegroundColor Yellow
        exit 0
    }

    Write-Host ""
    Write-Host "=== Amend last commit ===" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Last message: $lastMsg" -ForegroundColor White
    if ($lastBody) {
        Write-Host "  Body:" -ForegroundColor DarkGray
        $lastBody -split "`n" | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    }
    Write-Host ""

    $tempFile = [System.IO.Path]::GetTempFileName()
    if ($lastBody) {
        "$lastMsg`n`n$lastBody" | Out-File -FilePath $tempFile -Encoding UTF8
    } else {
        "$lastMsg`n" | Out-File -FilePath $tempFile -Encoding UTF8
    }

    Write-Host "  Opening editor to edit message..." -ForegroundColor Yellow
    git commit --amend -F $tempFile
    Remove-Item $tempFile -Force -ErrorAction SilentlyContinue

    if ($LASTEXITCODE -eq 0) {
        Write-Host ""
        Write-Host "  Commit amended!" -ForegroundColor Green
        $push = Read-Host "  Force push? (y/n)"
        if ($push -eq "y" -or $push -eq "Y") {
            Write-Host ""
            Write-Host "  Force pushing..." -ForegroundColor Cyan
            git push --force-with-lease
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  Pushed successfully!" -ForegroundColor Green
            } else {
                Write-Host "  Push failed." -ForegroundColor Red
            }
        }
    } else {
        Write-Host ""
        Write-Host "  Amend failed." -ForegroundColor Red
    }
}
