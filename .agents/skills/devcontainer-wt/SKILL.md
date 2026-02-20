---
name: devcontainer-wt
description: >
  Template engine for seamless devcontainer + git worktree workflows. Provides
  worktree-aware container isolation with per-worktree databases, Traefik
  subdomain routing, and automatic git symlink fixes. Use this skill when
  working in a project that uses devcontainer-wt, when adopting the template
  into a new project, or when adding/modifying infrastructure services,
  environment variables, or lifecycle hooks in a devcontainer-wt setup.
compatibility: >
  Requires Docker, Docker Compose, git with worktree support, and envsubst.
  Works on macOS (Docker Desktop) and Linux (native Docker).
metadata:
  author: kenfdev
  version: "1.0"
---

# devcontainer-wt

A template for running multiple git worktrees in isolated devcontainers with
shared infrastructure (Traefik, databases), per-worktree databases, and
automatic git worktree support inside containers.

## Architecture Overview

```
Browser → Traefik (:80) → app-{PROJECT}-{WORKTREE}:{APP_PORT}
                        → traefik.{PROJECT}.localhost (dashboard)

Docker Network: devnet-{PROJECT}
├── traefik-{PROJECT}          (reverse proxy, main worktree only)
├── postgres-{PROJECT}         (shared DB, main worktree only)
├── app-{PROJECT}-{WORKTREE_1} (main worktree container)
├── app-{PROJECT}-{WORKTREE_2} (feature worktree container)
└── ...
```

- **Main worktree** starts shared infrastructure (Traefik, DB) via `COMPOSE_PROFILES=infra`.
- **Feature worktrees** only start the app container and join the existing network.
- Each worktree gets its own database, env vars, and Traefik route.

## Lifecycle

1. **`init.sh`** (host, `initializeCommand`): Detects worktree context, writes `.env`, creates Docker network, expands `.env.app.template`.
2. **Docker Compose** brings up containers using `.env` for variable substitution.
3. **`post-start.sh`** (container, `postStartCommand`): Creates git symlink fix, then runs project setup (deps, DB init, migrations).

## File Classification

### DO NOT EDIT — Template Engine Files

These files contain the core devcontainer-wt machinery. Modifying them will break worktree detection, git support, or Traefik routing.

| File | Purpose |
|---|---|
| `.devcontainer/init.sh` | Host-side worktree detection, `.env` generation, orphan detection |
| `.devcontainer/hooks/post-start.sh` (git symlink block) | The `if [ -f ".git" ]` section that fixes git inside worktree containers |
| `.devcontainer/docker-compose.yml` (volumes, labels, env, networks) | Core volume mounts, Traefik labels, devcontainer-wt metadata labels, networking |
| `.devcontainer/docker-compose.infra.yml` (traefik service, networks) | Traefik reverse proxy configuration and network definition |
| `.devcontainer/devcontainer.json` (core fields) | `name`, `dockerComposeFile`, `service`, `workspaceFolder`, `initializeCommand`, `postStartCommand`, `remoteEnv` |

### CUSTOMIZE — User-Editable Files

These files are meant to be adapted for each project.

| File | What to customize |
|---|---|
| `.devcontainer/Dockerfile` | System-level dependencies (`apt-get install ...`) |
| `.devcontainer/devcontainer.json` | `features` (language runtimes), `customizations.vscode.extensions` |
| `.devcontainer/docker-compose.infra.yml` | Add services (Postgres, Redis, etc.) — must have `profiles: [infra]` |
| `.devcontainer/docker-compose.yml` | Change `loadbalancer.server.port` (default 3000), add shared cache volumes |
| `.devcontainer/hooks/post-start.sh` | Project setup below the `CUSTOMIZE` marker: deps, DB init, migrations |
| `.env.app.template` | Per-worktree environment variables with `${VARIABLE}` placeholders |

## How to Adopt the Template

When setting up devcontainer-wt in a new project:

1. Copy `.devcontainer/`, `.env.app.template`, and the devcontainer-wt `.gitignore` entries.
2. Add a devcontainer feature for the project's language in `devcontainer.json`.
3. Add system dependencies in `Dockerfile` if needed.
4. Add infrastructure services in `docker-compose.infra.yml` with `profiles: [infra]`.
5. Configure `.env.app.template` with project-specific variables.
6. Edit `post-start.sh` below the `CUSTOMIZE` marker for deps, DB init, migrations.
7. Update the Traefik port in `docker-compose.yml` if the app doesn't use port 3000.
8. Add VS Code extensions in `devcontainer.json`.

See [references/CUSTOMIZING.md](references/CUSTOMIZING.md) for detailed instructions and examples.

## Adding an Infrastructure Service

To add a new shared service (e.g., Redis):

1. Add the service to `.devcontainer/docker-compose.infra.yml`:
   ```yaml
   redis:
     profiles: [infra]
     image: redis:7-alpine
     container_name: "redis-${PROJECT_NAME}"
     networks:
       - devnet
     restart: unless-stopped
   ```
2. Add connection info to `.env.app.template`:
   ```
   REDIS_URL=redis://redis-${PROJECT_NAME}:6379/0
   ```
3. If the service needs a volume, add it to the `volumes:` section in the same file.

**Rules:**
- Always include `profiles: [infra]` so the service only starts from the main worktree.
- Always use `container_name: "servicename-${PROJECT_NAME}"` for consistent naming.
- Always add `networks: [devnet]` so containers can reach the service.

## Per-Worktree Database Setup

In `post-start.sh` (below the CUSTOMIZE marker), add idempotent DB creation:

```bash
# PostgreSQL example
PGPASSWORD=dev psql -h "postgres-${PROJECT_NAME}" -U dev -tc \
  "SELECT 1 FROM pg_database WHERE datname = '${PROJECT_NAME}_${WORKTREE_NAME}'" | \
  grep -q 1 || \
  PGPASSWORD=dev createdb -h "postgres-${PROJECT_NAME}" -U dev "${PROJECT_NAME}_${WORKTREE_NAME}"
```

The database name pattern is `{PROJECT_NAME}_{WORKTREE_NAME}`.

## Available Variables

These variables are available in `post-start.sh`, `.env.app.template`, and as container environment variables:

| Variable | Example | Source |
|---|---|---|
| `WORKTREE_NAME` | `myapp-feature-x` | Sanitized directory name |
| `PROJECT_NAME` | `myapp` | Main repo directory name (or `$PROJECT_NAME` override) |
| `MAIN_REPO_NAME` | `myapp` | Main repo directory name |
| `NETWORK_NAME` | `devnet-myapp` | Docker network name |

## URL Pattern

All URLs follow: `http://{WORKTREE_NAME}.{PROJECT_NAME}.localhost`

- Main worktree: `http://myapp.myapp.localhost`
- Feature worktree: `http://myapp-feature-x.myapp.localhost`
- Traefik dashboard: `http://traefik.myapp.localhost`

## Worktree Workflow

### Create a feature worktree

```bash
# From the main repo directory (on the host)
git worktree add ../myapp-feature-x -b feature-x
code ../myapp-feature-x
# Click "Reopen in Container"
```

### Clean up a worktree

Just use standard git:

```bash
git worktree remove ../myapp-feature-x
```

The orphaned container is automatically cleaned up the next time any worktree's
devcontainer starts (`init.sh` detects containers whose worktree directory no
longer exists and removes them).

## Troubleshooting

- **Git fails inside container:** Check that `post-start.sh` ran. Look for `[devcontainer-wt] Git symlink fix applied` in the terminal.
- **App not reachable:** Check `cat .devcontainer/.env` for `PROJECT_NAME` and `WORKTREE_NAME`. Verify Traefik is running: `docker ps | grep traefik`.
- **DB connection refused:** The main worktree must be running (it hosts the database).
- **Port 80 in use:** Set `TRAEFIK_PORT` before opening: `export TRAEFIK_PORT=8000`.
