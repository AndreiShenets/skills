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

function Get-BuildDataDirectory {
    param([Parameter(Mandatory)][string]$Worktree)
    $Common = (git -C $Worktree rev-parse --path-format=absolute --git-common-dir).Trim()
    $MainCheckout = Split-Path $Common -Parent
    Join-Path (Split-Path $MainCheckout -Parent) ((Split-Path $MainCheckout -Leaf) + '-as-custom')
}

function Get-BuildCacheDirectory {
    param([Parameter(Mandatory)][string]$Worktree)
    Join-Path (Get-BuildDataDirectory -Worktree $Worktree) 'cache'
}

function Assert-BuildWorktreeLocation {
    param([Parameter(Mandatory)][string]$Path)
    if ([IO.Path]::GetFullPath($Path) -match '(^|[\\/])\.git([\\/]|$)') {
        throw "Build worktrees must be outside .git: $Path. Move the worktree with git worktree move and update Work in run.json."
    }
}

function Get-BuildWorktreeDirectory {
    param(
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][ValidatePattern('^[\w-]+$')][string]$RunName
    )
    $Root = Get-BuildDataDirectory -Worktree $Worktree
    $Path = Join-Path $Root $RunName
    Assert-BuildWorktreeLocation -Path $Path
    $Path
}
