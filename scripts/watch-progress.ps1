#Requires -Version 5.1
<#
.SYNOPSIS
    Live in-place progress dashboard (overwrites same lines, no scroll).
.EXAMPLE
    .\scripts\watch-progress.ps1
    .\scripts\watch-progress.ps1 -Once
    .\scripts\watch-progress.ps1 -IntervalSec 1
#>
param(
    [switch]$Once,
    [int]$IntervalSec = 1,
    [string]$ProjectRoot = "$PSScriptRoot\.."
)

$ErrorActionPreference = "Continue"
$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
$PbfDir = Join-Path $ProjectRoot "data\pbf"
$TilesDir = Join-Path $ProjectRoot "data\tiles"
$ExpectedPbfMb = 1900

# Fixed number of dashboard lines (must stay constant)
$script:LineCount = 20
$script:OriginTop = $null
$script:OriginLeft = 0

function Get-Bar {
    param([double]$Pct, [int]$Width = 24)
    if ($null -eq $Pct) { $Pct = 0 }
    if ($Pct -lt 0) { $Pct = 0 }
    if ($Pct -gt 100) { $Pct = 100 }
    $Filled = [int][math]::Round($Width * $Pct / 100)
    $Empty = $Width - $Filled
    return ("[" + ("#" * $Filled) + ("-" * $Empty) + ("] {0,5:N1}%" -f $Pct))
}

function Get-SizeMb {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    return [math]::Round((Get-Item $Path).Length / 1MB, 1)
}

function Truncate-Text {
    param([string]$Text, [int]$Max = 64)
    if (-not $Text) { return "" }
    $Text = ($Text -replace "\s+", " ").Trim()
    if ($Text.Length -le $Max) { return $Text }
    return $Text.Substring(0, $Max - 1) + "."
}

function Get-NominatimProgress {
    $Result = [ordered]@{
        Container = "missing"; Health = "n/a"; Stage = "unknown"
        Detail = ""; Percent = 0; Ready = $false
    }

    $Exists = docker ps -a --filter "name=^nominatim$" --format "{{.Names}}" 2>$null
    if (-not $Exists) { return $Result }

    $StatusLine = docker ps -a --filter "name=^nominatim$" --format "{{.Status}}" 2>$null
    if ($StatusLine -match "Up") { $Result.Container = "running" }
    elseif ($StatusLine -match "Exited") { $Result.Container = "exited" }
    else { $Result.Container = (Truncate-Text "$StatusLine" 28) }

    try {
        $HealthJson = docker inspect nominatim --format "{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}" 2>$null
        $Result.Health = "$HealthJson".Trim()
    } catch { }

    if ($Result.Health -eq "healthy") {
        $Result.Stage = "READY"
        $Result.Detail = "API on :8080 (nginx cache)"
        $Result.Percent = 100
        $Result.Ready = $true
        return $Result
    }

    $Logs = docker logs nominatim --tail 40 2>&1 | ForEach-Object { "$_" }
    foreach ($Line in $Logs) {
        if ($Line -match "rank\s+(\d+).*ETA \(seconds\):\s*([\d.]+)") {
            $Rank = [int]$Matches[1]
            $EtaSec = [double]$Matches[2]
            $Result.Percent = [math]::Round([Math]::Min(88, 40 + (($Rank / 30.0) * 40)), 1)
            $Result.Detail = ("rank {0}, ETA {1:N0}s" -f $Rank, $EtaSec)
            if ($Line -match "@\s+([\d.]+)\s+per second") {
                $Result.Detail += (", {0}/s" -f [math]::Round([double]$Matches[1], 0))
            }
            $Result.Stage = "Indexing"
        }
        elseif ($Line -match "FINISHED rank\s+(\d+)") {
            $Result.Stage = "Indexing"
            $Result.Detail = "finished rank $($Matches[1])"
            $Result.Percent = [math]::Round(40 + (([int]$Matches[1] / 30.0) * 45), 1)
        }
        elseif ($Line -match "Warming database caches") {
            $Result.Stage = "Warming"; $Result.Percent = 95; $Result.Detail = "warming cache..."
        }
        elseif ($Line -match "Post-process tables") {
            $Result.Stage = "Post-process"; $Result.Percent = 85; $Result.Detail = "post-process tables"
        }
        elseif ($Line -match "Application startup complete") {
            $Result.Stage = "READY"; $Result.Percent = 100; $Result.Ready = $true; $Result.Detail = "API up"
        }
        elseif ($Line -match "Creating database|Setting up country|Loading data|osm2pgsql|import --osm|Storing properties") {
            $Result.Stage = "Loading OSM"; $Result.Percent = 25
            $Result.Detail = (Truncate-Text $Line 64)
        }
    }
    if (-not $Result.Detail -and $Logs) {
        $Result.Detail = Truncate-Text "$($Logs | Select-Object -Last 1)" 64
    }
    return $Result
}

function Get-PbfProgress {
    $Result = [ordered]@{ Status = "missing"; SizeMb = 0; Percent = 0; Detail = "" }
    $Target = Join-Path $PbfDir "poland-latest.osm.pbf"
    $Lock = Join-Path $PbfDir "poland-latest.osm.pbf.lock"
    $Partials = @(Get-ChildItem -Path $PbfDir -Filter "poland-latest.osm.pbf.download*" -ErrorAction SilentlyContinue)

    if (Test-Path $Target) {
        $Mb = Get-SizeMb $Target
        $Result.Status = "ready"; $Result.SizeMb = $Mb; $Result.Percent = 100; $Result.Detail = "$Mb MB"
        return $Result
    }
    if (Test-Path $Lock) {
        $LockPid = (Get-Content $Lock -ErrorAction SilentlyContinue | Select-Object -First 1)
        $Result.Status = "downloading"; $Result.Detail = "lock PID=$LockPid"
    }
    if ($Partials.Count -gt 0) {
        $Partial = $Partials | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $Mb = [math]::Round($Partial.Length / 1MB, 1)
        $Result.Status = "downloading"; $Result.SizeMb = $Mb
        $Result.Percent = [math]::Min(99, [math]::Round(100 * $Mb / $ExpectedPbfMb, 1))
        $Result.Detail = ("{0} / ~{1} MB" -f $Mb, $ExpectedPbfMb)
        return $Result
    }
    $Bits = Get-BitsTransfer -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq "poland-osm-pbf" }
    if ($Bits -and $Bits.BytesTotal -gt 0) {
        $Result.Status = "BITS"
        $Result.Percent = [math]::Round(100 * $Bits.BytesTransferred / $Bits.BytesTotal, 1)
        $Result.Detail = ("{0:N0}/{1:N0} MB" -f ($Bits.BytesTransferred / 1MB), ($Bits.BytesTotal / 1MB))
        return $Result
    }
    $Result.Detail = "run download-pbf.ps1"
    return $Result
}

function Get-TilesProgress {
    $Result = [ordered]@{ Status = "missing"; SizeMb = 0; Percent = 0; Detail = "" }
    $Target = Join-Path $TilesDir "poland.pmtiles"
    $Building = Join-Path $TilesDir "poland-building.pmtiles"

    $Cid = docker ps --filter "name=planetiler-poland" --format "{{.ID}}" 2>$null
    if (-not $Cid) {
        $Cid = docker ps --format "{{.ID}} {{.Image}}" 2>$null |
            Where-Object { $_ -match "planetiler" } |
            ForEach-Object { ($_ -split "\s+")[0] } |
            Select-Object -First 1
    }
    if ($Cid) {
        $Result.Status = "generating"
        $Logs = docker logs --tail 20 $Cid 2>&1 | ForEach-Object { "$_" }
        foreach ($Line in $Logs) {
            if ($Line -match "(\d+(?:\.\d+)?)\s*%") { $Result.Percent = [double]$Matches[1] }
            if ($Line -match "Write|Process|Sort|Read|download") {
                $Result.Detail = Truncate-Text $Line 64
            }
        }
        if ((-not $Result.Detail) -and $Logs) {
            $Result.Detail = Truncate-Text "$($Logs | Select-Object -Last 1)" 64
        }
        if (Test-Path $Building) {
            $Result.SizeMb = Get-SizeMb $Building
            $Result.Detail = ("{0} MB | {1}" -f $Result.SizeMb, $Result.Detail)
        }
        return $Result
    }
    if (Test-Path $Building) {
        $Result.Status = "partial"
        $Result.SizeMb = Get-SizeMb $Building
        $Result.Detail = "$($Result.SizeMb) MB temp"
        return $Result
    }
    if (Test-Path $Target) {
        $Result.Status = "ready"
        $Result.SizeMb = Get-SizeMb $Target
        $Result.Percent = 100
        $Result.Detail = "$($Result.SizeMb) MB"
        return $Result
    }
    $Result.Detail = "run generate-tiles.ps1"
    return $Result
}

function Get-ServiceShort {
    param([string]$Filter)
    $S = docker ps -a --filter $Filter --format "{{.Status}}" 2>$null
    if (-not $S) { return "absent" }
    if ($S -match "unhealthy") { return "unhealthy" }
    if ($S -match "healthy") { return "healthy" }
    if ($S -match "starting") { return "starting" }
    if ($S -match "Up") { return "up" }
    if ($S -match "Exited") { return "exited" }
    return (Truncate-Text $S 16)
}

function Test-Probe {
    param([string]$Url)
    try {
        $null = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 1
        return "OK"
    } catch {
        return "--"
    }
}

function Get-DashboardLines {
    $Now = Get-Date -Format "HH:mm:ss"
    $Pbf = Get-PbfProgress
    $Nom = Get-NominatimProgress
    $Tiles = Get-TilesProgress
    $NomSvc = Get-ServiceShort "name=^nominatim$"
    $MarSvc = Get-ServiceShort "name=^martin$"
    $NgxSvc = Get-ServiceShort "name=^nginx-cache$"
    $P1 = Test-Probe "http://localhost:8080/health"
    $P2 = Test-Probe "http://localhost:8080/status"
    $P3 = Test-Probe "http://localhost:8081/health"

    $PctPbf = if ($null -ne $Pbf.Percent) { [double]$Pbf.Percent } else { 0 }
    $PctNom = if ($null -ne $Nom.Percent) { [double]$Nom.Percent } else { 0 }
    $PctTiles = if ($null -ne $Tiles.Percent) { [double]$Tiles.Percent } else { 0 }

    return @(
        ("Portal DOM | live {0} | Ctrl+C stop" -f $Now)
        ""
        "1) PBF"
        ("   {0,-14} {1}" -f $Pbf.Status, (Get-Bar $PctPbf))
        ("   {0}" -f (Truncate-Text $Pbf.Detail 70))
        ""
        "2) Nominatim"
        ("   {0,-14} {1,-10} {2}" -f $Nom.Stage, $Nom.Health, (Get-Bar $PctNom))
        ("   {0}" -f (Truncate-Text $Nom.Detail 70))
        ""
        "3) Tiles"
        ("   {0,-14} {1}" -f $Tiles.Status, (Get-Bar $PctTiles))
        ("   {0}" -f (Truncate-Text $Tiles.Detail 70))
        ""
        "4) Containers"
        ("   nom={0,-10} martin={1,-10} nginx={2,-10}" -f $NomSvc, $MarSvc, $NgxSvc)
        ""
        "5) Probes"
        ("   :8080/health={0}  /status={1}  :8081={2}" -f $P1, $P2, $P3)
        ("refresh {0}s" -f $IntervalSec)
    )
}

function Write-LineAt {
    param([int]$Top, [int]$Left, [string]$Text, [int]$Width)
    if ($Text.Length -gt $Width) { $Text = $Text.Substring(0, $Width) }
    $padded = $Text.PadRight($Width)
    [Console]::SetCursorPosition($Left, $Top)
    # Write without advancing to next buffer line unexpectedly
    [Console]::Write($padded)
}

function Write-FrameInPlace {
    param([string[]]$Lines)

    $width = [Math]::Max(40, [Console]::WindowWidth - 1)

    # Normalize to exactly LineCount rows
    $fixed = New-Object string[] $script:LineCount
    for ($i = 0; $i -lt $script:LineCount; $i++) {
        $fixed[$i] = if ($i -lt $Lines.Count -and $null -ne $Lines[$i]) { [string]$Lines[$i] } else { "" }
    }

    if ($null -eq $script:OriginTop) {
        # Reserve space once: print blank block, then remember top
        $script:OriginLeft = [Console]::CursorLeft
        # Ensure we have enough buffer room
        for ($i = 0; $i -lt $script:LineCount; $i++) {
            [Console]::WriteLine("".PadRight([Math]::Min($width, 1)))
        }
        $script:OriginTop = [Console]::CursorTop - $script:LineCount
        if ($script:OriginTop -lt 0) { $script:OriginTop = 0 }
    }

    for ($i = 0; $i -lt $script:LineCount; $i++) {
        Write-LineAt -Top ($script:OriginTop + $i) -Left $script:OriginLeft -Text $fixed[$i] -Width $width
    }
    # Park cursor just below the frame (does not create new content on next paint)
    $below = $script:OriginTop + $script:LineCount
    if ($below -ge [Console]::BufferHeight) { $below = [Console]::BufferHeight - 1 }
    [Console]::SetCursorPosition(0, $below)
}

function Write-FrameOnce {
    param([string[]]$Lines)
    foreach ($L in $Lines) { Write-Host $L }
}

# --- main ---
if ($Once) {
    Write-FrameOnce (Get-DashboardLines)
    exit 0
}

# Interactive console required for in-place updates
if ([Console]::IsOutputRedirected) {
    Write-Host "WARN: output redirected - falling back to scrolling mode" -ForegroundColor Yellow
    while ($true) {
        Write-Host ("--- {0} ---" -f (Get-Date -Format "HH:mm:ss"))
        Write-FrameOnce (Get-DashboardLines)
        Start-Sleep -Seconds $IntervalSec
    }
}

try {
    [Console]::CursorVisible = $false
} catch { }

try {
    while ($true) {
        Write-FrameInPlace -Lines (Get-DashboardLines)
        Start-Sleep -Seconds $IntervalSec
    }
}
finally {
    try { [Console]::CursorVisible = $true } catch { }
    Write-Host ""
    Write-Host "Monitor stopped."
}
