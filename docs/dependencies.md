# Lista zależności — Nominatim + Serwer kafelków

Dokument do akceptacji UFG. Wersja: **1.1** | Data: 2026-08-27

Źródło prawdy: `docker-compose.yml`, `.env.example`, `scripts/*`, `styles/*`.

Projekt **nie ma** manifestów `package.json` / `requirements.txt` / `composer.json` — zależności to obrazy Docker, dane OSM, skrypty PowerShell/Bash oraz zasoby MapLibre.

---

## 0. Przegląd architektury zależności

```
Geofabrik (PBF)
    ├─► poland-latest.osm.pbf ──► Planetiler ──► poland.pmtiles ──► Martin ──► Nginx :8081
    └─► osmium filter ──► poland-filtered.osm.pbf ──► Nominatim (PG+PostGIS) ──► Nginx :8080

Frontend (Portal DOM / demo)
    ├─► MapLibre GL
    ├─► style_carto_positron.json (OpenMapTiles → lokalny Martin)
    ├─► style_versatiles_colorful.json (Shortbread → CDN Versatiles)
    └─► sprites/glyphs CDN (CARTO / Versatiles — docelowo lokalnie)
```

Ruch publiczny idzie **wyłącznie przez Nginx** — `nominatim` i `martin` mają tylko `expose` (bez publish na host).

---

## 1. Nominatim (geokodowanie miejscowości i ulic)

### Cel biznesowy
Lokalna instancja zamieniająca nazwy miejscowości/ulic z CBS na współrzędne lat/long. Zastępuje publiczny `nominatim.openstreetmap.org` (limit 1 req/s, ryzyko blokady).

### Komponenty

| Komponent | Wersja / obraz | Licencja | Uwagi |
|-----------|----------------|----------|-------|
| **Nominatim** | `mediagis/nominatim:5.1` | GPL-2.0 | Oficjalny obraz community |
| **PostgreSQL** | **16** (w obrazie; volume `/var/lib/postgresql/16/main`) | PostgreSQL License | Baza geokodowania |
| **PostGIS** | 3.x (w obrazie) | GPL-2.0 | Rozszerzenie geograficzne |
| **Python** | 3.x (w obrazie) | PSF | Skrypty importu / replication |
| **Apache HTTP** | 2.x (w obrazie) | Apache-2.0 | API HTTP wewnątrz kontenera `:8080` |
| **Osmium** | `iboates/osmium:latest` | GPL-3.0 | Job: filtr PBF (bez POI) — `scripts/filter-pbf.ps1` |
| **OSM PBF (pełny)** | Geofabrik Poland | ODbL | `poland-latest.osm.pbf` — źródło + kafelki |
| **OSM PBF (filtrowany)** | lokalny (osmium) | ODbL | `poland-filtered.osm.pbf` — import Nominatim |

### Optymalizacja datasetu

| Element | Wartość | Rola |
|---------|---------|------|
| `IMPORT_STYLE` | **`street`** | miejscowości + ulice (bez POI / adresów punktowych) |
| Filtr osmium | `place=*`, `highway=*`, `boundary=administrative` | mniejsza baza, szybszy import |
| Szczegóły | [nominatim-optimization.md](nominatim-optimization.md) | |

### Wymagania sprzętowe (Polska, wariant filtrowany)

| Zasób | Minimum POC | Produkcja |
|-------|-------------|-----------|
| Dysk (Nominatim + PBF) | ~20–40 GB (filtrowany import) | 60–80 GB (zapas + poprzednia wersja) |
| RAM | 4–8 GB | 8–16 GB |
| CPU | 4 rdzenie | 8+ rdzeni |
| Shared memory (`shm_size`) | 4 GB | 4 GB |
| Sieć | Dostęp do Geofabrik (pobranie PBF / diffs) | Replikacja między DC |

### Zmienne środowiskowe (kluczowe)

```
PBF_URL=https://download.geofabrik.de/europe/poland-latest.osm.pbf
REPLICATION_URL=https://download.geofabrik.de/europe/poland-updates/
NOMINATIM_PBF_PATH=/data/pbf/poland-filtered.osm.pbf
IMPORT_STYLE=street
NOMINATIM_PASSWORD=<secret>
POSTGRES_SHARED_BUFFERS=2GB
POSTGRES_MAINTENANCE_WORK_MEM=4GB
POSTGRES_EFFECTIVE_CACHE_SIZE=8GB
```

Uwagi:

- `street` = miejscowości + ulice (zalecane); `address` = + numery domów; `full` = nie używać
- Nie ustawiać `PBF_URL` razem z `PBF_PATH` w kontenerze Nominatim

### API używane przez portal

```
GET /search?city=Gdańsk&state=pomorskie&featuretype=settlement&format=json
GET /search?street=Zielona&city=Gdańsk&state=pomorskie&format=json
```

Endpoint publiczny: **Nginx `:8080`** → upstream `nominatim:8080` (cache tmpfs 7d).

Aplikacja bierze **pierwszy** wynik (`results[0].lat`, `results[0].lon`).

### Porty

| Port (host) | Usługa |
|-------------|--------|
| **8080** | Nginx cache → Nominatim HTTP API |
| (wewnętrzny) 8080 | Kontener `nominatim` — bez publish |
| 5432 | PostgreSQL — **nie wystawiony** w compose |

### Ryzyka bezpieczeństwa (do weryfikacji UFG)

- Obraz Docker z wieloma warstwami — wymaga skanowania podatności (Trivy/Grype)
- Brak Elasticsearch — OK, Nominatim używa tylko PostgreSQL
- Brak danych statystycznych UFG w tej usłudze
- Tag `:latest` na Osmium — zalecany pin wersji przed produkcją
- Wymagana warstwa security / regularne aktualizacje obrazu

---

## 2. Serwer kafelków wektorowych (podkład mapowy)

### Cel biznesowy
Lokalny podkład mapowy zastępujący zewnętrzne źródła (Versatile, Kartotherian). Pipeline: PBF → Planetiler → PMTiles → Martin → Nginx cache → Frontend.

### Komponenty

| Komponent | Wersja / obraz | Licencja | Uwagi |
|-----------|----------------|----------|-------|
| **Planetiler** | `ghcr.io/onthegomap/planetiler:latest` | BSD-3-Clause | Job (`generate-tiles.ps1`), nie daemon |
| **Martin Tile Server** | `ghcr.io/maplibre/martin:latest` | MIT / Apache-2.0 | Serwowanie PMTiles |
| **Nginx** | `nginx:1.27-alpine` | BSD-2-Clause | Cache HTTP kafelków **i** Nominatim |
| **OSM PBF** | Geofabrik Poland (pełny) | ODbL | `poland-latest.osm.pbf` — **nie** filtered |
| **OpenMapTiles schema** | (wbudowany w Planetiler) | BSD-3-Clause | Schemat warstw wektorowych |
| **Źródła Planetiler** | `data/planetiler-sources/` | zależne od `--download` | Dociągane przy generacji |

### Wymagania sprzętowe

| Zasób | Minimum POC | Produkcja |
|-------|-------------|-----------|
| Dysk operacyjny (Planetiler) | 20 GB | 30 GB |
| Dysk na kafelki (PMTiles) | ~5 GB | ~5–10 GB |
| RAM (Planetiler, `PLANETILER_MEMORY`) | 8 GB | 16 GB |
| RAM (Martin) | 512 MB–1 GB (cache in-process ~1 GB) | 1–2 GB |
| CPU | 4 rdzenie | 8+ rdzeni |

### Format kafelków

**PMTiles** (preferowany) — pojedynczy plik `poland.pmtiles`, serwowany przez Martin.

Alternatywa: **MBTiles** (SQLite) — wspierany przez Martina, nieużywany w POC.

### Porty

| Port (host) | Usługa |
|-------------|--------|
| (wewnętrzny) 3000 | Martin — bez publish |
| **8081** | Nginx cache → Martin |

### Endpointy kafelków (MapLibre GL)

```
GET /poland/{z}/{x}/{y}              # XYZ przez Nginx → Martin
GET /poland/{z}/{x}/{y}.pbf          # opcjonalnie z rozszerzeniem
GET /poland.json                     # TileJSON metadata
GET /health                          # healthcheck Nginx
```

---

## 3. Wspólne zależności infrastrukturalne

| Wymaganie | Status w UFG | Uwagi |
|-----------|--------------|-------|
| Docker Desktop / Docker Engine | Wymagany | Compose: `nominatim`, `martin`, `nginx-cache` |
| Kubernetes | Do weryfikacji z Fabianem | Ubuntu + Docker + K8s dostępne |
| Replikacja 2 DC (PKP + drugi ośrodek) | Do ustalenia | Te same dane OSM w obu DC |
| Elasticsearch / OpenSearch | **Niedostępny** | Nie wymagany |
| Exadata | Dostępny | Nominatim/Martin nie muszą na Exadata |
| Cron / worker do update | Wymagany | `scripts/update-all.ps1` — niedziela 00:00 |
| PowerShell | ≥ 5.1 | Skrypty ops (Windows) |
| BITS / Invoke-WebRequest | Host Windows | Download PBF |

---

## 4. Zależności aplikacji frontendowej (Portal DOM)

| Zależność | Typ | Opis |
|-----------|-----|------|
| **Styl bazowy — Positron** | `styles/style_carto_positron.json` | OpenMapTiles → lokalny Martin `:8081`; sprites/glyphs CARTO CDN |
| **Styl bazowy — Colorful** | `styles/style_versatiles_colorful.json` | Schemat **Shortbread** → obecnie CDN Versatiles (nie OpenMapTiles) |
| Legacy POC | `portal-light.json`, `portal-dark.json` | Uproszczone style demo |
| Mapowanie warstw | YAML | `styles/layer-mapping.yaml` |
| Tile source (OMT) | lokalny | `http://localhost:8081/poland.json` |
| Glyphs / sprites | CDN (POC) | CARTO + Versatiles — **produkcja: serwować lokalnie** |
| MapLibre GL JS | CDN (demo) | `unpkg.com/maplibre-gl@4` w `styles/demo/index.html` |
| GeoJSON konturów | Istniejące | Obszary administracyjne — bez zmian |
| CBS API | Istniejące | Słownik miejscowości/ulic — bez zmian |

**Uwaga schematów:** lokalny Planetiler generuje **OpenMapTiles**. Styl Versatiles Colorful wymaga tilesetu **Shortbread** — do pełnej lokalizacji osobny pipeline lub dalsze użycie CDN.

---

## 5. Podsumowanie obrazów Docker

### Runtime (daemon)

```yaml
mediagis/nominatim:5.1          # Nominatim + PostgreSQL 16 + PostGIS
ghcr.io/maplibre/martin:latest  # Serwer kafelków
nginx:1.27-alpine               # Cache HTTP (:8080 Nominatim, :8081 tiles)
```

### Joby okresowe (nie daemon)

```yaml
ghcr.io/onthegomap/planetiler:latest  # Generowanie PMTiles
iboates/osmium:latest                 # Filtr PBF pod Nominatim (bez POI)
```

**Uwaga:** tagi `:latest` (Martin, Planetiler, Osmium) — przed produkcją **przypiąć wersje** digest/tag.

Wymaga skanowania podatności przez UFG (Trivy/Grype).

---

## 6. Dane i sieć wychodząca

| Cel | Potrzeba |
|-----|----------|
| `download.geofabrik.de` | PBF + diffs (replication) |
| Docker Hub / GHCR | Pull obrazów |
| Źródła Planetiler (`--download`) | Job generacji kafelków |
| `tiles.basemaps.cartocdn.com` | Sprites/glyphs stylu Positron (POC) |
| `tiles.versatiles.org` | Tiles Shortbread + sprites/glyphs Colorful (POC) |
| `unpkg.com` | Tylko demo MapLibre |

Fallback lokalny: `poland-previous.osm.pbf`, `poland-previous.pmtiles`.

Alternatywy źródeł: [osm-alternatives.md](osm-alternatives.md).

---

## 7. Macierz licencji

| Artefakt | Licencja |
|----------|----------|
| Dane OSM / Geofabrik | **ODbL** |
| Nominatim | GPL-2.0 |
| PostgreSQL | PostgreSQL License |
| PostGIS | GPL-2.0 |
| Martin | MIT / Apache-2.0 |
| Planetiler + OpenMapTiles | BSD-3-Clause |
| Nginx | BSD-2-Clause |
| Osmium-tool | GPL-3.0 |
| MapLibre GL | BSD-3-Clause |

---

## 8. Checklist akceptacji UFG

- [ ] Akceptacja obrazu `mediagis/nominatim:5.1`
- [ ] Akceptacja obrazu `ghcr.io/maplibre/martin` (preferowany pin wersji)
- [ ] Akceptacja obrazu `ghcr.io/onthegomap/planetiler` (job okresowy; pin wersji)
- [ ] Akceptacja obrazu `iboates/osmium` (job filtracji PBF; pin wersji)
- [ ] Akceptacja `nginx:1.27-alpine`
- [ ] Akceptacja licencji ODbL (dane OSM) oraz GPL-3.0 (Osmium)
- [ ] Model replikacji między 2 DC
- [ ] Polityka skanowania podatności obrazów
- [ ] Polityka lokalnych glyphs/sprites (odcięcie od CARTO / Versatiles CDN)
- [ ] Wymagania dot. logowania/monitoringu
