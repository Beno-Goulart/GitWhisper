# GitWhisper entry point (PowerShell).
# Thin wrapper that forwards to the Python engine in ./python.
param(
    [Parameter(Position = 0)]
    [string]$Command = "",
    [Parameter()]
    [Alias("h")]
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ExtraArgs
)

$ErrorActionPreference = "Stop"

function Find-PythonEngine {
    param([string]$Root)
    $candidates = @()
    foreach ($base in @($Root, (Join-Path $HOME ".gitwhisper"))) {
        if ($base) {
            $candidates += (Join-Path $base "python\main.py")
        }
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }
    return ""
}

function Find-PythonExe {
    # Validate each candidate by running it: the Microsoft Store alias stubs
    # print an error and exit non-zero, so they are skipped.
    foreach ($candidate in @("python3", "python", "py")) {
        try {
            $cmd = Get-Command $candidate -ErrorAction Stop
            if (-not $cmd) {
                continue
            }
            if ($cmd.Source -like "$env:LOCALAPPDATA\Microsoft\WindowsApps\*") {
                continue
            }
            $version = & $cmd.Source --version 2>$null
            if ($LASTEXITCODE -eq 0) {
                return $cmd.Source
            }
        }
        catch {
            # try next candidate
        }
    }
    return ""
}

$engine = Find-PythonEngine -Root $PSScriptRoot
if (-not $engine) {
    Write-Host "Error: GitWhisper python engine not found." -ForegroundColor Red
    exit 1
}

$python = Find-PythonExe
if (-not $python) {
    Write-Host "Error: python not found in PATH. Install Python 3 to use GitWhisper." -ForegroundColor Red
    exit 1
}

# Make sure the Python child process speaks UTF-8 and that PowerShell decodes
# its output as UTF-8 (emojis in Windows PowerShell 5.1 and git hooks).
$utf8 = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8
$env:PYTHONIOENCODING = "utf-8"

$forward = @()
if ($Help) { $forward += "help" }
if ($Command) { $forward += $Command }
if ($ExtraArgs) { $forward += $ExtraArgs }

& $python $engine @forward
exit $LASTEXITCODE
