# continuo-core-finance-demo

The **"after"** of the Airflow→Continuo migration. The same two projects that ran on separate Airflows in [airflow-core-demo](https://github.com/carolsimone/airflow-core-demo) and [airflow-finance-demo](https://github.com/carolsimone/airflow-finance-demo) now live in one repo and release through **Continuo** — no Airflow, no cron.

## What changed from the "before"

Two teams, one repo. Each service is a dbt project with a Dockerfile; a release goes through Continuo instead of a scheduler firing on a guess.

- `services/continuo-core` — builds `daily_transactions`, `revenue_per_user`.
- `services/continuo-finance` — builds `fx_transactions_eur`, `operational_cost_per_user`, `ltv_per_user`, …

The two depend on each other across projects (`continuo-core` reads `analytics.fx_transactions_eur`; `continuo-finance` reads `analytics.revenue_per_user`). On Airflow that mesh had no run order two separate cron schedules could express. **Continuo sequences it itself** at release time, from the validation closure — the whole reason for the move. Unlike the Airflow "before", `fx_transactions_eur` is **not** frozen here — Continuo orders the mesh. The one frozen input is `marketing_cost_per_user`, a marketing-team table `ltv_per_user` reads: it is carried as a finance seed so this two-team demo runs without a marketing service.

## Run it locally

This is a content demo — everything runs on your machine (Continuo on a local kind/k3s cluster, with its bundled Postgres/Redis/Neo4j/MinIO). No Hetzner. **Set up Continuo first** with the `continuo` repo's `docs/try-it-locally.md` — give the container runtime **6 CPUs and 16 GiB of memory** (a starved runtime fails with a confusing API timeout).

1. Point at the local ui, which serves continuo's public release API (`/api/v1`), and get an operator's bearer token. With the bundled Dex (continuo's `deploy/AUTH.md`, "Bearer tokens"):
   ```bash
   kubectl -n continuo port-forward svc/ui 8090:8090 &
   kubectl -n continuo port-forward svc/continuo-dex 5556:5556 &
   CLIENT_SECRET=$(kubectl -n continuo get secret continuo-dex -o jsonpath='{.data.client-secret}' | base64 -d)
   export CONTINUO_TOKEN=$(curl -s -u "continuo-ui:${CLIENT_SECRET}" http://localhost:5556/dex/token \
     -d grant_type=password -d scope="openid email profile" \
     -d username=admin@example.com -d password=password | jq -r .id_token)
   ```
   The token lasts an hour; request a new one when it expires. `make release` reads `CONTINUO_TOKEN` and targets `CONTINUO_URL` (default `http://localhost:8090`).
2. Bootstrap both services — `make release` builds the image, loads it into the cluster, and POSTs the release through `scripts/release.sh`. An operator token may bootstrap; the first release of each service against an unseeded continuo does. Add `LOADER=k3s` if your cluster is k3s (default is kind):
   ```bash
   make release SERVICE=continuo-core    TAG=v1
   make release SERVICE=continuo-finance TAG=v1
   ```
   Each ends `promoted`. The first, `continuo-core`, finds production empty and bootstraps (promotes without validation); `continuo-finance` is then validated against the whole cross-service graph in a shadow before it promotes.
3. **Trigger a run so the tables physically exist.** Validation clones unchanged upstream tables from production, so they must be real before the break in step 4. Run the `daily` schedule from the UI:
   ```bash
   # (reuses the ui port-forward from step 1)
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
   continuo validates `continuo-core` against the topology, sees `continuo-finance`'s `ltv_per_user` still reads `revenue_eur`, and refuses to promote. `curl -s -H "Authorization: Bearer $CONTINUO_TOKEN" http://localhost:8090/api/v1/current-prod` still shows the last good release. Revert with `git checkout -- services/continuo-core`.

## The cross-team break, caught here

The break that silently corrupted finance on Airflow — `continuo-core` renames `revenue_per_user.revenue_eur` → `net_revenue_eur` — is **rejected at release time** on continuo, before it ships, because validation checks the whole topology (`continuo-finance`'s `ltv_per_user` still reads `revenue_eur`), not just the changed project. `GET /api/v1/current-prod` still shows the last good release — production is never touched. On Airflow, two separate schedulers had no way to see it.

## Why the services are named `continuo-*`

Continuo keys production state by **service name, globally** (`service_prod`, a singleton `current_prod`). These are named `continuo-core` / `continuo-finance` (not `core`/`finance`) so they don't collide with continuo-demo's services if both ever run against the same Continuo instance.

## Runs locally only

This repo releases only to a continuo running on your machine; it has no CI release workflow. Two things make that work: a port-forward to the cluster, and a bearer token you mint yourself.

**Port-forward the ui and Dex.** continuo's release API is served by the `ui` at `/api/v1` — the same service as the dashboard, so no other continuo service needs forwarding. Dex is the bundled login provider that issues your token:

```bash
kubectl -n continuo port-forward svc/ui 8090:8090 &
kubectl -n continuo port-forward svc/continuo-dex 5556:5556 &
```

**Mint a bearer token.** Every call to `/api/v1` carries `Authorization: Bearer <token>`. Locally the token is an ID token Dex issues for the demo operator account (`admin@example.com` / `password`), traded for the password in one request:

```bash
CLIENT_SECRET=$(kubectl -n continuo get secret continuo-dex -o jsonpath='{.data.client-secret}' | base64 -d)
export CONTINUO_TOKEN=$(curl -s -u "continuo-ui:${CLIENT_SECRET}" http://localhost:5556/dex/token \
  -d grant_type=password -d scope="openid email profile" \
  -d username=admin@example.com -d password=password | jq -r .id_token)

# Check it: prints the current production release, or an "invalid_token" error.
curl -s -H "Authorization: Bearer $CONTINUO_TOKEN" http://localhost:8090/api/v1/current-prod
```

If `echo $CONTINUO_TOKEN` prints `null`, the login failed: check the Dex port-forward. The token lasts one hour; run the `export CONTINUO_TOKEN=...` line again when a call answers `401`. `make release` reads `CONTINUO_TOKEN` and targets `CONTINUO_URL` (default `http://localhost:8090`).

[continuo-demo](https://github.com/carolsimone/continuo-demo) shows the CD path, where a pipeline releases with its GitHub Actions token instead.

`scripts/release.sh` is covered by `scripts/tests/test_release_sh.py`, which runs it against a stub of the release API (`uvx pytest==9.1.1 scripts/tests/test_release_sh.py`; needs curl and jq), and by `shellcheck scripts/release.sh`.

## License

[CC0 1.0 Universal](LICENSE) — example code, public domain.
