#!/usr/bin/env bash
# Testuje geokodowanie Nominatim z payloadem Portal DOM.
set -euo pipefail

BASE_URL="${NOMINATIM_URL:-http://localhost:8080}"
PASSED=0
FAILED=0

test_search() {
  local name="$1" query="$2"
  printf "Test: %s ... " "$name"
  local response
  if response=$(curl -sf "${BASE_URL}/search?${query}" 2>/dev/null); then
    local lat lon
    lat=$(echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['lat'] if d else '')" 2>/dev/null || echo "")
    if [[ -n "$lat" && "$lat" != "0" ]]; then
      echo "OK (lat=$lat)"
      PASSED=$((PASSED + 1))
    else
      echo "FAIL (brak wyników)"
      FAILED=$((FAILED + 1))
    fi
  else
    echo "FAIL (HTTP error)"
    FAILED=$((FAILED + 1))
  fi
}

echo "=== Test Nominatim: $BASE_URL ==="

test_search "Gdańsk" "city=Gdańsk&state=pomorskie&featuretype=settlement&format=json&limit=1"
test_search "Gdańsk Zielona" "street=Zielona&city=Gdańsk&state=pomorskie&format=json&limit=1"
test_search "Warszawa" "city=Warszawa&state=mazowieckie&featuretype=settlement&format=json&limit=1"
test_search "Kraków" "city=Kraków&state=małopolskie&featuretype=settlement&format=json&limit=1"

echo "Wynik: $PASSED passed, $FAILED failed"
curl -sf "${BASE_URL}/status" >/dev/null 2>&1 && echo "Status: OK" || echo "Status: niedostępny"
exit $([[ $FAILED -eq 0 ]] && echo 0 || echo 1)
