# GitWhisper `commit` command (PowerShell).

function Edit-MessageBody {
    param([string[]]$Body)

    $editedBody = @()
    $i = 0
    while ($i -lt $Body.Count) {
        Write-Host ""
        Write-Host "  [$($i + 1)] $($Body[$i])" -ForegroundColor DarkGray
        $editLine = Read-Host "  Edit (Enter=keep, '.'=delete, '+$=add after)"
        if ($editLine -eq ".") {
            $i++
            continue
        }
        if ($editLine -eq "+") {
            $editedBody += $Body[$i]
            $newLine = Read-Host "  New line"
            if ($newLine) { $editedBody += $newLine }
            $i++
            continue
        }
        if ($editLine -eq "") {
            $editedBody += $Body[$i]
        } else {
            $editedBody += $editLine
        }
        $i++
    }
    Write-Host ""
    $editedBody
}

function Invoke-Commit {
    $unstaged = git diff --name-only
    $untracked = git ls-files --others --exclude-standard

    if ($unstaged -or $untracked) {
        Write-Host ""
        Write-Host "  Unstaged changes detected." -ForegroundColor Yellow
        $stageAll = Read-Host "  Stage all changes? (y/n)"
        if ($stageAll -eq "y" -or $stageAll -eq "Y") {
            git add -A
            Write-Host "  All changes staged." -ForegroundColor Green
        }
    }

    $diffIndex = git diff --staged --name-status
    $diffStat = git diff --staged --stat
    $diffContent = (@(git diff --staged) -join "`n")

    if (-not $diffIndex) {
        Write-Host "No changes found." -ForegroundColor Yellow
        exit 0
    }

    Write-Host "`n=== Changes detected ===" -ForegroundColor Cyan
    Write-Host $diffStat
    Write-Host ""

    $lines = $diffIndex -split "`n"

    $added    = @()
    $modified = @()
    $deleted  = @()
    $renamed  = @()

    foreach ($line in $lines) {
        $parts = $line -split "`t"
        $status = $parts[0].Trim()
        $file   = $parts[-1].Trim()

        switch -Regex ($status) {
            "^A"  { $added += $file }
            "^M"  { $modified += $file }
            "^D"  { $deleted += $file }
            "^R"  { $renamed += $file }
        }
    }

    $allFiles   = $added + $modified
    $addedLower = $allFiles | ForEach-Object { $_.ToLower() }
    $deletedLower = $deleted | ForEach-Object { $_.ToLower() }

    $selfScript = $allFiles | Where-Object { $_ -match "gitwhisper|modules/|^install\.(ps1|sh)$" }

    $scope = Get-Scope -Files $allFiles
    if (-not $scope) {
        $scope = Get-BranchScope
    }
    $result = Get-CommitType -Added $added -Modified $modified -Deleted $deleted -AddedLower $addedLower -ModifiedLower ($modified | ForEach-Object { $_.ToLower() }) -DeletedLower $deletedLower -DiffContent $diffContent -SelfScript:($selfScript.Count -gt 0)

    $type = $result.Type
    $desc = $result.Desc

    $addedLines = ($diffContent -split "`n" | Where-Object { $_ -match "^\+[^+]" }) -join "`n"
    $removedLines = ($diffContent -split "`n" | Where-Object { $_ -match "^-[^-]" }) -join "`n"

    if ($selfScript.Count -gt 0) {
        $addedLines   = Remove-LiteralStrings -Content $addedLines
        $removedLines = Remove-LiteralStrings -Content $removedLines
    }

    $detailParts = @()

    $newParams = [regex]::Matches($addedLines, 'param\(\s*\[.*?\]\s*\$+(\w+)')
    if ($newParams.Count -gt 0) {
        $names = ($newParams | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique) -join ", "
        $detailParts += "adds -$names parameter"
    }

    $newBashFlags = [regex]::Matches($addedLines, '"--?(\w+)"')
    if ($newBashFlags.Count -gt 0) {
        $names = ($newBashFlags | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -notmatch "^(y|n|yes|no)$" } | Select-Object -Unique) -join ", "
        if ($names) { $detailParts += "adds --$names flag" }
    }

    $addedFuncs = [regex]::Matches($addedLines, 'function\s+([\w-]+)\s*\{')
    if ($addedFuncs.Count -gt 0) {
        $names = ($addedFuncs | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique | Select-Object -First 3) -join ", "
        if ($names) { $detailParts += "adds $names function" }
    }

    $addedBashFuncs = [regex]::Matches($addedLines, '([\w_]+)\s*\(\)\s*\{')
    if ($addedBashFuncs.Count -gt 0) {
        $names = ($addedBashFuncs | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -notmatch "^(contains_pattern|count_matches)$" } | Select-Object -Unique | Select-Object -First 3) -join ", "
        if ($names) { $detailParts += "adds $names function" }
    }

    $hasHighPriority = $detailParts.Count -ge 2

    if (-not $hasHighPriority) {
        $gitOps = [regex]::Matches($addedLines, 'git\s+(reset|commit|push|pull|merge|rebase|stash|tag|branch|checkout|diff|log|status|add|rm|mv)')
        if ($gitOps.Count -gt 0) {
            $ops = ($gitOps | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique | Select-Object -First 3) -join ", "
            $detailParts += "adds git $ops"
        }
    }

    if (-not $hasHighPriority) {
        $writeHost = [regex]::Matches($addedLines, 'Write-Host\s+"([^"]{5,50})"')
        if ($writeHost.Count -gt 0) {
            $msgs = ($writeHost | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -notmatch "^(Error|Warning|Pushing|Committing|Select|Cancel)" } | ForEach-Object { $_ -replace '\s+', ' ' } | Select-Object -Unique | Select-Object -First 2) -join ", "
            if ($msgs) { $detailParts += "adds $msgs messages" }
        }
    }

    $addedImports = [regex]::Matches($addedLines, "(?:import|require)\s*\{?\s*([\w]+)")
    if ($addedImports.Count -gt 0) {
        $names = ($addedImports | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique | Select-Object -First 3) -join ", "
        $detailParts += "adds $names import"
    }

    $addedClasses = [regex]::Matches($addedLines, "(?:class)\s+(\w+)")
    if ($addedClasses.Count -gt 0) {
        $names = ($addedClasses | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique) -join ", "
        $detailParts += "adds $names class"
    }

    $addedRoutes = [regex]::Matches($addedLines, "(?:router|Route|path)\s*\(\s*['""]([^'""]+)")
    if ($addedRoutes.Count -gt 0) {
        $paths = ($addedRoutes | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique) -join ", "
        $detailParts += "adds $paths route"
    }

    $addedHooks = [regex]::Matches($addedLines, "(useState|useEffect|useContext|useReducer|useMemo|useCallback|useRef)\s*\(")
    if ($addedHooks.Count -gt 0) {
        $hookNames = ($addedLines | Select-String -Pattern "(\w+)\s*\(" | ForEach-Object { $_.Matches[0].Groups[1].Value } | Where-Object { $_ -match "^use" } | Select-Object -Unique | Select-Object -First 3) -join ", "
        if ($hookNames) { $detailParts += "adds $hookNames" }
    }

    if ($detailParts.Count -eq 0) {
        $scriptFiles = @()
        $docFiles = @()
        $configFiles = @()
        $otherFiles = @()

        foreach ($f in ($added + $modified)) {
            $ext = [System.IO.Path]::GetExtension($f).ToLower()
            $name = [System.IO.Path]::GetFileName($f).ToLower()
            if ($ext -match "\.(ps1|sh|py|rb|js|ts)$" -or $name -match "commit-msg|changelog") {
                $scriptFiles += [System.IO.Path]::GetFileNameWithoutExtension($f)
            }
            elseif ($ext -match "\.(md|mdx|rst|txt)$" -or $name -match "readme|changelog|contributing|license") {
                $docFiles += [System.IO.Path]::GetFileNameWithoutExtension($f)
            }
            elseif ($name -match "(package\.json|dockerfile|makefile|\.gitignore|\.editorconfig|tsconfig)") {
                $configFiles += [System.IO.Path]::GetFileNameWithoutExtension($f)
            }
            else {
                $otherFiles += [System.IO.Path]::GetFileNameWithoutExtension($f)
            }
        }

        $mixParts = @()
        if ($scriptFiles.Count -gt 0) { $mixParts += "scripts ($($scriptFiles -join ', '))" }
        if ($docFiles.Count -gt 0) { $mixParts += "docs ($($docFiles -join ', '))" }
        if ($configFiles.Count -gt 0) { $mixParts += "config ($($configFiles -join ', '))" }
        if ($otherFiles.Count -gt 0) { $mixParts += ($otherFiles | Select-Object -First 3) -join ", " }

        if ($mixParts.Count -gt 0) {
            $detailParts += "updates $($mixParts -join ' and ')"
        }
        elseif ($Deleted.Count -gt 0) {
            $delNames = ($Deleted | ForEach-Object { [System.IO.Path]::GetFileName($_) } | Select-Object -First 2) -join ", "
            $detailParts += "removes $delNames"
        }
    }

    $detailDesc = ($detailParts | Select-Object -First 2 | ForEach-Object { $_ -replace '\s{2,}', ' ' } | Select-Object -Unique) -join " and "

    $gitmoji = @{}
    $gitmoji["feat"]     = [char]::ConvertFromUtf32(0x2728)
    $gitmoji["fix"]      = [char]::ConvertFromUtf32(0x1F41B)
    $gitmoji["docs"]     = [char]::ConvertFromUtf32(0x1F4DD)
    $gitmoji["style"]    = [char]::ConvertFromUtf32(0x1F484)
    $gitmoji["refactor"] = [char]::ConvertFromUtf32(0x267B)
    $gitmoji["perf"]     = [char]::ConvertFromUtf32(0x26A1)
    $gitmoji["test"]     = [char]::ConvertFromUtf32(0x2705)
    $gitmoji["build"]    = [char]::ConvertFromUtf32(0x1F527)
    $gitmoji["ci"]       = [char]::ConvertFromUtf32(0x1F477)
    $gitmoji["chore"]    = [char]::ConvertFromUtf32(0x1F528)
    $gitmoji["revert"]   = [char]::ConvertFromUtf32(0x23EA)

    $emoji = $gitmoji[$type]

    if ($scope) {
        $simpleWithEmoji    = "$emoji ${type}(${scope}): $desc"
        $simpleWithoutEmoji = "${type}(${scope}): $desc"
        $detailWithEmoji    = "$emoji ${type}(${scope}): $detailDesc"
        $detailWithoutEmoji = "${type}(${scope}): $detailDesc"
    } else {
        $simpleWithEmoji    = "$emoji ${type}: $desc"
        $simpleWithoutEmoji = "${type}: $desc"
        $detailWithEmoji    = "$emoji ${type}: $detailDesc"
        $detailWithoutEmoji = "${type}: $detailDesc"
    }

    function Truncate-Msg {
        param([string]$Msg, [int]$MaxLen = 50)
        if ($Msg.Length -le $MaxLen) { return $Msg }
        $cut = $Msg.Substring(0, $MaxLen - 1)
        return $cut.TrimEnd() + "~"
    }

    Write-Host ""
    Write-Host "=== Choose your commit message ===" -ForegroundColor Green
    Write-Host ""
    Write-Host "  [1] $simpleWithEmoji" -ForegroundColor White
    Write-Host "  [2] $simpleWithoutEmoji" -ForegroundColor White
    Write-Host "  [3] $detailWithEmoji" -ForegroundColor White
    Write-Host "  [4] $detailWithoutEmoji" -ForegroundColor White
    Write-Host "  [0] Cancel" -ForegroundColor DarkGray
    Write-Host ""

    $choice = Read-Host "  Select (0-4)"

    switch ($choice) {
        "1" { $selectedMsg = $simpleWithEmoji }
        "2" { $selectedMsg = $simpleWithoutEmoji }
        "3" { $selectedMsg = $detailWithEmoji }
        "4" { $selectedMsg = $detailWithoutEmoji }
        default {
            Write-Host ""
            Write-Host "  Cancelled." -ForegroundColor Yellow
            exit 0
        }
    }

    Write-Host ""
    Write-Host "  Committing: $selectedMsg" -ForegroundColor Cyan

    $bodyParts = @()
    if ($added.Count -gt 0) {
        $bodyParts += "Added:"
        $added | ForEach-Object { $bodyParts += "  - $_" }
    }
    if ($modified.Count -gt 0) {
        $bodyParts += "Modified:"
        $modified | ForEach-Object { $bodyParts += "  - $_" }
    }
    if ($deleted.Count -gt 0) {
        $bodyParts += "Removed:"
        $deleted | ForEach-Object { $bodyParts += "  - $_" }
    }
    $bodyParts += ""
    $bodyParts += "Change summary: $desc"
    if ($detailDesc -and $detailDesc -ne $desc) {
        $bodyParts += "Details: $detailDesc"
    }

    if ($DryRun) {
        Write-Host "  [DRY-RUN] Commit skipped." -ForegroundColor DarkGray
        return
    }

    $finalTitle = $selectedMsg
    $finalBody = @($bodyParts)

    :previewLoop while ($true) {
        $openEditor = $false

        Write-Host ""
        Write-Host "=== Commit preview ===" -ForegroundColor Green
        Write-Host ""
        Write-Host "  $finalTitle" -ForegroundColor White
        if ($finalBody.Count -gt 0) {
            Write-Host ""
            foreach ($bl in $finalBody) {
                Write-Host "  $bl" -ForegroundColor Gray
            }
        }
        Write-Host ""
        Write-Host "  [1] Commit as-is" -ForegroundColor White
        Write-Host "  [2] Edit subject" -ForegroundColor White
        Write-Host "  [3] Edit body" -ForegroundColor White
        Write-Host "  [4] Open in editor" -ForegroundColor White
        Write-Host "  [0] Cancel" -ForegroundColor DarkGray
        Write-Host ""

        $action = Read-Host "  Choose (0-4)"
        if (-not $action) {
            Write-Host ""
            Write-Host "  Cancelled." -ForegroundColor Yellow
            exit 0
        }
        switch ($action) {
            "1" { break previewLoop }
            "2" {
                Write-Host ""
                Write-Host "  Subject: $finalTitle" -ForegroundColor DarkGray
                $newTitle = Read-Host "  New subject (Enter to keep)"
                if ($newTitle) { $finalTitle = $newTitle }
            }
            "3" {
                $finalBody = @(Edit-MessageBody -Body $finalBody)
            }
            "4" {
                $openEditor = $true
                break previewLoop
            }
            default {
                Write-Host ""
                Write-Host "  Cancelled." -ForegroundColor Yellow
                exit 0
            }
        }
    }

    $fullMsg = "$finalTitle`n`n$($finalBody -join "`n")"
    $tempFile = [System.IO.Path]::GetTempFileName()

    [System.IO.File]::WriteAllText($tempFile, $fullMsg, [System.Text.UTF8Encoding]::new($false))

    if ($openEditor) {
        Write-Host ""
        Write-Host "  Opening editor..." -ForegroundColor Yellow
        git commit -e -F $tempFile
    } else {
        git commit -F $tempFile
    }

    Remove-Item $tempFile -Force -ErrorAction SilentlyContinue

    if ($LASTEXITCODE -eq 0) {
        Write-Host ""
        $push = Read-Host "  Push to remote? (y/n)"
        if ($push -eq "y" -or $push -eq "Y") {
            Write-Host ""
            Write-Host "  Pushing..." -ForegroundColor Cyan
            git push
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  Pushed successfully!" -ForegroundColor Green
            } else {
                Write-Host "  Push failed." -ForegroundColor Red
            }
        }
    } else {
        Write-Host ""
        Write-Host "  Commit failed." -ForegroundColor Red
    }
}
