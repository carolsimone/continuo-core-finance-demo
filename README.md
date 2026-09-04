# continuo-core-finance-demo

The **"after"** of the Airflow→Continuo migration. The same two projects that ran on separate Airflows in [airflow-core-demo](https://github.com/carolsimone/airflow-core-demo) and [airflow-finance-demo](https://github.com/carolsimone/airflow-finance-demo) now live in one repo and release through **Continuo** — no Airflow, no cron.

## What changed from the "before"

Two teams, one repo. Each service is a dbt project with a Dockerfile; a release goes through Continuo instead of a scheduler firing on a guess.

- `services/continuo-core` — builds `daily_transactions`, `revenue_per_user`.
- `services/continuo-finance` — builds `fx_transactions_eur`, `operational_cost_per_user`, `ltv_per_user`, …

The two depend on each other across projects (`continuo-core` reads `analytics.fx_transactions_eur`; `continuo-finance` reads `analytics.revenue_per_user`). On Airflow that mesh had no run order two separate cron schedules could express. **Continuo sequences it itself** at release time, from the validation closure — the whole reason for the move. There are **no fixtures** here; the `fx_transactions_eur` fixture in the "before" existed only because Airflow couldn't order the mesh.

## Run it locally

This is a content demo — everything runs on your machine (Continuo + k3s + your Postgres/Redis/Neo4j + MinIO for S3). No Hetzner. Full walkthrough: the `continuo` repo's `docs/try-it-locally.md`.

1. Stand up Continuo on your local cluster, then port-forward the release API:
   ```bash
   kubectl -n continuo port-forward svc/release-controller 8088:8088 &
   ```
2. Build each service image and load it into the cluster (k3s: `k3s ctr images import <(docker save …)`; kind: `kind load docker-image`):
   ```bash
   docker build -t continuo-core:v1 services/continuo-core
   docker build -t continuo-finance:v1 services/continuo-finance
   ```
3. Release through Continuo with `release.sh` in **local mode** (`RELEASE_API_URL` — no SSH):
   ```bash
   RELEASE_API_URL=http://localhost:8088 RELEASE_ID=rel-core-1 \
     SERVICE=continuo-core IMAGE_TAG=v1 \
     REPO=carolsimone/continuo-core-finance-demo COMMIT_SHA=$(git rev-parse HEAD) \
     bash scripts/release.sh          # first release bootstraps (promotes without validation)

   RELEASE_API_URL=http://localhost:8088 RELEASE_ID=rel-finance-1 \
     SERVICE=continuo-finance IMAGE_TAG=v1 \
     REPO=carolsimone/continuo-core-finance-demo COMMIT_SHA=$(git rev-parse HEAD) \
     bash scripts/release.sh
   ```
   Trigger a run so the tables physically exist, then do the break below and release `continuo-core` again with a fresh `RELEASE_ID` and image tag.

## The cross-team break, caught here

The break that silently corrupted finance on Airflow — `continuo-core` renames `revenue_per_user.revenue_eur` → `net_revenue_eur` — is **rejected at release time** on Continuo, before it ships, because validation checks the whole topology (`continuo-finance`'s `ltv_per_user` still reads `revenue_eur`), not just the changed project. `GET /current-prod` still shows the last good release — production is never touched. On Airflow, two separate schedulers had no way to see it.

## Why the services are named `continuo-*`

Continuo keys production state by **service name, globally** (`service_prod`, a singleton `current_prod`). These are named `continuo-core` / `continuo-finance` (not `core`/`finance`) so they don't collide with continuo-demo's services if both ever run against the same Continuo instance.

## CI (Hetzner) path — disabled

`.github/workflows/release.yml` with `scripts/release.sh` (no `RELEASE_API_URL`) releases via GitHub Actions to a remote instance over SSH, using `DOCKERHUB_*` / `HETZNER_*` secrets. Actions are **disabled** on this repo — the local path above is the one this demo uses. The workflow is kept as a reference for how CD integrates with Continuo.

## License

[CC0 1.0 Universal](LICENSE) — example code, public domain.
