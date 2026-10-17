$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

function Get-CustomRelease {
    param([string]$Tag)
    $PSNativeCommandUseErrorActionPreference = $false
    $Output = gh release view $Tag --repo AndreiShenets/t3code --json tagName,name,url,isDraft,isPrerelease,assets 2>&1
    if ($LASTEXITCODE -eq 0) { return (($Output -join "`n") | ConvertFrom-Json) }
    if (($Output -join "`n") -match 'release not found|HTTP 404') { return $null }
    throw "Cannot inspect release: $($Output -join '`n')"
}

function Get-RemoteTagCommit {
    param([string]$Work, [string]$Tag)
    $Refs = @(git -C $Work ls-remote origin "refs/tags/$Tag" "refs/tags/$Tag^{}")
    $Peeled = @($Refs | Where-Object { $_.EndsWith("refs/tags/$Tag^{}") })
    if ($Peeled.Count) { return ($Peeled[0] -split '\s+')[0] }
    if ($Refs.Count) { return ($Refs[0] -split '\s+')[0] }
}

function Publish-CustomRelease {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$NotesFile)
    $AssetName = "T3-Code-AS-Custom-$($State.Version)-$($State.Stamp)-x64.exe"
    $Installer = Join-Path $State.Out $AssetName
    Copy-Item (Join-Path $State.Out "T3-Code-$($State.Version)-x64.exe") $Installer
    $Checksums = Join-Path $State.Out 'SHA256SUMS'
    $ExeSha = (Get-FileHash $Installer -Algorithm SHA256).Hash.ToLowerInvariant()
    "$ExeSha  $AssetName" | Set-Content $Checksums -Encoding utf8NoBOM
    $Tag = "as-custom-v$($State.Version)-$($State.Stamp)"
    $Title = "T3 Code AS Custom $($State.Version) $($State.Stamp) ($($State.MainSha.Substring(0, 12)))"
    $Local = @(git -C $State.Work for-each-ref '--format=%(refname)' "refs/tags/$Tag")
    if ($Local -ccontains "refs/tags/$Tag") {
        if ((git -C $State.Work rev-parse "$Tag^{commit}").Trim() -ne $State.BuildSha) { throw 'Local tag target mismatch' }
    }
    $Remote = Get-RemoteTagCommit $State.Work $Tag
    if ($Remote) {
        if ($Remote -ne $State.BuildSha) { throw 'Remote tag target mismatch' }
        if ($Local -cnotcontains "refs/tags/$Tag") {
            git -C $State.Work fetch origin "refs/tags/${Tag}:refs/tags/$Tag" | Out-Host
        }
    } else {
        if ($Local -cnotcontains "refs/tags/$Tag") { git -C $State.Work tag -a $Tag $State.BuildSha -m $Title }
        git -C $State.Work push origin "refs/tags/$Tag" | Out-Host
    }

    $Release = Get-CustomRelease $Tag
    if (!$Release) {
        gh release create $Tag --repo AndreiShenets/t3code --verify-tag --title $Title --notes-file $NotesFile --draft --prerelease --latest=false | Out-Host
        $Release = Get-CustomRelease $Tag
    }
    if (!$Release -or $Release.tagName -cne $Tag -or $Release.name -cne $Title -or !$Release.isPrerelease) {
        throw 'Existing release metadata does not match this run'
    }
    foreach ($File in @($Installer, $Checksums)) {
        $Name = Split-Path -Leaf $File
        $Asset = @($Release.assets | Where-Object { $_.name -ceq $Name })
        if ($Release.isDraft -and $Asset.Count -eq 1 -and $Asset[0].state -eq 'starter') {
            gh release delete-asset $Tag $Name --yes --repo AndreiShenets/t3code | Out-Host
            $Asset = @()
        }
        if (!$Asset.Count) {
            if (!$Release.isDraft) { throw "Published release is missing $Name" }
            gh release upload $Tag $File --repo AndreiShenets/t3code | Out-Host
        } elseif ($Asset.Count -ne 1 -or $Asset[0].size -ne (Get-Item $File).Length) {
            throw "Existing release asset mismatch: $Name"
        }
    }
    $Verify = Join-Path $State.Scratch 'download-verification'
    gh release download $Tag --repo AndreiShenets/t3code --dir $Verify --pattern $AssetName --pattern SHA256SUMS --clobber | Out-Host
    if ((Get-FileHash (Join-Path $Verify $AssetName) -Algorithm SHA256).Hash.ToLowerInvariant() -ne $ExeSha) {
        throw 'Uploaded installer checksum mismatch'
    }
    if ((Get-Content (Join-Path $Verify 'SHA256SUMS') -Raw).Trim() -cne "$ExeSha  $AssetName") {
        throw 'Uploaded checksum file mismatch'
    }
    if ((Get-RemoteTagCommit $State.Work $Tag) -ne $State.BuildSha) { throw 'Remote tag target mismatch' }
    git -C $State.Work merge-base --is-ancestor $State.MainSha $State.BuildSha
    if ($Release.isDraft) {
        gh release edit $Tag --repo AndreiShenets/t3code --draft=false --prerelease --latest=false | Out-Host
    }
    $Release = Get-CustomRelease $Tag
    if (!$Release -or $Release.isDraft -or !$Release.isPrerelease) { throw 'Publication state mismatch' }
    return $Release.url
}
