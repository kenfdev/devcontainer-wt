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
  version: "2.0"
---

# devcontainer-wt

A template for running multiple git worktrees in isolated devcontainers with
shared infrastructure (Traefik, databases), per-worktree databases, and
automatic git worktree support inside containers.

Worktree management is delegated to external tools (git-wt, wtp, or raw
`git worktree`). This template focuses only on what those tools can't do:
making devcontainers work correctly with worktrees.

## Architecture Overview

```
Browser → Traefik (:80) → app-{PROJECT}-{WORKTREE}:{APP_PORT}
                        → traefik.{PROJECT}.localhost (dashboard)

Host: docker compose up -d (from project root)
├── traefik-{PROJECT}          (reverse proxy)
├── postgres-{PROJECT}         (shared DB)
└── ...

Docker Network: devnet-{PROJECT}
├── app-{PROJECT}-{WORKTREE_1} (main worktree container)
├── app-{PROJECT}-{WORKTREE_2} (feature worktree container)
└── ...
```

- **Infrastructure** runs independently on the host via `docker compose up -d` from the project root.
- **Each worktree** gets its own devcontainer that joins the shared network.
- Each worktree gets its own database, env vars, and Traefik route.

## Lifecycle

1. **`docker compose up -d`** (host, project root): Start shared infrastructure (Traefik, DB, etc.) independently.
2. **`init.sh`** (host, `initializeCommand`): Detects worktree context, writes `.env`, expands `.env.app.template`.
3. **Docker Compose** brings up the app container using `.env` for variable substitution.
4. **`post-start.sh`** (container, `postStartCommand`): Creates git symlink fix, then runs project setup (deps, DB init, migrations).

## File Classification

### DO NOT EDIT — Template Engine Files

These files contain the core devcontainer-wt machinery. Modifying them will break worktree detection, git support, or Traefik routing.

| File | Purpose |
|---|---|
| `.devcontainer/init.sh` | Host-side worktree detection, `.env` generation |
| `.devcontainer/hooks/post-start.sh` (git symlink block) | The `if [ -f ".git" ]` section that fixes git inside worktree containers |
| `.devcontainer/docker-compose.yml` (volumes, labels, env, networks) | Core volume mounts, Traefik labels, devcontainer-wt metadata labels, networking |
| `.devcontainer/devcontainer.json` (core fields) | `name`, `dockerComposeFile`, `service`, `workspaceFolder`, `initializeCommand`, `postStartCommand`, `remoteEnv` |

### CUSTOMIZE — User-Editable Files

These files are meant to be adapted for each project.

| File | What to customize |
|---|---|
| `.devcontainer/Dockerfile` | System-level dependencies (`apt-get install ...`) |
| `.devcontainer/devcontainer.json` | `features` (language runtimes), `customizations.vscode.extensions` |
| `docker-compose.yml` (project root) | Shared infrastructure: Traefik, Postgres, Redis, etc. |
| `.devcontainer/docker-compose.yml` | Change `loadbalancer.server.port` (default 3000), add shared cache volumes |
| `.devcontainer/hooks/post-start.sh` | Project setup below the `CUSTOMIZE` marker: deps, DB init, migrations |
| `.worktree/hooks/on-delete.sh` | Cleanup hook for worktree removal: drop DB, clear caches. |
| `.env.app.template` | Per-worktree environment variables with `${VARIABLE}` placeholders |

## How to Adopt the Template

When setting up devcontainer-wt in a new project:

1. Copy `.devcontainer/`, `docker-compose.yml`, `.worktree/`, `.env.app.template`, and the devcontainer-wt `.gitignore` entries.
2. Add a devcontainer feature for the project's language in `devcontainer.json`.
3. Add system dependencies in `Dockerfile` if needed.
4. Add infrastructure services in `docker-compose.yml` (project root).
5. Configure `.env.app.template` with project-specific variables.
6. Edit `post-start.sh` below the `CUSTOMIZE` marker for deps, DB init, migrations.
7. Update the Traefik port in `.devcontainer/docker-compose.yml` if the app doesn't use port 3000.
8. Add VS Code extensions in `devcontainer.json`.
9. Configure worktree hooks: `git config --add wt.hook ".worktree/hooks/on-create.sh"`

See [references/CUSTOMIZING.md](references/CUSTOMIZING.md) for detailed instructions and examples.

## Adding an Infrastructure Service

To add a new shared service (e.g., Redis):

1. Add the service to `docker-compose.yml` (project root):
   ```yaml
   redis:
     image: redis:7-alpine
     container_name: "redis-${PROJECT_NAME:-myapp}"
     networks:
       - devnet
     restart: unless-stopped
   ```
2. Add connection info to `.env.app.template`:
   ```
   REDIS_URL=redis://redis-${PROJECT_NAME}:6379/0
   ```
3. If the service needs a volume, add it to the `volumes:` section in the same file.
4. Restart infrastructure: `docker compose up -d`

**Rules:**
- Use `container_name: "servicename-${PROJECT_NAME:-myapp}"` for consistent naming.
- Add `networks: [devnet]` so containers can reach the service.
- Add `restart: unless-stopped` so services survive Docker restarts.

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
| `BRANCH_NAME` | `feature-x` | Sanitized git branch name (used in subdomain routing) |
| `PROJECT_NAME` | `myapp` | Main repo directory name (or `$PROJECT_NAME` override) |
| `MAIN_REPO_NAME` | `myapp` | Main repo directory name |
| `NETWORK_NAME` | `devnet-myapp` | Docker network name |
| `COMPOSE_PROJECT_NAME` | `myapp-feature-x` | Docker Compose project name |

## URL Pattern

All URLs follow: `http://{BRANCH_NAME}.{PROJECT_NAME}.localhost`

- Main worktree (branch `main`): `http://main.myapp.localhost`
- Feature worktree (branch `feature-x`): `http://feature-x.myapp.localhost`
- Traefik dashboard: `http://traefik.myapp.localhost`

## Worktree Hooks

The template provides hook scripts in `.worktree/hooks/`:

| Hook | When | What it does |
|---|---|---|
| `.worktree/hooks/on-create.sh` | After worktree creation | Copies gitignored files from `.worktreeinclude` |
| `.worktree/hooks/on-delete.sh` | Before worktree removal | Stops container, project-specific cleanup, prunes orphans |

Wire into your worktree tool:

```bash
# git-wt
git config --add wt.hook ".worktree/hooks/on-create.sh"
git config --add wt.deletehook ".worktree/hooks/on-delete.sh"

# Manual
cd ../myapp-feature-x && .worktree/hooks/on-create.sh
cd ../myapp-feature-x && .worktree/hooks/on-delete.sh
```

## Troubleshooting

- **Git fails inside container:** Check that `post-start.sh` ran. Look for `[devcontainer-wt] Git symlink fix applied` in the terminal.
- **App not reachable:** Check `cat .devcontainer/.env` for `PROJECT_NAME` and `WORKTREE_NAME`. Verify Traefik is running: `docker ps | grep traefik`.
- **DB connection refused:** Infrastructure must be started first: `docker compose up -d` from project root.
- **Port 80 in use:** Set `TRAEFIK_PORT` before starting infra: `TRAEFIK_PORT=8000 docker compose up -d`.
