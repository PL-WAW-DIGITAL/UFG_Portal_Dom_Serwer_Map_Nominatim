#Requires -Version 5.1
<#
.SYNOPSIS
    Filters PBF for Nominatim: places, highways, admin boundaries (no POI).
.DESCRIPTION
    Full poland-latest.osm.pbf stays for Planetiler/tiles.
    Output poland-filtered.osm.pbf is used by Nominatim (IMPORT_STYLE=street).
#>
param(
    [string]$SourcePbf = "$PSScriptRoot\..\data\pbf\poland-latest.osm.pbf",
    [string]$OutputPbf = "$PSScriptRoot\..\data\pbf\poland-filtered.osm.pbf"
)

$ErrorActionPreference = "Stop"
$SourcePbf = [System.IO.Path]::GetFullPath($SourcePbf)
$OutputPbf = [System.IO.Path]::GetFullPath($OutputPbf)
$InputDir = Split-Path $SourcePbf -Parent
$InputName = Split-Path $SourcePbf -Leaf
$OutputName = Split-Path $OutputPbf -Leaf

if (-not (Test-Path $SourcePbf)) { throw "Missing file: $SourcePbf" }

Write-Host "Filtering PBF: $InputName -> $OutputName"
Write-Host "Keep: place=*, highway=*, boundary=administrative (no amenity/shop/tourism POI)"

docker run --rm `
    -v "${InputDir}:/data" `
    iboates/osmium:latest `
    tags-filter "/data/$InputName" `
        n/place `
        w/place `
        r/place `
        w/highway `
        r/boundary=administrative `
        n/boundary=administrative `
        w/boundary=administrative `
    -o "/data/$OutputName" `
    --overwrite

if ($LASTEXITCODE -ne 0) { throw "osmium tags-filter failed (exit $LASTEXITCODE)" }

$InMb = [math]::Round((Get-Item $SourcePbf).Length / 1MB, 1)
$OutMb = [math]::Round((Get-Item $OutputPbf).Length / 1MB, 1)
Write-Host ("Success: {0} ({1} MB -> {2} MB)" -f $OutputPbf, $InMb, $OutMb)
Write-Host "Nominatim: PBF_PATH=/data/pbf/$OutputName IMPORT_STYLE=street"
