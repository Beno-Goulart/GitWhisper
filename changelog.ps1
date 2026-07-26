param(
    [switch]$SinceTag,
    [int]$Limit = 50
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path ".git")) {
    Write-Host "Error: Not a git repository." -ForegroundColor Red
    exit 1
}

# Get commits
if ($SinceTag) {
    $lastTag = ""
    try {
        $lastTag = git describe --tags --abbrev=0 2>&1
        if ($LASTEXITCODE -ne 0) { $lastTag = "" }
    } catch { $lastTag = "" }
    
    if ($lastTag) {
        $log = git log "$lastTag..HEAD" --pretty=format:"%H|%s|%ad" --date=short
    } else {
        Write-Host "No tags found. Showing all commits." -ForegroundColor Yellow
        $log = git log --pretty=format:"%H|%s|%ad" --date=short -n $Limit
    }
} else {
    $log = git log --pretty=format:"%H|%s|%ad" --date=short -n $Limit
}

if (-not $log) {
    Write-Host "No commits found." -ForegroundColor Yellow
    exit 0
}

# Parse commits by type
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
    
    $parts = $line -split "\|", 3
    if ($parts.Count -lt 3) { continue }
    
    $hash = $parts[0].Trim()
    $message = $parts[1].Trim()
    $date = $parts[2].Trim()
    
    # Parse type from message (handle gitmoji prefix like ♻ refactor: ...)
    $typeMatch = [regex]::Match($message, "(\w+)(?:\(([^)]+)\))?[!]?:\s*(.+)")
    if ($typeMatch.Success) {
        $type = $typeMatch.Groups[1].Value.ToLower()
        $scope = $typeMatch.Groups[2].Value
        $desc = $typeMatch.Groups[3].Value
        $shortHash = $hash.Substring(0, [Math]::Min(7, $hash.Length))
        
        $commitObj = @{
            Hash = $shortHash
            Message = $message
            Scope = $scope
            Description = $desc
            Date = $date
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

# Get version from last tag or generate
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

# Determine version bump
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

# Build CHANGELOG
$changelog = @"
# Changelog

All notable changes to this project will be documented in this file.

Format: [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/)

"@

# Add new version section
$changelog += "## [$newVersion]($today)`n`n"

foreach ($type in @("feat", "fix", "perf", "refactor", "docs", "test", "build", "ci", "chore", "style", "revert")) {
    $typeData = $types[$type]
    if ($typeData.Commits.Count -gt 0) {
        $changelog += "### $($typeData.Title)`n`n"
        foreach ($commit in $typeData.Commits) {
            $cHash = $commit.Hash
            $cScope = $commit.Scope
            $cDesc = $commit.Description
            if ($cScope) {
                $line = "- **${cScope}:** ${cDesc} (${cHash})"
                $changelog += $line + [char]10
            } else {
                $line = "- ${cDesc} (${cHash})"
                $changelog += $line + [char]10
            }
        }
        $changelog += [char]10
    }
}

# Write to file
$changelog | Out-File -FilePath "CHANGELOG.md" -Encoding UTF8

Write-Host "=== Changelog generated ===" -ForegroundColor Green
Write-Host ""
Write-Host "  Version: $newVersion" -ForegroundColor White
Write-Host "  Commits: $($allCommits.Count)" -ForegroundColor White
Write-Host "  File:    CHANGELOG.md" -ForegroundColor White
Write-Host ""

# Show preview
Write-Host "=== Preview ===" -ForegroundColor Cyan
Write-Host ""
$lines = $changelog -split "`n" | Select-Object -First 30
foreach ($line in $lines) {
    Write-Host "  $line"
}
if (($changelog -split "`n").Count -gt 30) {
    Write-Host "  ..." -ForegroundColor DarkGray
}
