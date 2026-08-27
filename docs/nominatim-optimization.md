# Optymalizacja datasetu Nominatim

**Status:** Wdrozone  
**Cel:** Mniejsza baza, szybszy import, brak POI w geokodowaniu

---

## Co jest wlaczane

| Element | Wartosc | Rola |
|---------|---------|------|
| `poland-latest.osm.pbf` | pelny extract | Planetiler / kafelki |
| `poland-filtered.osm.pbf` | place + highway + admin | Nominatim |
| `IMPORT_STYLE` | `street` | bez firm/POI/adresow punktowych |
| API `featuretype` | `settlement` / `street` | filtr wynikow w testach i klientach |
| Nginx cache | tmpfs | HIT zamiast Postgres |

Filtrowanie: `scripts/filter-pbf.ps1` (obraz `iboates/osmium`, wywolywane z `download-pbf.ps1`).

---

## Pierwszy import / reimport

```powershell
.\scripts\download-pbf.ps1          # pelny PBF + automatyczny filter
.\scripts\reimport-nominatim.ps1 -Force   # wipe volumes + import street
.\scripts\watch-progress.ps1
.\scripts\test-nominatim.ps1
```

Compose czyta:

```yaml
PBF_PATH: /data/pbf/poland-filtered.osm.pbf
IMPORT_STYLE: street
```

---

## Cotygodniowe update

1. `download-pbf.ps1` — pelny PBF + odswiezenie `poland-filtered.osm.pbf`
2. `nominatim replication --once` — `IMPORT_STYLE=street` **ignoruje POI** z diffow Geofabrik
3. `generate-tiles.ps1` — nadal z **pelnego** PBF
4. restart `martin` + `nginx-cache`

Wrapper: `scripts/update-all.ps1`

---

## Filtrowanie osmium (tagi)

**Zostawiane:** `place=*`, `highway=*`, `boundary=administrative`  
**Wycinane:** amenity, shop, tourism, public_transport, leisure, POI itp.

---

## API (klient Portal DOM)

```
/search?city=Gdansk&state=pomorskie&featuretype=settlement&format=json&limit=1
/search?street=Zielona&city=Gdansk&featuretype=street&format=json&limit=1
```

Przypadki: `scripts/nominatim-cases.json`.

---

## Szacunkowy efekt

| Metryka | Pelny import | street + filtered |
|---------|--------------|-------------------|
| Rozmiar PBF (Nominatim) | ~2 GB | ~0.4–1 GB |
| Rozmiar bazy | ~30–60 GB | ~10–20 GB |
| Czas importu | 2–8 h | 1–3 h |
| Trafienia firm/POI | tak | minimalne |

---

## Kryteria akceptacji

1. Baza istotnie mniejsza niz pelny `address`/`full`
2. `test-nominatim.ps1` — brak regresji (>=95%)
3. Brak firm w top-1 dla zapytan miejscowosci
4. p95 geokodowania OK na bench (`CacheMode compare`)
