# GitWhisper `release` command (PowerShell).

function Invoke-Release {
    param([string[]]$ExtraArgs)

    $push = $false
    $publishGh = $false
    $forceType = ""
    $versionOverride = ""

    for ($i = 0; $i -lt $ExtraArgs.Count; $i++) {
        switch -Regex ($ExtraArgs[$i]) {
            "^(--push|-Push)$" { $push = $true }
            "^(--github|--gh|-Github)$" { $publishGh = $true }
            "^(--major|-Major)$" { $forceType = "major" }
            "^(--minor|-Minor)$" { $forceType = "minor" }
            "^(--patch|-Patch)$" { $forceType = "patch" }
            "^(--version|-Version)$" {
                if ($i + 1 -lt $ExtraArgs.Count) { $versionOverride = $ExtraArgs[$i + 1]; $i++ }
            }
        }
    }

    $status = git status --porcelain --untracked-files=no
    if ($status) {
        Write-Host ""
        Write-Host "  Working tree has uncommitted changes." -ForegroundColor Yellow
        $cont = Read-Host "  Continue anyway? (y/n)"
        if ($cont -ne "y" -and $cont -ne "Y") {
            Write-Host ""
            Write-Host "  Cancelled." -ForegroundColor Yellow
            exit 0
        }
    }

    $lastTag = ""
    try {
        $lastTag = git describe --tags --abbrev=0 2>&1
        if ($LASTEXITCODE -ne 0) { $lastTag = "" }
    } catch { $lastTag = "" }

    if ($lastTag) {
        try { $log = git log "$lastTag..HEAD" --pretty=format:"%H|%s|%ad|%an|%ae" --date=short 2>$null }
        catch { $log = "" }
    } else {
        Write-Host ""
        Write-Host "  No tags found. Releasing from the beginning of history." -ForegroundColor Yellow
        try { $log = git log --pretty=format:"%H|%s|%ad|%an|%ae" --date=short 2>$null }
        catch { $log = "" }
    }

    if (-not $log) {
        Write-Host "No commits to release." -ForegroundColor Yellow
        exit 0
    }

    $types = @{
        "feat"     = @{ Title = "Features";       Commits = @() }
        "fix"      = @{ Title = "Bug Fixes";       Commits = @() }
        "perf"     = @{ Title = "Performance";     Commits = @() }
        "refactor" = @{ Title = "Refactoring";     Commits = @() }
        "docs"     = @{ Title = "Documentation";   Commits = @() }
        "test"     = @{ Title = "Tests";           Commits = @() }
        "build"    = @{ Title = "Build";           Commits = @() }
        "ci"       = @{ Title = "CI/CD";           Commits = @() }
        "chore"    = @{ Title = "Chores";          Commits = @() }
        "style"    = @{ Title = "Style";           Commits = @() }
        "revert"   = @{ Title = "Reverts";         Commits = @() }
    }

    $allCommits = @()
    $hasBreaking = $false

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

            if ($message -match "!" -or $message -match "BREAKING CHANGE") {
                $hasBreaking = $true
            }

            $pr = ""
            $prMatch = [regex]::Match($desc, "\(#(\d+)\)\s*$")
            if ($prMatch.Success) {
                $pr = $prMatch.Groups[1].Value
                $desc = $desc.Substring(0, $prMatch.Index).TrimEnd()
            }

            $commitObj = @{
                Hash = $shortHash
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
            $allCommits += $commitObj
        }
    }

    if ($allCommits.Count -eq 0) {
        Write-Host "No conventional commits found since last release." -ForegroundColor Yellow
        exit 0
    }

    if ($lastTag) {
        $currentVersion = $lastTag -replace "^v", ""
    } else {
        $currentVersion = "0.1.0"
    }

    if ($versionOverride) {
        $newVersion = $versionOverride -replace "^v", ""
    } else {
        $parts = $currentVersion -split "\."
        $major = [int]$parts[0]
        $minor = [int]$parts[1]
        $patch = [int]$parts[2]
        switch ($forceType) {
            "major" { $newVersion = "$($major + 1).0.0" }
            "minor" { $newVersion = "$major.$($minor + 1).0" }
            "patch" { $newVersion = "$major.$minor.$($patch + 1)" }
            default {
                if ($hasBreaking) { $newVersion = "$($major + 1).0.0" }
                elseif ($types["feat"].Commits.Count -gt 0) { $newVersion = "$major.$($minor + 1).0" }
                else { $newVersion = "$major.$minor.$($patch + 1)" }
            }
        }
    }

    $tagName = "v$newVersion"

    $existingTag = git tag -l $tagName
    if ($existingTag) {
        Write-Host "Tag $tagName already exists." -ForegroundColor Red
        exit 1
    }

    $today = Get-Date -Format "yyyy-MM-dd"

    $notes = Build-ReleaseNotes -Types $types -AllCommits $allCommits
    $section = "## [$newVersion]($today)`n`n$notes"

    $changelogFile = "CHANGELOG.md"
    $existingContent = ""
    if (Test-Path $changelogFile) {
        $existingContent = Get-Content $changelogFile -Raw
    }

    if ($existingContent -and $existingContent -match "## \[") {
        $idx = $existingContent.IndexOf("## [")
        $newContent = $existingContent.Substring(0, $idx) + $section + "`n" + $existingContent.Substring($idx)
    } else {
        $header = @"
# Changelog

All notable changes to this project will be documented in this file.

Format: [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/)

"@
        $newContent = $header + "`n" + $section
    }

    Write-Host ""
    Write-Host "=== Release preview ===" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Version:  $newVersion" -ForegroundColor White
    Write-Host "  Commits:  $($allCommits.Count)" -ForegroundColor White
    Write-Host "  Breaking: $hasBreaking" -ForegroundColor White
    Write-Host ""
    Write-Host "=== Changelog section ===" -ForegroundColor Cyan
    ($section -split "`n") | ForEach-Object { Write-Host "  $_" }

    if ($DryRun) {
        Write-Host ""
        Write-Host "  [DRY-RUN] Release skipped. No changes made." -ForegroundColor DarkGray
        exit 0
    }

    Write-Host ""
    $confirm = Read-Host "  Proceed with release v$newVersion? (y/n)"
    if ($confirm -ne "y" -and $confirm -ne "Y") {
        Write-Host ""
        Write-Host "  Cancelled." -ForegroundColor Yellow
        exit 0
    }

    Write-Host ""
    Write-Host "  Writing CHANGELOG.md..." -ForegroundColor Cyan
    $newContent | Out-File -FilePath $changelogFile -Encoding UTF8
    git add $changelogFile

    $tempFile = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($tempFile, "chore(release): $tagName`n`n$notes", [System.Text.UTF8Encoding]::new($false))
    git commit -F $tempFile
    Remove-Item $tempFile -Force -ErrorAction SilentlyContinue

    if ($LASTEXITCODE -ne 0) {
        Write-Host "  Release commit failed." -ForegroundColor Red
        exit 1
    }

    $headShort = git rev-parse --short HEAD
    $tempTag = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($tempTag, "$headShort`n`n$notes", [System.Text.UTF8Encoding]::new($false))
    git tag -a $tagName -F $tempTag
    Remove-Item $tempTag -Force -ErrorAction SilentlyContinue

    if ($LASTEXITCODE -ne 0) {
        Write-Host "  Tag creation failed." -ForegroundColor Red
        exit 1
    }

    Write-Host ""
    Write-Host "  Release $tagName created!" -ForegroundColor Green

    if ($push) {
        $pushChoice = "y"
    } else {
        $pushChoice = Read-Host "  Push commit and tag? (y/n)"
    }
    if ($pushChoice -eq "y" -or $pushChoice -eq "Y") {
        Write-Host ""
        Write-Host "  Pushing..." -ForegroundColor Cyan
        git push
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  Push failed." -ForegroundColor Red
            exit 1
        }
        git push origin $tagName
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  Tag push failed." -ForegroundColor Red
            exit 1
        }
        Write-Host "  Pushed successfully!" -ForegroundColor Green
    }

    $ghAvailable = Get-Command gh -ErrorAction SilentlyContinue
    if ($ghAvailable) {
        if ($publishGh -or $push) {
            $ghChoice = "y"
        } else {
            Write-Host ""
            $ghChoice = Read-Host "  Publish GitHub Release? (y/n)"
        }
        if ($ghChoice -eq "y" -or $ghChoice -eq "Y") {
            Write-Host ""
            Write-Host "  Publishing GitHub Release $tagName..." -ForegroundColor Cyan
            $tempNotes = [System.IO.Path]::GetTempFileName()
            [System.IO.File]::WriteAllText($tempNotes, "$headShort`n`n$notes", [System.Text.UTF8Encoding]::new($false))
            gh release create $tagName --title $tagName --notes-file $tempNotes
            Remove-Item $tempNotes -Force -ErrorAction SilentlyContinue
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  GitHub Release failed." -ForegroundColor Red
            } else {
                Write-Host "  GitHub Release published!" -ForegroundColor Green
            }
        }
    } elseif ($publishGh) {
        Write-Host ""
        Write-Host "  gh CLI not found. Install it to publish GitHub Releases." -ForegroundColor Yellow
    }
}
