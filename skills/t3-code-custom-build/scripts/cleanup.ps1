function Remove-PublishedBuildResources {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][scriptblock]$SaveState)
    if (!$State.ReleaseUrl) { throw 'Publish and verify the release before cleanup' }
    if ($State.RunId -notmatch '^\d{4}_\d{2}_\d{2}_\d{2}_\d{2}$') { throw 'Invalid cleanup run ID' }
    $Name = "t3-as-custom-$($State.RunId.Replace('_', '-'))"
    $Containers = @(docker ps --all --filter "name=^/$Name$" --format '{{.Names}}')
    if ($Containers -ccontains $Name) {
        $Container = docker inspect --format '{{json .}}' $Name | ConvertFrom-Json
        $Mount = @($Container.Mounts | Where-Object { $_.Destination -ceq '/build' })
        if ($Container.Name -cne "/$Name" -or $Container.State.Status -notin @('exited', 'created') -or
            $Container.Config.Env -cnotcontains "BUILD_SHA=$($State.BuildSha)" -or
            $Container.Config.Env -cnotcontains "BUILD_VERSION=$($State.Version)" -or
            $Mount.Count -ne 1 -or $Mount[0].Type -cne 'volume' -or $Mount[0].Name -cne $Name) {
            throw "Refusing cleanup of unverified or active build container: $Name"
        }
        # Persist the verified mount before removal so an interrupted cleanup can finish safely.
        $State.CleanupVolumeVerified = $Name
        & $SaveState
        docker rm $Name | Out-Host
    }
    $Volumes = @(docker volume ls --filter "name=$Name" --format '{{.Name}}')
    if ($Volumes -ccontains $Name) {
        if ($State.CleanupVolumeVerified -cne $Name) { throw "Cannot verify orphaned build volume: $Name" }
        docker volume rm $Name | Out-Host
    }
    $State.CleanupPending = $false
    & $SaveState
    Write-Host "Cleaned published build resources: $Name (shared cache retained)"
}
