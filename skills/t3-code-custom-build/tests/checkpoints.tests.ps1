$ErrorActionPreference = 'Stop'
$Root = Join-Path ([IO.Path]::GetTempPath()) ("t3-checkpoint-test-" + [guid]::NewGuid().ToString('N'))
. (Join-Path $PSScriptRoot '../scripts/checkpoints.ps1')
try {
    New-Item -ItemType Directory -Path $Root | Out-Null
    $File = Join-Path $Root 'output'
    Set-Content $File 'verified bytes'
    Save-BuildCheckpoint -Scratch $Root -Name fixture -Key inputs -Files @($File)
    if (!(Test-BuildCheckpoint -Scratch $Root -Name fixture -Key inputs -Files @($File))) { throw 'Valid result was not reused' }
    if (Test-BuildCheckpoint -Scratch $Root -Name fixture -Key changed -Files @($File)) { throw 'Changed inputs reused a result' }
    Set-Content $File 'tampered bytes'
    if (Test-BuildCheckpoint -Scratch $Root -Name fixture -Key inputs -Files @($File)) { throw 'Tampered output reused a result' }
    Remove-Item $File
    if (Test-BuildCheckpoint -Scratch $Root -Name fixture -Key inputs -Files @($File)) { throw 'Missing output reused a result' }
    Set-Content (Join-Path $Root 'fixture.checkpoint.json') '{'
    if (Test-BuildCheckpoint -Scratch $Root -Name fixture -Key inputs -Files @($File)) { throw 'Interrupted metadata reused a result' }
    Clear-BuildCheckpoint -Scratch $Root -Name fixture
    if (Test-Path (Join-Path $Root 'fixture.checkpoint.json')) { throw 'Failed-stage invalidation kept old success' }
    $Key = Get-CustomBuildKey -BuildSha source -Version 0.1.1 -MainSha main
    if ($Key -ceq (Get-CustomBuildKey -BuildSha source -Version 0.1.2 -MainSha main) -or
        $Key -ceq (Get-CustomBuildKey -BuildSha source -Version 0.1.1 -MainSha other)) { throw 'Build inputs are absent from checkpoint key' }
    Write-Host 'PASS: content-verified reuse; source/version/base invalidation; missing/tampered/interrupted checkpoints; failure invalidation'
} finally { Remove-Item -LiteralPath $Root -Recurse -Force }
