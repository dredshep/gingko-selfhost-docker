# Gingko Writer — Self-hosted Docker

Builds the upstream [gingko/client](https://github.com/gingko/client) and
[gingko/server](https://github.com/gingko/server) repositories into a single
Docker image, with Redis and CouchDB as companion services.

New accounts are automatically patched to `customer:selfhost` so they never
expire (the upstream SaaS trial is bypassed).

## Repository layout

```
.
├── Dockerfile              # multi-stage build (keys → client → server → runtime)
├── docker-compose.yml      # app + redis + couchdb + couchdb-init
├── .env.example            # template — copy to .env and edit
├── couchdb/
│   └── local.d/
│       └── proxy-auth.ini  # enables CouchDB proxy authentication
├── DESIGN.md               # architecture and troubleshooting notes
└── .gitignore
```

## Quick start

```bash
git clone https://github.com/dredshep/gingko-selfhost-docker ~/server/gingko
cd ~/server/gingko
cp .env.example .env
nano .env                   # set passwords, port, PUBLIC_URL
docker compose up -d --build
```

The first build takes a few minutes (clones upstream, compiles Elm, compiles
TypeScript). Subsequent rebuilds are faster thanks to Docker layer caching.

## Configuration

All settings live in `.env`. The important ones:

| Variable | Default | Purpose |
|---|---|---|
| `GINGKO_PORT` | `3000` | Host port the app is exposed on |
| `PUBLIC_URL` | `http://localhost:3000` | Baked into the client at build time for links and API base |
| `COUCHDB_PASSWORD` | — | **Must change** before exposing outside LAN |
| `COUCHDB_SECRET` | — | **Must change** — CouchDB cookie signing secret |
| `SESSION_SECRET` | — | **Must change** — Node session signing secret |
| `GINGKO_CLIENT_REF` | `master` | Branch/tag/commit to build the client from |
| `GINGKO_SERVER_REF` | `master` | Branch/tag/commit to build the server from |
| `ANTHROPIC_API_KEY` | empty | Optional — enables AI features if set |

If you change `GINGKO_PORT` from the default, update `PUBLIC_URL` to match:

```env
GINGKO_PORT=9484
PUBLIC_URL=http://localhost:9484
```

If the app is behind a reverse proxy with a real domain, set `PUBLIC_URL` to that
domain instead:

```env
PUBLIC_URL=https://gingko.example.com
```

## After starting

Open `http://<host-ip>:<GINGKO_PORT>` in a browser and create an account.

## Useful commands

```bash
# follow logs
docker compose logs -f app

# restart the app (keeps CouchDB and Redis running)
docker compose restart app

# rebuild from latest upstream
docker compose build --no-cache app
docker compose up -d

# stop everything (data volumes are preserved)
docker compose down
```

**Do not** run `docker compose down -v` unless you want to delete all data
(SQLite and CouchDB volumes).

## Reverse proxy / Cloudflare Tunnel

Point your reverse proxy at:

```
http://127.0.0.1:<GINGKO_PORT>
```

or from within the same Docker network:

```
http://gingko:3000
```

WebSocket passthrough is required — the client connects over `ws://` / `wss://`
on the same origin.

## Troubleshooting

See [DESIGN.md](DESIGN.md) for detailed notes on why each build choice was made
and what to do when upstream changes break the build.
