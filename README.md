# Serwer map + Nominatim — Portal DOM

Lokalna infrastruktura geokodowania (Nominatim) i podkładu mapowego (Planetiler + Martin) oparta na danych OpenStreetMap Polska.

## Szybki start

```powershell
# 1. Konfiguracja
Copy-Item .env.example .env

# 2. Pobierz dane OSM Polska (~2-3 GB) + filtr pod Nominatim (bez POI)
.\scripts\download-pbf.ps1

# 3. Uruchom Nominatim (import z poland-filtered.osm.pbf, IMPORT_STYLE=street)
docker compose up -d nominatim

# Podglad postepu (PBF / Nominatim / Planetiler / health)
.\scripts\watch-progress.ps1

# 4. Wygeneruj kafelki wektorowe (z pelnego poland-latest.osm.pbf)
.\scripts\generate-tiles.ps1

# 5. Uruchom serwer kafelków + cache
docker compose up -d martin nginx-cache

# 6. Test geokodowania
.\scripts\test-nominatim.ps1

# 7. Test wydajnosciowy (max obciazenie na tej maszynie)
.\scripts\bench-load.ps1
```

Reimport Nominatim (wipe + filtered, bez POI):

```powershell
.\scripts\reimport-nominatim.ps1 -Force
```

## Optymalizacja (bez POI)

| Plik | Uzycie |
|------|--------|
| `data/pbf/poland-latest.osm.pbf` | Planetiler / kafelki |
| `data/pbf/poland-filtered.osm.pbf` | Nominatim (`IMPORT_STYLE=street`) |

Szczegoly: [docs/nominatim-optimization.md](docs/nominatim-optimization.md)

## Usługi

| Usługa | Port | Opis |
|--------|------|------|
| Nominatim (przez cache) | **8080** | Geokodowanie — Nginx tmpfs cache 7d |
| Martin | (wewnętrzny) | Serwer kafelków — tylko w sieci Docker |
| Nginx Cache | **8081** | Kafelki wektorowe — Nginx tmpfs cache 14d |

Szczegoly: [docs/caching.md](docs/caching.md)

## Cache

Ruch idzie zawsze przez Nginx (RAM tmpfs):

```powershell
# MISS potem HIT
curl -sI "http://localhost:8080/search?city=Warszawa&format=json&limit=1" | findstr X-Cache
curl -sI "http://localhost:8080/search?city=Warszawa&format=json&limit=1" | findstr X-Cache
```

Po `docker compose up -d` kontenery `nominatim`/`martin` nie sa publikowane bezposrednio — tylko `:8080` i `:8081`.

## Progress

```powershell
# Live dashboard — aktualizacja w miejscu (bez Clear-Host)
.\scripts\watch-progress.ps1

# Co 0.5s (najszybszy podglad) — IntervalSec musi byc int, uzyj 1
.\scripts\watch-progress.ps1 -IntervalSec 1

# Jednorazowy snapshot
.\scripts\watch-progress.ps1 -Once
```

Pasek postępu jest też wbudowany w `download-pbf.ps1` (BITS) oraz `generate-tiles.ps1` (Planetiler).

## Load test

```powershell
# Domyslnie: COLD (bez cache) -> warm -> HOT (po cache) + tabela DELTA
.\scripts\bench-load.ps1

.\scripts\bench-load.ps1 -Target nominatim -CacheMode compare -MaxConcurrency 16 -DurationSec 8

# Tylko cold (X-Bypass-Cache) albo tylko hot
.\scripts\bench-load.ps1 -CacheMode cold
.\scripts\bench-load.ps1 -CacheMode hot

.\scripts\bench-load.ps1 -Target tiles -MaxErrorPct 2 -MaxP95Ms 500
```

Wyniki: `data/logs/bench-*.txt` oraz `bench-*.csv` (kolumna `phase` = COLD/HOT).

## Dokumentacja

- [Lista zależności (UFG)](docs/dependencies.md)
- [Plan POC (2 tygodnie)](docs/plan-poc.md)
- [HLD — architektura](docs/hld.md)
- [Checklist UFG / Fabian](docs/ufg-fabian-checklist.md)
- [Alternatywne źródła PBF](docs/osm-alternatives.md)
- [Optymalizacja Nominatim](docs/nominatim-optimization.md)
- [Procedura aktualizacji](docs/update-procedure.md)
- [Caching](docs/caching.md)

## Wymagania

- Docker Desktop (Windows) z min. 8 GB RAM
- ~20–40 GB wolnego dysku (filtrowany Nominatim + kafelki; mniej niz pelny import)
- `--shm-size=4g` dla Nominatim (skonfigurowane w compose)

## Struktura projektu

```
nominatimPDOM/
├── docker-compose.yml      # Wszystkie usługi
├── .env.example            # Zmienne środowiskowe
├── docs/                   # Dokumentacja
├── scripts/                # Skrypty operacyjne
├── tiles/                  # Konfiguracja Martin + Nginx
├── styles/                 # Style MapLibre GL (bazowe: Positron, Colorful)
│   └── demo/               # Podgląd stylów na lokalnych kafelkach
└── data/                   # Dane (gitignored)
    ├── pbf/                # Pliki OSM PBF
    └── tiles/              # Pliki PMTiles
```

Style bazowe: `styles/style_carto_positron.json` (OpenMapTiles → Martin), `styles/style_versatiles_colorful.json` (Shortbread / CDN). Demo: otwórz `styles/demo/index.html` (przy działającym `:8081`).

## Licencje

Dane OSM: [ODbL](https://openstreetmap.org/copyright) — © OpenStreetMap contributors
