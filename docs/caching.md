# Caching — Portal DOM maps stack

## Architecture (2 levels)

```
Client
  │
  ▼
Nginx (:8080 Nominatim, :8081 tiles)     ← L2: RAM tmpfs proxy_cache
  │                    │
  ▼                    ▼
Nominatim              Martin            ← L1: Postgres / Martin memory cache
```

| Layer | What | TTL | Storage |
|-------|------|-----|---------|
| Nginx Nominatim | `GET /search`, `/reverse` | 7 days | tmpfs 512 MB |
| Nginx tiles | `/{source}/{z}/{x}/{y}` | 14 days | tmpfs 2 GB |
| Martin | tile + PMTiles directory | 24 h / 1 GB | process RAM |
| Browser | `Cache-Control` headers | 1–14 days | client |

## Why this is fast

1. **tmpfs** — cache hits never touch disk
2. **proxy_cache_lock** — one upstream fetch per key (no stampedes)
3. **proxy_cache_background_update** + **use_stale** — stale responses while refreshing
4. **keepalive** pools to Nominatim/Martin — fewer TCP handshakes
5. **open_file_cache** — faster serving of cached objects
6. Nominatim/Martin **not published** publicly — only via Nginx

## Ports

| Port | Service |
|------|---------|
| **8080** | Cached Nominatim (was raw container) |
| **8081** | Cached tiles |
| (internal) | `nominatim:8080`, `martin:3000` |

Scripts (`test-nominatim`, `bench-load`) already use `:8080` — they benefit automatically.

## Headers

- `X-Cache-Status: HIT | MISS | STALE | UPDATING | BYPASS`
- Nominatim: `Cache-Control: public, max-age=86400, stale-while-revalidate=604800`
- Tiles: `Cache-Control: public, max-age=1209600, immutable`

## Invalidate cache

```powershell
# Recreate nginx (wipes tmpfs caches)
docker compose restart nginx-cache

# Or full recreate
docker compose up -d --force-recreate nginx-cache
```

After weekly OSM update (`update-all.ps1`), restart `nginx-cache` so stale geocodes/tiles refresh.

## Tune sizes

In [docker-compose.yml](../docker-compose.yml) `tmpfs`:

```yaml
tmpfs:
  - /var/cache/nginx/nominatim:size=512m,mode=1777
  - /var/cache/nginx/tiles:size=2048m,mode=1777
```

Increase if the host has spare RAM (e.g. `1024m` / `4096m`).

## Quick verify

```powershell
# First request = MISS, second = HIT
curl -sI "http://localhost:8080/search?city=Warszawa&format=json&limit=1" | findstr X-Cache
curl -sI "http://localhost:8080/search?city=Warszawa&format=json&limit=1" | findstr X-Cache

curl -sI "http://localhost:8081/poland/10/558/340" | findstr X-Cache
```
