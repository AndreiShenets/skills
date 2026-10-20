$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$Root = Join-Path 'C:/Temp/opencode' ("t3-public-config-test-" + [guid]::NewGuid().ToString('N'))
$Work = Join-Path $Root 'build'
$Repo = Join-Path $Root 'repo'
. (Join-Path $PSScriptRoot '../scripts/public-config.ps1')
$Names = @(
    'T3CODE_CLERK_PUBLISHABLE_KEY', 'VITE_CLERK_PUBLISHABLE_KEY', 'EXPO_PUBLIC_CLERK_PUBLISHABLE_KEY',
    'T3CODE_CLERK_JWT_TEMPLATE', 'VITE_CLERK_JWT_TEMPLATE', 'EXPO_PUBLIC_CLERK_JWT_TEMPLATE',
    'T3CODE_CLERK_CLI_OAUTH_CLIENT_ID', 'VITE_CLERK_CLI_OAUTH_CLIENT_ID',
    'T3CODE_RELAY_URL', 'VITE_T3CODE_RELAY_URL'
)
$Previous = @{}
foreach ($Name in $Names) {
    $Previous[$Name] = [Environment]::GetEnvironmentVariable($Name, 'Process')
    Remove-Item -LiteralPath "Env:$Name" -ErrorAction SilentlyContinue
}
try {
    New-Item -ItemType Directory -Path $Work, $Repo | Out-Null
    $Example = @'
T3CODE_CLERK_PUBLISHABLE_KEY=pk_live_fixture
T3CODE_CLERK_JWT_TEMPLATE=example-template
T3CODE_CLERK_CLI_OAUTH_CLIENT_ID=example-oauth
T3CODE_RELAY_URL=https://relay.example.test
CLERK_SECRET_KEY=fixture-not-for-client
UNRELATED_SETTING=leave-out
'@
    Set-Content "$Work/.env.example" $Example
    $Config = Get-T3ConnectPublicConfig -Worktree $Work -Repo $Repo
    if ($Config.Count -ne 4 -or $Config.T3CODE_CLERK_JWT_TEMPLATE -cne 'example-template' -or
        $Config.T3CODE_RELAY_URL -cne 'https://relay.example.test') { throw 'Fresh worktree did not use only public defaults' }
    if ((Get-ChildItem $Work -Force).Count -ne 1) { throw 'Resolution wrote an env file' }

    Set-Content "$Repo/.env" 'T3CODE_CLERK_JWT_TEMPLATE=repo-env'
    Set-Content "$Repo/.env.local" 'VITE_CLERK_JWT_TEMPLATE=repo-local'
    if ((Get-T3ConnectPublicConfig $Work $Repo).T3CODE_CLERK_JWT_TEMPLATE -cne 'repo-local') { throw 'Source checkout overrides were lost' }
    Set-Content "$Work/.env" 'T3CODE_CLERK_JWT_TEMPLATE=work-env'
    if ((Get-T3ConnectPublicConfig $Work $Repo).T3CODE_CLERK_JWT_TEMPLATE -cne 'work-env') { throw 'Source checkout overrode build checkout' }
    Set-Content "$Work/.env.local" 'EXPO_PUBLIC_CLERK_JWT_TEMPLATE="work local"'
    if ((Get-T3ConnectPublicConfig $Work $Repo).T3CODE_CLERK_JWT_TEMPLATE -cne 'work local') { throw 'Build-local quoted alias was not preserved' }
    $Before = Get-Content "$Work/.env.local" -Raw
    $env:VITE_CLERK_JWT_TEMPLATE = 'process-alias'
    if ((Get-T3ConnectPublicConfig $Work $Repo).T3CODE_CLERK_JWT_TEMPLATE -cne 'process-alias') { throw 'Process alias lost to file canonical name' }
    $env:T3CODE_CLERK_JWT_TEMPLATE = 'process-canonical'
    $Config = Get-T3ConnectPublicConfig $Work $Repo
    if ($Config.T3CODE_CLERK_JWT_TEMPLATE -cne 'process-canonical') { throw 'Process canonical name lost to alias' }

    Invoke-WithT3ConnectPublicConfig -Config $Config -Action {
        if ($env:T3CODE_RELAY_URL -cne 'https://relay.example.test') { throw 'Build did not receive config' }
    }
    if (Test-Path Env:T3CODE_RELAY_URL) { throw 'Absent process variable was not restored' }
    $Caught = $false
    try {
        Invoke-WithT3ConnectPublicConfig -Config $Config -Action { throw 'fixture build failure' }
    } catch {
        if ($_.Exception.Message -cne 'fixture build failure') { throw }
        $Caught = $true
    }
    if (!$Caught -or (Test-Path Env:T3CODE_RELAY_URL) -or $env:T3CODE_CLERK_JWT_TEMPLATE -cne 'process-canonical') { throw 'Failure did not restore caller environment' }
    if ((Get-Content "$Work/.env.local" -Raw) -cne $Before) { throw 'Existing deployment file was changed' }

    foreach ($Override in @(
        @{ T3CODE_RELAY_URL = 'http://insecure.example.test' },
        @{ T3CODE_RELAY_URL = 'https://user:password@example.test' },
        @{ T3CODE_CLERK_PUBLISHABLE_KEY = 'placeholder' },
        @{ T3CODE_CLERK_JWT_TEMPLATE = "invalid`nvalue" }
    )) {
        $Rejected = $false
        Invoke-WithT3ConnectPublicConfig -Config $Override -Action {
            try { Get-T3ConnectPublicConfig $Work $Repo 2>$null | Out-Null } catch { $script:Rejected = $true }
        }
        if (!$Rejected) { throw 'Invalid public configuration was accepted' }
    }
    Remove-Item "$Work/.env.example"
    $Rejected = $false
    try { Get-T3ConnectPublicConfig $Work $Repo 2>$null | Out-Null } catch { $Rejected = $true }
    if (!$Rejected) { throw 'Missing required configuration was accepted' }
    Write-Host 'PASS: public-only defaults; process/build/source override precedence; aliases; no file writes; validation; environment restoration on success/failure'
} finally {
    foreach ($Name in $Previous.Keys) {
        if ($null -eq $Previous[$Name]) { Remove-Item -LiteralPath "Env:$Name" -ErrorAction SilentlyContinue }
        else { [Environment]::SetEnvironmentVariable($Name, $Previous[$Name], 'Process') }
    }
    Remove-Item -LiteralPath $Root -Recurse -Force
}
