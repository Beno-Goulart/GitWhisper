param(
    [switch]$Staged
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path ".git")) {
    Write-Host "Error: Not a git repository." -ForegroundColor Red
    exit 1
}

if ($Staged) {
    $diffIndex = git diff --staged --name-status
    $diffStat = git diff --staged --stat
    $diffContent = git diff --staged
} else {
    $diffIndex = git diff --name-status
    $diffStat = git diff --stat
    $diffContent = git diff
}

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

# --- Scope detection from folder structure ---
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

# --- Type detection ---
function Get-CommitType {
    param(
        [string[]]$Added,
        [string[]]$Modified,
        [string[]]$Deleted,
        [string[]]$AddedLower,
        [string[]]$ModifiedLower,
        [string[]]$DeletedLower,
        [string]$DiffContent
    )

    $allModified = $AddedLower + $ModifiedLower
    $allChanged  = $AddedLower + $ModifiedLower + $DeletedLower

    # --- Detect test files ---
    $testFiles = $allModified | Where-Object { $_ -match "(test|spec|\.test\.|\.spec\.)" }
    $nonTestFiles = $allModified | Where-Object { $_ -notmatch "(test|spec|\.test\.|\.spec\.)" }

    # --- Detect config / build files ---
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

    # --- Detect CI files ---
    $ciPatterns = @("\.github/workflows", "\.gitlab-ci", "\.circleci", "\.travis", "jenkins", "azure-pipelines", "bitbucket-pipelines")
    $isCI = $allChanged | Where-Object {
        $file = $_
        $ciPatterns | Where-Object { $file -match $_ }
    }

    # --- Detect documentation ---
    $docPatterns = @("readme", "changelog", "contributing", "license", "authors", "docs/", "\.md$", "\.mdx$", "\.rst$", "\.txt$")
    $isDoc = $allChanged | Where-Object {
        $file = $_
        $docPatterns | Where-Object { $file -match $_ }
    }

    # --- Detect style files ---
    $stylePatterns = @("\.css$", "\.scss$", "\.less$", "\.sass$", "\.stylus$", "\.prettierrc", "\.stylelintrc", "stylelint")
    $isStyle = $allChanged | Where-Object {
        $file = $_
        $stylePatterns | Where-Object { $file -match $_ }
    }

    # --- Detect migration / db ---
    $dbPatterns = @("migration", "migrate", "schema", "\.sql$", "knex", "prisma", "sequelize", "typeorm", "drizzle")
    $isDB = $allChanged | Where-Object {
        $file = $_
        $dbPatterns | Where-Object { $file -match $_ }
    }

    # --- Detect performance-related content ---
    $hasPerfContent = $DiffContent -match "(perf|optim|cache|lazy|memo|defer|throttle|debounce|batch|index)"

    # --- Detect breaking change ---
    $hasBreaking = $DiffContent -match "(BREAKING|breaking.change)"

    # --- Analyze diff for specific descriptions ---
    $addedLines   = ($DiffContent -split "`n" | Where-Object { $_ -match "^\+[^+]" }) -join "`n"
    $removedLines = ($DiffContent -split "`n" | Where-Object { $_ -match "^-[^-]" }) -join "`n"
    $diffAll      = $DiffContent

    # Extract meaningful items from diff
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

    # Build specific description
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

    # Fallback descriptions based on file content patterns
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

    # --- Priority-based type detection ---

    # Deleted only -> revert or refactor
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

    # Config/build only
    if ($isConfig.Count -gt 0 -and $nonTestFiles.Count -eq 0 -and $isDoc.Count -eq 0 -and $isCI.Count -eq 0) {
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

    # CI only
    if ($isCI.Count -gt 0 -and $nonTestFiles.Count -eq 0) {
        return @{ Type = "ci"; Desc = "updates CI pipeline" }
    }

    # Documentation only
    if ($isDoc.Count -gt 0 -and $nonTestFiles.Count -eq 0 -and $isConfig.Count -eq 0) {
        if ($specificDesc) {
            return @{ Type = "docs"; Desc = $specificDesc }
        }
        return @{ Type = "docs"; Desc = "updates documentation" }
    }

    # Test only
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

    # Style only
    if ($isStyle.Count -gt 0 -and $nonTestFiles.Count -eq 0) {
        if ($specificDesc) {
            return @{ Type = "style"; Desc = $specificDesc }
        }
        return @{ Type = "style"; Desc = "fixes formatting" }
    }

    # DB / migrations
    if ($isDB.Count -gt 0 -and $nonTestFiles.Count -eq 0) {
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

    # Performance content detected (skip for docs, config, test, style files)
    if ($hasPerfContent -and $Added.Count -eq 0 -and $isDoc.Count -eq 0 -and $isConfig.Count -eq 0 -and $testFiles.Count -eq 0 -and $isStyle.Count -eq 0) {
        $perfItems = [regex]::Matches($diffAll, "(cache|memo|lazy|defer|throttle|debounce|batch|index|optim)")
        if ($perfItems.Count -gt 0) {
            $items = ($perfItems | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique | Select-Object -First 2) -join ", "
            return @{ Type = "perf"; Desc = "adds $items optimization" }
        }
        return @{ Type = "perf"; Desc = "improves performance" }
    }

    # --- Mixed changes ---

    # New files added (feature)
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

    # Only modifications
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

    # Mixed additions + modifications + deletions
    if ($specificDesc) {
        return @{ Type = "refactor"; Desc = $specificDesc }
    }
    $parts = @()
    if ($Added.Count -gt 0)    { $parts += "$($Added.Count) added" }
    if ($Modified.Count -gt 0) { $parts += "$($Modified.Count) modified" }
    if ($Deleted.Count -gt 0)  { $parts += "$($Deleted.Count) removed" }
    return @{ Type = "refactor"; Desc = ($parts -join ", ") }
}

$scope = Get-Scope -Files $allFiles
$result = Get-CommitType -Added $added -Modified $modified -Deleted $deleted -AddedLower $addedLower -ModifiedLower ($modified | ForEach-Object { $_.ToLower() }) -DeletedLower $deletedLower -DiffContent $diffContent

$type = $result.Type
$desc = $result.Desc

# --- Gitmoji mapping (Unicode for PS 5.1) ---
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

# --- Build both versions ---
$emoji = $gitmoji[$type]

if ($scope) {
    $withEmoji    = "$emoji ${type}(${scope}): $desc"
    $withoutEmoji = "${type}(${scope}): $desc"
} else {
    $withEmoji    = "$emoji ${type}: $desc"
    $withoutEmoji = "${type}: $desc"
}

# --- Enforce <=50 chars on summary (trim if needed) ---
function Truncate-Msg {
    param([string]$Msg, [int]$MaxLen = 50)
    if ($Msg.Length -le $MaxLen) { return $Msg }
    $cut = $Msg.Substring(0, $MaxLen - 1)
    return $cut.TrimEnd() + "~"
}

# --- Output ---
Write-Host "=== Suggested messages ===" -ForegroundColor Green
Write-Host ""
Write-Host "  WITH emoji:    " -NoNewline; Write-Host $withEmoji -ForegroundColor White
Write-Host "  WITHOUT emoji: " -NoNewline; Write-Host $withoutEmoji -ForegroundColor White
Write-Host ""

Write-Host "--- Copy ---" -ForegroundColor DarkGray
Write-Host "  git commit -m `"$withEmoji`"" -ForegroundColor DarkCyan
Write-Host "  git commit -m `"$withoutEmoji`"" -ForegroundColor DarkGray
Write-Host ""
