#!/usr/bin/env bash
# Filtruje PBF pod Nominatim: miejscowosci, ulice, granice admin (bez POI).
# Pelny poland-latest.osm.pbf zostaje dla Planetiler/kafelkow.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT="${INPUT:-${SCRIPT_DIR}/../data/pbf/poland-latest.osm.pbf}"
OUTPUT="${OUTPUT:-${SCRIPT_DIR}/../data/pbf/poland-filtered.osm.pbf}"

[[ -f "$INPUT" ]] || { echo "Brak pliku: $INPUT"; exit 1; }

INPUT_DIR="$(dirname "$INPUT")"
INPUT_NAME="$(basename "$INPUT")"
OUTPUT_NAME="$(basename "$OUTPUT")"

echo "Filtrowanie PBF: $INPUT_NAME -> $OUTPUT_NAME"
echo "Zostawiam: place=*, highway=*, boundary=administrative"

docker run --rm \
  -v "${INPUT_DIR}:/data" \
  iboates/osmium:latest \
  tags-filter "/data/${INPUT_NAME}" \
    n/place \
    w/place \
    r/place \
    w/highway \
    r/boundary=administrative \
    n/boundary=administrative \
    w/boundary=administrative \
  -o "/data/${OUTPUT_NAME}" \
  --overwrite

echo "Sukces: $OUTPUT ($(du -m "$OUTPUT" | cut -f1) MB)"
echo "Uzyj w Nominatim: PBF_PATH=/data/pbf/${OUTPUT_NAME} IMPORT_STYLE=street"
