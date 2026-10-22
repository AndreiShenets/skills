$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
. (Join-Path $PSScriptRoot 'progress.ps1')
. (Join-Path $PSScriptRoot 'tooling.ps1')

function Invoke-CustomBuildPreflight {
    param(
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][string]$BaseRef,
        [Parameter(Mandatory)][string]$LogPath
    )
    git -C $Worktree merge-base --is-ancestor $BaseRef HEAD
    $ChangedPaths = @(git -C $Worktree -c core.quotepath=false diff --no-renames --name-only --diff-filter=ACMDT $BaseRef HEAD | Sort-Object -Unique)
    $Files = @($ChangedPaths | Where-Object { Test-Path -LiteralPath (Join-Path $Worktree $_) -PathType Leaf })
    $CodeFiles = @($Files | Where-Object { $_ -match '\.[cm]?[jt]sx?$' })
    $FormatFiles = @($Files | Where-Object { $_ -match '\.(?:[cm]?[jt]sx?|jsonc?|ya?ml|md|css|html)$' })
    $Tests = @($CodeFiles | ForEach-Object {
        if ($_ -match '\.(?:test|spec)\.[cm]?[jt]sx?$') { $_ }
        else {
            $Stem = $_ -replace '\.[cm]?[jt]sx?$', ''
            foreach ($Kind in @('', '.browser', '.live')) {
                foreach ($Suffix in @('.test.ts', '.test.tsx', '.spec.ts', '.spec.tsx')) {
                    $Candidate = "$Stem$Kind$Suffix"
                    if (Test-Path -LiteralPath (Join-Path $Worktree $Candidate) -PathType Leaf) { $Candidate }
                }
            }
        }
    } | Sort-Object -Unique)
    $ManualTests = @($Tests | Where-Object { $_ -match '\.(?:browser|live)\.(?:test|spec)\.' })
    $Tests = @($Tests | Where-Object { $_ -notin $ManualTests })
    $Packages = @($ChangedPaths | ForEach-Object {
        if ($_ -match '^((?:apps|packages)/[^/]+)/') { $Matches[1] }
    } | Sort-Object -Unique | Where-Object {
        $Manifest = Join-Path $Worktree "$_/package.json"
        $ViteConfig = Join-Path $Worktree "$_/vite.config.ts"
        (Test-Path -LiteralPath $Manifest) -and (
            (Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json).scripts.typecheck -or
            ((Test-Path -LiteralPath $ViteConfig) -and (Get-Content -LiteralPath $ViteConfig -Raw) -match '\btypecheck\s*:')
        )
    })

    function Invoke-PreflightCommand {
        param([string]$Label, [string[]]$Arguments)
        Invoke-BuildStep -Label $Label -Action {
            "vp $($Arguments -join ' ')" | Tee-Object -FilePath $LogPath -Append | Write-Host
            $PSNativeCommandUseErrorActionPreference = $false
            Invoke-WorktreeVp -Worktree $Worktree -Arguments $Arguments 2>&1 | Tee-Object -FilePath $LogPath -Append | Out-Host
            if ($LASTEXITCODE -ne 0) {
                "FAIL: $Label (exit $LASTEXITCODE)" | Tee-Object -FilePath $LogPath -Append | Write-Host
                throw "$Label failed (exit $LASTEXITCODE); see $LogPath"
            }
            "PASS: $Label" | Tee-Object -FilePath $LogPath -Append | Write-Host
        }
    }

    if (Test-Path -LiteralPath $LogPath) {
        $Stem = [IO.Path]::GetFileNameWithoutExtension($LogPath)
        $Extension = [IO.Path]::GetExtension($LogPath)
        $Attempt = 0
        do {
            $Attempt++
            $Archive = Join-Path (Split-Path $LogPath -Parent) ('{0}.attempt-{1:D4}{2}' -f $Stem, $Attempt, $Extension)
        } while (Test-Path -LiteralPath $Archive)
        Move-Item -LiteralPath $LogPath -Destination $Archive
    }
    Set-Content -LiteralPath $LogPath -Encoding utf8NoBOM -Value "Preflight: $BaseRef..HEAD"
    foreach ($File in $ManualTests) {
        "Manual verification not run (browser/live): $File" | Tee-Object -FilePath $LogPath -Append | Write-Host
    }
    $EnvironmentNames = @('ELECTRON_RUN_AS_NODE', 'GH_TOKEN', 'GITHUB_TOKEN')
    $PreviousEnvironment = @{}
    foreach ($Name in $EnvironmentNames) {
        $PreviousEnvironment[$Name] = [Environment]::GetEnvironmentVariable($Name, 'Process')
    }
    Push-Location $Worktree
    try {
        # Harness flags and operator credentials must not select different fixture behavior.
        foreach ($Name in $EnvironmentNames) {
            [Environment]::SetEnvironmentVariable($Name, [NullString]::Value, 'Process')
        }
        if ($FormatFiles.Count) {
            foreach ($Batch in (Split-BuildFileArguments -Prefix @('fmt', '--check', '--no-error-on-unmatched-pattern') -Files $FormatFiles)) {
                Invoke-PreflightCommand 'Preflight formatting' $Batch.Arguments
            }
        }
        if ($CodeFiles.Count) {
            foreach ($Batch in (Split-BuildFileArguments -Prefix @('lint', '--report-unused-disable-directives') -Files $CodeFiles)) {
                Invoke-PreflightCommand 'Preflight lint' $Batch.Arguments
            }
        }
        foreach ($Package in $Packages) {
            Invoke-PreflightCommand "Preflight typecheck $Package" @('run', '--filter', "./$Package", 'typecheck')
        }
        if (@($Files | Where-Object { $_ -like 'scripts/*' }).Count -and (Test-Path 'scripts/tsconfig.json')) {
            Invoke-PreflightCommand 'Preflight typecheck scripts' @('run', '--filter', './scripts', 'typecheck')
        }
        if ($Tests.Count) {
            # Electron's lazy first import can race when test workers install it concurrently.
            Invoke-PreflightCommand 'Preflight Electron runtime' @('run', '--filter', './apps/desktop', 'ensure:electron')
            $TestPrefix = @('test', 'run')
            # Bound concurrent Git and settings-fixture I/O on Windows without retrying failures.
            if ($IsWindows) { $TestPrefix += @('--maxWorkers', '4') }
            foreach ($Batch in (Split-BuildFileArguments -Prefix $TestPrefix -Files $Tests)) {
                Invoke-PreflightCommand 'Preflight focused tests' $Batch.Arguments
            }
        }
    } finally {
        foreach ($Name in $EnvironmentNames) {
            if ($null -eq $PreviousEnvironment[$Name]) {
                [Environment]::SetEnvironmentVariable($Name, [NullString]::Value, 'Process')
            } else {
                [Environment]::SetEnvironmentVariable($Name, $PreviousEnvironment[$Name], 'Process')
            }
        }
        Pop-Location
    }
}
