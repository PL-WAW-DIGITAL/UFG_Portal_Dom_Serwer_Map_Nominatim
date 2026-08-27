#!/usr/bin/env bash
# Pobiera Poland OSM PBF z Geofabrik z obsługą fallback.
set -euo pipefail

PBF_URL="${PBF_URL:-https://download.geofabrik.de/europe/poland-latest.osm.pbf}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/../data/pbf}"
LOG_DIR="${SCRIPT_DIR}/../data/logs"

mkdir -p "$OUTPUT_DIR" "$LOG_DIR"
LOG_FILE="${LOG_DIR}/download-$(date +%Y-%m-%d).log"
TARGET="${OUTPUT_DIR}/poland-latest.osm.pbf"
PREVIOUS="${OUTPUT_DIR}/poland-previous.osm.pbf"
TEMP="${OUTPUT_DIR}/poland-latest.osm.pbf.download"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

log "Start pobierania: $PBF_URL"

if [[ -f "$TARGET" && "${FORCE:-}" != "1" ]]; then
  AGE_H=$(( ($(date +%s) - $(stat -c %Y "$TARGET" 2>/dev/null || stat -f %m "$TARGET")) / 3600 ))
  if [[ $AGE_H -lt 24 ]]; then
    log "Plik istnieje (<24h). Ustaw FORCE=1 aby pobrać ponownie."
    FILTERED="${OUTPUT_DIR}/poland-filtered.osm.pbf"
    if [[ ! -f "$FILTERED" || "$TARGET" -nt "$FILTERED" ]]; then
      log "Filtrowanie PBF pod Nominatim..."
      "${SCRIPT_DIR}/filter-pbf.sh"
    fi
    exit 0
  fi
fi

[[ -f "$TARGET" ]] && cp "$TARGET" "$PREVIOUS" && log "Zachowano poprzednią wersję"

if curl -fL "$PBF_URL" -o "$TEMP"; then
  SIZE_MB=$(du -m "$TEMP" | cut -f1)
  if [[ $SIZE_MB -lt 100 ]]; then
    log "BŁĄD: plik za mały (${SIZE_MB}MB)"
    rm -f "$TEMP"
    exit 1
  fi
  mv "$TEMP" "$TARGET"
  log "Sukces. Rozmiar: ${SIZE_MB} MB"
  log "Filtrowanie PBF pod Nominatim (bez POI)..."
  "${SCRIPT_DIR}/filter-pbf.sh"
else
  log "BLAD pobierania. Fallback na poprzednia wersje."
  rm -f "$TEMP"
  exit 1
fi
