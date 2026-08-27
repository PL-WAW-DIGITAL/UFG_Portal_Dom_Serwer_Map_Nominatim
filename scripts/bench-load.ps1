#Requires -Version 5.1
<#
.SYNOPSIS
    Load test with BEFORE (cold / bypass) vs AFTER (warmed cache) comparison.
.DESCRIPTION
    1) COLD:  every request sends X-Bypass-Cache:1 (hits Nominatim/Martin)
    2) WARM:  fetch each URL once to fill nginx tmpfs cache
    3) HOT:   same load without bypass (expects X-Cache-Status: HIT)
    4) Prints side-by-side delta (RPS, p50/p95, HIT%)
.EXAMPLE
    .\scripts\bench-load.ps1
    .\scripts\bench-load.ps1 -Target nominatim -CacheMode compare -MaxConcurrency 16
    .\scripts\bench-load.ps1 -CacheMode cold
    .\scripts\bench-load.ps1 -CacheMode hot
#>
param(
    [ValidateSet("nominatim", "tiles", "both")]
    [string]$Target = "both",
    [ValidateSet("compare", "cold", "hot")]
    [string]$CacheMode = "compare",
    [int]$DurationSec = 10,
    [int]$MaxConcurrency = 32,
    [double]$MaxErrorPct = 5.0,
    [int]$MaxP95Ms = 5000,
    [string]$NominatimUrl = "http://localhost:8080",
    [string]$TilesUrl = "http://localhost:8081",
    [string]$CasesFile = "$PSScriptRoot\nominatim-cases.json",
    [string]$OutDir = "$PSScriptRoot\..\data\logs"
)

$ErrorActionPreference = "Continue"
$OutDir = [System.IO.Path]::GetFullPath($OutDir)
$CasesFile = [System.IO.Path]::GetFullPath($CasesFile)
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$Stamp = Get-Date -Format "yyyy-MM-dd-HHmmss"
$ReportFile = Join-Path $OutDir "bench-$Stamp.txt"
$CsvFile = Join-Path $OutDir "bench-$Stamp.csv"

if (-not (Test-Path $CasesFile)) { throw "Missing cases file: $CasesFile" }
$rawJson = Get-Content -LiteralPath $CasesFile -Raw -Encoding UTF8
$NominatimCases = @((ConvertFrom-Json -InputObject $rawJson))
$NominatimUrls = New-Object System.Collections.Generic.List[object]
foreach ($case in $NominatimCases) {
    if (-not $case.query) { throw "Case missing query: $($case.name)" }
    $NominatimUrls.Add([pscustomobject]@{
        Name  = [string]$case.name
        Query = [string]$case.query
        Url   = ($NominatimUrl + "/search?" + $case.query)
    }) | Out-Null
}
Write-Host ("Loaded {0} Nominatim cases" -f $NominatimUrls.Count) -ForegroundColor Cyan

$TilePaths = @(
    "/poland/6/34/21", "/poland/8/139/85", "/poland/10/558/340", "/poland/12/2234/1363",
    "/poland/13/4469/2726", "/poland/14/8939/5453", "/poland/10/559/341", "/poland/12/2235/1364"
)

function Write-Report {
    param([string]$Message, [ConsoleColor]$Color = "White")
    Write-Host $Message -ForegroundColor $Color
    Add-Content -Path $ReportFile -Value $Message
}

function Get-Percentile {
    param([double[]]$Values, [double]$Pct)
    if (-not $Values -or $Values.Count -eq 0) { return 0 }
    $Sorted = @($Values | Sort-Object)
    $Idx = [math]::Ceiling(($Pct / 100.0) * $Sorted.Count) - 1
    if ($Idx -lt 0) { $Idx = 0 }
    if ($Idx -ge $Sorted.Count) { $Idx = $Sorted.Count - 1 }
    return $Sorted[$Idx]
}

function Test-EndpointReady {
    param([string]$Name, [string]$Url)
    try {
        $null = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5
        Write-Report "  $Name ready ($Url)" Green
        return $true
    } catch {
        Write-Report "  $Name NOT ready ($Url)" Red
        return $false
    }
}

function Invoke-WarmCache {
    param([string[]]$Urls, [int]$Rounds = 2)
    Write-Report ("Warming cache: {0} URLs x {1} rounds..." -f $Urls.Count, $Rounds)
    $ok = 0; $fail = 0
    for ($r = 1; $r -le $Rounds; $r++) {
        foreach ($Url in $Urls) {
            try {
                $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 30
                if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 400) { $ok++ } else { $fail++ }
            } catch { $fail++ }
        }
    }
    Write-Report ("  Warm done: ok={0} fail={1}" -f $ok, $fail)
}

function Invoke-LoadWaveRunspace {
    param(
        [string[]]$Urls,
        [int]$Concurrency,
        [int]$Seconds,
        [switch]$ValidateNominatimBody,
        [switch]$BypassCache
    )

    $Latencies = New-Object System.Collections.Generic.List[double]
    $OkCount = 0; $FailCount = 0
    $HitCount = 0; $MissCount = 0; $BypassCount = 0; $OtherCache = 0
    $PerUrlOk = New-Object "int[]" $Urls.Count
    $PerUrlFail = New-Object "int[]" $Urls.Count

    $Pool = [runspacefactory]::CreateRunspacePool(1, [Math]::Max(1, $Concurrency))
    $Pool.Open()
    $StopAt = [datetime]::UtcNow.AddSeconds($Seconds)
    $Workers = @()

    $WorkerScript = {
        param($Urls, $StopAtTicks, $TimeoutSec, $ValidateBody, $DoBypass)
        $n = $Urls.Count
        $localOk = 0; $localFail = 0
        $localHit = 0; $localMiss = 0; $localBypass = 0; $localOther = 0
        $localMs = New-Object System.Collections.Generic.List[double]
        $perOk = New-Object "int[]" $n
        $perFail = New-Object "int[]" $n
        $i = 0
        $stopAt = [datetime]::new($StopAtTicks)
        $headers = @{}
        if ($DoBypass) { $headers["X-Bypass-Cache"] = "1" }

        while ([datetime]::UtcNow -lt $stopAt) {
            $idx = $i % $n
            $url = $Urls[$idx]
            $i++
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $ok = $false
            try {
                if ($headers.Count -gt 0) {
                    $resp = Invoke-WebRequest -Uri $url -Headers $headers -UseBasicParsing -TimeoutSec $TimeoutSec
                } else {
                    $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec $TimeoutSec
                }
                $sw.Stop()
                $cs = ""
                if ($resp.Headers["X-Cache-Status"]) { $cs = [string]$resp.Headers["X-Cache-Status"] }
                switch -Regex ($cs) {
                    "HIT"     { $localHit++ }
                    "MISS"    { $localMiss++ }
                    "BYPASS"  { $localBypass++ }
                    "STALE|UPDATING|EXPIRED|REVALIDATED" { $localOther++ }
                    default   { if ($cs) { $localOther++ } }
                }
                if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 400) {
                    if ($ValidateBody) {
                        $data = $resp.Content | ConvertFrom-Json
                        if ($data -and @($data).Count -gt 0 -and $data[0].lat -and ([double]$data[0].lat -ne 0 -or [double]$data[0].lon -ne 0)) {
                            $ok = $true
                        }
                    } else { $ok = $true }
                }
            } catch {
                $sw.Stop()
                $ok = $false
            }
            $localMs.Add([double]$sw.Elapsed.TotalMilliseconds) | Out-Null
            if ($ok) { $localOk++; $perOk[$idx]++ } else { $localFail++; $perFail[$idx]++ }
        }
        return @{
            Ok = $localOk; Fail = $localFail; Ms = $localMs.ToArray()
            PerOk = $perOk; PerFail = $perFail
            Hit = $localHit; Miss = $localMiss; Bypass = $localBypass; Other = $localOther
        }
    }

    for ($w = 0; $w -lt $Concurrency; $w++) {
        $Ps = [powershell]::Create().AddScript($WorkerScript).
            AddArgument($Urls).AddArgument($StopAt.Ticks).AddArgument(30).
            AddArgument([bool]$ValidateNominatimBody).AddArgument([bool]$BypassCache)
        $Ps.RunspacePool = $Pool
        $Workers += @{ Pipe = $Ps; Handle = $Ps.BeginInvoke() }
    }

    foreach ($W in $Workers) {
        $Out = $W.Pipe.EndInvoke($W.Handle)
        $W.Pipe.Dispose()
        if ($Out -and $Out.Count -gt 0) {
            $R = $Out[0]
            $OkCount += [int]$R.Ok; $FailCount += [int]$R.Fail
            $HitCount += [int]$R.Hit; $MissCount += [int]$R.Miss
            $BypassCount += [int]$R.Bypass; $OtherCache += [int]$R.Other
            foreach ($m in $R.Ms) { $Latencies.Add([double]$m) | Out-Null }
            if ($R.PerOk) {
                for ($i = 0; $i -lt $Urls.Count; $i++) {
                    $PerUrlOk[$i] += [int]$R.PerOk[$i]
                    $PerUrlFail[$i] += [int]$R.PerFail[$i]
                }
            }
        }
    }
    $Pool.Close(); $Pool.Dispose()

    $Total = $OkCount + $FailCount
    $CacheKnown = $HitCount + $MissCount + $BypassCount + $OtherCache
    $HitPct = if ($CacheKnown -gt 0) { [math]::Round(100.0 * $HitCount / $CacheKnown, 1) } else { 0 }
    $Arr = $Latencies.ToArray()

    return [pscustomobject]@{
        Concurrency = $Concurrency
        Total = $Total; Ok = $OkCount; Fail = $FailCount
        ErrorPct = if ($Total -gt 0) { [math]::Round(100.0 * $FailCount / $Total, 2) } else { 100 }
        Rps = if ($Seconds -gt 0) { [math]::Round($Total / $Seconds, 1) } else { 0 }
        OkRps = if ($Seconds -gt 0) { [math]::Round($OkCount / $Seconds, 1) } else { 0 }
        P50Ms = [math]::Round((Get-Percentile $Arr 50), 1)
        P95Ms = [math]::Round((Get-Percentile $Arr 95), 1)
        P99Ms = [math]::Round((Get-Percentile $Arr 99), 1)
        AvgMs = if ($Arr.Count -gt 0) { [math]::Round(($Arr | Measure-Object -Average).Average, 1) } else { 0 }
        MaxMs = if ($Arr.Count -gt 0) { [math]::Round(($Arr | Measure-Object -Maximum).Maximum, 1) } else { 0 }
        Hit = $HitCount; Miss = $MissCount; BypassHdr = $BypassCount; CacheOther = $OtherCache
        HitPct = $HitPct
        PerUrlOk = $PerUrlOk; PerUrlFail = $PerUrlFail
        Mode = $(if ($BypassCache) { "COLD" } else { "HOT" })
    }
}

function Test-NominatimCases {
    param([Parameter(Mandatory)]$CaseList)
    $Cases = New-Object System.Collections.Generic.List[object]
    foreach ($item in $CaseList) { $Cases.Add($item) | Out-Null }

    Write-Report ""
    Write-Report "=== Case validation ===" Cyan
    $Passed = 0; $Failed = 0
    $ValidUrls = New-Object System.Collections.Generic.List[string]
    $ValidNames = New-Object System.Collections.Generic.List[string]

    foreach ($C in $Cases) {
        Write-Host ("  {0} ... " -f $C.Name) -NoNewline
        try {
            $Sw = [System.Diagnostics.Stopwatch]::StartNew()
            $Response = Invoke-RestMethod -Uri $C.Url -TimeoutSec 30
            $Sw.Stop()
            $Ms = [math]::Round($Sw.Elapsed.TotalMilliseconds)
            if ($null -eq $Response -or @($Response).Count -eq 0 -or -not $Response[0].lat) {
                Write-Host ("FAIL ({0}ms)" -f $Ms) -ForegroundColor Red
                $Failed++; continue
            }
            $Lat = [double]$Response[0].lat; $Lon = [double]$Response[0].lon
            Write-Host ("OK {0}ms" -f $Ms) -ForegroundColor Green
            Write-Report ("  OK  {0} ({1}ms) lat={2} lon={3}" -f $C.Name, $Ms, $Lat, $Lon)
            $Passed++; $ValidUrls.Add($C.Url) | Out-Null; $ValidNames.Add($C.Name) | Out-Null
        } catch {
            Write-Host ("FAIL {0}" -f $_.Exception.Message) -ForegroundColor Red
            $Failed++
        }
    }
    Write-Report ("Validation: {0} passed, {1} failed" -f $Passed, $Failed)
    return [pscustomobject]@{ Urls = $ValidUrls.ToArray(); Names = $ValidNames.ToArray() }
}

function Get-ConcurrencySteps {
    param([int]$Max)
    return @(@(1, 2, 4, 8, 12, 16, 24, 32, 48, 64, 96, 128) | Where-Object { $_ -le $Max })
}

function Invoke-ServiceBenchPhase {
    param(
        [string]$Name,
        [string]$Phase,   # COLD | HOT
        [string[]]$Urls,
        [string[]]$CaseNames = @(),
        [switch]$ValidateNominatimBody,
        [switch]$BypassCache
    )

    Write-Report ""
    Write-Report ("=== {0} / {1} ===" -f $Name, $Phase) Cyan
    if ($BypassCache) {
        Write-Report "Mode: COLD (X-Bypass-Cache:1 -> upstream, no nginx cache)"
    } else {
        Write-Report "Mode: HOT (nginx cache enabled, expect HIT after warm)"
    }
    Write-Report ("URLs={0} Duration/wave={1}s MaxConc={2}" -f $Urls.Count, $DurationSec, $MaxConcurrency)
    Write-Report ""

    $Header = "{0,5} {1,8} {2,8} {3,7} {4,7} {5,7} {6,7} {7,7} {8,6}" -f `
        "Conc", "OkRPS", "Err%", "p50", "p95", "p99", "HIT%", "HIT", "MISS"
    Write-Report $Header
    Write-Report ("-" * $Header.Length)

    $Best = $null; $LastRow = $null

    foreach ($C in (Get-ConcurrencySteps -Max $MaxConcurrency)) {
        Write-Host ("  [{0}] concurrency={1} ..." -f $Phase, $C) -ForegroundColor DarkGray
        $Row = Invoke-LoadWaveRunspace -Urls $Urls -Concurrency $C -Seconds $DurationSec `
            -ValidateNominatimBody:$ValidateNominatimBody -BypassCache:$BypassCache
        $LastRow = $Row

        $Line = "{0,5} {1,8} {2,8} {3,7} {4,7} {5,7} {6,7} {7,7} {8,6}" -f `
            $Row.Concurrency, $Row.OkRps, $Row.ErrorPct, $Row.P50Ms, $Row.P95Ms, $Row.P99Ms, $Row.HitPct, $Row.Hit, $Row.Miss
        Write-Report $Line

        "service,phase,concurrency,rps,ok_rps,error_pct,p50_ms,p95_ms,p99_ms,avg_ms,hit_pct,hit,miss,bypass,total,ok,fail" |
            Out-Null
        "{0},{1},{2},{3},{4},{5},{6},{7},{8},{9},{10},{11},{12},{13},{14},{15},{16}" -f `
            $Name, $Phase, $Row.Concurrency, $Row.Rps, $Row.OkRps, $Row.ErrorPct, $Row.P50Ms, $Row.P95Ms, $Row.P99Ms, $Row.AvgMs, `
            $Row.HitPct, $Row.Hit, $Row.Miss, $Row.BypassHdr, $Row.Total, $Row.Ok, $Row.Fail |
            Add-Content $CsvFile

        $ok = ($Row.ErrorPct -le $MaxErrorPct) -and ($Row.P95Ms -le $MaxP95Ms) -and ($Row.Ok -gt 0)
        if ($ok) {
            if (-not $Best -or $Row.OkRps -gt $Best.OkRps) { $Best = $Row }
        } else {
            Write-Report ("  >> stop at conc={0} (err={1}% p95={2}ms)" -f $C, $Row.ErrorPct, $Row.P95Ms) Yellow
            break
        }
    }

    if ($LastRow -and $CaseNames.Count -gt 0 -and $LastRow.PerUrlOk) {
        Write-Report ""
        Write-Report ("Per-case ({0}, last wave conc={1}):" -f $Phase, $LastRow.Concurrency)
        for ($i = 0; $i -lt $CaseNames.Count -and $i -lt $LastRow.PerUrlOk.Count; $i++) {
            $okN = [int]$LastRow.PerUrlOk[$i]; $failN = [int]$LastRow.PerUrlFail[$i]
            $tot = $okN + $failN
            $pct = if ($tot -gt 0) { [math]::Round(100.0 * $okN / $tot, 1) } else { 0 }
            Write-Report ("  {0,-32} ok={1,5} fail={2,3} {3}%" -f $CaseNames[$i], $okN, $failN, $pct)
        }
    }

    if ($Best) {
        Write-Report ("BEST [{0}/{1}] ~{2} ok-req/s @ conc={3} | p50={4}ms p95={5}ms HIT%={6}" -f `
            $Name, $Phase, $Best.OkRps, $Best.Concurrency, $Best.P50Ms, $Best.P95Ms, $Best.HitPct) Green
    }
    return $Best
}

function Write-CacheCompare {
    param($Name, $Cold, $Hot)
    Write-Report ""
    Write-Report ("=== COMPARE before/after cache warm: {0} ===" -f $Name) Cyan
    if (-not $Cold -or -not $Hot) {
        Write-Report "  Incomplete (missing COLD or HOT result)" Yellow
        return
    }

    $rpsGain = if ($Cold.OkRps -gt 0) { [math]::Round(100.0 * ($Hot.OkRps - $Cold.OkRps) / $Cold.OkRps, 1) } else { 0 }
    $p50Imp = if ($Cold.P50Ms -gt 0) { [math]::Round(100.0 * ($Cold.P50Ms - $Hot.P50Ms) / $Cold.P50Ms, 1) } else { 0 }
    $p95Imp = if ($Cold.P95Ms -gt 0) { [math]::Round(100.0 * ($Cold.P95Ms - $Hot.P95Ms) / $Cold.P95Ms, 1) } else { 0 }

    Write-Report ("{0,-12} {1,10} {2,10} {3,10}" -f "", "COLD", "HOT", "DELTA")
    Write-Report ("{0,-12} {1,10} {2,10} {3,10}" -f "OkRPS", $Cold.OkRps, $Hot.OkRps, ("{0}%" -f $rpsGain))
    Write-Report ("{0,-12} {1,10} {2,10} {3,10}" -f "p50 ms", $Cold.P50Ms, $Hot.P50Ms, ("{0}%" -f $p50Imp))
    Write-Report ("{0,-12} {1,10} {2,10} {3,10}" -f "p95 ms", $Cold.P95Ms, $Hot.P95Ms, ("{0}%" -f $p95Imp))
    Write-Report ("{0,-12} {1,10} {2,10} {3,10}" -f "HIT%", $Cold.HitPct, $Hot.HitPct, "")
    Write-Report ("{0,-12} {1,10} {2,10}" -f "conc", $Cold.Concurrency, $Hot.Concurrency)
    Write-Report ""
    Write-Report ("Verdict: cache warm => OkRPS {0}% | p50 latency {1}% | p95 latency {2}% | HOT HIT%={3}" -f `
        $rpsGain, $p50Imp, $p95Imp, $Hot.HitPct) Green
}

# CSV header
"service,phase,concurrency,rps,ok_rps,error_pct,p50_ms,p95_ms,p99_ms,avg_ms,hit_pct,hit,miss,bypass,total,ok,fail" |
    Set-Content $CsvFile -Encoding UTF8

Write-Report "Portal DOM load benchmark - $Stamp" Cyan
Write-Report ("Machine: {0} | CPUs: {1} | CacheMode: {2}" -f $env:COMPUTERNAME, $env:NUMBER_OF_PROCESSORS, $CacheMode)
Write-Report ("Report: $ReportFile")
Write-Report ("CSV:    $CsvFile")
Write-Report ""
Write-Report "Preflight:"

$NomOk = $false; $TilesOk = $false
if ($Target -in @("nominatim", "both")) { $NomOk = Test-EndpointReady "Nominatim" "$NominatimUrl/status" }
if ($Target -in @("tiles", "both")) { $TilesOk = Test-EndpointReady "Tiles" "$TilesUrl/health" }

$Summary = @()

function Invoke-CacheCompareFlow {
    param(
        [string]$Name,
        [string[]]$Urls,
        [string[]]$CaseNames,
        [switch]$ValidateBody
    )

    $ColdBest = $null; $HotBest = $null

    if ($CacheMode -in @("compare", "cold")) {
        $ColdBest = Invoke-ServiceBenchPhase -Name $Name -Phase "COLD" -Urls $Urls -CaseNames $CaseNames `
            -ValidateNominatimBody:$ValidateBody -BypassCache
    }

    if ($CacheMode -in @("compare", "hot")) {
        Invoke-WarmCache -Urls $Urls -Rounds 2
        $HotBest = Invoke-ServiceBenchPhase -Name $Name -Phase "HOT" -Urls $Urls -CaseNames $CaseNames `
            -ValidateNominatimBody:$ValidateBody
    }

    if ($CacheMode -eq "compare") {
        Write-CacheCompare -Name $Name -Cold $ColdBest -Hot $HotBest
    }

    if ($HotBest) {
        return "[{0}] COLD={1} rps -> HOT={2} rps (HIT%={3})" -f $Name, $(if ($ColdBest) { $ColdBest.OkRps } else { "-" }), $HotBest.OkRps, $HotBest.HitPct
    } elseif ($ColdBest) {
        return "[{0}] COLD={1} rps (no HOT run)" -f $Name, $ColdBest.OkRps
    }
    return $null
}

if ($Target -in @("nominatim", "both")) {
    if (-not $NomOk) {
        Write-Report "Skipping Nominatim" Yellow
    } else {
        $Validated = Test-NominatimCases -CaseList $NominatimUrls
        if ($Validated.Urls.Count -eq 0) {
            Write-Report "No valid Nominatim cases" Red
        } else {
            $line = Invoke-CacheCompareFlow -Name "nominatim" -Urls $Validated.Urls -CaseNames $Validated.Names -ValidateBody
            if ($line) { $Summary += $line }
        }
    }
}

if ($Target -in @("tiles", "both")) {
    if (-not $TilesOk) {
        Write-Report "Skipping tiles" Yellow
    } else {
        $TUrls = @($TilePaths | ForEach-Object { "$TilesUrl$_" })
        $line = Invoke-CacheCompareFlow -Name "tiles" -Urls $TUrls -CaseNames $TilePaths
        if ($line) { $Summary += $line }
    }
}

Write-Report ""
Write-Report "=== Summary ===" Cyan
if ($Summary.Count -eq 0) {
    Write-Report "No results. Is Nominatim healthy?" Red
    exit 1
}
foreach ($S in $Summary) { Write-Report " - $S" Green }
Write-Report ""
Write-Report "COLD = X-Bypass-Cache:1 (upstream). HOT = after warm (nginx tmpfs)."
Write-Report "Done."
exit 0
