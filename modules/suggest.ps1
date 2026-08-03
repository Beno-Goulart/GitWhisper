# GitWhisper `suggest` command (PowerShell).
# Used by the smart hooks to pre-fill a suggested message.

function Invoke-Suggest {
    $diffIndex = git diff --staged --name-status
    if (-not $diffIndex) { exit 0 }
    $diffContent = (@(git diff --staged) -join "`n")

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
