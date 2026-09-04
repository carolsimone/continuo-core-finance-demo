# continuo-core-finance-demo

The **"after"** of the Airflow→Continuo migration. The same two projects that ran on separate Airflows in [airflow-core-demo](https://github.com/carolsimone/airflow-core-demo) and [airflow-finance-demo](https://github.com/carolsimone/airflow-finance-demo) now live in one repo and release through **Continuo** — no Airflow, no cron.

## What changed from the "before"

Two teams, one repo. Each service is a dbt project with a Dockerfile; a release goes through Continuo instead of a scheduler firing on a guess.

- `services/continuo-core` — builds `daily_transactions`, `revenue_per_user`.
- `services/continuo-finance` — builds `fx_transactions_eur`, `operational_cost_per_user`, `ltv_per_user`, …

The two depend on each other across projects (`continuo-core` reads `analytics.fx_transactions_eur`; `continuo-finance` reads `analytics.revenue_per_user`). On Airflow that mesh had no run order two separate cron schedules could express. **Continuo sequences it itself** at release time, from the validation closure — the whole reason for the move. Unlike the Airflow "before", `fx_transactions_eur` is **not** frozen here — Continuo orders the mesh. The one frozen input is `marketing_cost_per_user`, a marketing-team table `ltv_per_user` reads: it is carried as a finance seed so this two-team demo runs without a marketing service.

## Run it locally

This is a content demo — everything runs on your machine (Continuo on a local kind/k3s cluster, with its bundled Postgres/Redis/Neo4j/MinIO). No Hetzner. **Set up Continuo first** with the `continuo` repo's `docs/try-it-locally.md` — give the container runtime **≥ 12 GiB** (a starved runtime fails with a confusing API timeout).

1. Point at the local release API:
   ```bash
   kubectl -n continuo port-forward svc/release-controller 8088:8088 &
   ```
2. Bootstrap both services — `make release` builds the image, loads it into the cluster, and POSTs the release. Add `LOADER=k3s` if your cluster is k3s (default is kind):
   ```bash
   make release SERVICE=continuo-core    TAG=v1
   make release SERVICE=continuo-finance TAG=v1
   ```
   Each ends `promoted`: Continuo validates the whole cross-service graph in a shadow, then promotes.
3. **Trigger a run so the tables physically exist.** Validation clones unchanged upstream tables from production, so they must be real before the break in step 4. Run the `daily` schedule from the UI:
   ```bash
   kubectl -n continuo port-forward svc/ui 8090:8090 &
   # Log in (dex demo login: admin@example.com / password — see try-it-locally.md for the one-time
   # /etc/hosts line the OIDC redirect needs), pick the `daily` schedule, press ▶ Trigger run.
   kubectl -n continuo get jobs -w   # wait for the run's Jobs to finish
   ```
4. **Break it, and watch Continuo refuse the release.** Rename the column `continuo-finance` depends on, then release `continuo-core` again:
   ```bash
   ( cd services/continuo-core
     sed -i.bak -E 's/(COALESCE\(a\.revenue_eur, 0\)[[:space:]]+AS )revenue_eur,/\1net_revenue_eur,/' models/revenue_per_user.sql
     sed -i.bak -E 's/^([[:space:]]*-[[:space:]]*name:[[:space:]]*)revenue_eur[[:space:]]*$/\1net_revenue_eur/' models/schema.yml
     sed -i.bak -E 's/([^_])revenue_eur/\1net_revenue_eur/g' tests/assert_revenue_non_negative.sql
     rm -f models/*.bak tests/*.bak )
   make release SERVICE=continuo-core TAG=v2      # -> rejected
   ```
   Continuo validates `continuo-core` against the topology, sees `continuo-finance`'s `ltv_per_user` still reads `revenue_eur`, and refuses to promote. `curl -s http://localhost:8088/current-prod` still shows the last good release. Revert with `git checkout -- services/continuo-core`.

## The cross-team break, caught here

The break that silently corrupted finance on Airflow — `continuo-core` renames `revenue_per_user.revenue_eur` → `net_revenue_eur` — is **rejected at release time** on Continuo, before it ships, because validation checks the whole topology (`continuo-finance`'s `ltv_per_user` still reads `revenue_eur`), not just the changed project. `GET /current-prod` still shows the last good release — production is never touched. On Airflow, two separate schedulers had no way to see it.

## Why the services are named `continuo-*`

Continuo keys production state by **service name, globally** (`service_prod`, a singleton `current_prod`). These are named `continuo-core` / `continuo-finance` (not `core`/`finance`) so they don't collide with continuo-demo's services if both ever run against the same Continuo instance.

## CI (Hetzner) path — disabled

`.github/workflows/release.yml` with `scripts/release.sh` (no `RELEASE_API_URL`) releases via GitHub Actions to a remote instance over SSH, using `DOCKERHUB_*` / `HETZNER_*` secrets. Actions are **disabled** on this repo — the local path above is the one this demo uses. The workflow is kept as a reference for how CD integrates with Continuo.

## License

[CC0 1.0 Universal](LICENSE) — example code, public domain.
