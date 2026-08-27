#Requires -Version 5.1
<#
.SYNOPSIS
    Pelna procedura aktualizacji: PBF -> Nominatim -> PMTiles -> restart.
    Uruchamiac przez Task Scheduler w niedziele 00:00.
#>
param(
    [switch]$SkipNominatim,
    [switch]$SkipTiles,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$ScriptDir = $PSScriptRoot
$ProjectRoot = Split-Path $ScriptDir -Parent
$LogDir = Join-Path $ProjectRoot "data\logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogFile = Join-Path $LogDir ("update-{0:yyyy-MM-dd-HHmm}.log" -f (Get-Date))

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Line = "[{0:yyyy-MM-dd HH:mm:ss}] [{1}] {2}" -f (Get-Date), $Level, $Message
    Write-Host $Line
    Add-Content -Path $LogFile -Value $Line
}

Write-Log "=== Start procedury aktualizacji ==="

Write-Log "Krok 1/5: Pobieranie PBF (+ filter pod Nominatim)"
if ($DryRun) {
    Write-Log "[DRY RUN] download-pbf.ps1 (+ filter-pbf)" "DRY"
} else {
    & "$ScriptDir\download-pbf.ps1" -Force
    if ($LASTEXITCODE -ne 0) {
        Write-Log "Pobieranie PBF failed - kontynuacja na starych danych" "WARN"
        # Still try to refresh filtered if full PBF exists
        $FullPbf = Join-Path $ProjectRoot "data\pbf\poland-latest.osm.pbf"
        if (Test-Path $FullPbf) {
            & "$ScriptDir\filter-pbf.ps1"
        }
    }
}

if (-not $SkipNominatim) {
    Write-Log "Krok 2/5: Aktualizacja Nominatim (replication; IMPORT_STYLE=street ignoruje POI)"
    if ($DryRun) {
        Write-Log "[DRY RUN] docker compose exec nominatim replication" "DRY"
    } else {
        Push-Location $ProjectRoot
        try {
            docker compose exec nominatim nominatim replication --once 2>&1 | Tee-Object -FilePath $LogFile -Append
            if ($LASTEXITCODE -ne 0) {
                Write-Log "Replikacja Nominatim failed - stara baza aktywna" "WARN"
            }
        } catch {
            Write-Log "Nominatim update error: $_" "WARN"
        } finally {
            Pop-Location
        }
    }
}

if (-not $SkipTiles) {
    Write-Log "Krok 3/5: Generowanie PMTiles (pelny poland-latest.osm.pbf)"
    if ($DryRun) {
        Write-Log "[DRY RUN] generate-tiles.ps1" "DRY"
    } else {
        & "$ScriptDir\generate-tiles.ps1"
        if ($LASTEXITCODE -ne 0) {
            Write-Log "Generowanie kafelkow failed - stary PMTiles serwowany" "WARN"
        }
    }
}

Write-Log "Krok 4/5: Restart Martin + Nginx (flush stale cache)"
if ($DryRun) {
    Write-Log "[DRY RUN] docker compose restart martin nginx-cache" "DRY"
} else {
    Push-Location $ProjectRoot
    docker compose restart martin nginx-cache 2>&1 | Tee-Object -FilePath $LogFile -Append
    Pop-Location
}

Write-Log "Krok 5/5: Health check..."
try {
    $null = Invoke-RestMethod -Uri "http://localhost:8080/status" -TimeoutSec 10 -ErrorAction Stop
    Write-Log "Nominatim: OK"
} catch {
    Write-Log "Nominatim: niedostepny" "WARN"
}

try {
    $null = Invoke-WebRequest -Uri "http://localhost:8081/health" -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
    Write-Log "Nginx cache: OK"
} catch {
    Write-Log "Nginx cache: niedostepny" "WARN"
}

Write-Log "=== Procedura aktualizacji zakonczona ==="
