# Checklist spotkania z Fabianem (UFG)

**Cel:** Weryfikacja akceptacji komponentów i wymagań infrastrukturalnych  
**Uczestnicy:** Piotr, Przemek, Fabian (UFG)  
**Data proponowana:** Do ustalenia (dogrywka po spotkaniu 26.08)

---

## Pytania do Fabiana

### Docker / Kubernetes

1. Czy UFG akceptuje wdrożenie obrazów Docker w środowisku produkcyjnym?
2. Czy preferowany jest Docker Compose, Kubernetes, czy instalacja natywna?
3. Jakie są wymagania dot. rejestru obrazów (własny registry vs Docker Hub / GHCR)?
4. Czy wymagane jest budowanie własnych obrazów z bazowych (security hardening)?

### Akceptacja konkretnych obrazów

| Obraz | Pytanie |
|-------|---------|
| `mediagis/nominatim:5.1` | Czy akceptowalny? Wymaga skanowania Trivy? |
| `ghcr.io/maplibre/martin:latest` | Czy akceptowalny? Czy wymaga pinu wersji? |
| `ghcr.io/onthegomap/planetiler:latest` | Job okresowy (nie daemon) — OK? Pin wersji? |
| `iboates/osmium:latest` | Job filtracji PBF (bez POI) — OK? Pin wersji? GPL-3.0? |
| `nginx:1.27-alpine` | Czy akceptowalny? |

### Replikacja między 2 DC

5. Jaki model replikacji jest wymagany między drugim ośrodkiem?
6. Czy wystarczy active-passive, czy wymagany active-active?
7. Jak replikować dane PostgreSQL (Nominatim) — streaming replication, backup/restore?
8. Jak replikować pliki PMTiles między DC?

### Bezpieczeństwo

9. Jakie narzędzia skanowania podatności obrazów są wymagane (Trivy, Grype, Snyk)?
10. Czy wymagany jest WAF / reverse proxy przed usługami?
11. Czy porty 8080 (Nginx→Nominatim) i 8081 (Nginx→tiles) mogą być wystawione tylko wewnętrznie?
12. Jakie wymagania dot. logowania i audytu?

### Zasoby

13. Ile RAM/CPU/dysku na Nominatim filtrowany (~20–40 GB dysk POC, 8 GB RAM, shm 4g)?
14. Ile RAM/CPU/dysku na pipeline kafelków (~20 GB operacyjne + 5 GB PMTiles, Planetiler 8g heap)?
15. Czy Przemek może testować lokalnie, czy wymagane środowisko UFG od razu?

### Inne

16. Brak Elasticsearch/OpenSearch — czy to OK dla tych usług?
17. Czy Exadata jest wymagany, czy wystarczy zwykły PostgreSQL w kontenerze?
18. Jakie są wymagania SLA/monitoringu (Prometheus, Grafana, inne)?

---

## Decyzje do podjęcia

| # | Decyzja | Opcje | Rekomendacja zespołu |
|---|---------|-------|---------------------|
| 1 | Deployment model | Docker / K8s / natywny | Docker Compose → K8s |
| 2 | Replikacja DC | active-passive / active-active | active-passive (dane statyczne) |
| 3 | Skanowanie obrazów | Trivy przed deploy | Tak |
| 4 | Dostęp zewnętrzny | Tylko wewnętrzna sieć | Tylko wewnętrzna |

---

## Materiały do przekazania Fabianowi

- [ ] [dependencies.md](dependencies.md) — pełna lista zależności
- [ ] [hld.md](hld.md) — architektura wysokopoziomowa
- [ ] `docker-compose.yml` — definicja usług
- [ ] Wyniki skanowania Trivy obrazów (do wykonania przed spotkaniem)

---

## Notatki ze spotkania

_Po spotkaniu uzupełnić:_

| Pytanie | Odpowiedź | Data |
|---------|-----------|------|
| | | |
| | | |

---

## Następne kroki po spotkaniu

1. Zaktualizować `docker-compose.yml` wg wymagań UFG
2. Dostosować model replikacji
3. Uruchomić POC w środowisku UFG (jeśli akceptacja wstępna)
4. Zaplanować pełne skanowanie bezpieczeństwa przed produkcją
