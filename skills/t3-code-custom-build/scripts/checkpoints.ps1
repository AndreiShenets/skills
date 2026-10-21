function Get-CustomBuildKey {
    param(
        [string]$BuildSha, [string]$Version, [string]$MainSha = '', [string]$RunId = '',
        [System.Collections.IDictionary]$PublicConfig = @{},
        [ValidateSet('preflight', 'windows', 'linux', 'installer')][string]$Stage = 'installer',
        [string]$ToolchainIdentity = ''
    )
    $Inputs = @('stage-keys-v2', $Stage, $BuildSha, $Version, $MainSha, $RunId, (node --version), $ToolchainIdentity)
    foreach ($Key in ($PublicConfig.Keys | Sort-Object)) { $Inputs += "${Key}=$($PublicConfig[$Key])" }
    $Common = @('checkpoints.ps1', 'git.ps1', 'progress.ps1', 'tooling.ps1', 'public-config.ps1', 'public-config.mjs')
    $Scripts = switch ($Stage) {
        preflight { $Common + @('preflight.ps1', 'workflow.ps1') }
        windows { $Common + @('workflow.ps1') }
        linux { $Common + @('build-with-wsl.ps1', 'linux-build.sh', 'linux-cache.ps1', 'linux-build.Dockerfile') }
        installer { $Common + @('workflow.ps1', 'preflight.ps1', 'build-with-wsl.ps1', 'linux-build.sh', 'linux-cache.ps1', 'linux-build.Dockerfile', 'wsl-smoke.sh') }
    }
    foreach ($Name in ($Scripts | Sort-Object -Unique)) {
        $File = Get-Item -LiteralPath (Join-Path $PSScriptRoot $Name)
        $Inputs += "$($File.Name):$((Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash)"
    }
    $Bytes = [Text.Encoding]::UTF8.GetBytes(($Inputs -join "`n"))
    "$BuildSha-$([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)))"
}

function Get-WindowsBuildOutputs {
    param([Parameter(Mandatory)][string]$Worktree)
    # Keep the complete output inventory: missing, added and changed files invalidate reuse.
    $Directories = @('apps/desktop/dist-electron', 'apps/server/dist')
    foreach ($Directory in $Directories) {
        $Path = Join-Path $Worktree $Directory
        if (!(Test-Path -LiteralPath $Path -PathType Container)) { return }
        $Files = @(Get-ChildItem -LiteralPath $Path -File -Recurse -Force)
        if (!$Files.Count) { return }
    }
    if (!(Test-Path -LiteralPath (Join-Path $Worktree 'apps/server/dist/client/index.html') -PathType Leaf)) { return }
    foreach ($Directory in $Directories) {
        Get-ChildItem -LiteralPath (Join-Path $Worktree $Directory) -File -Recurse -Force |
            Sort-Object FullName | ForEach-Object { $_.FullName }
    }
}

function Test-BuildCheckpoint {
    param([string]$Scratch, [string]$Name, [string]$Key, [string[]]$Files)
    $Record = Join-Path $Scratch "$Name.checkpoint.json"
    if (!(Test-Path -LiteralPath $Record)) { return $false }
    try {
        $Saved = Get-Content -LiteralPath $Record -Raw | ConvertFrom-Json -AsHashtable
        if ($Saved.Key -cne $Key -or $Saved.Files.Count -ne $Files.Count) { return $false }
        foreach ($File in $Files) {
            if (!(Test-Path -LiteralPath $File -PathType Leaf) -or
                !$Saved.Files.Contains($File) -or
                (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash -cne $Saved.Files[$File]) { return $false }
        }
        return $true
    } catch { return $false }
}

function Save-BuildCheckpoint {
    param([string]$Scratch, [string]$Name, [string]$Key, [string[]]$Files)
    $Hashes = [ordered]@{}
    foreach ($File in $Files) { $Hashes[$File] = (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash }
    $Record = Join-Path $Scratch "$Name.checkpoint.json"
    @{ Key = $Key; Files = $Hashes } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$Record.tmp" -Encoding utf8NoBOM
    [IO.File]::Move("$Record.tmp", $Record, $true)
}

function Clear-BuildCheckpoint {
    param([string]$Scratch, [string]$Name)
    [IO.File]::Delete((Join-Path $Scratch "$Name.checkpoint.json"))
}
