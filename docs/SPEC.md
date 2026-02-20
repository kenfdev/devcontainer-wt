# devcontainer-wt

A reference architecture and reusable template for seamless devcontainer + git worktree workflows.

## Problem

Working with devcontainers and git worktrees simultaneously is painful:

1. **Git context breaks inside containers.** A git worktree's `.git` is a file (not a directory) containing an absolute host path (e.g. `gitdir: /Users/you/repo/.git/worktrees/feature-x`). When the worktree is mounted into a container at a different path (e.g. `/workspaces/repo-feature-x`), this host path doesn't resolve. All git operations (`log`, `blame`, `status`) fail inside the container. Note: this problem is specific to worktrees — regular repos have a `.git` directory that gets mounted alongside the project and works fine.

2. **Port conflicts.** Each devcontainer maps ports to the host (e.g. `3000:3000`). Running multiple worktree containers simultaneously causes port binding conflicts.

3. **No shared infrastructure.** Each devcontainer typically spins up its own database, cache, etc. There's no built-in way to share these across worktrees or isolate data per worktree within a shared service.

4. **No orchestration.** There's no standard way to create a worktree, spin up its container, route traffic to it, initialize its database, and clean everything up when done.

## Solution Overview

**devcontainer-wt** is a template + shell scripts approach (not a dedicated tool) that solves all four problems using existing devcontainer lifecycle hooks and Docker Compose features:

- **Git fix:** Mount the git common directory at a predictable container path and create a symlink inside the container so the host path in the `.git` file resolves transparently. No file mutation — the host's `.git` file is never modified.
- **No port conflicts:** A per-project Traefik reverse proxy routes by subdomain (`feature-x.myapp.localhost`). No host port mapping needed per worktree. Traefik port is configurable.
- **Shared infrastructure:** One set of shared services (database, cache, proxy) runs from the main worktree. Per-worktree app containers join a per-project Docker network.
- **Per-worktree isolation:** Each worktree gets its own database via user-provided hooks. Traefik routes are automatic via Docker labels. Worktree names are sanitized for DB-safe naming.
- **Per-worktree env vars:** A `.env.app.template` (tracked in git) with `${VARIABLE}` placeholders is expanded by `init.sh` into `.env.app` (gitignored) per worktree. Seamless, zero-config per worktree.
- **Lifecycle management:** Git alias for intentional cleanup. Orphan detection runs during `init.sh` (no cron setup needed).

## Target User

Solo developer on macOS or Linux managing multiple feature branches simultaneously, including parallel AI coding agents (one agent per worktree). The primary workflows are:

1. **Parallel development:** Work on multiple features at the same time, each in its own devcontainer (human or AI agent).
2. **PR review:** Quickly spin up a colleague's branch, test it in a full environment, tear it down.

## Architecture

```
                          Host Machine
  ┌──────────────────────────────────────────────────┐
  │                                                  │
  │  myapp/  (main worktree)                         │
  │    .git/                                         │
  │    .devcontainer/                                │
  │    src/                                          │
  │                                                  │
  │  myapp-feature-x/  (worktree)                    │
  │    .git  (file → myapp/.git/worktrees/feature-x) │
  │    .devcontainer/                                │
  │    src/                                          │
  │                                                  │
  │  myapp-pr-123/  (worktree)                       │
  │    .git  (file → myapp/.git/worktrees/pr-123)    │
  │    .devcontainer/                                │
  │    src/                                          │
  └──────────────────────────────────────────────────┘

              Container Path Mapping (symlink approach)
  ┌──────────────────────────────────────────────────┐
  │                                                  │
  │  /workspaces/myapp/           (main worktree)    │
  │    .git/                      (directory, works)  │
  │                                                  │
  │  /workspaces/myapp-feature-x/ (worktree)         │
  │    .git  (unchanged — still has host path,       │
  │           but symlink makes it resolve)           │
  │                                                  │
  │  /workspaces/myapp/.git/      (mounted from host)│
  │    worktrees/feature-x/       (shared git data)  │
  │    worktrees/pr-123/                             │
  │                                                  │
  │  /Users/you/myapp/.git → /workspaces/myapp/.git  │
  │    (symlink created by post-start.sh)            │
  └──────────────────────────────────────────────────┘

              Docker Network: devnet-myapp
  ┌──────────────────────────────────────────────────┐
  │                                                  │
  │  ┌─────────┐  ┌──────────┐  ┌────────┐          │
  │  │ Traefik │  │ Postgres │  │ Redis  │  ...      │
  │  │ :80     │  │ :5432    │  │ :6379  │           │
  │  └────┬────┘  └──────────┘  └────────┘          │
  │       │           Shared Infrastructure          │
  │       │         (from main worktree,             │
  │       │          via compose profiles)           │
  │  ┌────┴──────────────┬──────────────────┐       │
  │  │                   │                  │        │
  │  ▼                   ▼                  ▼        │
  │ ┌──────────┐  ┌──────────────┐  ┌──────────┐   │
  │ │app-myapp-│  │app-myapp-    │  │app-myapp-│   │
  │ │  myapp   │  │  feature-x   │  │  pr-123  │   │
  │ │ :3000    │  │ :3000        │  │ :3000    │   │
  │ └──────────┘  └──────────────┘  └──────────┘   │
  │  Per-worktree app containers                     │
  │  (no host port mapping — Traefik routes traffic) │
  └──────────────────────────────────────────────────┘

  Browser:
    myapp.myapp.localhost           → app-myapp-myapp:3000
    feature-x.myapp.localhost       → app-myapp-feature-x:3000
    pr-123.myapp.localhost          → app-myapp-pr-123:3000

  Traefik Dashboard:
    traefik.myapp.localhost         → Traefik dashboard (debug routing)
```

### Key Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Git fix | Symlink inside container (no file mutation) | Creates a symlink so the host path in `.git` file resolves. The `.git` file is never modified — no host-side breakage, no restoration needed. |
| Directory layout | Sibling directories | Most common git worktree pattern. Main worktree is a natural home for shared infra. |
| Port conflict solution | Traefik with subdomain routing | Single entry point, configurable port (default 80). Auto-discovers containers via Docker labels. Zero-config per worktree. |
| Traefik dashboard | Enabled by default | Routes to `traefik.{project}.localhost`. Invaluable for debugging routing issues. |
| Routing pattern | Always `{worktree}.{project}.localhost` | Consistent pattern, no special-casing for main worktree. Main worktree gets `myapp.myapp.localhost`. |
| Container naming | Always `app-{project}-{worktree}` | Consistent pattern, no special-casing. Main worktree gets `app-myapp-myapp`. |
| DNS | `.localhost` TLD, zero-config | Works in Chrome and macOS out of the box. Document `/etc/hosts` or `dnsmasq` workaround for Linux/Firefox. |
| Network isolation | Per-project Docker network (`devnet-{project}`) | Prevents container name collisions and unintended cross-project access. Cross-project communication is not a supported use case. |
| Project naming | Auto-detect from main repo directory name, with override | Routes become `{worktree}.{project}.localhost`. Auto-detected for zero config, overridable via `PROJECT_NAME` for custom naming. |
| Infra lifecycle | Docker Compose profiles | Infra services (DB, cache, proxy) only start in the main worktree. Feature worktrees skip them automatically. |
| Infra restart policy | `unless-stopped` | Infra services (DB, cache, proxy) survive Docker Desktop restarts. Dev data stays up. |
| Per-worktree env vars | `.env.app.template` expanded by `init.sh` | Tracked template with `${VARIABLE}` placeholders. `init.sh` renders it into `.env.app` (gitignored) per worktree via `envsubst`. Secrets come from host env vars or manual edits. |
| DB per worktree | User-provided hooks with sanitized names | Template provides extension points with commented examples. DB engine is project-specific — template does not prescribe a database. |
| Internal DNS | `extra_hosts` in compose | Ensures `*.localhost` resolves to Traefik from inside containers (needed for SSR, OAuth, webhooks). |
| Orphan cleanup | Check during init.sh | Every time a worktree starts, init.sh checks for orphaned containers. No cron setup needed. |
| Cleanup | Git alias for intentional teardown | Stops container, removes worktree directory. `git worktree remove` (without `--force`) refuses to delete dirty worktrees — built-in safety. User-provided hooks handle DB cleanup. |
| Lifecycle hooks | Single `post-start.sh` (runs every start) | Contains git symlink fix + extension points for project setup (deps, migrations, dev server). Simpler than splitting into multiple hook files. |
| Workspace path | Conventional `/workspaces/{name}` | Standard devcontainer path convention. Symlink approach makes this transparent. |
| Compose variables | Resolved in init.sh, written to `.env` | `${localWorkspaceFolder}` is a devcontainer variable, NOT available in docker-compose.yml. All paths resolved in init.sh and passed via `.env`. |
| Compose DX | Accept `--env-file` friction for manual commands | Manual `docker compose` commands on host require `--env-file .devcontainer/.env`. Documented, not abstracted. |
| VS Code extensions | Per-container installation | Each container installs its own extensions. Sharing a volume across concurrent containers is unsafe (race conditions). Declare extensions in devcontainer.json. |
| Git authentication | VS Code auto-forwarding + `GITHUB_TOKEN` for headless | VS Code auto-forwards SSH agent and git credentials. For CLI-only usage (devcontainer CLI, AI agents), forward `GITHUB_TOKEN` via `remoteEnv`. |
| Git concurrency | Safe for parallel agents | Git worktrees are designed for parallel work. Per-worktree index/HEAD/working tree. Shared refs use lock files. Bind mounts preserve lock file semantics. Repo-wide operations (`gc`, `repack`) may need serialization but fail safely with lock errors. |
| IDE support | VS Code primary, headless supported | VS Code is the primary tested IDE. Headless via `devcontainer CLI` works with the same lifecycle hooks — set `GITHUB_TOKEN` for git auth. |
| AI agent workflow | One agent per worktree | Each AI agent works in its own worktree/container. Full isolation (separate DB, deps, env). |
| Dockerfile | Minimal + devcontainer features | Thin Dockerfile. Bare template — no devcontainer features included. Users add what they need. |
| Resource limits | None in template | Resource management is project-specific. Docker Desktop global limits apply. |
| Form factor | Template + shell scripts, copied per project | No external dependency. Each project gets its own copy. Simple, explicit, version controlled. Manual copy for updates. |
| Platform | macOS + Linux | Template works on both Docker Desktop (macOS) and native Docker (Linux). |
| Codespaces | Not supported | GitHub Codespaces has different constraints (no Traefik, no sibling worktrees). Out of scope. |
| HTTPS | HTTP only | Keeps the template simple. Developers who need HTTPS can configure Traefik TLS themselves. |
| Versioning | Pin major versions | `traefik:v3`, `postgres:16`, etc. Stable and predictable. Users update manually when ready. |
| Data safety | Named Docker volumes + documentation | `docker system prune --volumes` deletes unused named volumes (general Docker behavior, not worktree-specific). Documented. |
| Main worktree detection | `[ -d ".git" ]` check | Simple and covers standard workflows. Bare repo and submodule edge cases are out of scope. |
| Name collision | Document, don't mitigate | Sanitization may cause collisions (e.g., `feature/login` and `feature-login` both become `feature_login`). Rare enough to document rather than add complexity. |
| File permissions | Devcontainer handles it | `remoteUser` + `updateRemoteUserUID` handle UID mapping. No template-level fix needed. |

## Prerequisite

**The main worktree must be started first.** Infrastructure services (Traefik, Postgres, Redis) run only in the main worktree's devcontainer. Feature worktree containers depend on these services being available. If you open a feature worktree before the main worktree, the app container will start but database connections and Traefik routing will fail.

The `init.sh` script will create the Docker network if it doesn't exist, so at minimum networking will work. But infra services require the main worktree to be running.

## Directory Structure

```
myapp/                                   # main worktree
  .git/                                  # git database
  .devcontainer/
    devcontainer.json                    # devcontainer configuration
    docker-compose.yml                   # per-worktree app services
    docker-compose.infra.yml             # shared infrastructure (profiles-gated)
    Dockerfile                           # minimal app container image
    init.sh                              # host-side: resolves paths → .env, expands .env.app.template
    hooks/
      post-start.sh                      # in-container: git symlink fix + project setup extension points
    .env                                 # generated by init.sh (gitignored)
    .env.app                             # generated by init.sh from template (gitignored)
  .env.app.template                      # per-worktree env var template (tracked in git)
  src/
  ...

myapp-feature-x/                         # git worktree (sibling directory)
  .git                                   # file → ../myapp/.git/worktrees/feature-x
  .devcontainer/                         # same files (tracked in git)
  .env.app.template                      # same template (tracked in git)
  src/
  ...
```

## Configuration Files

### `.devcontainer/devcontainer.json`

```jsonc
{
  "name": "${localWorkspaceFolderBasename}",
  "dockerComposeFile": [
    "docker-compose.infra.yml",
    "docker-compose.yml"
  ],
  "service": "app",
  "workspaceFolder": "/workspaces/${localWorkspaceFolderBasename}",
  "initializeCommand": ".devcontainer/init.sh",
  "postStartCommand": ".devcontainer/hooks/post-start.sh",
  "remoteEnv": {
    "WORKTREE_NAME": "${localWorkspaceFolderBasename}",
    // For CLI-only usage (no VS Code), forward credentials explicitly:
    "GITHUB_TOKEN": "${localEnv:GITHUB_TOKEN}"
  },
  "customizations": {
    "vscode": {
      "extensions": [
        // Add your project's extensions here.
        // Each worktree container installs its own copy.
      ]
    }
  }
}
```

Key points:
- `workspaceFolder` uses conventional `/workspaces/{name}` path. The git fix is handled by `post-start.sh`.
- `initializeCommand` runs on the **host** before the container starts. Generates `.env` and `.env.app` with resolved paths.
- `postStartCommand` runs **inside** the container on every start. Creates the git symlink and runs project setup.
- VS Code automatically forwards SSH agent and git credentials — no configuration needed.
- `GITHUB_TOKEN` is forwarded for CLI-only / headless usage (devcontainer CLI, AI agents).

### `.devcontainer/init.sh`

Runs on the **host**. Resolves git paths, detects project name, sanitizes worktree name, creates the Docker network, expands the env var template, checks for orphaned containers, and writes `.env` for Docker Compose substitution.

```bash
#!/bin/bash
set -euo pipefail

# --- Worktree and project detection ---

WORKTREE_DIR_NAME=$(basename "$PWD")

# Sanitize worktree name for use in DB names, container names, etc.
# Replace any non-alphanumeric character (except hyphen) with underscore, then lowercase.
WORKTREE_NAME=$(echo "$WORKTREE_DIR_NAME" | sed 's/[^a-zA-Z0-9-]/_/g' | tr '[:upper:]' '[:lower:]')

# Detect project name: use PROJECT_NAME env var if set, otherwise derive from main repo directory.
# The main repo directory is the parent of the git common dir.
gitdir="$(git rev-parse --git-common-dir)"
case $gitdir in
  /*) ;;
  *) gitdir="$PWD/$gitdir"
esac
GIT_COMMON_DIR=$(cd "$gitdir" && pwd)
MAIN_REPO_NAME=$(basename "$(dirname "$GIT_COMMON_DIR")")
PROJECT_NAME="${PROJECT_NAME:-$MAIN_REPO_NAME}"

NETWORK_NAME="devnet-${PROJECT_NAME}"
LOCAL_WORKSPACE_FOLDER="$PWD"

# --- Docker network ---

# Create per-project network if it doesn't exist (idempotent).
docker network create "$NETWORK_NAME" 2>/dev/null || true

# --- Write .env for docker-compose variable substitution ---

cat > .devcontainer/.env <<EOF
WORKTREE_NAME=${WORKTREE_NAME}
GIT_COMMON_DIR=${GIT_COMMON_DIR}
MAIN_REPO_NAME=${MAIN_REPO_NAME}
PROJECT_NAME=${PROJECT_NAME}
NETWORK_NAME=${NETWORK_NAME}
LOCAL_WORKSPACE_FOLDER=${LOCAL_WORKSPACE_FOLDER}
TRAEFIK_PORT=${TRAEFIK_PORT:-80}
EOF

# Activate infra profile only for the main worktree.
# Main worktree has .git as a directory; worktrees have .git as a file.
if [ -d ".git" ]; then
  echo "COMPOSE_PROFILES=infra" >> .devcontainer/.env
fi

# --- Expand .env.app.template → .env.app ---

# The .env.app.template uses ${VARIABLE} placeholders.
# All variables from init.sh are available for substitution.
if [ -f ".env.app.template" ]; then
  export WORKTREE_NAME MAIN_REPO_NAME PROJECT_NAME NETWORK_NAME
  envsubst < .env.app.template > .devcontainer/.env.app
  echo "[devcontainer-wt] .env.app generated from template."
else
  # Create empty .env.app so docker-compose env_file doesn't fail.
  touch .devcontainer/.env.app
fi

# --- Orphan container detection ---

# Check for containers whose worktree directories no longer exist.
orphans=$(docker ps --filter "label=devcontainer-wt.project=${PROJECT_NAME}" \
  --format '{{.Names}} {{.Label "devcontainer-wt.worktree-dir"}}' 2>/dev/null || true)

if [ -n "$orphans" ]; then
  echo "$orphans" | while read -r container_name worktree_dir; do
    [ -z "$container_name" ] && continue
    if [ ! -d "$worktree_dir" ]; then
      echo "[devcontainer-wt] Orphaned container detected: $container_name (worktree dir: $worktree_dir)"
      echo "[devcontainer-wt] Run 'docker rm -f $container_name' to clean up."
    fi
  done
fi

echo "[devcontainer-wt] init.sh complete for worktree '${WORKTREE_NAME}' (project: ${PROJECT_NAME})"
```

### `.env.app.template`

Per-worktree environment variable template. Tracked in git. Uses `${VARIABLE}` placeholders that `init.sh` expands via `envsubst`.

```bash
# Per-worktree environment variables.
# Available placeholders: ${WORKTREE_NAME}, ${PROJECT_NAME}, ${MAIN_REPO_NAME}, ${NETWORK_NAME}
# Host env vars are also available (e.g., ${API_KEY} if set on host).

# Examples (uncomment and adapt for your project):
# DATABASE_URL=postgres://dev:dev@postgres-${PROJECT_NAME}:5432/${PROJECT_NAME}_${WORKTREE_NAME}
# REDIS_URL=redis://redis-${PROJECT_NAME}:6379/0
# APP_NAME=${PROJECT_NAME}-${WORKTREE_NAME}
```

### `.devcontainer/docker-compose.infra.yml`

Shared infrastructure services. Only started in the main worktree (via `COMPOSE_PROFILES=infra`).

```yaml
services:
  traefik:
    profiles: [infra]
    image: traefik:v3
    container_name: "traefik-${PROJECT_NAME}"
    command:
      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
      - --providers.docker.network=${NETWORK_NAME}
      - --entrypoints.web.address=:80
      - --api.insecure=true
    ports:
      - "${TRAEFIK_PORT}:80"
      - "8080:8080"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.traefik-dashboard.rule=Host(`traefik.${PROJECT_NAME}.localhost`)"
      - "traefik.http.routers.traefik-dashboard.entrypoints=web"
      - "traefik.http.services.traefik-dashboard.loadbalancer.server.port=8080"
    networks:
      - devnet
    restart: unless-stopped

  # Example infrastructure services.
  # Uncomment and adapt for your project's needs.

  # postgres:
  #   profiles: [infra]
  #   image: postgres:16
  #   container_name: "postgres-${PROJECT_NAME}"
  #   environment:
  #     POSTGRES_PASSWORD: dev
  #     POSTGRES_USER: dev
  #   ports:
  #     - "${POSTGRES_HOST_PORT:-15432}:5432"
  #   volumes:
  #     - pgdata:/var/lib/postgresql/data
  #   networks:
  #     - devnet
  #   restart: unless-stopped

  # redis:
  #   profiles: [infra]
  #   image: redis:7-alpine
  #   container_name: "redis-${PROJECT_NAME}"
  #   networks:
  #     - devnet
  #   restart: unless-stopped

# volumes:
#   pgdata:
#     name: "${PROJECT_NAME}-pgdata"

networks:
  devnet:
    name: ${NETWORK_NAME}
```

### `.devcontainer/docker-compose.yml`

Per-worktree app services. All variables come from `.env` (generated by `init.sh`).

```yaml
services:
  app:
    build:
      context: ..
      dockerfile: .devcontainer/Dockerfile
    container_name: "app-${PROJECT_NAME}-${WORKTREE_NAME}"
    volumes:
      # Mount the worktree at the conventional /workspaces path
      - ${LOCAL_WORKSPACE_FOLDER}:/workspaces/${WORKTREE_NAME}:cached
      # Mount the git common directory so the symlink target exists
      - ${GIT_COMMON_DIR}:/workspaces/${MAIN_REPO_NAME}/.git:rw
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${PROJECT_NAME}-${WORKTREE_NAME}.rule=Host(`${WORKTREE_NAME}.${PROJECT_NAME}.localhost`)"
      - "traefik.http.routers.${PROJECT_NAME}-${WORKTREE_NAME}.entrypoints=web"
      - "traefik.http.services.${PROJECT_NAME}-${WORKTREE_NAME}.loadbalancer.server.port=3000"
      - "devcontainer-wt=true"
      - "devcontainer-wt.project=${PROJECT_NAME}"
      - "devcontainer-wt.worktree=${WORKTREE_NAME}"
      - "devcontainer-wt.worktree-dir=${LOCAL_WORKSPACE_FOLDER}"
    env_file:
      - .env.app
    environment:
      - WORKTREE_NAME=${WORKTREE_NAME}
      - PROJECT_NAME=${PROJECT_NAME}
      - MAIN_REPO_NAME=${MAIN_REPO_NAME}
    extra_hosts:
      - "${WORKTREE_NAME}.${PROJECT_NAME}.localhost:host-gateway"
    networks:
      - devnet

    # Shared build caches (uncomment and adapt for your stack):
    # volumes:
    #   - npm-cache:/home/node/.npm
    #   - go-mod-cache:/go/pkg/mod
    #   - pip-cache:/home/vscode/.cache/pip

# Shared cache volumes (uncomment and adapt):
# Named volumes with a fixed name: are shared across all worktree containers.
# Share the package manager CACHE, not node_modules (platform-specific binaries).
#
# volumes:
#   npm-cache:
#     name: "${PROJECT_NAME}-npm-cache"
#   go-mod-cache:
#     name: "${PROJECT_NAME}-go-mod-cache"
#   pip-cache:
#     name: "${PROJECT_NAME}-pip-cache"

networks:
  devnet:
    external: true
    name: ${NETWORK_NAME}
```

### `.devcontainer/Dockerfile`

Minimal Dockerfile. Use devcontainer features in `devcontainer.json` for additional tooling.

```dockerfile
FROM mcr.microsoft.com/devcontainers/base:ubuntu

# Install project-specific system dependencies here.
# Prefer devcontainer features for common tools (Node, Python, Go, etc.)
# Example:
#   RUN apt-get update && apt-get install -y postgresql-client && rm -rf /var/lib/apt/lists/*
```

### `.devcontainer/hooks/post-start.sh`

Runs **inside** the container on **every start** (including restarts). Handles the git worktree symlink fix and provides extension points for project-specific setup.

```bash
#!/bin/bash
set -euo pipefail

echo "=== devcontainer-wt: starting worktree '${WORKTREE_NAME}' ==="

# --- Git worktree symlink fix ---
# If this is a worktree (not the main repo), the .git file contains a host path
# (e.g., gitdir: /Users/you/myapp/.git/worktrees/feature-x) that doesn't resolve
# inside the container. Instead of rewriting the file, we create a symlink so the
# host path resolves transparently. The .git file is NEVER modified.
if [ -f ".git" ]; then
  host_gitdir=$(sed 's/gitdir: //' .git)
  host_git_common="${host_gitdir%/worktrees/*}"

  # Create symlink: /Users/you/myapp/.git → /workspaces/myapp/.git
  mkdir -p "$(dirname "$host_git_common")"
  ln -sfn "/workspaces/${MAIN_REPO_NAME}/.git" "$host_git_common"

  # Verify git works
  if git status --short > /dev/null 2>&1; then
    echo "[devcontainer-wt] Git symlink fix applied. Git is working."
  else
    echo "[devcontainer-wt] WARNING: Git check failed after symlink fix."
    echo "[devcontainer-wt] Host gitdir: $host_gitdir"
    echo "[devcontainer-wt] Symlink: $host_git_common → /workspaces/${MAIN_REPO_NAME}/.git"
  fi
fi

# =============================================================================
# PROJECT SETUP — customize below for your project
# =============================================================================

# --- One-time setup (runs every start but should be idempotent) ---
# Examples:
#   pnpm install
#   bundle install

# --- Database initialization ---
# Create a per-worktree database if it doesn't exist.
# Examples:
#   PGPASSWORD=dev psql -h "postgres-${PROJECT_NAME}" -U dev -tc \
#     "SELECT 1 FROM pg_database WHERE datname = '${PROJECT_NAME}_${WORKTREE_NAME}'" | \
#     grep -q 1 || \
#     PGPASSWORD=dev createdb -h "postgres-${PROJECT_NAME}" -U dev "${PROJECT_NAME}_${WORKTREE_NAME}"

# --- Migrations ---
# Examples:
#   pnpm migrate
#   rails db:migrate

# --- Dev server ---
# Note: If you start a long-running process here, it blocks the hook.
# Use background processes or a process manager instead.
# Examples:
#   nohup pnpm dev > /tmp/dev-server.log 2>&1 &

echo "=== devcontainer-wt: worktree '${WORKTREE_NAME}' ready ==="
```

## How the Git Fix Works

Understanding the git worktree path problem and how this template solves it:

### The Problem

When you create a git worktree, git writes a `.git` **file** (not directory) in the worktree with an absolute host path:

```
# ~/projects/myapp-feature-x/.git (this is a file, not a directory)
gitdir: /Users/you/projects/myapp/.git/worktrees/feature-x
```

In a normal devcontainer (no worktrees), `.git` is a **directory** that gets mounted alongside the project — git works fine. But with a worktree, the `.git` file's host path doesn't exist inside the container.

### The Solution (Symlink Approach)

Instead of rewriting the `.git` file (which would mutate the bind-mounted file and break host-side git), the template creates a symlink inside the container:

1. **`init.sh` (host-side):** Resolves the main repo's `.git` directory path and writes it to `.env`.

2. **`docker-compose.yml`:** Mounts the git common directory at a predictable container path:
   ```
   Host: ~/projects/myapp/.git/  →  Container: /workspaces/myapp/.git/
   ```

3. **`post-start.sh` (container-side):** Reads the host path from the `.git` file and creates a symlink so it resolves:
   ```
   .git file says:  gitdir: /Users/you/projects/myapp/.git/worktrees/feature-x
   Symlink created: /Users/you/projects/myapp/.git → /workspaces/myapp/.git
   Git follows:     /Users/you/projects/myapp/.git/worktrees/feature-x
                    → (via symlink) /workspaces/myapp/.git/worktrees/feature-x ✓
   ```

4. **`commondir` (no change needed):** Inside `.git/worktrees/feature-x/commondir`, the relative path `../..` still resolves correctly to the git common directory regardless of where it's mounted.

### Why Symlink Instead of File Rewrite

The original approach used `sed` to rewrite the `.git` file inside the container. But since the file is bind-mounted, this modifies the host's `.git` file too — breaking host-side git operations. The symlink approach:

- **Never modifies any files.** The host's `.git` file stays untouched.
- **No restoration needed.** No init.sh logic to restore the `.git` file on each start.
- **Idempotent.** `ln -sfn` can be run on every start safely.
- **Transparent to all git tools.** Path resolution happens at the filesystem level.

The only cosmetic side effect: it creates a host-path directory structure inside the container (e.g., `/Users/you/projects/myapp/.git`). This is harmless.

### Git Concurrency with Parallel Agents

Git worktrees are designed for parallel work on different branches. Each worktree has its own:
- Working tree (files)
- Index (staging area)
- HEAD (current commit)

The shared parts (objects, refs, packed-refs) use lock files for safe concurrent access. Since Docker bind mounts go through the host filesystem, lock files work correctly — the same as running multiple terminals on the host.

**Safe for parallel AI agents:** Each agent in its own worktree can commit, branch, and push independently. Repo-wide operations like `git gc` or `git repack` use exclusive locks and will fail with a lock error if another operation holds the lock (retry-safe, not data-corrupting).

Note: The back-pointer file (`.git/worktrees/feature-x/gitdir`) still contains the host path. This only affects `git worktree list` and `git worktree prune`, which are typically run on the host — not inside containers.

## Multi-Service Per Worktree

For projects with multiple services (frontend, backend, worker), define them all in `docker-compose.yml`:

```yaml
services:
  frontend:
    build:
      context: ..
      dockerfile: .devcontainer/Dockerfile.frontend
    container_name: "frontend-${PROJECT_NAME}-${WORKTREE_NAME}"
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${PROJECT_NAME}-${WORKTREE_NAME}-web.rule=Host(`${WORKTREE_NAME}.${PROJECT_NAME}.localhost`)"
      - "traefik.http.routers.${PROJECT_NAME}-${WORKTREE_NAME}-web.entrypoints=web"
      - "traefik.http.services.${PROJECT_NAME}-${WORKTREE_NAME}-web.loadbalancer.server.port=3000"
    networks:
      - devnet

  api:
    build:
      context: ..
      dockerfile: .devcontainer/Dockerfile.api
    container_name: "api-${PROJECT_NAME}-${WORKTREE_NAME}"
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${PROJECT_NAME}-${WORKTREE_NAME}-api.rule=Host(`api.${WORKTREE_NAME}.${PROJECT_NAME}.localhost`)"
      - "traefik.http.routers.${PROJECT_NAME}-${WORKTREE_NAME}-api.entrypoints=web"
      - "traefik.http.services.${PROJECT_NAME}-${WORKTREE_NAME}-api.loadbalancer.server.port=4000"
    networks:
      - devnet

  worker:
    build:
      context: ..
      dockerfile: .devcontainer/Dockerfile.worker
    container_name: "worker-${PROJECT_NAME}-${WORKTREE_NAME}"
    networks:
      - devnet
```

Each service gets its own Traefik route: the frontend at `feature-x.myapp.localhost`, the API at `api.feature-x.myapp.localhost`.

> **Note:** The above example uses separate containers (one service per container), so Traefik automatically associates each router with the single service on that container. If you use a **single container with multiple Traefik services** (e.g., a monorepo — see CUSTOMIZING.md), you must add an explicit `.service` label on each router:
> ```yaml
> - "traefik.http.routers.${PROJECT_NAME}-${WORKTREE_NAME}-ui.service=${PROJECT_NAME}-${WORKTREE_NAME}-ui"
> ```
> Without this, Traefik cannot determine which backend service each router should use.

## Shared Build Caches

To avoid duplicating `node_modules`, Go modules, Gradle caches, etc. across worktrees, use Docker named volumes:

```yaml
volumes:
  # Shared across ALL worktrees (same content, like package registries)
  npm-cache:
    name: "${PROJECT_NAME}-npm-cache"
  go-mod-cache:
    name: "${PROJECT_NAME}-go-mod-cache"

services:
  app:
    volumes:
      - npm-cache:/home/node/.npm
      - go-mod-cache:/go/pkg/mod
```

Named volumes with a fixed `name:` are shared across Docker Compose projects. This means all worktree containers share the same npm/go/gradle cache, saving disk space and download time.

Note: Don't share `node_modules` directories directly (they may contain platform-specific binaries). Share the **package manager cache** instead, and let each worktree do its own `npm install` (which will be fast because packages are cached).

**Data safety note:** `docker system prune --volumes` deletes all unused named volumes, including these caches and any database volumes. This is general Docker behavior. Be cautious with volume prune commands when using devcontainer-wt.

## Workflows

### Initial Setup

```bash
# 1. Clone the repo
git clone https://github.com/you/your-repo.git myapp
cd myapp

# 2. Open in VS Code and "Reopen in Container"
#    This runs init.sh (detects main worktree, enables infra profile,
#    creates devnet-myapp network) and starts Traefik + infra services
#    + the app container.
code .

# 3. Access via browser
#    http://myapp.myapp.localhost (or http://myapp.myapp.localhost:PORT if custom TRAEFIK_PORT)
#    http://traefik.myapp.localhost (Traefik dashboard for debugging routes)
```

### Create a Feature Worktree

```bash
# 1. Create the worktree (from the main repo, on the host)
cd myapp
git worktree add ../myapp-feature-x -b feature-x

# 2. Open in VS Code and "Reopen in Container"
#    init.sh detects this is a worktree (not main), skips infra profile.
#    App container joins the existing devnet-myapp network.
#    post-start.sh creates git symlink and runs project setup.
code ../myapp-feature-x

# 3. Access via browser
#    http://feature-x.myapp.localhost
```

Each worktree opens as a **separate VS Code window** with its own devcontainer. This is the intended UX — clean separation between worktrees.

### PR Review Flow

```bash
# 1. Fetch and create worktree for the PR branch
cd myapp
git fetch origin
git worktree add ../myapp-pr-123 origin/feature-branch

# 2. Open, test, review
code ../myapp-pr-123
# Browser: http://pr-123.myapp.localhost

# 3. Cleanup when done (see Cleanup section)
```

### Headless Usage (devcontainer CLI / AI Agents)

The template works with `devcontainer CLI` without VS Code. All lifecycle hooks (`initializeCommand`, `postStartCommand`) execute the same way.

```bash
# Start a worktree container headlessly
devcontainer up --workspace-folder ../myapp-feature-x

# Execute commands inside
devcontainer exec --workspace-folder ../myapp-feature-x bash
```

For git authentication in headless mode, ensure `GITHUB_TOKEN` is set in your host environment. The template forwards it via `remoteEnv`.

### Cleanup

#### Intentional cleanup (git alias)

Add to `~/.gitconfig`:

```ini
[alias]
  wt-remove = "!f() { \
    docker compose -f \"$1/.devcontainer/docker-compose.yml\" --env-file \"$1/.devcontainer/.env\" down 2>/dev/null; \
    git worktree remove \"$1\"; \
  }; f"
```

Usage:
```bash
git wt-remove ../myapp-feature-x
# Stops container, removes worktree directory.
# git worktree remove refuses to delete dirty worktrees (uncommitted changes) — use --force to override.
```

Note: Database cleanup is project-specific. Add your own cleanup commands to the alias (e.g., `docker exec` to drop a DB) or handle it separately.

#### Automatic orphan detection

Orphan detection runs automatically during `init.sh` — every time any worktree's devcontainer starts, it checks for containers whose worktree directories no longer exist and prints a warning. No cron setup needed.

To manually clean up an orphaned container:
```bash
docker rm -f <container-name>
```

## Platform Considerations

### macOS (Docker Desktop)

- `*.localhost` resolves to `127.0.0.1` by default. Traefik subdomain routing works out of the box.
- `extra_hosts: host-gateway` maps to `host.docker.internal` which Docker Desktop resolves to the host's IP.
- Performance: Use `:cached` volume mount flag for better file system performance.
- `realpath` may not be available. The `init.sh` script uses `cd ... && pwd` instead for portability.

### Linux (Native Docker)

- `*.localhost` resolution may require configuration. If subdomains don't resolve, add entries to `/etc/hosts` or use `dnsmasq`:
  ```
  # /etc/hosts (manual per worktree)
  127.0.0.1 feature-x.myapp.localhost
  127.0.0.1 pr-123.myapp.localhost

  # Or use dnsmasq for wildcard (automatic)
  address=/localhost/127.0.0.1
  ```
- `extra_hosts: host-gateway` maps to the Docker bridge gateway IP (typically `172.17.0.1`).
- Native Docker has better file system performance than Docker Desktop — `:cached` flag is optional but harmless.

## Limitations

- **Explicit adoption required.** Projects must use this template's `.devcontainer/` structure. Existing devcontainer setups need modification.
- **Docker Compose only.** The `initializeCommand` → `.env` → compose substitution pattern requires Docker Compose as the devcontainer backend. Image-based or Dockerfile-based devcontainer configurations won't work.
- **Main worktree must start first.** The main worktree hosts shared infrastructure. Feature worktrees depend on infra services being running. The Docker network is created by init.sh regardless, but Traefik and other infra services require the main worktree.
- **Main worktree is special.** Deleting the main worktree's devcontainer would stop infra for all worktrees. (Mitigated by the fact that the main worktree is typically permanent.)
- **Name collision risk.** Sanitization may cause collisions (e.g., `feature/login` and `feature-login` both become `feature_login`). Use distinct worktree directory names.
- **GitHub Codespaces not supported.** Different constraints (no Traefik, no sibling worktrees). Out of scope.

## Open Questions

- **Compose V2 `.env` location.** Docker Compose V2 reads `.env` from the compose file's directory. Need to verify this works consistently when devcontainer CLI invokes compose.
- **Hot reload.** File watchers inside containers may need tuning (e.g. `inotify` limits on Linux, polling on macOS via Docker Desktop). This is a general devcontainer concern, not specific to worktrees.
- **Git worktree back-pointer.** The `.git/worktrees/{name}/gitdir` file still contains the host path after the symlink fix. This only affects `git worktree list` inside the container. If this becomes a problem, the post-start.sh script can rewrite it too, but it modifies a shared git metadata file (visible to the host and other containers).
- **`envsubst` availability.** The `init.sh` script uses `envsubst` to expand `.env.app.template`. This is available on most Linux systems (part of `gettext`) and on macOS via Homebrew. Need to verify availability or provide a fallback.
