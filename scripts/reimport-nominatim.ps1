#Requires -Version 5.1
<#
.SYNOPSIS
    Full Nominatim reimport from poland-filtered.osm.pbf (no POI).
.DESCRIPTION
    Wipes nominatim Docker volumes and starts a fresh import.
    Requires poland-filtered.osm.pbf (run filter-pbf.ps1 / download-pbf.ps1 first).
#>
param(
    [switch]$SkipFilter,
    [switch]$Force
)

$ErrorActionPreference = "Continue"
$ProjectRoot = Split-Path $PSScriptRoot -Parent
$Filtered = Join-Path $ProjectRoot "data\pbf\poland-filtered.osm.pbf"
$Full = Join-Path $ProjectRoot "data\pbf\poland-latest.osm.pbf"

Push-Location $ProjectRoot
try {
    if (-not $SkipFilter) {
        if (-not (Test-Path $Full)) {
            throw "Missing $Full - run download-pbf.ps1 first"
        }
        Write-Host "Ensuring filtered PBF..."
        & "$PSScriptRoot\filter-pbf.ps1"
        if ($LASTEXITCODE -ne 0) { throw "filter-pbf failed" }
    }

    if (-not (Test-Path $Filtered)) { throw "Missing $Filtered" }
    $Mb = [math]::Round((Get-Item $Filtered).Length / 1MB, 1)
    Write-Host "Filtered PBF: $Mb MB"

    if (-not $Force) {
        $ans = Read-Host "This WIPES nominatim volumes and starts a full reimport. Type YES to continue"
        if ($ans -ne "YES") { Write-Host "Aborted."; exit 1 }
    }

    Write-Host "Stopping nominatim..."
    docker compose stop nominatim | Out-Null

    Write-Host "Removing nominatim container + volumes..."
    docker compose rm -f nominatim | Out-Null

    $project = "nominatimpdom"
    foreach ($vol in @("${project}_nominatim-data", "${project}_nominatim-flatnode")) {
        Write-Host "Removing volume: $vol"
        docker volume rm $vol 2>$null | Out-Null
    }

    Write-Host "Starting Nominatim import (IMPORT_STYLE=street, filtered PBF)..."
    docker compose up -d nominatim
    if ($LASTEXITCODE -ne 0) { throw "docker compose up nominatim failed" }

    Write-Host ""
    Write-Host "Import started. Monitor with:"
    Write-Host "  .\scripts\watch-progress.ps1"
    Write-Host "When healthy:"
    Write-Host "  .\scripts\test-nominatim.ps1"
    Write-Host "  .\scripts\bench-load.ps1 -Target nominatim -CacheMode compare"
    exit 0
}
finally {
    Pop-Location
}
