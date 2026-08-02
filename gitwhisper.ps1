param(
    [Parameter(Position = 0)]
    [string]$Command = "",
    [Parameter()]
    [switch]$Help,
    [Parameter()]
    [switch]$Undo,
    [Parameter()]
    [switch]$SinceTag,
    [Parameter()]
    [int]$Limit = 50,
    [Parameter()]
    [switch]$DryRun,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ExtraArgs
)

$ErrorActionPreference = "Stop"

# GitHub usernames that belong to the project maintainers.
# They are excluded from the "community contributors" section.
$coreMaintainers = @()

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

if ($DryRun -or $Command -eq "--dry-run" -or $Command -eq "-n" -or ($ExtraArgs -contains "--dry-run") -or ($ExtraArgs -contains "-n")) {
    $DryRun = $true
    if (-not $Command -or $Command -eq "--dry-run" -or $Command -eq "-n") {
        $Command = ""
    }
}

$Base = ""
if ($ExtraArgs) {
    for ($i = 0; $i -lt $ExtraArgs.Count; $i++) {
        if ($ExtraArgs[$i] -eq "--base" -and $i + 1 -lt $ExtraArgs.Count) {
            $Base = $ExtraArgs[$i + 1]
            break
        }
    }
}

if ($Help -or $Command -eq "help" -or $Command -eq "--help" -or $Command -eq "-h") {
    Show-Help
}

if (-not (Test-Path ".git")) {
    Write-Host "Error: Not a git repository." -ForegroundColor Red
    exit 1
}

function Get-GwConfig {
    $cfg = @{}
    if (-not (Test-Path ".gitwhisperconfig")) { return $cfg }
    $section = ""
    foreach ($raw in Get-Content ".gitwhisperconfig") {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith("#") -or $line.StartsWith(";")) { continue }
        if ($line -match "^\[(.+)\]$") { $section = $Matches[1].Trim(); continue }
        if ($line -match "^([^=]+)=(.*)$") {
            $key = $Matches[1].Trim().ToLower()
            $val = $Matches[2].Trim()
            $cfg["$section.$key"] = $val
        }
    }
    return $cfg
}

$gwConfig = Get-GwConfig
if ($gwConfig["general.core_maintainers"]) {
    $script:coreMaintainers = @($gwConfig["general.core_maintainers"] -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

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
    $diffContent = git diff --staged

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

    $selfScript = $allFiles | Where-Object { $_ -match "gitwhisper|^install\.(ps1|sh)$" }

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

function Remove-LiteralStrings {
    param([string]$Content)
    if (-not $Content) { return "" }
    $Content = [regex]::Replace($Content, '"(?:[^"\\]|\\.)*"', '""')
    $Content = [regex]::Replace($Content, "'(?:[^'\\]|\\.)*'", "''")
    return $Content
}

function Get-Scope {
    param([string[]]$Files)

    if ($Files.Count -eq 0) { return "" }

    $dirGroups = @{}
    foreach ($f in $Files) {
        $dir = Split-Path $f -Parent
        if ($dir) {
            $topDir = ($dir -split "[\\/]")[0]
            if (-not $dirGroups.ContainsKey($topDir)) {
                $dirGroups[$topDir] = 0
            }
            $dirGroups[$topDir]++
        }
    }

    if ($dirGroups.Count -eq 1) {
        return $dirGroups.Keys[0]
    }
    if ($dirGroups.Count -gt 1) {
        $top = $dirGroups.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1
        if ($top.Value -ge ($Files.Count * 0.6)) {
            return $top.Key
        }
    }

    if ($Files.Count -eq 1) {
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($Files[0])
        return $baseName
    }

    return ""
}

function Get-BranchScope {
    $branch = git symbolic-ref --short HEAD 2>$null
    if (-not $branch) { return "" }

    $ignored = @("main", "master", "develop", "dev", "staging", "production", "release")
    if ($ignored -contains $branch) { return "" }

    if ($branch -match "/(.+)") {
        $scope = $Matches[1]
        $prefixes = @("feature/", "bugfix/", "hotfix/", "fix/", "chore/", "docs/", "test/", "refactor/", "perf/", "release/")
        foreach ($p in $prefixes) {
            if ($scope -match "^$p(.+)$") {
                $scope = $Matches[1]
                break
            }
        }
        return $scope
    }

    return ""
}

function Get-CommitType {
    param(
        [string[]]$Added,
        [string[]]$Modified,
        [string[]]$Deleted,
        [string[]]$AddedLower,
        [string[]]$ModifiedLower,
        [string[]]$DeletedLower,
        [string]$DiffContent,
        [switch]$SelfScript
    )

    if ($SelfScript) {
        $DiffContent = Remove-LiteralStrings -Content $DiffContent
    }

    $allModified = @(($AddedLower + $ModifiedLower) | Where-Object { $_ })
    $allChanged  = @(($AddedLower + $ModifiedLower + $DeletedLower) | Where-Object { $_ })

    $testFiles = $allModified | Where-Object { $_ -match "(test|spec|\.test\.|\.spec\.)" }
    $nonTestFiles = $allModified | Where-Object { $_ -notmatch "(test|spec|\.test\.|\.spec\.)" }

    $configPatterns = @(
        "package\.json", "package-lock\.json", "yarn\.lock", "pnpm-lock",
        "tsconfig", "jsconfig", "webpack", "vite\.config", "rollup\.config",
        "\.eslintrc", "eslint\.config", "\.prettierrc", "prettier\.config",
        "jest\.config", "vitest\.config", "babel\.config", "\.babelrc",
        "dockerfile", "docker-compose", "\.dockerignore",
        "makefile", "cmake", "meson\.build",
        "\.gitignore", "\.editorconfig", "\.env", "\.env\.",
        "turbo\.json", "nx\.json", "lerna\.json", "pnpm-workspace",
        "commitlint", "husky", "lint-staged",
        "renovate", "dependabot", "\.github",
        "netlify", "vercel", "firebase", "railway", "render"
    )
    $isConfig = $allChanged | Where-Object {
        $file = $_
        $configPatterns | Where-Object { $file -match $_ }
    }

    $ciPatterns = @("\.github/workflows", "\.gitlab-ci", "\.circleci", "\.travis", "jenkins", "azure-pipelines", "bitbucket-pipelines")
    $isCI = $allChanged | Where-Object {
        $file = $_
        $ciPatterns | Where-Object { $file -match $_ }
    }

    $docPatterns = @("readme", "changelog", "contributing", "license", "authors", "docs/", "\.md$", "\.mdx$", "\.rst$", "\.txt$")
    $isDoc = $allChanged | Where-Object {
        $file = $_
        $docPatterns | Where-Object { $file -match $_ }
    }

    $stylePatterns = @("\.css$", "\.scss$", "\.less$", "\.sass$", "\.stylus$", "\.prettierrc", "\.stylelintrc", "stylelint")
    $isStyle = $allChanged | Where-Object {
        $file = $_
        $stylePatterns | Where-Object { $file -match $_ }
    }

    $dbPatterns = @("migration", "migrate", "schema", "\.sql$", "knex", "prisma", "sequelize", "typeorm", "drizzle")
    $isDB = $allChanged | Where-Object {
        $file = $_
        $dbPatterns | Where-Object { $file -match $_ }
    }

    $otherFiles = $allChanged | Where-Object {
        $file = $_
        $file -notmatch "(test|spec|\.test\.|\.spec\.)" -and
        -not ($configPatterns | Where-Object { $file -match $_ }) -and
        -not ($ciPatterns | Where-Object { $file -match $_ }) -and
        -not ($docPatterns | Where-Object { $file -match $_ }) -and
        -not ($stylePatterns | Where-Object { $file -match $_ }) -and
        -not ($dbPatterns | Where-Object { $file -match $_ })
    }

    $isScript = $allChanged | Where-Object { $_ -match "(commit-msg|\.sh$|\.ps1$|\.py$|\.rb$|\.js$|\.ts$)" }
    $perfContent = ($DiffContent -split "`n" | Where-Object { $_ -match "^[+-][^+-]" }) -join "`n"
    $hasPerfContent = $perfContent -match "(perf|optim|cache|lazy|memo|defer|throttle|debounce|batch|index)"

    $hasBreaking = $DiffContent -match "(BREAKING|breaking.change)"

    $addedLines   = ($DiffContent -split "`n" | Where-Object { $_ -match "^\+[^+]" }) -join "`n"
    $removedLines = ($DiffContent -split "`n" | Where-Object { $_ -match "^-[^-]" }) -join "`n"
    $diffAll      = $DiffContent

    $addedImports   = [regex]::Matches($addedLines, "(?:import|require)\s*\{?\s*([\w]+)")
    $removedImports = [regex]::Matches($removedLines, "(?:import|require)\s*\{?\s*([\w]+)")
    $addedFunctions = [regex]::Matches($addedLines, "(?:function|const|let|var)\s+(\w+)")
    $removedFunctions = [regex]::Matches($removedLines, "(?:function|const|let|var)\s+(\w+)")
    $addedClasses   = [regex]::Matches($addedLines, "(?:class)\s+(\w+)")
    $removedClasses = [regex]::Matches($removedLines, "(?:class)\s+(\w+)")
    $addedProps     = [regex]::Matches($addedLines, "(?:props?|interface|type)\s+(\w+)")
    $removedProps   = [regex]::Matches($removedLines, "(?:props?|interface|type)\s+(\w+)")
    $addedExports   = [regex]::Matches($addedLines, "(?:export)\s+(?:default\s+)?(?:function|class|const|let|var)\s+(\w+)")
    $addedRoutes    = [regex]::Matches($addedLines, "(?:router|Route|path)\s*\(\s*['""]([^'""]+)")
    $addedHooks     = [regex]::Matches($addedLines, "(?:useState|useEffect|useContext|useReducer|useMemo|useCallback|useRef)\s*\(")
    $addedEvents    = [regex]::Matches($addedLines, "(?:addEventListener|\.on\(\s*['""])(\w+)")
    $addedAsync     = [regex]::Matches($addedLines, "(?:async|await|Promise|\.then\()")

    $specificParts = @()

    if ($addedImports.Count -gt 0) {
        $names = ($addedImports | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique | Select-Object -First 3) -join ", "
        $specificParts += "adds $names import"
    }
    if ($removedImports.Count -gt 0) {
        $names = ($removedImports | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique | Select-Object -First 3) -join ", "
        $specificParts += "removes $names import"
    }
    if ($addedFunctions.Count -gt 0) {
        $names = ($addedFunctions | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique | Select-Object -First 2) -join ", "
        $specificParts += "adds $names"
    }
    if ($removedFunctions.Count -gt 0) {
        $names = ($removedFunctions | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique | Select-Object -First 2) -join ", "
        $specificParts += "removes $names"
    }
    if ($addedClasses.Count -gt 0) {
        $names = ($addedClasses | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique) -join ", "
        $specificParts += "adds $names class"
    }
    if ($addedProps.Count -gt 0 -and $addedFunctions.Count -eq 0 -and $addedClasses.Count -eq 0) {
        $names = ($addedProps | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique | Select-Object -First 2) -join ", "
        $specificParts += "adds $names types"
    }
    if ($addedRoutes.Count -gt 0) {
        $paths = ($addedRoutes | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique) -join ", "
        $specificParts += "adds $paths route"
    }
    if ($addedHooks.Count -gt 0) {
        $hookNames = ($addedLines | Select-String -Pattern "(\w+)\s*\(" | ForEach-Object { $_.Matches[0].Groups[1].Value } | Where-Object { $_ -match "^use" } | Select-Object -Unique | Select-Object -First 3) -join ", "
        if ($hookNames) { $specificParts += "adds $hookNames" }
    }
    if ($addedEvents.Count -gt 0) {
        $names = ($addedEvents | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique) -join ", "
        $specificParts += "adds $names listener"
    }
    if ($addedAsync.Count -gt 0 -and $specificParts.Count -eq 0) {
        $specificParts += "adds async handling"
    }

    if ($specificParts.Count -eq 0) {
        if ($addedLines -match "console\.(log|error|warn)") {
            $specificParts += "adds logging"
        }
        elseif ($addedLines -match "(try|catch|throw|Error)") {
            $specificParts += "adds error handling"
        }
        elseif ($addedLines -match "(\/\/|#|\/\*|docs?:)") {
            $specificParts += "adds comments"
        }
        elseif ($removedLines -match "console\.(log|error|warn)") {
            $specificParts += "removes console logs"
        }
        elseif ($addedLines -match "(className|class=|style=|className=)") {
            $specificParts += "updates styles"
        }
        elseif ($addedLines -match "(margin|padding|border|color|font|display|flex|grid)") {
            $specificParts += "adjusts CSS properties"
        }
        elseif ($addedLines -match "(width|height|size|scale|transform|position)") {
            $specificParts += "adjusts layout"
        }
        elseif ($addedLines -match "(onClick|onChange|onSubmit|onFocus|onBlur)") {
            $specificParts += "adds event handlers"
        }
        elseif ($addedLines -match "(useState|useEffect|useContext|useReducer)") {
            $specificParts += "adds React hooks"
        }
        elseif ($addedLines -match "(fetch|axios|http|api|endpoint)") {
            $specificParts += "adds API call"
        }
        elseif ($addedLines -match "(if|else|switch|case|return)") {
            $specificParts += "updates logic"
        }
    }

    $specificDesc = $specificParts -join " and "

    if ($Deleted.Count -gt 0 -and $Added.Count -eq 0 -and $Modified.Count -eq 0) {
        if ($Deleted.Count -eq 1) {
            $name = [System.IO.Path]::GetFileName($Deleted[0])
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($Deleted[0])
            if ($specificDesc) {
                return @{ Type = "refactor"; Desc = "$specificDesc from $name" }
            }
            return @{ Type = "refactor"; Desc = "removes $name" }
        } else {
            return @{ Type = "refactor"; Desc = "removes $($Deleted.Count) files" }
        }
    }

    if ($isConfig.Count -gt 0 -and $otherFiles.Count -eq 0 -and $isDoc.Count -eq 0 -and $isCI.Count -eq 0) {
        if ($isCI.Count -gt 0) {
            return @{ Type = "ci"; Desc = "updates CI configuration" }
        }
        if ($isConfig -match "package\.json|yarn\.lock|pnpm-lock|npm") {
            $pkgChanges = [regex]::Matches($diffAll, '"([\w@/-]+)"\s*:\s*"')
            if ($pkgChanges.Count -gt 0) {
                $pkgs = ($pkgChanges | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -notmatch "^(name|version|description|main|scripts|dependencies|devDependencies)" } | Select-Object -Unique | Select-Object -First 3) -join ", "
                if ($pkgs) { return @{ Type = "build"; Desc = "updates $pkgs dependency" } }
            }
            return @{ Type = "build"; Desc = "updates dependencies" }
        }
        if ($isConfig -match "dockerfile|docker-compose") {
            return @{ Type = "build"; Desc = "updates Docker configuration" }
        }
        return @{ Type = "chore"; Desc = "updates configuration" }
    }

    if ($isCI.Count -gt 0 -and $otherFiles.Count -eq 0) {
        return @{ Type = "ci"; Desc = "updates CI pipeline" }
    }

    if ($isDoc.Count -gt 0 -and $nonTestFiles.Count -eq 0 -and $isConfig.Count -eq 0) {
        if ($specificDesc) {
            return @{ Type = "docs"; Desc = $specificDesc }
        }
        return @{ Type = "docs"; Desc = "updates documentation" }
    }

    if ($testFiles.Count -gt 0 -and $nonTestFiles.Count -eq 0) {
        if ($Added.Count -gt 0 -and $Modified.Count -eq 0) {
            if ($testFiles.Count -eq 1) {
                $name = [System.IO.Path]::GetFileName($Added[0])
                $baseName = [System.IO.Path]::GetFileNameWithoutExtension($Added[0])
                if ($addedLines -match "(describe|it|test)\s*\(") {
                    $testNames = [regex]::Matches($addedLines, "(?:describe|it|test)\s*\(\s*['""]([^'""]+)")
                    if ($testNames.Count -gt 0) {
                        $tName = ($testNames | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique | Select-Object -First 2) -join ", "
                        return @{ Type = "test"; Desc = "adds $tName test for $baseName" }
                    }
                }
                return @{ Type = "test"; Desc = "adds tests for $baseName" }
            }
            return @{ Type = "test"; Desc = "adds $($testFiles.Count) test files" }
        }
        if ($specificDesc) {
            return @{ Type = "test"; Desc = $specificDesc }
        }
        return @{ Type = "test"; Desc = "updates tests" }
    }

    if ($isStyle.Count -gt 0 -and $nonTestFiles.Count -eq 0) {
        if ($specificDesc) {
            return @{ Type = "style"; Desc = $specificDesc }
        }
        return @{ Type = "style"; Desc = "fixes formatting" }
    }

    if ($isDB.Count -gt 0 -and $otherFiles.Count -eq 0) {
        if ($Added.Count -gt 0 -and $Modified.Count -eq 0) {
            $tableNames = [regex]::Matches($diffAll, "(?:CREATE TABLE|ALTER TABLE|INSERT INTO)\s+(\w+)")
            if ($tableNames.Count -gt 0) {
                $tables = ($tableNames | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique) -join ", "
                return @{ Type = "feat"; Desc = "adds migration for $tables" }
            }
            return @{ Type = "feat"; Desc = "adds database migration" }
        }
        return @{ Type = "fix"; Desc = "fixes database schema" }
    }

    if ($hasPerfContent -and $Added.Count -eq 0 -and $isDoc.Count -eq 0 -and $isConfig.Count -eq 0 -and $testFiles.Count -eq 0 -and $isStyle.Count -eq 0 -and $isScript.Count -eq 0) {
        $perfItems = [regex]::Matches($perfContent, "(cache|memo|lazy|defer|throttle|debounce|batch|index|optim)")
        if ($perfItems.Count -gt 0) {
            $items = ($perfItems | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique | Select-Object -First 2) -join ", "
            return @{ Type = "perf"; Desc = "adds $items optimization" }
        }
        return @{ Type = "perf"; Desc = "improves performance" }
    }

    if ($Added.Count -gt 0 -and $Modified.Count -eq 0 -and $Deleted.Count -eq 0) {
        if ($Added.Count -eq 1) {
            $name = [System.IO.Path]::GetFileName($Added[0])
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($Added[0])
            $ext = [System.IO.Path]::GetExtension($Added[0]).ToLower()

            if ($ext -match "\.(css|scss|less|sass|styled)") {
                return @{ Type = "style"; Desc = "adds styles for $baseName" }
            }
            if ($ext -match "\.(md|mdx|rst|txt)") {
                return @{ Type = "docs"; Desc = "adds $name" }
            }
            if ($specificDesc) {
                return @{ Type = "feat"; Desc = "$specificDesc in $baseName" }
            }
            return @{ Type = "feat"; Desc = "adds $name" }
        }
        return @{ Type = "feat"; Desc = "adds $($Added.Count) files" }
    }

    if ($Added.Count -eq 0 -and $Modified.Count -gt 0 -and $Deleted.Count -eq 0) {
        if ($Modified.Count -eq 1) {
            $name = [System.IO.Path]::GetFileName($Modified[0])
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($Modified[0])
            $ext = [System.IO.Path]::GetExtension($Modified[0]).ToLower()

            if ($ext -match "\.(md|mdx|rst|txt)") {
                return @{ Type = "docs"; Desc = "updates $name" }
            }
            if ($ext -match "\.(css|scss|less|sass)") {
                if ($specificDesc) {
                    return @{ Type = "style"; Desc = "$specificDesc in $baseName" }
                }
                return @{ Type = "style"; Desc = "fixes styles in $baseName" }
            }
            if ($specificDesc) {
                return @{ Type = "fix"; Desc = "$specificDesc in $baseName" }
            }
            return @{ Type = "fix"; Desc = "fixes $name" }
        }
        return @{ Type = "refactor"; Desc = "updates $($Modified.Count) files" }
    }

    if ($specificDesc) {
        return @{ Type = "refactor"; Desc = $specificDesc }
    }
    $parts = @()
    if ($Added.Count -gt 0)    { $parts += "$($Added.Count) added" }
    if ($Modified.Count -gt 0) { $parts += "$($Modified.Count) modified" }
    if ($Deleted.Count -gt 0)  { $parts += "$($Deleted.Count) removed" }
    return @{ Type = "refactor"; Desc = ($parts -join ", ") }
}

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

    $log = git log "$mergeBase..$branch" --pretty=format:"%H|%s|%ad" --date=short --no-merges
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
            $log = git log "$lastTag..HEAD" --pretty=format:"%H|%s|%ad|%an|%ae" --date=short
        } else {
            Write-Host "No tags found. Showing all commits." -ForegroundColor Yellow
            $log = git log --pretty=format:"%H|%s|%ad|%an|%ae" --date=short -n $Limit
        }
    } else {
        $log = git log --pretty=format:"%H|%s|%ad|%an|%ae" --date=short -n $Limit
    }

    if (-not $log) {
        Write-Host "No commits found." -ForegroundColor Yellow
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

function Get-GithubUsername {
    param([string]$Name, [string]$Email)

    if ($Email -match "^([^@+]+)(\+[^@]*)?@users\.noreply\.github\.com$") {
        $u = $Matches[1]
        if ($u -match "^[a-zA-Z0-9-]+$") { return $u }
    }
    if ($Name -match "^@([a-zA-Z0-9-]+)$") { return $Matches[1] }
    if ($Name -match "^[a-zA-Z0-9-]+$") { return $Name }
    return ""
}

function Format-ReleaseBullet {
    param($Commit)

    $line = "- $($Commit.Description)"
    if ($Commit.Pr) { $line += " (#$($Commit.Pr))" }
    return $line
}

function Build-ReleaseNotes {
    param(
        [hashtable]$Types,
        [array]$AllCommits
    )

    $areas = @{}
    foreach ($c in $AllCommits) {
        $area = if ($c.Scope) { $c.Scope } else { "General" }
        if (-not $areas.ContainsKey($area)) { $areas[$area] = @{} }
        if (-not $areas[$area].ContainsKey($c.Type)) { $areas[$area][$c.Type] = @() }
        $areas[$area][$c.Type] += $c
    }

    $areaStats = @()
    foreach ($key in $areas.Keys) {
        $count = 0
        foreach ($list in $areas[$key].Values) { $count += $list.Count }
        $areaStats += [PSCustomObject]@{ Name = $key; Count = $count }
    }
    $areaOrder = @($areaStats | Where-Object { $_.Name -ne "General" } | Sort-Object Count -Descending) + @($areaStats | Where-Object { $_.Name -eq "General" })

    $typeOrder = @("feat", "fix", "perf", "refactor", "docs", "test", "build", "ci", "chore", "style", "revert")

    $notes = ""
    foreach ($area in $areaOrder) {
        $displayArea = $area.Name.Substring(0, 1).ToUpper() + $area.Name.Substring(1)
        if ($notes) { $notes += [char]10 }
        $notes += "### $displayArea`n`n"
        foreach ($type in $typeOrder) {
            if (-not $areas[$area.Name].ContainsKey($type)) { continue }
            $title = $Types[$type].Title
            $notes += "#### $title`n`n"
            foreach ($commit in $areas[$area.Name][$type]) {
                $notes += (Format-ReleaseBullet -Commit $commit) + [char]10
            }
            $notes += [char]10
        }
    }

    $contributorMap = @{}
    foreach ($c in $AllCommits) {
        if (-not $c.AuthorUser) { continue }
        if (-not $contributorMap.ContainsKey($c.AuthorUser)) { $contributorMap[$c.AuthorUser] = @() }
        $contributorMap[$c.AuthorUser] += $c
    }

    $community = @()
    foreach ($u in $contributorMap.Keys) {
        if ($script:coreMaintainers -notcontains $u) { $community += $u }
    }
    $community = @($community | Sort-Object @{ Expression = { $contributorMap[$_].Count }; Descending = $true })

    if ($community.Count -gt 0) {
        if ($notes) { $notes += [char]10 }
        $notes += "### Contributors`n`n"
        $noun = if ($community.Count -eq 1) { "contributor" } else { "contributors" }
        $notes += "Thank you to $($community.Count) community ${noun}:`n`n"
        foreach ($u in $community) {
            $notes += "@$u`n"
            foreach ($c in @($contributorMap[$u] | Sort-Object Date)) {
                $subject = $c.Type
                if ($c.Scope) { $subject += "($($c.Scope))" }
                $subject += ": $($c.Description)"
                if ($c.Pr) { $subject += " (#$($c.Pr))" }
                $notes += "- $subject`n"
            }
            $notes += [char]10
        }
    }

    $allUsers = @($contributorMap.Keys | Sort-Object @{ Expression = { $contributorMap[$_].Count }; Descending = $true })
    if ($allUsers.Count -gt 0) {
        $mentions = @($allUsers | ForEach-Object { "@$_" })
        $notes += "**Contributors:** " + ($mentions -join ", ") + [char]10
    }

    return $notes
}

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
        $log = git log "$lastTag..HEAD" --pretty=format:"%H|%s|%ad|%an|%ae" --date=short
    } else {
        Write-Host ""
        Write-Host "  No tags found. Releasing from the beginning of history." -ForegroundColor Yellow
        $log = git log --pretty=format:"%H|%s|%ad|%an|%ae" --date=short
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

function Get-SuggestedMessage {
    param(
        [string]$DiffContent,
        [string[]]$Added,
        [string[]]$Modified,
        [string[]]$Deleted
    )

    $allFiles = $Added + $Modified
    $selfScript = $allFiles | Where-Object { $_ -match "gitwhisper|^install\.(ps1|sh)$" }

    $scope = Get-Scope -Files $allFiles
    if (-not $scope) { $scope = Get-BranchScope }

    $result = Get-CommitType -Added $Added -Modified $Modified -Deleted $Deleted `
        -AddedLower ($allFiles | ForEach-Object { $_.ToLower() }) `
        -ModifiedLower ($Modified | ForEach-Object { $_.ToLower() }) `
        -DeletedLower ($Deleted | ForEach-Object { $_.ToLower() }) `
        -DiffContent $DiffContent -SelfScript:($selfScript.Count -gt 0)

    $type = $result.Type
    $desc = $result.Desc

    $addedLines = ($DiffContent -split "`n" | Where-Object { $_ -match "^\+[^+]" }) -join "`n"
    $removedLines = ($DiffContent -split "`n" | Where-Object { $_ -match "^-[^-]" }) -join "`n"

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

        foreach ($f in ($Added + $Modified)) {
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

    $default = 1
    if ($gwConfig["general.default"]) {
        try { $default = [int]$gwConfig["general.default"] } catch { $default = 1 }
    }
    if ($default -lt 1 -or $default -gt 4) { $default = 1 }

    $emojiOn = $true
    if ($gwConfig["general.emoji"] -eq "false") { $emojiOn = $false }

    $title = switch ($default) {
        1 { if ($emojiOn) { $simpleWithEmoji } else { $simpleWithoutEmoji } }
        2 { $simpleWithoutEmoji }
        3 { if ($emojiOn) { $detailWithEmoji } else { $detailWithoutEmoji } }
        4 { $detailWithoutEmoji }
    }

    $bodyParts = @()
    if ($Added.Count -gt 0) {
        $bodyParts += "Added:"
        $Added | ForEach-Object { $bodyParts += "  - $_" }
    }
    if ($Modified.Count -gt 0) {
        $bodyParts += "Modified:"
        $Modified | ForEach-Object { $bodyParts += "  - $_" }
    }
    if ($Deleted.Count -gt 0) {
        $bodyParts += "Removed:"
        $Deleted | ForEach-Object { $bodyParts += "  - $_" }
    }
    $bodyParts += ""
    $bodyParts += "Change summary: $desc"
    if ($detailDesc -and $detailDesc -ne $desc) {
        $bodyParts += "Details: $detailDesc"
    }

    return "$title`n`n$($bodyParts -join "`n")"
}

function Invoke-Suggest {
    $diffIndex = git diff --staged --name-status
    if (-not $diffIndex) { exit 0 }
    $diffContent = git diff --staged

    $added = @()
    $modified = @()
    $deleted = @()

    foreach ($line in ($diffIndex -split "`n")) {
        if (-not $line) { continue }
        $parts = $line -split "`t"
        $status = $parts[0].Trim()
        $file   = $parts[-1].Trim()
        switch -Regex ($status) {
            "^A"  { $added += $file }
            "^M"  { $modified += $file }
            "^D"  { $deleted += $file }
        }
    }

    $msg = Get-SuggestedMessage -DiffContent $diffContent -Added $added -Modified $modified -Deleted $deleted
    if ($msg) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($msg)
        $stdout = [System.Console]::OpenStandardOutput()
        $stdout.Write($bytes, 0, $bytes.Length)
        $stdout.Flush()
        $stdout.Close()
    }
    exit 0
}

function New-GwConfigFile {
    $content = @'
# GitWhisper configuration
# Created by `gitwhisper init`. Re-run `gitwhisper init` to update hooks after edits.

[general]
# include emoji in generated commit messages (true/false)
emoji = true

# suggestion pre-filled by the hook: 1=simple+emoji, 2=simple, 3=detailed+emoji, 4=detailed
default = 1

# maintainers excluded from the "community contributors" section of the changelog
core_maintainers =

[hooks]
# pre-fill the commit message on `git commit` (true/false)
prepare = true

# reject commits that do not follow Conventional Commits (true/false)
validate = true
'@
    $content | Out-File -FilePath ".gitwhisperconfig" -Encoding UTF8
    Write-Host "  Created .gitwhisperconfig" -ForegroundColor Green
}

function Get-GitwhisperCommand {
    $script = Join-Path $PSScriptRoot "gitwhisper.ps1"
    if (Test-Path $script) {
        return "powershell.exe -NoProfile -ExecutionPolicy Bypass -File '$($script.Replace('\', '/'))'"
    }
    return "gitwhisper"
}

function Get-PrepareHookContent {
    param([string]$Cmd)

    $tpl = @'
#!/bin/sh
# Generated by GitWhisper init. Re-run `gitwhisper init` to update.
GW_CMD="__GW_CMD__"

MSG_FILE="$1"
SOURCE="$2"

# only pre-fill plain commits (skip -m, --amend, merge, template, etc.)
case "$SOURCE" in
    message|template|merge|squash|commit) exit 0 ;;
esac

# do nothing when there are no staged changes
if ! git diff --cached --quiet 2>/dev/null; then
    SUGGEST=$(eval "$GW_CMD suggest < /dev/null" 2>/dev/null)
    if [ -n "$SUGGEST" ]; then
        # only pre-fill when the message file has no real content yet
        REAL=$(grep -v '^#' "$MSG_FILE" | grep -v '^[[:space:]]*$' | head -1)
        if [ -z "$REAL" ]; then
            printf '%s\n' "$SUGGEST" > "$MSG_FILE"
        fi
    fi
fi

exit 0
'@
    return $tpl.Replace("__GW_CMD__", $Cmd)
}

function Get-CommitMsgHookContent {
    $tpl = @'
#!/bin/sh
# Generated by GitWhisper init. Re-run `gitwhisper init` to update.
MSG_FILE="$1"

FIRST_LINE=""
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
        \#*) continue ;;
        "") continue ;;
    esac
    FIRST_LINE="$line"
    break
done < "$MSG_FILE"

if ! echo "$FIRST_LINE" | grep -qE '^[^[:alnum:]]*(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert|db)(\([^)]*\))?(!)?: .+'; then
    echo ""
    echo "GitWhisper: commit message does not follow Conventional Commits."
    echo ""
    echo "  Expected: <type>(<scope>): <description>"
    echo "  Example:  feat(api): add login endpoint"
    echo ""
    echo "  Run 'gitwhisper' to generate a message, or edit the subject line."
    echo ""
    exit 1
fi

exit 0
'@
    return $tpl
}

function Install-Hook {
    param(
        [string]$Path,
        [string]$Content,
        [switch]$Force
    )

    if (Test-Path $Path) {
        $existing = Get-Content $Path -Raw -ErrorAction SilentlyContinue
        if ($existing -and $existing -notmatch "GitWhisper") {
            if (-not $Force) {
                Write-Host ""
                $answer = Read-Host "  $(Split-Path $Path -Leaf) exists and is not from GitWhisper. Back up and overwrite? (y/n)"
                if ($answer -ne "y" -and $answer -ne "Y") {
                    Write-Host "  Skipping $(Split-Path $Path -Leaf)." -ForegroundColor Yellow
                    return
                }
            }
            Copy-Item $Path "$Path.bak" -Force
            Write-Host "  Backed up existing hook to $Path.bak" -ForegroundColor Yellow
        }
    }
    $Content | Out-File -FilePath $Path -Encoding ASCII -NoNewline
    Write-Host "  Installed $(Split-Path $Path -Leaf)" -ForegroundColor Green
}

function Invoke-Init {
    param([switch]$Force)

    Write-Host ""
    Write-Host "=== GitWhisper init ===" -ForegroundColor Cyan
    Write-Host ""

    if (Test-Path ".gitwhisperconfig") {
        if ($Force) {
            Write-Host "  .gitwhisperconfig already exists. Recreating." -ForegroundColor Yellow
            New-GwConfigFile
        } else {
            Write-Host "  .gitwhisperconfig already exists. Keeping it." -ForegroundColor Green
        }
    } else {
        New-GwConfigFile
    }

    $hooksDir = Join-Path ".git" "hooks"
    if (-not (Test-Path $hooksDir)) {
        Write-Host ""
        Write-Host "  Error: could not find $hooksDir." -ForegroundColor Red
        exit 1
    }

    $gwCmd = Get-GitwhisperCommand

    if ($gwConfig["hooks.prepare"] -eq "false") {
        Remove-Item (Join-Path $hooksDir "prepare-commit-msg") -Force -ErrorAction SilentlyContinue
        Write-Host "  prepare-commit-msg disabled in config. Removed." -ForegroundColor Yellow
    } else {
        Install-Hook -Path (Join-Path $hooksDir "prepare-commit-msg") -Content (Get-PrepareHookContent -Cmd $gwCmd) -Force:$Force
    }

    if ($gwConfig["hooks.validate"] -eq "false") {
        Remove-Item (Join-Path $hooksDir "commit-msg") -Force -ErrorAction SilentlyContinue
        Write-Host "  commit-msg disabled in config. Removed." -ForegroundColor Yellow
    } else {
        Install-Hook -Path (Join-Path $hooksDir "commit-msg") -Content (Get-CommitMsgHookContent) -Force:$Force
    }

    Write-Host ""
    Write-Host "  Done! GitWhisper hooks installed." -ForegroundColor Green
    Write-Host "  Next 'git commit' will pre-fill a suggested message." -ForegroundColor White
    Write-Host "  Config file: .gitwhisperconfig" -ForegroundColor White
    Write-Host ""
}

switch ($Command.ToLower()) {
    "" { Invoke-Commit }
    "commit" { Invoke-Commit }
    "undo" { Invoke-Undo }
    "amend" { Invoke-Amend }
    "changelog" { Invoke-Changelog -SinceTag:$SinceTag -Limit $Limit }
    "release" { Invoke-Release -ExtraArgs $ExtraArgs }
    "init" { Invoke-Init -Force ($ExtraArgs -contains "--force" -or $ExtraArgs -contains "-Force") }
    "suggest" { Invoke-Suggest }
    "pr" { Invoke-Pr -BaseBranch $Base -CreatePR ($ExtraArgs -contains "create") }
    default {
        Write-Host "Unknown command: $Command" -ForegroundColor Red
        Show-Help
    }
}
