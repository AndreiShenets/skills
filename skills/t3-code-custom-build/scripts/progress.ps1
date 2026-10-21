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

function Get-MainCheckoutDirectory {
    param([Parameter(Mandatory)][string]$Worktree)
    # Git lists the main checkout first, independent of the caller's branch/worktree.
    $Entry = @(git -C $Worktree -c core.quotepath=false worktree list --porcelain)[0]
    if (!$Entry.StartsWith('worktree ') -or !(Test-Path -LiteralPath (Join-Path $Entry.Substring(9) '.git'))) {
        throw 'Cannot resolve the main Git checkout for build caches'
    }
    $Entry.Substring(9)
}

function Get-BuildDataDirectory {
    param([Parameter(Mandatory)][string]$Worktree)
    Join-Path (Get-MainCheckoutDirectory -Worktree $Worktree) 'release/as-custom'
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
