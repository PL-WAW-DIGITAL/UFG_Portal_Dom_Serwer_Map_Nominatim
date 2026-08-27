#Requires -Version 5.1
<#
.SYNOPSIS
    Generates vector PMTiles from OSM PBF using Planetiler (with live progress).
#>
param(
    [string]$PbfFile = "$PSScriptRoot\..\data\pbf\poland-latest.osm.pbf",
    [string]$OutputDir = "$PSScriptRoot\..\data\tiles",
    [string]$Memory = "8g",
    [string]$Area = "poland"
)

# Continue: docker writes progress/JVM messages to stderr; Stop would abort the script.
$ErrorActionPreference = "Continue"

$PbfFile = [System.IO.Path]::GetFullPath($PbfFile)
$OutputDir = [System.IO.Path]::GetFullPath($OutputDir)
$SourcesDir = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\data\planetiler-sources"))
$LogDir = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\data\logs"))
New-Item -ItemType Directory -Force -Path $OutputDir, $SourcesDir, $LogDir | Out-Null

if (-not (Test-Path $PbfFile)) {
    throw "Missing PBF file: $PbfFile. Run scripts/download-pbf.ps1 first."
}

$OutputFile = Join-Path $OutputDir "poland.pmtiles"
$PreviousFile = Join-Path $OutputDir "poland-previous.pmtiles"
$TempFile = Join-Path $OutputDir "poland-building.pmtiles"
$ContainerName = "planetiler-poland"
$RunLog = Join-Path $LogDir ("planetiler-{0:yyyy-MM-dd-HHmm}.log" -f (Get-Date))

function Get-DockerText {
    param([Parameter(Mandatory)][string[]]$DockerArgs)
    (& docker @DockerArgs 2>&1 | ForEach-Object { "$_" })
}

function Remove-ContainerSafe {
    param([string]$Name)
    $null = Get-DockerText -DockerArgs @("rm", "-f", $Name)
}

if (Test-Path $OutputFile) {
    Write-Host "Keeping previous tiles as poland-previous.pmtiles..."
    Copy-Item $OutputFile $PreviousFile -Force
}

$PbfMount = Split-Path $PbfFile -Parent
$PbfName = Split-Path $PbfFile -Leaf

Remove-ContainerSafe $ContainerName
if (Test-Path $TempFile) { Remove-Item $TempFile -Force -ErrorAction SilentlyContinue }

Write-Host "Generating PMTiles from $PbfName (RAM: $Memory)..."
Write-Host "This may take 1-4 hours. Progress below (also: .\scripts\watch-progress.ps1)"
Write-Host "Log: $RunLog"
Write-Host ""

$runOut = Get-DockerText -DockerArgs @(
    "run", "-d", "--name", $ContainerName,
    "-e", "JAVA_TOOL_OPTIONS=-Xmx$Memory",
    "-v", "${PbfMount}:/data/pbf:ro",
    "-v", "${OutputDir}:/data/tiles",
    "-v", "${SourcesDir}:/data/sources",
    "ghcr.io/onthegomap/planetiler:latest",
    "--download",
    "--area=$Area",
    "--osm-path=/data/pbf/$PbfName",
    "--output=/data/tiles/poland-building.pmtiles",
    "--force"
)
if ($LASTEXITCODE -ne 0) {
    throw ("docker run failed: {0}" -f ($runOut -join " "))
}

$LastPct = -1
while ($true) {
    $State = (Get-DockerText -DockerArgs @("inspect", "-f", "{{.State.Status}}", $ContainerName) | Select-Object -First 1)
    if (-not $State -or $State -match "Error|No such") { break }

    $Logs = Get-DockerText -DockerArgs @("logs", $ContainerName, "--tail", "40")
    $Logs | Set-Content -Path $RunLog -Encoding UTF8

    $Pct = $null
    $Phase = ""
    foreach ($Line in $Logs) {
        if ($Line -match "(\d+(?:\.\d+)?)\s*%") {
            $Pct = [double]$Matches[1]
        }
        if ($Line -match "(download|Read OSM|Process|Write|Sort|emit|tile)") {
            $Phase = ($Line -replace "\s+", " ").Trim()
            if ($Phase.Length -gt 80) { $Phase = $Phase.Substring(0, 80) }
        }
    }

    $SizeMb = if (Test-Path $TempFile) { [math]::Round((Get-Item $TempFile).Length / 1MB, 1) } else { 0 }
    if ($null -eq $Pct) { $Pct = $LastPct }
    if ($Pct -lt 0) { $Pct = 0 }
    $LastPct = $Pct

    $Filled = [int][math]::Round(30 * [math]::Min(100, $Pct) / 100)
    $Bar = ("#" * $Filled) + ("-" * (30 - $Filled))
    Write-Host ("`r  Tiles [{0}] {1,5:N1}%  out={2} MB  {3}   " -f $Bar, $Pct, $SizeMb, $Phase) -NoNewline

    if ($State -in @("exited", "dead")) { break }
    Start-Sleep -Seconds 5
}
Write-Host ""

$ExitCodeRaw = (Get-DockerText -DockerArgs @("inspect", "-f", "{{.State.ExitCode}}", $ContainerName) | Select-Object -First 1)
$ExitCode = 1
if ($ExitCodeRaw -match "^\d+$") { $ExitCode = [int]$ExitCodeRaw }

Get-DockerText -DockerArgs @("logs", $ContainerName) | Set-Content -Path $RunLog -Encoding UTF8
Remove-ContainerSafe $ContainerName

if ($ExitCode -ne 0) {
    throw "Planetiler failed (exit=$ExitCode). See $RunLog"
}

if (-not (Test-Path $TempFile)) {
    throw "Planetiler did not produce the output file. See $RunLog"
}

if (Test-Path $OutputFile) {
    Remove-Item $OutputFile -Force
}
Move-Item $TempFile $OutputFile -Force
$SizeMb = [math]::Round((Get-Item $OutputFile).Length / 1MB, 1)
Write-Host "Success. PMTiles: $OutputFile ($SizeMb MB)"
Write-Host "Run: docker compose up -d martin nginx-cache"
