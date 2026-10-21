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
    $Config = @{ T3CODE_RELAY_URL = 'https://relay.example.test' }
    $ConfiguredKey = Get-CustomBuildKey -BuildSha source -Version 0.1.1 -MainSha main -PublicConfig $Config
    if ($Key -ceq $ConfiguredKey) { throw 'Connect config did not invalidate a disabled build' }
    $Config.T3CODE_RELAY_URL = 'https://other.example.test'
    if ($ConfiguredKey -ceq (Get-CustomBuildKey -BuildSha source -Version 0.1.1 -MainSha main -PublicConfig $Config)) { throw 'Changed deployment reused a build key' }
    $Windows = Get-CustomBuildKey -Stage windows -BuildSha source -Version 0.1.1
    $Linux = Get-CustomBuildKey -Stage linux -BuildSha source -Version 0.1.1 -ToolchainIdentity image-a
    if ($Windows -ceq $Linux -or $Linux -ceq (Get-CustomBuildKey -Stage linux -BuildSha source -Version 0.1.1 -ToolchainIdentity image-b)) { throw 'Stage/toolchain identity is absent from checkpoint keys' }
    # Test dependency scopes in a disposable copy, never by mutating the skill itself.
    $Scripts = Join-Path $Root 'scripts'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../scripts') -Destination $Scripts -Recurse
    . (Join-Path $Scripts 'checkpoints.ps1')
    $BeforeWindows = Get-CustomBuildKey -Stage windows -BuildSha source -Version 0.1.1
    $BeforeLinux = Get-CustomBuildKey -Stage linux -BuildSha source -Version 0.1.1
    Add-Content (Join-Path $Scripts 'release-notes.ps1') '# notes-only change'
    if ($BeforeWindows -cne (Get-CustomBuildKey -Stage windows -BuildSha source -Version 0.1.1) -or
        $BeforeLinux -cne (Get-CustomBuildKey -Stage linux -BuildSha source -Version 0.1.1)) { throw 'Release-note changes invalidated compilation' }
    Add-Content (Join-Path $Scripts 'linux-build.sh') '# Linux-only change'
    if ($BeforeWindows -cne (Get-CustomBuildKey -Stage windows -BuildSha source -Version 0.1.1) -or
        $BeforeLinux -ceq (Get-CustomBuildKey -Stage linux -BuildSha source -Version 0.1.1)) { throw 'Linux tooling did not invalidate only its dependent stages' }
    $BeforeLinux = Get-CustomBuildKey -Stage linux -BuildSha source -Version 0.1.1
    Add-Content (Join-Path $Scripts 'workflow.ps1') '# changed client compilation/branding'
    if ($BeforeLinux -ceq (Get-CustomBuildKey -Stage linux -BuildSha source -Version 0.1.1)) { throw 'Linux archive ignored changed client compilation inputs' }
    Write-Host 'PASS: content-verified reuse; source/version/base/Connect invalidation; missing/tampered/interrupted checkpoints; failure invalidation'
} finally { Remove-Item -LiteralPath $Root -Recurse -Force }
