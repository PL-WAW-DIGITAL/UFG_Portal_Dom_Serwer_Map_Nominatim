#!/usr/bin/env bash
# Generates vector PMTiles from OSM PBF using Planetiler.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PBF_FILE="${PBF_FILE:-${SCRIPT_DIR}/../data/pbf/poland-latest.osm.pbf}"
OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/../data/tiles}"
SOURCES_DIR="${SCRIPT_DIR}/../data/planetiler-sources"
MEMORY="${PLANETILER_MEMORY:-8g}"
AREA="${AREA:-poland}"

mkdir -p "$OUTPUT_DIR" "$SOURCES_DIR"

[[ -f "$PBF_FILE" ]] || { echo "Missing PBF: $PBF_FILE. Run download-pbf.sh"; exit 1; }

PBF_DIR="$(dirname "$PBF_FILE")"
PBF_NAME="$(basename "$PBF_FILE")"
OUTPUT="${OUTPUT_DIR}/poland.pmtiles"
TEMP="${OUTPUT_DIR}/poland-building.pmtiles"

[[ -f "$OUTPUT" ]] && cp "$OUTPUT" "${OUTPUT_DIR}/poland-previous.pmtiles"

echo "Generating PMTiles (RAM: $MEMORY)..."

docker run --rm \
  -e "JAVA_TOOL_OPTIONS=-Xmx${MEMORY}" \
  -v "${PBF_DIR}:/data/pbf:ro" \
  -v "${OUTPUT_DIR}:/data/tiles" \
  -v "${SOURCES_DIR}:/data/sources" \
  ghcr.io/onthegomap/planetiler:latest \
  --download \
  --area="$AREA" \
  --osm-path="/data/pbf/${PBF_NAME}" \
  --output="/data/tiles/poland-building.pmtiles" \
  --force

mv "$TEMP" "$OUTPUT"
echo "Success: $OUTPUT ($(du -m "$OUTPUT" | cut -f1) MB)"
