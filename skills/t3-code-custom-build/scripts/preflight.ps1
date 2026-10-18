$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
. (Join-Path $PSScriptRoot 'progress.ps1')

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
            foreach ($Suffix in @('.test.ts', '.test.tsx', '.spec.ts', '.spec.tsx')) {
                $Candidate = "$Stem$Suffix"
                if (Test-Path -LiteralPath (Join-Path $Worktree $Candidate) -PathType Leaf) { $Candidate }
            }
        }
    } | Sort-Object -Unique)
    $ManualTests = @($Tests | Where-Object { $_ -match '\.(?:browser|live)\.(?:test|spec)\.' })
    $Tests = @($Tests | Where-Object { $_ -notin $ManualTests })
    $Packages = @($ChangedPaths | ForEach-Object {
        if ($_ -match '^((?:apps|packages)/[^/]+)/') { $Matches[1] }
    } | Sort-Object -Unique | Where-Object {
        $Manifest = Join-Path $Worktree "$_/package.json"
        (Test-Path -LiteralPath $Manifest) -and (Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json).scripts.typecheck
    })

    function Invoke-PreflightCommand {
        param([string]$Label, [string[]]$Arguments)
        Invoke-BuildStep -Label $Label -Action {
            "vp $($Arguments -join ' ')" | Tee-Object -FilePath $LogPath -Append | Write-Host
            $PSNativeCommandUseErrorActionPreference = $false
            vp @Arguments 2>&1 | Tee-Object -FilePath $LogPath -Append | Out-Host
            if ($LASTEXITCODE -ne 0) {
                "FAIL: $Label (exit $LASTEXITCODE)" | Tee-Object -FilePath $LogPath -Append | Write-Host
                throw "$Label failed (exit $LASTEXITCODE); see $LogPath"
            }
            "PASS: $Label" | Tee-Object -FilePath $LogPath -Append | Write-Host
        }
    }

    Set-Content -LiteralPath $LogPath -Encoding utf8NoBOM -Value "Preflight: $BaseRef..HEAD"
    foreach ($File in $ManualTests) {
        "Manual verification not run (browser/live): $File" | Tee-Object -FilePath $LogPath -Append | Write-Host
    }
    $PreviousElectronRunAsNode = [Environment]::GetEnvironmentVariable('ELECTRON_RUN_AS_NODE', 'Process')
    Push-Location $Worktree
    try {
        # The harness flag leaks into subprocess fixtures and makes them look like Electron probes.
        [Environment]::SetEnvironmentVariable('ELECTRON_RUN_AS_NODE', $null, 'Process')
        if ($FormatFiles.Count) {
            Invoke-PreflightCommand 'Preflight formatting' (@('fmt', '--check', '--no-error-on-unmatched-pattern') + $FormatFiles)
        }
        if ($CodeFiles.Count) {
            Invoke-PreflightCommand 'Preflight lint' (@('lint', '--report-unused-disable-directives') + $CodeFiles)
        }
        foreach ($Package in $Packages) {
            Invoke-PreflightCommand "Preflight typecheck $Package" @('run', '--filter', "./$Package", 'typecheck')
        }
        if (@($Files | Where-Object { $_ -like 'scripts/*' }).Count -and (Test-Path 'scripts/tsconfig.json')) {
            Invoke-PreflightCommand 'Preflight typecheck scripts' @('exec', 'tsc-rs', '--project', 'scripts/tsconfig.json', '--noEmit')
        }
        if ($Tests.Count) {
            Invoke-PreflightCommand 'Preflight focused tests' (@('test', 'run') + $Tests)
        }
    } finally {
        [Environment]::SetEnvironmentVariable('ELECTRON_RUN_AS_NODE', $PreviousElectronRunAsNode, 'Process')
        Pop-Location
    }
}
