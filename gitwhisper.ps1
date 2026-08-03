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

# Root of the GitWhisper installation. Used by Get-GitwhisperCommand (init)
# to build the command the prepare hook will call.
$script:GW_SCRIPT_ROOT = $PSScriptRoot

# Load shared library and command modules (in dependency order).
. "$PSScriptRoot/modules/lib.ps1"
. "$PSScriptRoot/modules/help.ps1"
. "$PSScriptRoot/modules/undo.ps1"
. "$PSScriptRoot/modules/amend.ps1"
. "$PSScriptRoot/modules/commit.ps1"
. "$PSScriptRoot/modules/suggest.ps1"
. "$PSScriptRoot/modules/init.ps1"
. "$PSScriptRoot/modules/pr.ps1"
. "$PSScriptRoot/modules/changelog.ps1"
. "$PSScriptRoot/modules/release.ps1"

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

$gwConfig = Get-GwConfig
if ($gwConfig["general.core_maintainers"]) {
    $script:coreMaintainers = @($gwConfig["general.core_maintainers"] -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
if ($gwConfig["general.scope"]) {
    $script:gwForcedScope = $gwConfig["general.scope"]
}
foreach ($k in $gwConfig.Keys) {
    if ($k -like "types.*.order") {
        $base = $k.Substring(6, $k.Length - 12)
        $hint = 0
        if ([int]::TryParse($gwConfig[$k], [ref]$hint)) {
            $script:gwTypeOrderHints[$base] = $hint
        }
    }
    elseif ($k -like "types.*") {
        $type = $k.Substring(6)
        $parts = @($gwConfig[$k] -split "\|")
        $script:gwTypeEmoji[$type] = $parts[0].Trim()
        if ($parts.Count -gt 1 -and $parts[1].Trim()) {
            $script:gwTypeTitles[$type] = $parts[1].Trim()
        }
        if ($script:gwTypeOrder -notcontains $type) { $script:gwTypeOrder += $type }
    }
    elseif ($k -like "scope.*") {
        $script:gwScopeMap[$k.Substring(6)] = $gwConfig[$k]
    }
}
if ($script:gwTypeOrderHints.Count -gt 0) {
    $script:gwTypeOrder = @($script:gwTypeOrder | Sort-Object @{ Expression = {
        if ($script:gwTypeOrderHints.ContainsKey($_)) { $script:gwTypeOrderHints[$_] } else { 999 }
    }; Ascending = $true })
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
