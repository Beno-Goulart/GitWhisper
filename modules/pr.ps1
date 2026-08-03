# GitWhisper `pr` command (PowerShell).

function Invoke-Pr {
    param(
        [string]$BaseBranch = "",
        [switch]$CreatePR
    )

    $branch = git symbolic-ref --short HEAD 2>$null
    if (-not $branch) {
        Write-Host "Error: Not on a branch." -ForegroundColor Red
        exit 1
    }

    if (-not $BaseBranch) {
        foreach ($try in @("main", "master", "develop")) {
            $exists = git rev-parse --verify $try 2>$null
            if ($exists) { $BaseBranch = $try; break }
        }
        if (-not $BaseBranch) {
            Write-Host "Error: Could not detect base branch. Use --base." -ForegroundColor Red
            exit 1
        }
    }

    $mergeBase = git merge-base $BaseBranch $branch 2>$null
    if (-not $mergeBase) {
        Write-Host "Error: Branches $BaseBranch and $branch have no common ancestor." -ForegroundColor Red
        exit 1
    }

    try {
        $log = git log "$mergeBase..$branch" --pretty=format:"%H|%s|%ad" --date=short --no-merges 2>$null
    } catch {
        $log = ""
    }
    if (-not $log) {
        Write-Host "No commits found between $BaseBranch and $branch." -ForegroundColor Yellow
        exit 0
    }

    $emojiMap = @{}
    $emojiMap["feat"]     = [char]::ConvertFromUtf32(0x2728)
    $emojiMap["fix"]      = [char]::ConvertFromUtf32(0x1F41B)
    $emojiMap["docs"]     = [char]::ConvertFromUtf32(0x1F4DD)
    $emojiMap["style"]    = [char]::ConvertFromUtf32(0x1F484)
    $emojiMap["refactor"] = [char]::ConvertFromUtf32(0x267B)
    $emojiMap["perf"]     = [char]::ConvertFromUtf32(0x26A1)
    $emojiMap["test"]     = [char]::ConvertFromUtf32(0x2705)
    $emojiMap["build"]    = [char]::ConvertFromUtf32(0x1F527)
    $emojiMap["ci"]       = [char]::ConvertFromUtf32(0x1F477)
    $emojiMap["chore"]    = [char]::ConvertFromUtf32(0x1F528)
    $emojiMap["revert"]   = [char]::ConvertFromUtf32(0x23EA)

    $types = @{
        "feat"     = @{ Emoji = $emojiMap["feat"];     Title = "Features";       Commits = @() }
        "fix"      = @{ Emoji = $emojiMap["fix"];      Title = "Bug Fixes";       Commits = @() }
        "perf"     = @{ Emoji = $emojiMap["perf"];     Title = "Performance";     Commits = @() }
        "refactor" = @{ Emoji = $emojiMap["refactor"]; Title = "Refactoring";     Commits = @() }
        "docs"     = @{ Emoji = $emojiMap["docs"];     Title = "Documentation";   Commits = @() }
        "test"     = @{ Emoji = $emojiMap["test"];     Title = "Tests";           Commits = @() }
        "build"    = @{ Emoji = $emojiMap["build"];    Title = "Build";           Commits = @() }
        "ci"       = @{ Emoji = $emojiMap["ci"];       Title = "CI/CD";           Commits = @() }
        "chore"    = @{ Emoji = $emojiMap["chore"];    Title = "Chores";          Commits = @() }
        "style"    = @{ Emoji = $emojiMap["style"];    Title = "Style";           Commits = @() }
        "revert"   = @{ Emoji = $emojiMap["revert"];   Title = "Reverts";         Commits = @() }
    }

    $allCommits = @()

    foreach ($line in ($log -split "`n")) {
        if (-not $line) { continue }
        $parts = $line -split "\|", 3
        if ($parts.Count -lt 3) { continue }
        $hash = $parts[0].Trim()
        $message = $parts[1].Trim()
        $date = $parts[2].Trim()

        $match = [regex]::Match($message, "(\w+)(?:\(([^)]+)\))?[!]?:\s*(.+)")
        if ($match.Success) {
            $type = $match.Groups[1].Value.ToLower()
            $scope = $match.Groups[2].Value
            $desc = $match.Groups[3].Value
            $shortHash = $hash.Substring(0, 7)
            $commitObj = @{ Hash = $shortHash; Scope = $scope; Description = $desc; Date = $date }
            if ($types.ContainsKey($type)) {
                $types[$type].Commits += $commitObj
            } else {
                $types["chore"].Commits += $commitObj
            }
            $allCommits += $commitObj
        }
    }

    if ($allCommits.Count -eq 0) {
        Write-Host "No conventional commits found." -ForegroundColor Yellow
        exit 0
    }

    $summaryParts = @()
    if ($types["feat"].Commits.Count -gt 0) {
        $featDesc = ($types["feat"].Commits | ForEach-Object { $_.Description } | Select-Object -First 3) -join ", "
        $summaryParts += "adds $featDesc"
    }
    if ($types["fix"].Commits.Count -gt 0) {
        $fixDesc = ($types["fix"].Commits | ForEach-Object { $_.Description } | Select-Object -First 2) -join ", "
        $summaryParts += "fixes $fixDesc"
    }
    if ($types["refactor"].Commits.Count -gt 0) {
        $summaryParts += "refactors codebase"
    }
    $summary = if ($summaryParts) { ($summaryParts -join "; ").Substring(0, 1).ToUpper() + ($summaryParts -join "; ").Substring(1) } else { "Updates codebase" }

    $prBody = @"
## Summary
$summary

## Changes
"@

    foreach ($type in @("feat", "fix", "perf", "refactor", "docs", "test", "build", "ci", "chore", "style", "revert")) {
        $td = $types[$type]
        if ($td.Commits.Count -gt 0) {
            $prBody += "`n### $($td.Title)`n"
            foreach ($c in $td.Commits) {
                $emoji = $td.Emoji
                if ($c.Scope) {
                    $prBody += "`n- $emoji **$($c.Scope):** $($c.Description) ($($c.Hash))"
                } else {
                    $prBody += "`n- $emoji $($c.Description) ($($c.Hash))"
                }
            }
        }
    }

    $prBody += "`n"
    $prBody += "---"
    $prBody += "`n**Branch:** $branch → $BaseBranch"
    $prBody += "`n**Commits:** $($allCommits.Count)"

    Write-Host ""
    Write-Host "=== PR Description ===" -ForegroundColor Green
    Write-Host ""
    $prBody -split "`n" | ForEach-Object { Write-Host "  $_" }

    if (-not $CreatePR) {
        Write-Host ""
        $copy = Read-Host "  Copy to clipboard? (y/n)"
        if ($copy -eq "y" -or $copy -eq "Y") {
            $prBody | Set-Clipboard
            Write-Host ""
            Write-Host "  Copied to clipboard!" -ForegroundColor Green
        }
    }

    Write-Host ""
    if ($CreatePR) {
        $create = "y"
    } else {
        $create = Read-Host "  Create PR now? (y/n)"
    }
    if ($create -eq "y" -or $create -eq "Y") {
        $title = $allCommits[0].Description
        if ($allCommits.Count -gt 1) {
            $title = "$($types["feat"].Commits.Count) features, $($types["fix"].Commits.Count) fixes"
        }
        try {
            $ghCheck = Get-Command gh -ErrorAction Stop
            $prBody | gh pr create --title "$title" --body - --base $BaseBranch --head $branch
            if ($LASTEXITCODE -eq 0) {
                Write-Host ""
                Write-Host "  PR created successfully!" -ForegroundColor Green
            } else {
                Write-Host ""
                Write-Host "  PR creation failed." -ForegroundColor Red
            }
        } catch {
            Write-Host ""
            Write-Host "  gh CLI not found. Opening browser..." -ForegroundColor Yellow
            $url = "https://github.com/$(git remote get-url origin 2>$null | ForEach-Object { $_ -replace '.*[:/]([^/]+/[^/.]+)(\.git)?$', '$1' })/compare/$BaseBranch...$branch"
            Start-Process $url
        }
    }
}
