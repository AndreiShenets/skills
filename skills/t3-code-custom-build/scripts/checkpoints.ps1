function Get-CustomBuildKey {
    param([string]$BuildSha, [string]$Version, [string]$MainSha = '', [string]$RunId = '', [System.Collections.IDictionary]$PublicConfig = @{})
    $Inputs = @($BuildSha, $Version, $MainSha, $RunId, (node --version))
    foreach ($Key in ($PublicConfig.Keys | Sort-Object)) { $Inputs += "${Key}=$($PublicConfig[$Key])" }
    foreach ($File in (Get-ChildItem -LiteralPath $PSScriptRoot -File | Sort-Object Name)) {
        $Inputs += "$($File.Name):$((Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash)"
    }
    $Bytes = [Text.Encoding]::UTF8.GetBytes(($Inputs -join "`n"))
    "$BuildSha-$([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)))"
}

function Test-BuildCheckpoint {
    param([string]$Scratch, [string]$Name, [string]$Key, [string[]]$Files)
    $Record = Join-Path $Scratch "$Name.checkpoint.json"
    if (!(Test-Path -LiteralPath $Record)) { return $false }
    try {
        $Saved = Get-Content -LiteralPath $Record -Raw | ConvertFrom-Json -AsHashtable
        if ($Saved.Key -cne $Key -or $Saved.Files.Count -ne $Files.Count) { return $false }
        foreach ($File in $Files) {
            if (!(Test-Path -LiteralPath $File -PathType Leaf) -or
                !$Saved.Files.Contains($File) -or
                (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash -cne $Saved.Files[$File]) { return $false }
        }
        return $true
    } catch { return $false }
}

function Save-BuildCheckpoint {
    param([string]$Scratch, [string]$Name, [string]$Key, [string[]]$Files)
    $Hashes = [ordered]@{}
    foreach ($File in $Files) { $Hashes[$File] = (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash }
    $Record = Join-Path $Scratch "$Name.checkpoint.json"
    @{ Key = $Key; Files = $Hashes } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$Record.tmp" -Encoding utf8NoBOM
    [IO.File]::Move("$Record.tmp", $Record, $true)
}

function Clear-BuildCheckpoint {
    param([string]$Scratch, [string]$Name)
    [IO.File]::Delete((Join-Path $Scratch "$Name.checkpoint.json"))
}
