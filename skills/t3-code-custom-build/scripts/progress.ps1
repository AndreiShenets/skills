function Invoke-BuildStep {
    param([Parameter(Mandatory)][string]$Label, [Parameter(Mandatory)][scriptblock]$Action)
    $Timer = [Diagnostics.Stopwatch]::StartNew()
    $Complete = $false
    Write-Host "[$(Get-Date -Format HH:mm:ss)] Starting: $Label"
    try {
        & $Action
        $Complete = $true
    } finally {
        $Result = if ($Complete) { 'Completed' } else { 'Failed' }
        Write-Host "[$(Get-Date -Format HH:mm:ss)] ${Result}: $Label ($($Timer.Elapsed.ToString('hh\:mm\:ss')))"
    }
}

function Get-BuildCacheDirectory {
    param([Parameter(Mandatory)][string]$Worktree)
    $Common = (git -C $Worktree rev-parse --path-format=absolute --git-common-dir).Trim()
    Join-Path $Common 'as-custom/cache'
}
