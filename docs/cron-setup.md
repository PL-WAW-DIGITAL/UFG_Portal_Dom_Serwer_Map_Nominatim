# Konfiguracja Task Scheduler (Windows)

## Cotygodniowa aktualizacja (niedziela 00:00)

```powershell
$Action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"C:\Users\a926850\prj\nominatimPDOM\scripts\update-all.ps1`""

$Trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At "00:00"

$Settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Hours 12)

Register-ScheduledTask `
    -TaskName "PortalDOM-MapUpdate" `
    -Action $Action `
    -Trigger $Trigger `
    -Settings $Settings `
    -Description "Aktualizacja danych OSM: PBF, Nominatim, PMTiles"
```

## Tylko pobieranie PBF (codziennie, opcjonalnie)

```powershell
$Action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"C:\Users\a926850\prj\nominatimPDOM\scripts\download-pbf.ps1`""

$Trigger = New-ScheduledTaskTrigger -Daily -At "02:00"

Register-ScheduledTask `
    -TaskName "PortalDOM-PbfDownload" `
    -Action $Action `
    -Trigger $Trigger `
    -Description "Pobieranie Poland PBF z Geofabrik"
```

## Linux (cron)

```cron
# /etc/cron.d/portal-dom-maps
0 0 * * 0 deploy /opt/nominatimPDOM/scripts/update-all.ps1
```

Lub bash:

```cron
0 0 * * 0 deploy /opt/nominatimPDOM/scripts/download-pbf.sh && /opt/nominatimPDOM/scripts/generate-tiles.sh
```

## Fallback

Procedura `update-all.ps1` automatycznie:
- Zachowuje poprzedni PBF jako `poland-previous.osm.pbf`
- Zachowuje poprzednie kafelki jako `poland-previous.pmtiles`
- Przy bledzie kontynuuje na starych danych

Szczegoly: [update-procedure.md](../docs/update-procedure.md)
