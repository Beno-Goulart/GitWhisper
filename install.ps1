[CmdletBinding()]
param(
    [Alias("h")][switch]$Help,
    [Alias("c")][switch]$Check,
    [Alias("y")][switch]$Yes,
    [Alias("p")][string]$ProfilePath = "",
    [Alias("t")][string]$Type = "function",
    [Alias("b")][string]$BinDir = "",
    [Alias("u")][switch]$Uninstall
)

$ErrorActionPreference = "Stop"

$GW_VERSION = "0.4.0"
$MARKER_START = "# >>> GitWhisper >>>"
$MARKER_END   = "# <<< GitWhisper <<<"
$SCRIPT_DIR   = Split-Path -Parent $MyInvocation.MyCommand.Path
$GW_SCRIPT    = Join-Path $SCRIPT_DIR "gitwhisper.ps1"
$GW_INSTALL_DIR = Join-Path $HOME ".gitwhisper"

function Write-Box {
    param([string]$Title, [string[]]$Lines)
    $max = $Title.Length
    foreach ($line in $Lines) { if ($line.Length -gt $max) { $max = $line.Length } }
    $bar = "─" * $max
    Write-Host ("  ┌─" + $bar + "─┐") -ForegroundColor Cyan
    Write-Host ("  │ " + $Title + (" " * ($max - $Title.Length)) + " │") -ForegroundColor Cyan
    foreach ($line in $Lines) {
        Write-Host ("  │ " + $line + (" " * ($max - $line.Length)) + " │") -ForegroundColor Cyan
    }
    Write-Host ("  └─" + $bar + "─┘") -ForegroundColor Cyan
}

function Write-Banner {
    Write-Host ""
    Write-Box "GitWhisper Installer v$GW_VERSION" @("Conventional Commits + gitmoji, automatically.", "")
    Write-Host ""
}

function Read-YN {
    param([string]$Prompt, [string]$Default)
    $hint = if ($Default -eq "y") { " [Y/n]" } elseif ($Default -eq "n") { " [y/N]" } else { "" }
    while ($true) {
        $ans = Read-Host "  $Prompt$hint"
        if ($null -eq $ans) { return $Default }
        $ans = $ans.Trim().ToLower()
        if ($ans -eq "") { $ans = $Default }
        if ($ans -in @("y", "yes")) { return "y" }
        if ($ans -in @("n", "no")) { return "n" }
    }
}

function Read-Number {
    param([string]$Prompt, [int]$Min, [int]$Max)
    while ($true) {
        $ans = Read-Host "  $Prompt ($Min-$Max)"
        if ($null -eq $ans) { return $Min }
        $n = 0
        if ([int]::TryParse($ans, [ref]$n) -and $n -ge $Min -and $n -le $Max) { return $n }
    }
}

function Read-Path {
    param([string]$Prompt, [string]$Default)
    $ans = Read-Host "  $Prompt [$Default]"
    if ($null -eq $ans -or $ans.Trim() -eq "") { $ans = $Default }
    if ($ans.StartsWith("~")) { $ans = $ans -replace "^~", $HOME }
    return $ans
}

function Get-DefaultProfile {
    return $PROFILE
}

function Ensure-Profile {
    param([string]$Path)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (-not (Test-Path $Path)) { New-Item -ItemType File -Path $Path -Force | Out-Null }
}

function Test-Installed {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $false }
    $content = Get-Content $Path -Raw -ErrorAction SilentlyContinue
    return ($content -and $content.Contains($MARKER_START))
}

function Remove-ProfileBlock {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return }
    $content = Get-Content $Path -Raw
    if (-not $content) { return }
    $content = [regex]::Replace($content, "(?s)[\r\n]*" + [regex]::Escape($MARKER_START) + ".*?" + [regex]::Escape($MARKER_END) + "[\r\n]*", "`r`n")
    $content = $content.TrimStart("`r", "`n")
    [System.IO.File]::WriteAllText($Path, $content, [System.Text.Encoding]::UTF8)
}

function Get-BinDirFromProfile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return "" }
    $content = Get-Content $Path -Raw -ErrorAction SilentlyContinue
    if (-not $content) { return "" }
    $m = [regex]::Match($content, '\$env:Path\s*=\s*"([^"]*?);\$env:Path"')
    if ($m.Success) { return $m.Groups[1].Value }
    return ""
}

function Install-Engine {
    # Self-contained copy of the Python engine + thin wrappers.
    New-Item -ItemType Directory -Path $GW_INSTALL_DIR -Force | Out-Null
    Copy-Item -Path (Join-Path $SCRIPT_DIR "gitwhisper.ps1") -Destination (Join-Path $GW_INSTALL_DIR "gitwhisper.ps1") -Force -ErrorAction SilentlyContinue
    Copy-Item -Path (Join-Path $SCRIPT_DIR "gitwhisper.sh") -Destination (Join-Path $GW_INSTALL_DIR "gitwhisper.sh") -Force -ErrorAction SilentlyContinue
    $pyDir = Join-Path $SCRIPT_DIR "python"
    if (Test-Path $pyDir) {
        $dest = Join-Path $GW_INSTALL_DIR "python"
        if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
        Copy-Item -Path $pyDir -Destination $dest -Recurse -Force
    }
}

function Install-ProfileFunction {
    param([string]$Path)
    Install-Engine
    $scriptPath = (Join-Path $GW_INSTALL_DIR "gitwhisper.ps1").Replace("'", "''")
    $block = @"

$MARKER_START
function gitwhisper { & '$scriptPath' @args }
$MARKER_END
"@
    Add-Content -Path $Path -Value $block -Encoding UTF8
}

function Install-BinWrapper {
    param([string]$BinPath, [string]$Path)
    Install-Engine
    New-Item -ItemType Directory -Path $BinPath -Force | Out-Null
    $scriptPath = (Join-Path $GW_INSTALL_DIR "gitwhisper.ps1").Replace('"', '""')
    $cmd = "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" %*`r`n"
    [System.IO.File]::WriteAllText((Join-Path $BinPath "gitwhisper.cmd"), $cmd, [System.Text.Encoding]::ASCII)
    $ps1shim = "#!/usr/bin/env pwsh`r`n# Generated by the GitWhisper installer.`r`n& '$((Join-Path $GW_INSTALL_DIR "gitwhisper.ps1").Replace("'", "''"))' @args`r`n"
    [System.IO.File]::WriteAllText((Join-Path $BinPath "gitwhisper.ps1"), $ps1shim, [System.Text.Encoding]::UTF8)
    if (-not ($env:Path -split ";" -contains $BinPath)) {
        $block = @"

$MARKER_START
`$env:Path = "$BinPath;`$env:Path"
$MARKER_END
"@
        Add-Content -Path $Path -Value $block -Encoding UTF8
    }
}

function Install-All {
    param([string]$Path, [string]$InstallType, [string]$BinPath)
    Ensure-Profile $Path
    Remove-ProfileBlock $Path
    if ($InstallType -eq "bin") { Install-BinWrapper $BinPath $Path }
    else { Install-ProfileFunction $Path }
}

function Uninstall-All {
    param([string]$Path, [string]$BinPath)
    $fromProfile = Get-BinDirFromProfile $Path
    Remove-ProfileBlock $Path
    foreach ($d in @($BinPath, $fromProfile)) {
        if ($d) {
            foreach ($f in @((Join-Path $d "gitwhisper.cmd"), (Join-Path $d "gitwhisper.ps1"))) {
                if (Test-Path $f) { Remove-Item $f -Force; Write-Host "  Removed $f" -ForegroundColor Green }
            }
        }
    }
    foreach ($f in @((Join-Path $GW_INSTALL_DIR "gitwhisper.ps1"), (Join-Path $GW_INSTALL_DIR "gitwhisper.sh"))) {
        if (Test-Path $f) { Remove-Item $f -Force }
    }
    $pyDir = Join-Path $GW_INSTALL_DIR "python"
    if (Test-Path $pyDir) { Remove-Item $pyDir -Recurse -Force }
    Write-Host "  GitWhisper removed from $Path" -ForegroundColor Green
    Write-Host "  Restart your terminal or run: . $PROFILE" -ForegroundColor Yellow
}

function Write-Status {
    param([string]$Path, [string]$InstallType, [string]$BinPath)
    $installed = if (Test-Installed $Path) { "yes" } else { "no" }
    Write-Box "Status" @(
        "  shell            : powershell",
        "  profile file     : $Path",
        "  integration      : $InstallType",
        "  bin directory    : $BinPath",
        "  installed        : $installed"
    )
}

function Show-Options {
    param([string]$Path, [string]$InstallType, [string]$BinPath)
    Write-Box "Install options" @(
        "  [1] Shell profile    : $Path",
        "  [2] Integration      : $InstallType  (1=function in profile, 2=executable in bin)",
        "  [3] Bin directory    : $BinPath"
    )
}

function Edit-Options {
    param([string]$Path, [string]$InstallType, [string]$BinPath)
    while ($true) {
        Write-Host ""
        Show-Options $Path $InstallType $BinPath
        Write-Host ""
        Write-Host "  [1-3] edit an option   [I] install now   [Q] back"
        $ans = Read-Host "  Choose"
        if ($null -eq $ans) { return "" }
        switch -Regex ($ans.Trim()) {
            "^1$" { $Path = Read-Path "Shell profile file" $Path }
            "^2$" { $t = Read-Number "Integration (1=function in profile, 2=executable in bin)" 1 2; $InstallType = if ($t -eq 2) { "bin" } else { "function" } }
            "^3$" { if ($InstallType -eq "bin") { $BinPath = Read-Path "Bin directory" $BinPath } }
            "^[iI]$" { return "$Path|$InstallType|$BinPath" }
            "^[qQ]$" { return "" }
        }
    }
}

function Setup-Project {
    Write-Host ""
    Write-Box "Project setup" @("Install GitWhisper hooks in a project")
    Write-Host ""
    $dir = (Get-Location).Path
    $d = Read-Host "  Project directory [$dir]"
    if ($null -ne $d -and $d.Trim() -ne "") { $dir = $d.Trim().Replace("~", $HOME) }
    if (-not (Test-Path "$dir\.git")) {
        Write-Host "  No .git directory found in $dir." -ForegroundColor Yellow
        if ((Read-YN "Continue anyway?" "n") -ne "y") { return }
    }
    $emoji = Read-YN "Include emoji in commit messages?" "y"
    $default = Read-Number "Default message format (1=simple+emoji, 2=simple, 3=detailed+emoji, 4=detailed)" 1 4
    $prepare = Read-YN "Enable pre-fill hook (prepare-commit-msg)?" "y"
    $validate = Read-YN "Enforce Conventional Commits (commit-msg hook)?" "y"
    Write-Host ""
    Write-Box "Project setup summary" @(
        "  directory  : $dir",
        "  emoji      : $emoji",
        "  default    : $default",
        "  pre-fill   : $prepare",
        "  validate   : $validate"
    )
    if ((Read-YN "Apply?" "y") -ne "y") { return }
    $config = @"

# GitWhisper configuration
# Created by the GitWhisper installer.

[general]
emoji = $emoji
default = $default

[hooks]
prepare = $prepare
validate = $validate
"@
    Set-Content -Path "$dir\.gitwhisperconfig" -Value $config.TrimStart() -Encoding UTF8
    Push-Location $dir
    try { & $GW_SCRIPT init } finally { Pop-Location }
    Write-Host "  Done! GitWhisper hooks installed." -ForegroundColor Green
}

function Write-Help {
    Write-Banner
    Write-Host "  Usage:"
    Write-Host "    ./install.ps1                     interactive wizard"
    Write-Host "    ./install.ps1 -Check              show detection status"
    Write-Host "    ./install.ps1 -Yes -ProfilePath ~/Documents/PowerShell/Microsoft.PowerShell_profile.ps1 [-Type function|bin] [-BinDir ~/.local/bin]"
    Write-Host "                                     non-interactive install"
    Write-Host "    ./install.ps1 -Uninstall [-ProfilePath ...]"
    Write-Host "                                     remove GitWhisper"
    Write-Host ""
    Write-Host "  Flags:"
    Write-Host "    -h, -Help        show this help"
    Write-Host "    -c, -Check       detect profile and print status"
    Write-Host "    -y, -Yes         accept defaults, no prompts"
    Write-Host "    -p, -ProfilePath profile file to modify"
    Write-Host "    -t, -Type        integration: function (default) or bin"
    Write-Host "    -b, -BinDir      bin directory (only for -Type bin)"
    Write-Host "    -u, -Uninstall   remove GitWhisper from the profile"
    Write-Host ""
}

if ($Help) { Write-Help; exit 0 }

if ($ProfilePath -eq "") { $ProfilePath = Get-DefaultProfile }
if ($BinDir -eq "") { $BinDir = Join-Path $HOME ".local\bin" }

if ($Type -notin @("function", "bin")) {
    Write-Host "Error: invalid integration type: $Type (use function or bin)" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $GW_SCRIPT)) {
    Write-Host "Error: gitwhisper.ps1 not found next to this installer ($SCRIPT_DIR)." -ForegroundColor Red
    exit 1
}

if ($Check) {
    Write-Status $ProfilePath $Type $BinDir
    exit 0
}

if ($Uninstall) {
    if ($Yes -or (Test-Installed $ProfilePath)) {
        Uninstall-All $ProfilePath $BinDir
        exit 0
    }
    Write-Host "GitWhisper is not installed in $ProfilePath." -ForegroundColor Red
    exit 1
}

if ($Yes) {
    Install-All $ProfilePath $Type $BinDir
    Write-Host ""
    Write-Status $ProfilePath $Type $BinDir
    Write-Host "  GitWhisper installed." -ForegroundColor Green
    Write-Host "  Restart your terminal or run: . $PROFILE" -ForegroundColor Yellow
    exit 0
}

Write-Banner
while ($true) {
    Write-Host ""
    Write-Status $ProfilePath $Type $BinDir
    $installed = Test-Installed $ProfilePath
    Write-Host ""
    if ($installed) { Write-Host "  GitWhisper is installed." -ForegroundColor Green; Write-Host "" }
    if ($installed) { Write-Host "  1) Reinstall / update" }
    else { Write-Host "  1) Install now" }
    Write-Host "  2) Change install options"
    Write-Host "  3) Set up a project (hooks + config)"
    Write-Host "  4) Uninstall"
    Write-Host "  5) Quit"
    Write-Host ""
    $ans = Read-Host "  Choose [1-5]"
    if ($null -eq $ans) { $ans = "5" }
    switch -Regex ($ans.Trim()) {
        "^1$" {
            Install-All $ProfilePath $Type $BinDir
            Write-Host ""
            Write-Status $ProfilePath $Type $BinDir
            Write-Host "  GitWhisper installed." -ForegroundColor Green
            Write-Host "  Restart your terminal or run: . $PROFILE" -ForegroundColor Yellow
        }
        "^2$" {
            $edited = Edit-Options $ProfilePath $Type $BinDir
            if (-not $edited) { continue }
            $parts = $edited.Split("|")
            $ProfilePath = $parts[0]
            $Type = $parts[1]
            $BinDir = $parts[2]
            Install-All $ProfilePath $Type $BinDir
            Write-Host ""
            Write-Status $ProfilePath $Type $BinDir
            Write-Host "  GitWhisper installed." -ForegroundColor Green
            Write-Host "  Restart your terminal or run: . $PROFILE" -ForegroundColor Yellow
        }
        "^3$" { Setup-Project }
        "^4$" {
            if ($installed) { Uninstall-All $ProfilePath $BinDir }
            else { Write-Host "GitWhisper is not installed in $ProfilePath." -ForegroundColor Red }
        }
        "^5$" { Write-Host ""; Write-Host "  Goodbye." -ForegroundColor Green; exit 0 }
    }
}
