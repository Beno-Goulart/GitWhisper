# GitWhisper shared library (PowerShell).
# Dot-sourced by gitwhisper.ps1. Contains shared state and helpers used by
# more than one command module (commit/suggest and changelog/release).

# GitHub usernames that belong to the project maintainers.
# They are excluded from the "community contributors" section.
$script:coreMaintainers = @()

# Customization loaded from the project's .gitwhisperconfig
# ([types], [scope] and [general] scope/emoji overrides).
$script:gwTypeEmoji = @{}
$script:gwTypeTitles = @{}
$script:gwTypeOrder = @("feat", "fix", "perf", "refactor", "docs", "test", "build", "ci", "chore", "style", "revert")
$script:gwTypeOrderHints = @{}
$script:gwScopeMap = @{}
$script:gwForcedScope = ""
$script:gwEmoji = $true

function Get-GwConfig {
    $cfg = @{}
    if (-not (Test-Path ".gitwhisperconfig")) { return $cfg }
    $section = ""
    foreach ($raw in Get-Content ".gitwhisperconfig" -Encoding UTF8) {
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

function Get-BranchType {
    try {
        $branch = git symbolic-ref --short HEAD 2>$null
    } catch {
        $branch = ""
    }
    if (-not $branch) { return "" }
    switch (($branch -split "/")[0]) {
        "feat"        { return "feat" }
        "feature"     { return "feat" }
        "fix"         { return "fix" }
        "bugfix"      { return "fix" }
        "bug"         { return "fix" }
        "hotfix"      { return "fix" }
        "docs"        { return "docs" }
        "doc"         { return "docs" }
        "test"        { return "test" }
        "tests"       { return "test" }
        "chore"       { return "chore" }
        "refactor"    { return "refactor" }
        "refactoring" { return "refactor" }
        "perf"        { return "perf" }
        "style"       { return "style" }
        "ci"          { return "ci" }
        "build"       { return "build" }
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
        $deletedIsDoc = $Deleted | Where-Object { $_ -match "\.(md|mdx|rst|txt)$|readme|changelog|docs/" }
        if ($deletedIsDoc.Count -eq $Deleted.Count) {
            if ($Deleted.Count -eq 1) {
                $name = [System.IO.Path]::GetFileName($Deleted[0])
                return @{ Type = "docs"; Desc = "removes $name" }
            }
            return @{ Type = "docs"; Desc = "removes $($Deleted.Count) documentation files" }
        }
        if ($Deleted.Count -eq 1) {
            $name = [System.IO.Path]::GetFileName($Deleted[0])
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($Deleted[0])
            if ($specificDesc) {
                return @{ Type = "refactor"; Desc = "$specificDesc from $name"; Strong = $false }
            }
            return @{ Type = "refactor"; Desc = "removes $name"; Strong = $false }
        } else {
            return @{ Type = "refactor"; Desc = "removes $($Deleted.Count) files"; Strong = $false }
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
                return @{ Type = "feat"; Desc = "$specificDesc in $baseName"; Strong = $false }
            }
            return @{ Type = "feat"; Desc = "adds $name"; Strong = $false }
        }
        return @{ Type = "feat"; Desc = "adds $($Added.Count) files"; Strong = $false }
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
                return @{ Type = "fix"; Desc = "$specificDesc in $baseName"; Strong = $false }
            }
            return @{ Type = "fix"; Desc = "fixes $name"; Strong = $false }
        }
        if ($specificDesc) {
            if ($specificDesc -match "adds ") {
                return @{ Type = "feat"; Desc = $specificDesc; Strong = $false }
            }
            if ($specificDesc -match "removes ") {
                return @{ Type = "refactor"; Desc = $specificDesc; Strong = $false }
            }
            return @{ Type = "fix"; Desc = $specificDesc; Strong = $false }
        }
        return @{ Type = "fix"; Desc = "updates $($Modified.Count) files"; Strong = $false }
    }

    if ($specificDesc -and $specificDesc -match "adds ") {
        return @{ Type = "feat"; Desc = $specificDesc; Strong = $false }
    }
    if ($specificDesc) {
        return @{ Type = "refactor"; Desc = $specificDesc; Strong = $false }
    }
    $parts = @()
    if ($Added.Count -gt 0)    { $parts += "$($Added.Count) added" }
    if ($Modified.Count -gt 0) { $parts += "$($Modified.Count) modified" }
    if ($Deleted.Count -gt 0)  { $parts += "$($Deleted.Count) removed" }
    return @{ Type = "refactor"; Desc = ($parts -join ", "); Strong = $false }
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

function Get-ReleaseTypes {
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
    foreach ($t in $script:gwTypeTitles.Keys) {
        if (-not $types.ContainsKey($t)) { $types[$t] = @{ Title = $t; Commits = @() } }
        $types[$t].Title = $script:gwTypeTitles[$t]
    }
    foreach ($t in $script:gwTypeOrder) {
        if (-not $types.ContainsKey($t)) { $types[$t] = @{ Title = $t; Commits = @() } }
    }
    return $types
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

    if ($script:gwTypeOrder.Count -gt 0) {
        $typeOrder = @($script:gwTypeOrder)
        foreach ($t in @("feat", "fix", "perf", "refactor", "docs", "test", "build", "ci", "chore", "style", "revert")) {
            if ($typeOrder -notcontains $t) { $typeOrder += $t }
        }
    } else {
        $typeOrder = @("feat", "fix", "perf", "refactor", "docs", "test", "build", "ci", "chore", "style", "revert")
    }

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

function Get-SuggestedMessage {
    param(
        [string]$DiffContent,
        [string[]]$Added,
        [string[]]$Modified,
        [string[]]$Deleted
    )

    $allFiles = $Added + $Modified
    $selfScript = $allFiles | Where-Object { $_ -match "gitwhisper|modules/|^install\.(ps1|sh)$" }

    $scope = Get-Scope -Files $allFiles
    if (-not $scope) { $scope = Get-BranchScope }

    if ($script:gwForcedScope) {
        $scope = $script:gwForcedScope
    }
    elseif ($script:gwScopeMap.Count -gt 0) {
        foreach ($pat in $script:gwScopeMap.Keys) {
            foreach ($f in $allFiles) {
                if ($f.StartsWith($pat)) { $scope = $script:gwScopeMap[$pat]; break }
            }
            if ($scope) { break }
        }
    }

    $result = Get-CommitType -Added $Added -Modified $Modified -Deleted $Deleted `
        -AddedLower ($allFiles | ForEach-Object { $_.ToLower() }) `
        -ModifiedLower ($Modified | ForEach-Object { $_.ToLower() }) `
        -DeletedLower ($Deleted | ForEach-Object { $_.ToLower() }) `
        -DiffContent $DiffContent -SelfScript:($selfScript.Count -gt 0)

    $type = $result.Type
    $desc = $result.Desc

    if ($result.Strong -eq $false) {
        $branchType = Get-BranchType
        if ($branchType) { $type = $branchType }
    }

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

    foreach ($t in $script:gwTypeEmoji.Keys) {
        $gitmoji[$t] = $script:gwTypeEmoji[$t]
    }

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
