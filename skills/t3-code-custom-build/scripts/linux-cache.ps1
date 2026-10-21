function Get-LinuxBuildImage {
    param([Parameter(Mandatory)][string]$Worktree)
    $Dockerfile = Join-Path $PSScriptRoot 'linux-build.Dockerfile'
    $Hash = (Get-FileHash -LiteralPath $Dockerfile -Algorithm SHA256).Hash.ToLowerInvariant()
    $Tag = "t3-as-custom-linux-build:$Hash"
    # A missing image is expected on the first run, including with native error promotion enabled.
    $PSNativeCommandUseErrorActionPreference = $false
    $Image = docker image inspect --format '{{.Id}}' $Tag 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'Preparing reusable Linux build image'
        # Empty context: never send the checkout or its caches to the Docker daemon.
        Get-Content -LiteralPath $Dockerfile -Raw | docker build --platform linux/amd64 --tag $Tag - | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Could not prepare Linux build image' }
        $Image = docker image inspect --format '{{.Id}}' $Tag
        if ($LASTEXITCODE -ne 0) { throw 'Could not resolve Linux build image' }
    }
    $Identity = "$Image".Trim()
    if ($Identity -cnotmatch '^sha256:[a-f0-9]{64}$') { throw 'Invalid Linux build image identity' }
    $Identity
}

function Get-LinuxCacheNamespace {
    param([Parameter(Mandatory)][string]$Worktree)
    # Use the same main-checkout-relative identity as the shared Windows cache.
    $Root = [IO.Path]::GetFullPath((Get-BuildCacheDirectory -Worktree $Worktree)).ToLowerInvariant()
    $Bytes = [Text.Encoding]::UTF8.GetBytes($Root)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Get-LinuxBuildInputs {
    param(
        [Parameter(Mandatory)][string]$ImageId,
        [Parameter(Mandatory)][string]$SeaNode,
        [Parameter(Mandatory)][string]$VpVersion,
        [Parameter(Mandatory)][string]$CacheNamespace
    )
    $Hashes = @('linux-build.sh', 'build-with-wsl.ps1', 'linux-cache.ps1', 'linux-build.Dockerfile') | ForEach-Object {
        (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $_) -Algorithm SHA256).Hash
    }
    $Bytes = [Text.Encoding]::UTF8.GetBytes((@($ImageId, $SeaNode, $VpVersion, $CacheNamespace) + $Hashes) -join "`n")
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}
