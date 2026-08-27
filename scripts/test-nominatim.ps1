#Requires -Version 5.1
<#
.SYNOPSIS
    Tests Nominatim geocoding with Portal DOM (CBS) payload style.
    Cases loaded from scripts/nominatim-cases.json
#>
param(
    [string]$BaseUrl = "http://localhost:8080",
    [string]$CasesFile = "$PSScriptRoot\nominatim-cases.json"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $CasesFile)) {
    Write-Error "Missing cases file: $CasesFile"
}

$Tests = Get-Content $CasesFile -Raw -Encoding UTF8 | ConvertFrom-Json

Write-Host "=== Nominatim test: $BaseUrl ===" -ForegroundColor Cyan
Write-Host ("Cases: {0} (from {1})" -f $Tests.Count, $CasesFile)
Write-Host ""

$Passed = 0
$Failed = 0

foreach ($Test in $Tests) {
    $Url = "$BaseUrl/search?$($Test.query)"
    Write-Host "Test: $($Test.name)" -NoNewline

    try {
        $Response = Invoke-RestMethod -Uri $Url -Method Get -TimeoutSec 30

        if ($Response.Count -eq 0 -or -not $Response[0].lat) {
            Write-Host " FAIL (no results)" -ForegroundColor Red
            $Failed++
            continue
        }

        $Result = $Response[0]
        $Lat = [double]$Result.lat
        $Lon = [double]$Result.lon

        if ($Lat -eq 0 -and $Lon -eq 0) {
            Write-Host " FAIL (0,0)" -ForegroundColor Red
            $Failed++
            continue
        }

        Write-Host " OK" -ForegroundColor Green
        Write-Host "  lat=$Lat lon=$Lon display=$($Result.display_name)"
        $Passed++
    }
    catch {
        Write-Host " FAIL ($($_.Exception.Message))" -ForegroundColor Red
        $Failed++
    }
}

Write-Host ""
Write-Host "Result: $Passed passed, $Failed failed" -ForegroundColor $(if ($Failed -eq 0) { "Green" } else { "Yellow" })

try {
    $null = Invoke-RestMethod -Uri "$BaseUrl/status" -TimeoutSec 5
    Write-Host "Nominatim status: OK"
}
catch {
    Write-Host "Nominatim status: unavailable (import may still be running)" -ForegroundColor Yellow
}

exit $(if ($Failed -eq 0) { 0 } else { 1 })
