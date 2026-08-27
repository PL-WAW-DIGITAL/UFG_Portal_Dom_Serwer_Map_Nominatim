#Requires -Version 5.1
<#
.SYNOPSIS
    Downloads Poland OSM PBF from Geofabrik with fallback to previous version.
.DESCRIPTION
    Part of the update procedure (docs/update-procedure.md).
    Run manually or via Task Scheduler (Sunday 00:00).
#>
param(
    [string]$PbfUrl = "https://download.geofabrik.de/europe/poland-latest.osm.pbf",
    [string]$OutputDir = "$PSScriptRoot\..\data\pbf",
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$OutputDir = [System.IO.Path]::GetFullPath($OutputDir)
$LogDir = Join-Path (Split-Path $OutputDir -Parent) "logs"
New-Item -ItemType Directory -Force -Path $OutputDir, $LogDir | Out-Null

$TargetFile = Join-Path $OutputDir "poland-latest.osm.pbf"
$PreviousFile = Join-Path $OutputDir "poland-previous.osm.pbf"
$LockFile = Join-Path $OutputDir "poland-latest.osm.pbf.lock"
$TempFile = Join-Path $OutputDir ("poland-latest.osm.pbf.download.{0}" -f $PID)
$LogFile = Join-Path $LogDir ("download-{0:yyyy-MM-dd}.log" -f (Get-Date))

function Write-Log {
    param([string]$Message)
    $Line = "[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $Message
    Write-Host $Line
    Add-Content -Path $LogFile -Value $Line
}

function Remove-FileSafe {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return }
    try {
        Remove-Item $Path -Force -ErrorAction Stop
    } catch {
        Write-Log "WARN: cannot remove $Path ($_)"
    }
}

Write-Log "Start download: $PbfUrl"

$FilteredFile = Join-Path $OutputDir "poland-filtered.osm.pbf"

function Ensure-FilteredPbf {
    param([string]$FullPbf, [string]$Filtered)
    $NeedFilter = $false
    if (-not (Test-Path $Filtered)) {
        $NeedFilter = $true
        Write-Log "Filtered PBF missing — running filter-pbf.ps1"
    } elseif ((Get-Item $FullPbf).LastWriteTime -gt (Get-Item $Filtered).LastWriteTime) {
        $NeedFilter = $true
        Write-Log "Full PBF newer than filtered — re-running filter-pbf.ps1"
    }
    if ($NeedFilter) {
        & "$PSScriptRoot\filter-pbf.ps1" -SourcePbf $FullPbf -OutputPbf $Filtered
        if ($LASTEXITCODE -ne 0) { throw "filter-pbf.ps1 failed (exit $LASTEXITCODE)" }
    } else {
        Write-Log "Filtered PBF up to date: $Filtered"
    }
}

if ((Test-Path $TargetFile) -and -not $Force) {
    $Age = (Get-Date) - (Get-Item $TargetFile).LastWriteTime
    if ($Age.TotalHours -lt 24) {
        Write-Log "File exists and is less than 24h old ($([math]::Round($Age.TotalHours, 1))h). Use -Force to re-download."
        Ensure-FilteredPbf -FullPbf $TargetFile -Filtered $FilteredFile
        exit 0
    }
}

# Another download already running?
if (Test-Path $LockFile) {
    $LockAge = (Get-Date) - (Get-Item $LockFile).LastWriteTime
    $LockPid = (Get-Content $LockFile -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($LockAge.TotalHours -lt 6) {
        $StillRunning = $false
        if ($LockPid) {
            $StillRunning = $null -ne (Get-Process -Id $LockPid -ErrorAction SilentlyContinue)
        }
        if ($StillRunning -or $LockAge.TotalMinutes -lt 30) {
            Write-Log "ERROR: download already in progress (lock PID=$LockPid, age=$([math]::Round($LockAge.TotalMinutes, 1)) min). Wait or remove $LockFile"
            exit 2
        }
        Write-Log "WARN: stale lock file found, removing"
    }
    Remove-FileSafe $LockFile
}

try {
    Set-Content -Path $LockFile -Value $PID -Encoding ASCII

    if (Test-Path $TargetFile) {
        Write-Log "Keeping previous version as poland-previous.osm.pbf"
        Copy-Item $TargetFile $PreviousFile -Force
    }

    # Clean leftover partial downloads from previous runs
    Get-ChildItem -Path $OutputDir -Filter "poland-latest.osm.pbf.download*" -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -ne $TempFile } |
        ForEach-Object { Remove-FileSafe $_.FullName }

    Write-Log "Downloading to $TempFile ..."

    # Prefer async BITS with live progress bar
    $usedBits = $false
    if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
        try {
            $BitsJob = Start-BitsTransfer -Source $PbfUrl -Destination $TempFile `
                -DisplayName "poland-osm-pbf" -Asynchronous -ErrorAction Stop
            Write-Log "BITS job started (id=$($BitsJob.JobId))"
            while ($BitsJob.JobState -in @("Connecting", "Transferring", "Queued", "TransientError")) {
                $Pct = 0
                if ($BitsJob.BytesTotal -gt 0) {
                    $Pct = [math]::Round(100 * $BitsJob.BytesTransferred / $BitsJob.BytesTotal, 1)
                }
                $DoneMb = [math]::Round($BitsJob.BytesTransferred / 1MB, 1)
                $TotalMb = if ($BitsJob.BytesTotal -gt 0) { [math]::Round($BitsJob.BytesTotal / 1MB, 1) } else { "?" }
                $Filled = [int][math]::Round(30 * $Pct / 100)
                $Bar = ("#" * $Filled) + ("-" * (30 - $Filled))
                Write-Host ("`r  PBF [{0}] {1,5}%  {2}/{3} MB  {4}   " -f $Bar, $Pct, $DoneMb, $TotalMb, $BitsJob.JobState) -NoNewline
                Start-Sleep -Seconds 2
                $BitsJob = Get-BitsTransfer -JobId $BitsJob.JobId -ErrorAction Stop
            }
            Write-Host ""
            if ($BitsJob.JobState -eq "Transferred") {
                Complete-BitsTransfer -BitsJob $BitsJob
                $usedBits = $true
                Write-Log "BITS download complete"
            } else {
                $State = $BitsJob.JobState
                Remove-BitsTransfer -BitsJob $BitsJob -ErrorAction SilentlyContinue
                throw "BITS ended in state: $State"
            }
        } catch {
            Write-Log "WARN: BITS failed ($_), falling back to Invoke-WebRequest"
            Remove-FileSafe $TempFile
        }
    }

    if (-not $usedBits) {
        Write-Log "Using Invoke-WebRequest (no live % for this method)..."
        Invoke-WebRequest -Uri $PbfUrl -OutFile $TempFile -UseBasicParsing
    }

    $SizeMb = [math]::Round((Get-Item $TempFile).Length / 1MB, 1)
    if ($SizeMb -lt 100) {
        throw "Downloaded file is suspiciously small ($SizeMb MB). Likely a download error."
    }

    if (Test-Path $TargetFile) {
        Remove-Item $TargetFile -Force
    }
    Move-Item $TempFile $TargetFile -Force
    Write-Log "Success. Size: $SizeMb MB"

    Write-Log "Filtering PBF for Nominatim (no POI)..."
    & "$PSScriptRoot\filter-pbf.ps1" -SourcePbf $TargetFile
    if ($LASTEXITCODE -ne 0) {
        throw "filter-pbf.ps1 failed (exit $LASTEXITCODE)"
    }
    exit 0
}
catch {
    Write-Log "ERROR: $_"
    Remove-FileSafe $TempFile
    if (Test-Path $PreviousFile) {
        Write-Log "Fallback: using poland-previous.osm.pbf"
    }
    exit 1
}
finally {
    Remove-FileSafe $LockFile
}
