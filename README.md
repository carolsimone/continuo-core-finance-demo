# continuo-core-finance-demo

The **"after"** of the Airflow→Continuo migration. The same two projects that ran on separate Airflows in [airflow-core-demo](https://github.com/carolsimone/airflow-core-demo) and [airflow-finance-demo](https://github.com/carolsimone/airflow-finance-demo) now live in one repo and release through **Continuo** — no Airflow, no cron.

## What changed from the "before"

Two teams, one repo. Each service is a dbt project with a Dockerfile; a push releases it through Continuo instead of a scheduler firing on a guess.

- `services/core` — `daily_transactions`, `revenue_per_user`.
- `services/finance` — `fx_transactions_eur`, `operational_cost_per_user`, `ltv_per_user`, …

`core` and `finance` depend on each other across projects (core reads `analytics.fx_transactions_eur`; finance reads `analytics.revenue_per_user`). On Airflow that mesh had no run order two separate cron schedules could express. **Continuo sequences it itself** at release time, from the validation closure — the whole reason for the move.

## How a release works

On every push to `services/**`, `.github/workflows/release.yml`:

1. Builds and pushes the changed service's image (`linux/amd64` + `arm64`).
2. Runs `scripts/release.sh`: reads `GET /current-prod` (first run auto-bootstraps), `POST`s the candidate to `/releases`, then polls `GET /releases/{id}` to a terminal status — **failing the deploy on `rejected`**.

Continuo compiles the changed service and validates the **full topology** before promoting blue/green. It is the reference external integration against continuo's public release-loading contract — no shared code with continuo internals.

## The cross-team break, caught here

The break that silently corrupted finance on Airflow — `core` renames `revenue_per_user.revenue_eur` → `net_revenue_eur` — is **rejected at release time** on Continuo, before it ships, because validation checks the whole topology (finance's `ltv_per_user` still reads `revenue_eur`), not just the changed project. On Airflow, two separate schedulers had no way to see it.

## Releasing to your Continuo instance

Set these repo Actions secrets (the release workflow needs them; values are not in this repo):

| Secret | Purpose |
|---|---|
| `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` | push service images; the username must match what continuo's executor pulls with |
| `HETZNER_HOST` / `HETZNER_SSH_KEY` | reach continuo's release API |

Then push a change under `services/**`. The first release bootstraps (promotes without validation); every later one is validated.

## License

[CC0 1.0 Universal](LICENSE) — example code, public domain.
