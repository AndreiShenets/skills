function Invoke-WorktreeVp {
    param(
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$BootstrapRepo
    )
    $PSNativeCommandArgumentPassing = 'Standard'
    $PreviousEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    try {
        $Manifest = Join-Path $Worktree 'node_modules/vite-plus/package.json'
        if (!(Test-Path -LiteralPath $Manifest) -and $Arguments[0] -eq 'install' -and $BootstrapRepo) {
            $Manifest = Join-Path $BootstrapRepo 'node_modules/vite-plus/package.json'
        }
        if (Test-Path -LiteralPath $Manifest) {
            $Package = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
            $Bin = if ($Package.bin -is [string]) { $Package.bin } else { $Package.bin.vp }
            if (!$Bin) { throw "Vite+ has no vp entry point: $Manifest" }
            $Cli = Join-Path (Split-Path $Manifest) $Bin
            if (!(Test-Path -LiteralPath $Cli -PathType Leaf)) { throw "Missing Vite+ entry point: $Cli" }
            & node $Cli @Arguments
        } elseif ($Arguments[0] -eq 'install') {
            $Vp = Get-Command vp -CommandType Application -ErrorAction Stop | Select-Object -First 1
            & $Vp.Source @Arguments
        } else {
            throw "Install dependencies in the build worktree first: $Worktree"
        }
    } finally { [Console]::OutputEncoding = $PreviousEncoding }
}

function Split-BuildFileArguments {
    param([string[]]$Prefix, [string[]]$Files, [int]$MaxCharacters = 7000)
    $Batch = [Collections.Generic.List[string]]::new()
    $Length = ($Prefix -join ' ').Length
    foreach ($File in $Files) {
        if ($Batch.Count -and $Length + $File.Length + 3 -gt $MaxCharacters) {
            @{ Arguments = @($Prefix) + $Batch.ToArray() }
            $Batch.Clear()
            $Length = ($Prefix -join ' ').Length
        }
        $Batch.Add($File)
        $Length += $File.Length + 3
    }
    if ($Batch.Count) { @{ Arguments = @($Prefix) + $Batch.ToArray() } }
}
