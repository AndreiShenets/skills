function Get-T3ConnectPublicConfig {
    param([Parameter(Mandatory)][string]$Worktree, [string]$Repo = $Worktree)
    $Json = node (Join-Path $PSScriptRoot 'public-config.mjs') $Worktree $Repo
    if ($LASTEXITCODE -ne 0) { throw 'Could not resolve public T3 Connect configuration; check .env.example and deployment overrides' }
    $Json | ConvertFrom-Json -AsHashtable
}

function Invoke-WithT3ConnectPublicConfig {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config, [Parameter(Mandatory)][scriptblock]$Action)
    $Previous = @{}
    try {
        foreach ($Key in $Config.Keys) {
            $Previous[$Key] = [Environment]::GetEnvironmentVariable($Key, 'Process')
            [Environment]::SetEnvironmentVariable($Key, $Config[$Key], 'Process')
        }
        & $Action
    } finally {
        foreach ($Key in $Previous.Keys) {
            if ($null -eq $Previous[$Key]) { Remove-Item -LiteralPath "Env:$Key" -ErrorAction SilentlyContinue }
            else { [Environment]::SetEnvironmentVariable($Key, $Previous[$Key], 'Process') }
        }
    }
}
