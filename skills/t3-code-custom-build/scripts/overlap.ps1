param(
    [ValidateSet('Plan', 'Save')][string]$Action = 'Plan',
    [Parameter(Mandatory)][string]$Repo,
    [Parameter(Mandatory)][string]$UpstreamRef,
    [Parameter(Mandatory)][string]$NightlyTag,
    [Parameter(Mandatory)][string]$PublishedRef,
    [string]$FindingsFile
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
. (Join-Path $PSScriptRoot 'overlap-cache.ps1')
$Inputs = @{
    Repo = $Repo; NightlyTag = $NightlyTag
    UpstreamSha = (git -C $Repo rev-parse "$UpstreamRef^{commit}").Trim()
    PublishedSha = (git -C $Repo rev-parse "$PublishedRef^{commit}").Trim()
}
if ($Action -eq 'Save') {
    if (!$FindingsFile) { throw 'Save requires agent-verified -FindingsFile' }
    Save-OverlapFindings @Inputs -FindingsFile $FindingsFile
} else {
    $Directory = Join-Path (Get-BuildCacheDirectory $Repo) 'overlap/reviews'
    New-Item -ItemType Directory -Force -Path $Directory | Out-Null
    $Plan = Join-Path $Directory ("review-$([guid]::NewGuid().ToString('N')).json")
    Get-OverlapReviewPlan @Inputs | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $Plan -Encoding utf8NoBOM
    Write-Host "Overlap review plan: $Plan"
}
