# Bloc 6 — Observabilité : Prometheus + Grafana

> 🔲 À faire

## Sources de métriques

| Source | Exporter |
|---|---|
| Vault | vault-exporter |
| SPIRE | metrics endpoint natif |
| Boundary | audit log → node_exporter textfile |

## Dashboard Grafana (3 panels)

1. Vault leases actifs
2. SVIDs SPIRE valides + renouvellements
3. Sessions Boundary actives
