# Production Deployment

Where the IronLog API runs and how to ship to it. Production holds real user
data: deploys, restores, backfills and any write to the production MongoDB
need explicit approval from the owner (see `AGENTS.md`, Safety And Approvals).

## Where Production Lives

| What | Value |
|---|---|
| Public API | `https://ironlog.egorianin.ru` (Swagger: `/docs`) |
| DNS | A record `ironlog.egorianin.ru -> 185.92.222.132`, zone `egorianin.ru` at reg.ru |
| Host | Vultr VDS, Amsterdam, `185.92.222.132`, Ubuntu 26.10, clock in UTC |
| SSH | `ssh -o IdentitiesOnly=yes -i ~/.ssh/shorts_lab_vds_ed25519 root@185.92.222.132` (key only, `MaxAuthTries 3`, no ssh alias) |
| Compose dir | `/opt/ironlog/server` (compose project `ironlog`) |

The name is under our own domain on purpose: the next host move changes only
the A record (plus this file), and app builds keep working without a release.
The iOS default is `SyncService.defaultServerURL`.

The box is shared and small (1 vCPU, 1.6 GB RAM for every tenant). Other
tenants run there: the owner's VPN (Xray VLESS Reality on 443/tcp, AmneziaWG on
several UDP ports), opencall.guru, mif.academy, egorianin.ru and CrowdSec.
Never stop, edit or restart anything that is not ironlog's. Before changing a
shared file (`/etc/caddy/Caddyfile` first of all), re-read it and back it up:
other agents may be editing the box at the same time.

## Layout On The Host

```text
/opt/ironlog/server          compose project "ironlog" (not a git checkout)
  app/ tools/ Dockerfile requirements.txt docker-compose.yml
  .env                       JWT_SECRET, IRONLOG_SCHEMAS_DIR, IRONLOG_DOCS_DIR,
                             IRONLOG_HTTP_PORT=8844 (ADMIN_EMAILS optional)
/opt/ironlog/schemas         mounted into app as /schemas (read-only)
/opt/ironlog/docs            mounted into app as /docs (read-only)
/opt/ironlog/deploy-backups  pre-deploy tarballs and mongo dumps
```

Containers (from `ironlog-server/docker-compose.yml`):

| Service | Image | Published on | Notes |
|---|---|---|---|
| `ironlog-app-1` | `ironlog-app` (built from `Dockerfile`) | `127.0.0.1:8844 -> 8000` | `mem_limit 256m` |
| `ironlog-mongo-1` | `mongo:7.0.34` | `127.0.0.1:27017` | volume `ironlog_mongo_data`, WiredTiger cache 0.25 GB, `mem_limit 512m`, no auth (loopback only) |

Ports are published on loopback only. Docker writes its own iptables rules
and bypasses ufw, so a `0.0.0.0` binding is reachable from the internet; the
old host's public `:8844` attracted mostly scanners. There is no public HTTP
port any more.

Keep `JWT_SECRET` when moving hosts: a new secret invalidates every issued
token and logs all users out.

## TLS And Routing

ironlog has no Caddy of its own. Port 80 belongs to the host Caddy (installed
from apt, one `/etc/caddy/Caddyfile` for all tenants), and 443/tcp belongs to
Xray, which forwards every non-VLESS connection to the host Caddy on
`127.0.0.1:8001` with a PROXY protocol header. HTTPS sites are therefore
declared as `name:8001` bound to `127.0.0.1`, and HTTP to HTTPS redirects are
one shared `http://...` block.

ironlog's part of `/etc/caddy/Caddyfile`:

```caddy
ironlog.egorianin.ru:8001 {
	bind 127.0.0.1
	import access_log
	encode zstd gzip
	reverse_proxy 127.0.0.1:8844
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "DENY"
		Referrer-Policy "no-referrer"
	}
}
```

plus `http://ironlog.egorianin.ru` in the shared redirect block. Caddy gets the
certificate by HTTP-01 on its own once the name resolves to the host. Apply
edits with:

```bash
caddy validate --config /etc/caddy/Caddyfile && systemctl reload caddy
```

The Caddyfile is never synced from this repo. uvicorn runs with
`--forwarded-allow-ips=172.16.0.0/12`: Caddy reaches the app through
docker-proxy, so the app sees the compose network gateway (inside
`172.16.0.0/12`) and trusts its `X-Forwarded-*` headers.

## Deploy

```bash
ironlog-server/deploy_tls_to_vps.sh
```

The script (approval required) backs up `/opt/ironlog/server` to
`deploy-backups/`, rsyncs `app/`, `tools/`, `Dockerfile`, `requirements.txt`
and `docker-compose.yml`, mirrors `schemas/` and `docs/`, then runs
`docker compose up --build -d`. It never touches `.env` secrets or the host
Caddyfile. Overrides: `IRONLOG_DEPLOY_SERVER`, `IRONLOG_DEPLOY_DIR`,
`IRONLOG_PUBLIC_HOST`, `IRONLOG_DEPLOY_SSH_KEY`.

Check after a deploy:

```bash
curl -sS https://ironlog.egorianin.ru/health
```

## Database Operations

Run on the host:

```bash
# Backup
docker exec ironlog-mongo-1 mongodump --quiet --db ironlog --archive --gzip \
  > /opt/ironlog/deploy-backups/ironlog-$(date +%Y%m%d-%H%M%S).archive.gz

# Restore (replaces the collections it contains)
docker exec -i ironlog-mongo-1 mongorestore --quiet --archive --gzip --drop \
  --nsInclude='ironlog.*' < /opt/ironlog/deploy-backups/<file>.archive.gz

# Document and index counts per collection
docker exec ironlog-mongo-1 mongosh --quiet ironlog --eval \
  'db.getCollectionNames().sort().forEach(c=>print(c, db[c].countDocuments(), db[c].getIndexes().length))'
```

## Moving To Another Host

What the 2026-10-30 move did, in order:

1. Copy the running image (`docker save | docker load`) or build from the
   same commit, plus `.env`, `schemas/` and `docs/`; start the compose project
   and check `127.0.0.1:8844/health` on the new host.
2. Add the Caddy block, point the name at the new host, check HTTPS.
3. Stop `app` on the old host, take the final `mongodump`, restore it on the
   new host, compare document counts per collection, then stop the old `mongo`.
4. Update this file and any address that is not behind the DNS name.

Move data host to host directly (a temporary key restricted with `from=` in
`authorized_keys`, removed afterwards); the laptop link to the servers is
unreliable.

## Previous Host

Until 2026-10-30 production ran on a Timeweb VDS, `72.56.99.246`, as
`https://72.56.99.246.nip.io` (plus a public HTTP port `8844`). Those
addresses no longer serve the API. On that host, `server-app-1` and
`server-mongo-1` are stopped but kept, with volume `server_mongo_data` and the
final dump `/opt/ironlog/deploy-backups/migrate-final-20261030-150414.archive.gz`.
Its `server-caddy-1` still serves other projects' bridges and must stay up
until the owner decommissions that host.
