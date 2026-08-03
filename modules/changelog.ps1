# GitWhisper `changelog` command (PowerShell).

function Invoke-Changelog {
    param(
        [switch]$SinceTag,
        [int]$Limit = 50
    )

    if ($SinceTag) {
        $lastTag = ""
        try {
            $lastTag = git describe --tags --abbrev=0 2>&1
            if ($LASTEXITCODE -ne 0) { $lastTag = "" }
        } catch { $lastTag = "" }

        if ($lastTag) {
            try { $log = git log "$lastTag..HEAD" --pretty=format:"%H|%s|%ad|%an|%ae" --date=short 2>$null }
            catch { $log = "" }
        } else {
            Write-Host "No tags found. Showing all commits." -ForegroundColor Yellow
            try { $log = git log --pretty=format:"%H|%s|%ad|%an|%ae" --date=short -n $Limit 2>$null }
            catch { $log = "" }
        }
    } else {
        try { $log = git log --pretty=format:"%H|%s|%ad|%an|%ae" --date=short -n $Limit 2>$null }
        catch { $log = "" }
    }

    if (-not $log) {
        Write-Host "No commits found." -ForegroundColor Yellow
        exit 0
    }

    $types = Get-ReleaseTypes

    $allCommits = @()
    $dates = @{}

    foreach ($line in ($log -split "`n")) {
        if (-not $line -or $line -eq "") { continue }

        $parts = $line -split "\|", 5
        if ($parts.Count -lt 5) { continue }

        $hash = $parts[0].Trim()
        $message = $parts[1].Trim()
        $date = $parts[2].Trim()
        $authorName = $parts[3].Trim()
        $authorEmail = $parts[4].Trim()

        $typeMatch = [regex]::Match($message, "(\w+)(?:\(([^)]+)\))?[!]?:\s*(.+)")
        if ($typeMatch.Success) {
            $type = $typeMatch.Groups[1].Value.ToLower()
            $scope = $typeMatch.Groups[2].Value
            $desc = $typeMatch.Groups[3].Value
            $shortHash = $hash.Substring(0, [Math]::Min(7, $hash.Length))

            $pr = ""
            $prMatch = [regex]::Match($desc, "\(#(\d+)\)\s*$")
            if ($prMatch.Success) {
                $pr = $prMatch.Groups[1].Value
                $desc = $desc.Substring(0, $prMatch.Index).TrimEnd()
            }

            $commitObj = @{
                Hash = $shortHash
                Message = $message
                Scope = $scope
                Description = $desc
                Type = $type
                Date = $date
                Pr = $pr
                AuthorUser = (Get-GithubUsername -Name $authorName -Email $authorEmail)
            }

            if ($types.ContainsKey($type)) {
                $types[$type].Commits += $commitObj
            } else {
                $types["chore"].Commits += $commitObj
            }

            if (-not $dates.ContainsKey($date)) {
                $dates[$date] = @()
            }
            $dates[$date] += $commitObj

            $allCommits += $commitObj
        }
    }

    if ($allCommits.Count -eq 0) {
        Write-Host "No conventional commits found." -ForegroundColor Yellow
        exit 0
    }

    $lastTag = ""
    try {
        $lastTag = git describe --tags --abbrev=0 2>&1
        if ($LASTEXITCODE -ne 0) { $lastTag = "" }
    } catch { $lastTag = "" }

    if ($lastTag) {
        $currentVersion = $lastTag -replace "^v", ""
    } else {
        $currentVersion = "0.1.0"
    }

    $hasFeat = $types["feat"].Commits.Count -gt 0
    $hasFix = $types["fix"].Commits.Count -gt 0
    $hasBreaking = $allCommits | Where-Object { $_.Message -match "!" }

    if ($hasBreaking) {
        $parts = $currentVersion -split "\."
        $newVersion = "$([int]$parts[0] + 1).0.0"
    } elseif ($hasFeat) {
        $parts = $currentVersion -split "\."
        $newVersion = "$($parts[0]).$([int]$parts[1] + 1).0"
    } elseif ($hasFix) {
        $parts = $currentVersion -split "\."
        $newVersion = "$($parts[0]).$($parts[1]).$([int]$parts[2] + 1)"
    } else {
        $newVersion = $currentVersion
    }

    $today = Get-Date -Format "yyyy-MM-dd"

    $changelog = @"
# Changelog

All notable changes to this project will be documented in this file.

Format: [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/)

"@

    $changelog += "## [$newVersion]($today)`n`n"

    $changelog += (Build-ReleaseNotes -Types $types -AllCommits $allCommits)

    $changelog | Out-File -FilePath "CHANGELOG.md" -Encoding UTF8

    Write-Host "=== Changelog generated ===" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Version: $newVersion" -ForegroundColor White
    Write-Host "  Commits: $($allCommits.Count)" -ForegroundColor White
    Write-Host "  File:    CHANGELOG.md" -ForegroundColor White
    Write-Host ""

    Write-Host "=== Preview ===" -ForegroundColor Cyan
    Write-Host ""
    $lines = $changelog -split "`n" | Select-Object -First 30
    foreach ($line in $lines) {
        Write-Host "  $line"
    }
    if (($changelog -split "`n").Count -gt 30) {
        Write-Host "  ..." -ForegroundColor DarkGray
    }
}
