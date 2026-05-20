# Design Notes

This document explains the architecture of the self-host Docker build and the
reasoning behind each non-obvious choice. If the build breaks after an upstream
update, start here.

## Overview

The Dockerfile uses a multi-stage build with four stages:

```
keys            → generates an RSA-2048 keypair (shared secret between client & server)
client-builder  → clones gingko/client, injects config, compiles Elm + JS
server-builder  → clones gingko/server, patches source for Docker networking, compiles TS
runtime         → minimal Node 18 image with the compiled output from both builders
```

The `docker-compose.yml` orchestrates the app alongside Redis (session store) and
CouchDB (document database), with a one-shot init container that creates the
required CouchDB system databases on first run.

## Why Node 18 for the client builder (not `oven/bun`)

The client-builder originally used `oven/bun:1` as its base image. This caused
three cascading failures:

### 1. `node-pty` fails to compile against Node 24 headers

The `oven/bun:1` image reports itself as Node 24 to `node-gyp`. The `node-pty`
package (a transitive dependency in the client repo) uses an old version of
`nan` that is incompatible with the V8 API changes in Node 24 — removed
`CopyablePersistentTraits`, removed `SetAccessor` from `ObjectTemplate`,
changed `ScriptOrigin` constructors, etc. The compilation fails with ~20 C++
errors.

Using `node:18-bookworm-slim` as the base gives `node-gyp` Node 18 headers,
which are fully compatible with the version of `nan` that `node-pty` ships.

### 2. `elm-watch` workers crash under bun's `child_process.fork()`

`elm-watch` spawns postprocess workers using `child_process.fork()`. Bun's
compatibility layer returns `null` for `worker.stdout`, causing:

```
TypeError: null is not an object (evaluating 'this.worker.stdout.on')
```

Real Node's `child_process.fork()` pipes stdout correctly.

### 3. Python 3.13 removed `distutils`

The `oven/bun:1` image ships Python 3.13, which removed the `distutils` module
from the standard library. `node-gyp` 9.x imports `from distutils.version import
StrictVersion` and crashes. The Node 18 slim image ships Python 3.11 where
`distutils` is still available. The server-builder installs `python3-setuptools`
as a belt-and-suspenders measure (it backports `distutils` for Python 3.12+).

### Resolution

The client-builder now uses `node:18-bookworm-slim` as its base and installs
bun on top via `curl -fsSL https://bun.sh/install | bash`. This gives us real
Node for native compilation and elm-watch workers, with bun available for fast
package installs and script execution.

## Git clone stall protection

Shallow clones from GitHub (`git clone --depth 1`) can stall indefinitely when a
TCP connection goes half-dead — git has no built-in timeout on data transfer.
Both clone steps set:

```
GIT_HTTP_LOW_SPEED_LIMIT=1024   # bytes/sec
GIT_HTTP_LOW_SPEED_TIME=30      # seconds
```

If throughput drops below 1 KB/s for 30 consecutive seconds, git aborts the
transfer. The `||` retry gives it one more attempt on a fresh connection. Without
this, a stalled clone can hang the entire Docker build indefinitely (observed at
7+ minutes on a gigabit connection before being killed manually).

## CouchDB configuration

### `NODENAME` must not include the `couchdb@` prefix

The CouchDB 3.4 Docker entrypoint automatically prepends `couchdb@` to whatever
value is set in the `NODENAME` environment variable. Setting
`NODENAME=couchdb@127.0.0.1` produces the invalid Erlang node name
`couchdb@couchdb@127.0.0.1`, which crashes the BEAM VM immediately with zero
log output. The correct setting is `NODENAME=127.0.0.1`.

### The `proxy-auth.ini` bind mount must not be `:ro`

The CouchDB entrypoint runs `find /opt/couchdb/etc -type f -exec chmod ...` and
`chown` across all config files. The script uses `set -e`, so when `chmod` fails
on a read-only bind-mounted file (even with `-f` to suppress stderr), the
entrypoint exits silently with code 1. The bind mount must be read-write so the
entrypoint can adjust ownership. CouchDB's own entrypoint may also write admin
credentials into files in the `local.d` directory.

### The `proxy-auth.ini` file must exist before first `docker compose up`

If the file does not exist on the host when Docker Compose starts, Docker creates
a **directory** at that path instead. CouchDB then fails to parse a directory as
an INI file and crashes. The file is tracked in the repo so this cannot happen
after a clean clone.

### `couchdb-init` sidecar

CouchDB 3.x requires `_users`, `_replicator`, and `_global_changes` databases to
exist. The `couchdb-init` service is a one-shot `curl` container that waits for
CouchDB to respond on `/_up`, then creates these databases with `PUT` requests.
It uses `restart: "no"` and the app container depends on it via
`condition: service_completed_successfully`.

## Server source patches

The server-builder applies four regex patches to `src/index.ts` at build time:

| Patch | What it does |
|---|---|
| CouchDB host | Replaces hardcoded `127.0.0.1:5984` with env-configurable `COUCHDB_HOST:COUCHDB_PORT` |
| Redis URL | Adds a `url` option to `createClient()` so Redis connects to the `redis` service |
| CouchDB proxy | Updates the `/db` reverse proxy target to use the same host variables |
| Self-host account | Replaces `"trial:" + trialExpiry` with `"customer:selfhost"` so new accounts never expire |

Each patch throws a hard error if the upstream source no longer matches the
expected regex. When this happens, check the latest `gingko/server` source and
update the pattern accordingly.

## Runtime image

The runtime stage copies only the compiled output:

- `/app/server` — the built Node server (with `node_modules` pruned to production deps)
- `/app/client/web` — the static Elm/JS/CSS client assets

It installs `pandoc` (used by the server for document export) and `ca-certificates`.
The app listens on port 3000 internally; `GINGKO_PORT` in `.env` controls the
host-side mapping.
