#!/usr/bin/env bash
# Live progress dashboard for PBF / Nominatim / Planetiler
set -euo pipefail
INTERVAL="${1:-3}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bar() {
  local pct=${1%.*}
  (( pct < 0 )) && pct=0
  (( pct > 100 )) && pct=100
  local filled=$(( pct * 28 / 100 ))
  local empty=$(( 28 - filled ))
  printf '[%s%s] %5s%%' "$(printf '#%.0s' $(seq 1 $filled 2>/dev/null || true))" "$(printf '-%.0s' $(seq 1 $empty 2>/dev/null || true))" "$1"
}

while true; do
  clear
  echo "=== Portal DOM — progress monitor ==="
  echo "Updated: $(date '+%Y-%m-%d %H:%M:%S')  (Ctrl+C to stop)"
  echo

  echo "1) PBF"
  if [[ -f "$ROOT/data/pbf/poland-latest.osm.pbf" ]]; then
    mb=$(du -m "$ROOT/data/pbf/poland-latest.osm.pbf" | cut -f1)
    echo "   Status : ready ($mb MB)"
    echo "   Progress: $(bar 100)"
  else
    partial=$(ls -1t "$ROOT/data/pbf"/poland-latest.osm.pbf.download* 2>/dev/null | head -1 || true)
    if [[ -n "${partial:-}" ]]; then
      mb=$(du -m "$partial" | cut -f1)
      pct=$(( mb * 100 / 1900 )); (( pct > 99 )) && pct=99
      echo "   Status : downloading"
      echo "   Progress: $(bar $pct)"
      echo "   Detail : $mb / ~1900 MB"
    else
      echo "   Status : missing — run scripts/download-pbf.sh"
    fi
  fi
  echo

  echo "2) Nominatim"
  if docker ps -a --filter name=^nominatim$ --format '{{.Names}}' | grep -q nominatim; then
    health=$(docker inspect nominatim --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null || echo n/a)
    status=$(docker ps -a --filter name=^nominatim$ --format '{{.Status}}')
    echo "   Container: $status"
    echo "   Health   : $health"
    if [[ "$health" == "healthy" ]]; then
      echo "   Progress: $(bar 100)"
      echo "   Stage   : READY"
    else
      line=$(docker logs nominatim --tail 5 2>&1 | tail -1)
      echo "   Detail  : $line"
    fi
  else
    echo "   Status : not created"
  fi
  echo

  echo "3) Planetiler / tiles"
  if [[ -f "$ROOT/data/tiles/poland.pmtiles" ]]; then
    mb=$(du -m "$ROOT/data/tiles/poland.pmtiles" | cut -f1)
    echo "   Status : ready ($mb MB)"
    echo "   Progress: $(bar 100)"
  elif docker ps --format '{{.Names}} {{.Image}}' | grep -qi planetiler; then
    echo "   Status : generating"
    docker logs planetiler-poland --tail 3 2>/dev/null || true
  else
    echo "   Status : idle / missing"
  fi
  echo

  echo "4) Probes"
  for u in http://localhost:8080/status http://localhost:3000/health http://localhost:8081/health; do
    if curl -sf --max-time 2 "$u" >/dev/null; then echo "   $u : OK"; else echo "   $u : down"; fi
  done

  sleep "$INTERVAL"
done
