# plane-evo shared-host production path

Deploy **this repository** to Contabo **13.140.219.161** at `plane.evotechly.com`, beside Postiz at `postiz.evotechly.com`.

Do not use this path on EvoCRM VPS **13.140.219.162**.

## Pin

| Item | Value |
| --- | --- |
| Repo | `github.com/Mohamedbeghanem/plane-evo` |
| Default / product branch | `preview` |
| Product SHA (fork snapshot of makeplane/plane) | `053b2c0e5874fb3225404a8775d04f38f9e1704c` |
| App version (`package.json`) | `1.4.2` |
| Image namespace | `plane-evo/plane-{frontend,space,admin,live,backend,proxy}:<git sha12>` |

This fork has a single branch (`preview`) and no product commits of its own at the pin above. Images must still be **built from this checkout**. Pulling `makeplane/plane-*:stable` (or running `deployments/cli/community/install.sh`) silently ships upstream, not the fork.

## Forbidden paths

- `./setup.sh` — local-dev env only
- `deployments/cli/community/install.sh` — clones `makeplane/plane`, pulls `makeplane/*`
- `deployments/cli/community/docker-compose.yml` alone — `image: makeplane/plane-*`, publishes 80/443
- Root `docker-compose.yml` — builds fork code but hard-codes container names `web`/`api`/`proxy` and defaults `LISTEN_HTTP_PORT=80`
- `makeplane/plane-aio-community` — stock AIO image

## Exact commands (on 13.140.219.161, after checkout)

```bash
# 1. Checkout the deploy commit (PR HEAD, then preview once merged)
git clone https://github.com/Mohamedbeghanem/plane-evo.git /opt/plane-evo
cd /opt/plane-evo
git checkout <DEPLOY_SHA>

# 2. Env file — operator fills secrets on the host. Do not reuse Postiz DB/Redis/MQ.
cp deployments/fork-shared-host/plane.env.example deployments/fork-shared-host/plane.env
# edit plane.env: every REPLACE_* value, DATABASE_URL, AMQP_URL

# 3. Render + guards (must report fork images and no public 80/443)
./deployments/fork-shared-host/run.sh config

# 4. BUILD — not on this 8GB VPS while Postiz is live unless live inventory
#    shows spare RAM + swap. CONTRIBUTING.md: 12 GB recommended for builds.
#    Prefer: build on a 16GB+ machine, docker save plane-evo/*:<tag> | load on VPS.
COMPOSE_PARALLEL_LIMIT=1 ./deployments/fork-shared-host/run.sh build

# 5. Run (pull never, no bind of 80/443)
./deployments/fork-shared-host/run.sh up

# 6. Health (loopback; public HTTPS needs host nginx + DNS, out of scope here)
./deployments/fork-shared-host/run.sh health
curl -fsS http://127.0.0.1:18080/
curl -fsS http://127.0.0.1:18080/live/health/
```

Docker Compose equivalent of the wrapper:

```bash
export PLANE_IMAGE_TAG="$(git rev-parse --short=12 HEAD)"
docker compose -p plane-evo \
  -f deployments/fork-shared-host/docker-compose.yml \
  --env-file deployments/fork-shared-host/plane.env \
  build --pull never
docker compose -p plane-evo \
  -f deployments/fork-shared-host/docker-compose.yml \
  --env-file deployments/fork-shared-host/plane.env \
  up -d --pull never --no-build
```

## Loopback host ports (collision table)

| Bind | Owner | Notes |
| --- | --- | --- |
| `127.0.0.1:18080` | **plane-evo proxy** | Only Plane publish. Host nginx → this for `plane.evotechly.com` |
| `80` / `443` | host nginx | Postiz + Plane vhosts. Plane Caddy must not bind these |
| `4007` | Postiz (typical `4007:5000`) | Do not reuse |
| `8080` | Temporal UI if Postiz published it | Do not reuse |
| `5432` / `6379` / `5672` / `9000` | not published by this compose | Plane Postgres/Redis/Rabbit/MinIO stay on `plane-evo` network |

Confirm live Postiz publishes with `ss -lntp` / `docker ps` before `up` (live inventory pending).

## Services and dependencies

```
migrator → plane-db, plane-redis
api      → plane-db, plane-redis, plane-mq, plane-minio (via env)
worker / beat-worker → api + same data plane
web / space / admin / live → api
proxy (Caddy) → web, api, space, admin, live, minio /uploads
```

Internal ports (docker network only): web/space/admin/live `3000`, api `8000`, postgres `5432`, redis `6379`, rabbit `5672`, minio `9000`.

Caddy routes (then nginx forwards `/` to loopback 18080, including websockets):

- `/` → web:3000
- `/god-mode/` → admin:3000
- `/spaces/` → space:3000
- `/live/` → live:3000 (websocket)
- `/api/` `/auth/` `/static/` → api:8000
- `/uploads/` → plane-minio:9000

## Env keys that must be set

Required at compose interpolation time (see `plane.env.example`):

`PLANE_IMAGE_TAG`, `SECRET_KEY`, `LIVE_SERVER_SECRET_KEY`, `POSTGRES_PASSWORD`, `DATABASE_URL`, `RABBITMQ_PASSWORD`, `AMQP_URL`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`

Keep `DATABASE_URL` / `AMQP_URL` in lockstep with the passwords. MinIO root login is the AWS key pair; rotating one without the other breaks uploads.

Optional / God Mode: `ENABLE_SIGNUP`, SMTP (`ENABLE_SMTP`, `EMAIL_*`), OAuth (`GOOGLE_*`, `GITHUB_*`, `GITLAB_*`, `GITEA_*`), `LLM_*`.

`WEB_URL` / `CORS_ALLOWED_ORIGINS` must be `https://plane.evotechly.com` so session cookies are Secure.

## Migrations, admin, health

- Migrator command: `./bin/docker-entrypoint-migrator.sh` → `manage.py wait_for_db` + `migrate`. `run.sh up` waits for `plane-evo-migrator` exit 0.
- API start also `register_instance`, `configure_instance`, `create_bucket`, `collectstatic`.
- First instance admin: open `https://plane.evotechly.com/god-mode/` and register. Only the first signup becomes instance admin (`ADMIN_ALREADY_EXIST` after that). CLI fallback after a normal user exists: `docker exec -it plane-evo-api python manage.py create_instance_admin <email>`.
- Health: API `GET /` → `{"status":"OK"}`; live `GET /live/health/`; web/admin/space image HEALTHCHECK on `:3000`.

## Volumes and backups

Compose project `plane-evo` (do not share Postiz volumes).

| Volume | Data |
| --- | --- |
| `plane-evo_pgdata` | Postgres 15 |
| `plane-evo_redisdata` | Valkey |
| `plane-evo_uploads` | MinIO /export |
| `plane-evo_rabbitmq_data` | RabbitMQ |
| `plane-evo_proxy_config`, `plane-evo_proxy_data` | Caddy state (HTTP-only here) |
| `plane-evo_logs_*` | API/worker logs |

```bash
./deployments/fork-shared-host/run.sh backup /var/backups/plane-evo
```

Upstream `restore.sh` looks for `plane-app_*` volume names and will not hit these volumes. Restore is a later SSH-agent step: stop stack, `docker run` untar into the `plane-evo_*` volumes, start stack.

## nginx / websocket

Install `nginx.plane.evotechly.com.conf` as a **separate** `server_name` from Postiz. Pass `Upgrade` / `Connection` for `/live/`. `client_max_body_size 10m` ≥ `FILE_SIZE_LIMIT` (5 MiB default).

`NUM_PROXIES=2` and `TRUSTED_PROXIES=private_ranges` because nginx (host) + Caddy (container) sit in front of the API.

TLS stays on host nginx. Plane `SITE_ADDRESS=:80` so bundled Caddy does not attempt ACME.

## Capacity (catalog ~8 GB, live inventory pending)

CONTRIBUTING.md: **12 GB RAM recommended** for this monorepo; **8 GB often fails during image build**.

Runtime cgroup caps in compose (sum ≈ 3.4 GiB):

| Service | mem_limit |
| --- | --- |
| api / worker / migrator | 512m |
| postgres | 512m |
| rabbitmq | 384m |
| live / beat-worker / minio | 256m |
| web / space / admin / proxy / redis | 128m |
| gunicorn workers | 1 |

Build (web/admin/space turbo + proxy xcaddy + api uv): expect **several GB peak per image**, worse if parallel. On 13.140.219.161 with Postiz+Temporal already running:

- **Do not build in parallel.** `COMPOSE_PARALLEL_LIMIT=1`
- **Prefer building off-box** and `docker load`
- If building on-box: confirm free RAM + swap from live inventory first; expect OOM without ≥8 GB swap
- If Postiz already uses ≳4 GB RSS, Plane runtime 3.4 GiB will not fit; drop sibling, add RAM, or raise this host — do not silently remove cgroup caps

`postgres max_connections=100` (upstream compose uses 1000, unsafe here).

## Sibling isolation checklist

- Compose project / network / containers all prefixed `plane-evo`
- No `container_name: web|api|proxy`
- No shared `.env` with Postiz
- No host bind except `127.0.0.1:18080`
- Never `docker compose down -v` on a generic project name
- Never SSH/apply this stack to `13.140.219.162`
