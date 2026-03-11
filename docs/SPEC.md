# devcontainer-wt

A thin, opinionated template for seamless devcontainer + git worktree workflows. Worktree management is delegated to external tools (e.g., [git-wt](https://github.com/k1LoW/git-wt), [wtp](https://github.com/satococoa/wtp), or raw `git worktree`). This template focuses only on what those tools can't do: making devcontainers work correctly with worktrees.

## Problem

Working with devcontainers and git worktrees simultaneously is painful:

1. **Git context breaks inside containers.** A git worktree's `.git` is a file (not a directory) containing an absolute host path (e.g. `gitdir: /Users/you/repo/.git/worktrees/feature-x`). When the worktree is mounted into a container at a different path (e.g. `/workspaces/repo-feature-x`), this host path doesn't resolve. All git operations (`log`, `blame`, `status`) fail inside the container. Note: this problem is specific to worktrees — regular repos have a `.git` directory that gets mounted alongside the project and works fine.

2. **Port conflicts.** Each devcontainer maps ports to the host (e.g. `3000:3000`). Running multiple worktree containers simultaneously causes port binding conflicts.

3. **No shared infrastructure.** Each devcontainer typically spins up its own database, cache, etc. There's no built-in way to share these across worktrees or isolate data per worktree within a shared service.

4. **Gitignored files don't propagate.** When creating a worktree, git only checks out tracked files. Gitignored files (`.env`, `docker-compose.local.yml`, IDE configs) must be manually copied.

## Solution Overview

**devcontainer-wt** is a template-only approach (no CLI wrapper) that solves these problems using existing devcontainer lifecycle hooks, Docker Compose, and external worktree management tools:

- **Git fix:** Mount the git common directory at the same absolute host path inside the container so the `.git` file's host path references resolve directly. No symlink or file mutation needed.
- **No port conflicts:** A per-project Traefik reverse proxy routes by subdomain (`feature-x.myapp.localhost`, using the branch name). No host port mapping needed per worktree. Traefik port is configurable.
- **Shared infrastructure:** Infrastructure services (database, cache, proxy) run from a standalone `docker-compose.yml` at the project root — started with `docker compose up` on the host, completely independent of devcontainers. Per-worktree app containers join a shared Docker network.
- **Gitignored file propagation:** `.worktreeinclude` + `.worktreeinclude.local` define glob patterns for files to copy to new worktrees. Copying is handled by worktree tool hooks (e.g., `git-wt`'s `wt.hook`).
- **Per-worktree env vars:** A `.env.app.template` (tracked in git) with `${VARIABLE}` placeholders is expanded by `init.sh` into `.env.app` (gitignored) per worktree. Seamless, zero-config per worktree.
- **Lifecycle hooks:** `.worktree/hooks/on-create.sh` and `.worktree/hooks/on-delete.sh` provide extension points for worktree tool hooks (file copying, container cleanup, DB teardown).

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
  │    docker-compose.yml   (infra — run on host)    │
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

  Host: docker compose up (from myapp/)
  ┌──────────────────────────────────────────────────┐
  │  ┌─────────┐  ┌──────────┐  ┌────────┐          │
  │  │ Traefik │  │ Postgres │  │ Redis  │  ...      │
  │  │ :80     │  │ :5432    │  │ :6379  │           │
  │  └────┬────┘  └──────────┘  └────────┘          │
  │       │           Shared Infrastructure          │
  │       │     (started independently on host)      │
  └───────┼──────────────────────────────────────────┘
          │
          │  Docker Network: devnet-myapp
  ┌───────┼──────────────────────────────────────────┐
  │  ┌────┴──────────────┬──────────────────┐       │
  │  │                   │                  │        │
  │  ▼                   ▼                  ▼        │
  │ ┌──────────┐  ┌──────────────┐  ┌──────────┐   │
  │ │app-myapp-│  │app-myapp-    │  │app-myapp-│   │
  │ │  myapp   │  │  feature-x   │  │  pr-123  │   │
  │ │ :3000    │  │ :3000        │  │ :3000    │   │
  │ └──────────┘  └──────────────┘  └──────────┘   │
  │  Per-worktree app containers (devcontainers)     │
  │  (no host port mapping — Traefik routes traffic) │
  └──────────────────────────────────────────────────┘

  Browser (routes by branch name):
    main.myapp.localhost            → app-myapp-myapp:3000
    feature-x.myapp.localhost       → app-myapp-feature-x:3000
    pr-123.myapp.localhost          → app-myapp-pr-123:3000

  Traefik Dashboard:
    traefik.myapp.localhost         → Traefik dashboard (debug routing)
```

### Key Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Git fix | Same-path volume mount (no file mutation) | Mounts the git common directory at the same absolute host path inside the container. The `.git` file's host path references resolve directly. No symlink or post-start script needed. |
| Directory layout | Sibling directories | Most common git worktree pattern. Main worktree is a natural home for shared infra. |
| Worktree management | External tools (git-wt, wtp, raw git worktree) | Template does NOT wrap `git worktree`. Users choose their preferred tool. Template provides hook scripts that any tool can call. |
| Port conflict solution | Traefik with subdomain routing | Single entry point, configurable port (default 80). Auto-discovers containers via Docker labels. Zero-config per worktree. |
| Traefik dashboard | Enabled by default | Routes to `traefik.{project}.localhost`. Invaluable for debugging routing issues. |
| Routing pattern | Always `{branch}.{project}.localhost` | Consistent pattern using the git branch name. Main worktree gets `main.myapp.localhost`. Shorter URLs than using the worktree directory name. |
| Container naming | Always `app-{project}-{worktree}` | Consistent pattern, no special-casing. Main worktree gets `app-myapp-myapp`. |
| DNS | `.localhost` TLD, zero-config | Works in Chrome and macOS out of the box. Document `/etc/hosts` or `dnsmasq` workaround for Linux/Firefox. |
| Network isolation | Per-project Docker network (`devnet-{project}`) | Prevents container name collisions and unintended cross-project access. Default name derived from PROJECT_NAME, overridable via `NETWORK_NAME` env var. |
| Project naming | Auto-detect from main repo directory name, with override | Routes become `{branch}.{project}.localhost`. Auto-detected for zero config, overridable via `PROJECT_NAME` for custom naming. |
| Compose project name | `{PROJECT_NAME}-{BRANCH_NAME}` | Each worktree gets a unique Docker Compose project name for container isolation. Prevents container name collisions across worktrees. |
| Infra lifecycle | Standalone `docker-compose.yml` at project root | Infrastructure runs independently on the host via `docker compose up`. No devcontainer required. No profiles — all defined services start. |
| Infra restart policy | `unless-stopped` | Infra services (DB, cache, proxy) survive Docker Desktop restarts. Dev data stays up. |
| Per-worktree env vars | `.env.app.template` expanded by `init.sh` | Tracked template with `${VARIABLE}` placeholders. `init.sh` renders it into `.env.app` (gitignored) per worktree via `envsubst`. Secrets come from host env vars or manual edits. |
| DB per worktree | User-provided hooks with sanitized names | Template provides extension points with commented examples. DB engine is project-specific — template does not prescribe a database. |
| Internal DNS | `extra_hosts` in compose | Ensures `*.localhost` resolves to Traefik from inside containers (needed for SSR, OAuth, webhooks). |
| Worktree hooks | `.worktree/hooks/on-create.sh` and `on-delete.sh` | Prescribed hook scripts at a well-known location. Users wire them into their worktree tool of choice (git-wt `wt.hook`/`wt.deletehook`, wtp hooks, or manual invocation). |
| Worktreeinclude | `.worktreeinclude` + `.worktreeinclude.local` at repo root | Glob patterns for gitignored files to copy from main worktree to new worktrees. `.local` variant is personal (gitignored). Executed by `on-create.sh`. |
| Local compose overrides | `docker-compose.local.yml` in `.devcontainer/` (gitignored) | Personal Docker Compose overrides. A `.devcontainer/docker-compose.local.yml.template` is tracked to help developers create their own. `init.sh` creates an empty stub if missing. |
| Workspace path | Conventional `/workspaces/{name}` | Standard devcontainer path convention. |
| Compose variables | Resolved in init.sh, written to `.env` | `${localWorkspaceFolder}` is a devcontainer variable, NOT available in docker-compose.yml. All paths resolved in init.sh and passed via `.env`. |
| VS Code extensions | Per-container installation | Each container installs its own extensions. Sharing a volume across concurrent containers is unsafe (race conditions). Declare extensions in devcontainer.json. |
| Git authentication | VS Code auto-forwarding + `GITHUB_TOKEN` for headless | VS Code auto-forwards SSH agent and git credentials. For CLI-only usage (devcontainer CLI, AI agents), forward `GITHUB_TOKEN` via `remoteEnv`. |
| Git concurrency | Safe for parallel agents | Git worktrees are designed for parallel work. Per-worktree index/HEAD/working tree. Shared refs use lock files. Bind mounts preserve lock file semantics. Repo-wide operations (`gc`, `repack`) may need serialization but fail safely with lock errors. |
| IDE support | VS Code primary, headless supported | VS Code is the primary tested IDE. Headless via `devcontainer CLI` works with the same lifecycle hooks — set `GITHUB_TOKEN` for git auth. |
| AI agent workflow | One agent per worktree | Each AI agent works in its own worktree/container. Full isolation (separate DB, deps, env). |
| Dockerfile | Minimal + devcontainer features | Thin Dockerfile. Bare template — no devcontainer features included. Users add what they need. |
| Resource limits | None in template | Resource management is project-specific. Docker Desktop global limits apply. |
| Form factor | Template files, copied per project | No external dependency. Each project gets its own copy. Simple, explicit, version controlled. Manual copy for updates. |
| Platform | macOS + Linux | Template works on both Docker Desktop (macOS) and native Docker (Linux). |
| Codespaces | Not supported | GitHub Codespaces has different constraints (no Traefik, no sibling worktrees). Out of scope. |
| HTTPS | HTTP only | Keeps the template simple. Developers who need HTTPS can configure Traefik TLS themselves. |
| Versioning | Pin major versions | `traefik:v3`, `postgres:16`, etc. Stable and predictable. Users update manually when ready. |
| Data safety | Named Docker volumes + documentation | `docker system prune --volumes` deletes unused named volumes (general Docker behavior, not worktree-specific). Documented. |
| Name collision | Document, don't mitigate | Branch name sanitization may cause collisions (e.g., `feature/login` and `feature-login` both become `feature-login`). Rare enough to document rather than add complexity. |
| File permissions | Devcontainer handles it | `remoteUser` + `updateRemoteUserUID` handle UID mapping. No template-level fix needed. |

## Prerequisites

1. **Start infrastructure first.** Run `docker compose up -d` from the project root (main worktree) before opening any devcontainer. Infrastructure services (Traefik, Postgres, Redis) are independent of devcontainers and must be running for worktree containers to function.

2. **Install a worktree management tool (recommended).** The template works with raw `git worktree` commands, but tools like [git-wt](https://github.com/k1LoW/git-wt) or [wtp](https://github.com/satococoa/wtp) provide a better experience with hook support for automatic setup and cleanup.

## Directory Structure

```
myapp/                                   # main worktree
  .git/                                  # git database
  docker-compose.yml                     # shared infrastructure (Traefik, DB, cache)
  .devcontainer/
    devcontainer.json                    # devcontainer configuration
    docker-compose.yml                   # per-worktree app services
    docker-compose.local.yml             # personal overrides (gitignored, auto-stubbed)
    docker-compose.local.yml.template    # template for personal overrides (tracked)
    Dockerfile                           # minimal app container image
    init.sh                              # host-side: resolves paths → .env, expands .env.app.template
    .env                                 # generated by init.sh (gitignored)
    .env.app                             # generated by init.sh from template (gitignored)
  .worktree/
    hooks/
      on-create.sh                       # host-side: runs after worktree creation (copies .worktreeinclude files)
      on-delete.sh                       # host-side: cleanup hook (stop container, drop DB, prune orphans)
  .worktreeinclude                       # glob patterns for files to copy to new worktrees (tracked)
  .worktreeinclude.local                 # personal patterns (gitignored)
  .env.app.template                      # per-worktree env var template (tracked in git)
  src/
  ...

myapp-feature-x/                         # git worktree (sibling directory)
  .git                                   # file → ../myapp/.git/worktrees/feature-x
  .devcontainer/                         # same files (tracked in git)
  .worktree/                             # same files (tracked in git)
  .env.app.template                      # same template (tracked in git)
  src/
  ...
```

## Configuration Files

### `docker-compose.yml` (project root)

Shared infrastructure services. Started independently on the host with `docker compose up -d`. Completely decoupled from devcontainers — no VS Code or devcontainer CLI required.

```yaml
services:
  traefik:
    image: traefik:v3
    container_name: "traefik-${PROJECT_NAME:-myapp}"
    command:
      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
      - --providers.docker.network=${NETWORK_NAME:-devnet-myapp}
      - --entrypoints.web.address=:80
      - --api.insecure=true
    ports:
      - "${TRAEFIK_PORT:-80}:80"
      - "8080:8080"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.traefik-dashboard.rule=Host(`traefik.${PROJECT_NAME:-myapp}.localhost`)"
      - "traefik.http.routers.traefik-dashboard.entrypoints=web"
      - "traefik.http.services.traefik-dashboard.loadbalancer.server.port=8080"
    networks:
      - devnet
    restart: unless-stopped

  # Example infrastructure services.
  # Uncomment and adapt for your project's needs.

  # postgres:
  #   image: postgres:16
  #   container_name: "postgres-${PROJECT_NAME:-myapp}"
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
  #   image: redis:7-alpine
  #   container_name: "redis-${PROJECT_NAME:-myapp}"
  #   networks:
  #     - devnet
  #   restart: unless-stopped

# volumes:
#   pgdata:
#     name: "${PROJECT_NAME:-myapp}-pgdata"

networks:
  devnet:
    name: ${NETWORK_NAME:-devnet-myapp}
```

To start infrastructure:

```bash
cd myapp
docker compose up -d
# Access Traefik dashboard: http://traefik.myapp.localhost
```

### `.devcontainer/devcontainer.json`

```jsonc
{
  "name": "${localWorkspaceFolderBasename}",
  "dockerComposeFile": [
    "docker-compose.yml",
    "docker-compose.local.yml"
  ],
  "service": "app",
  "workspaceFolder": "/workspaces/${localWorkspaceFolderBasename}",
  "initializeCommand": ".devcontainer/init.sh",
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
- `dockerComposeFile` references only the app compose and local overrides. Infrastructure is managed separately.
- `workspaceFolder` uses conventional `/workspaces/{name}` path.
- `initializeCommand` runs on the **host** before the container starts. Generates `.env` and `.env.app` with resolved paths.
- VS Code automatically forwards SSH agent and git credentials — no configuration needed.
- `GITHUB_TOKEN` is forwarded for CLI-only / headless usage (devcontainer CLI, AI agents).

### `.devcontainer/init.sh`

Runs on the **host**. Resolves git paths, detects project name, sanitizes worktree name, creates an empty `docker-compose.local.yml` stub if missing, expands the env var template, and writes `.env` for Docker Compose substitution.

```bash
#!/bin/bash
set -euo pipefail

# --- Worktree and project detection ---

WORKTREE_DIR_NAME=$(basename "$PWD")

# Sanitize worktree name for use in DB names, container names, etc.
# Replace any non-alphanumeric character (except hyphen) with underscore, then lowercase.
WORKTREE_NAME=$(echo "$WORKTREE_DIR_NAME" | sed 's/[^a-zA-Z0-9-]/_/g' | tr '[:upper:]' '[:lower:]')

# Detect the current branch name for use in subdomain routing.
# Replace slashes with hyphens and sanitize for DNS-safe names.
BRANCH_NAME=$(git branch --show-current | sed 's|/|-|g; s/[^a-zA-Z0-9-]/_/g' | tr '[:upper:]' '[:lower:]')

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

NETWORK_NAME="${NETWORK_NAME:-devnet-${PROJECT_NAME}}"
COMPOSE_PROJECT_NAME="${PROJECT_NAME}-${BRANCH_NAME}"
LOCAL_WORKSPACE_FOLDER="$PWD"

# --- Local compose overrides ---

# Create empty docker-compose.local.yml stub if missing (prevents Docker Compose errors).
if [ ! -f ".devcontainer/docker-compose.local.yml" ]; then
  echo "# Personal Docker Compose overrides (gitignored). See docker-compose.local.yml.template for examples." \
    > .devcontainer/docker-compose.local.yml
fi

# --- Write .env for docker-compose variable substitution ---

cat > .devcontainer/.env <<EOF
COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME}
WORKTREE_NAME=${WORKTREE_NAME}
BRANCH_NAME=${BRANCH_NAME}
GIT_COMMON_DIR=${GIT_COMMON_DIR}
MAIN_REPO_NAME=${MAIN_REPO_NAME}
PROJECT_NAME=${PROJECT_NAME}
NETWORK_NAME=${NETWORK_NAME}
LOCAL_WORKSPACE_FOLDER=${LOCAL_WORKSPACE_FOLDER}
EOF

# --- Expand .env.app.template → .env.app ---

# The .env.app.template uses ${VARIABLE} placeholders.
# All variables from init.sh are available for substitution.
if [ -f ".env.app.template" ]; then
  export WORKTREE_NAME BRANCH_NAME MAIN_REPO_NAME PROJECT_NAME NETWORK_NAME COMPOSE_PROJECT_NAME
  envsubst < .env.app.template > .devcontainer/.env.app
  echo "[devcontainer-wt] .env.app generated from template."
else
  # Create empty .env.app so docker-compose env_file doesn't fail.
  touch .devcontainer/.env.app
fi

echo "[devcontainer-wt] init.sh complete for worktree '${WORKTREE_NAME}' branch '${BRANCH_NAME}' (project: ${PROJECT_NAME})"
```

### `.env.app.template`

Per-worktree environment variable template. Tracked in git. Uses `${VARIABLE}` placeholders that `init.sh` expands via `envsubst`.

```bash
# Per-worktree environment variables.
# Available placeholders: ${WORKTREE_NAME}, ${BRANCH_NAME}, ${PROJECT_NAME}, ${MAIN_REPO_NAME}, ${NETWORK_NAME}, ${COMPOSE_PROJECT_NAME}
# Host env vars are also available (e.g., ${API_KEY} if set on host).

# Examples (uncomment and adapt for your project):
# DATABASE_URL=postgres://dev:dev@postgres-${PROJECT_NAME}:5432/${PROJECT_NAME}_${WORKTREE_NAME}
# REDIS_URL=redis://redis-${PROJECT_NAME}:6379/0
# APP_NAME=${PROJECT_NAME}-${WORKTREE_NAME}
```

### `.worktreeinclude` and `.worktreeinclude.local`

Glob patterns (one per line) for gitignored files that should be copied from the main worktree to new worktrees. Comments (`#`) and empty lines are ignored.

- `.worktreeinclude` — tracked in git. Shared across the team.
- `.worktreeinclude.local` — gitignored. Personal patterns for individual developers.

```bash
# .worktreeinclude
# Copy local compose overrides to new worktrees
.devcontainer/docker-compose.local.yml
```

File copying is handled by `.worktree/hooks/on-create.sh`, which is invoked by the user's worktree management tool (see [Worktree Hooks](#worktree-hooks)).

### `.devcontainer/docker-compose.local.yml` and `.devcontainer/docker-compose.local.yml.template`

Personal Docker Compose overrides (gitignored). Use this for custom volume mounts, environment variables, or other per-developer customizations that shouldn't be shared with the team.

A tracked template file (`.devcontainer/docker-compose.local.yml.template`) provides examples:

```yaml
# docker-compose.local.yml.template
# Copy this to docker-compose.local.yml and customize.
# This file is gitignored — your overrides stay local.

# Example: mount a local directory into the container
# services:
#   app:
#     volumes:
#       - /path/to/my/local/data:/workspaces/data:cached
```

This file is always listed in `devcontainer.json`'s `dockerComposeFile` array. If it doesn't exist, `init.sh` creates an empty stub so Docker Compose doesn't error. To propagate your local compose file to new worktrees, add `.devcontainer/docker-compose.local.yml` to `.worktreeinclude`.

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
      # Mount the git common directory at the same absolute host path so
      # .git file references (absolute paths) remain valid inside the container
      - ${GIT_COMMON_DIR}:${GIT_COMMON_DIR}:cached
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${PROJECT_NAME}-${WORKTREE_NAME}.rule=Host(`${BRANCH_NAME}.${PROJECT_NAME}.localhost`)"
      - "traefik.http.routers.${PROJECT_NAME}-${WORKTREE_NAME}.entrypoints=web"
      - "traefik.http.services.${PROJECT_NAME}-${WORKTREE_NAME}.loadbalancer.server.port=3000"
      - "devcontainer-wt=true"
      - "devcontainer-wt.project=${PROJECT_NAME}"
      - "devcontainer-wt.worktree=${WORKTREE_NAME}"
      - "devcontainer-wt.worktree-dir=${LOCAL_WORKSPACE_FOLDER}"
      - "devcontainer-wt.branch=${BRANCH_NAME}"
    env_file:
      - .env.app
    environment:
      - WORKTREE_NAME=${WORKTREE_NAME}
      - BRANCH_NAME=${BRANCH_NAME}
      - PROJECT_NAME=${PROJECT_NAME}
      - MAIN_REPO_NAME=${MAIN_REPO_NAME}
    extra_hosts:
      - "${BRANCH_NAME}.${PROJECT_NAME}.localhost:host-gateway"
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

## Worktree Hooks

The template provides hook scripts in `.worktree/hooks/` that handle worktree lifecycle events. These scripts are **not called automatically** — users wire them into their worktree management tool of choice.

### `.worktree/hooks/on-create.sh`

Runs on the **host** after a new worktree is created. Copies gitignored files listed in `.worktreeinclude`.

```bash
#!/bin/bash
set -euo pipefail

# --- Resolve main worktree ---

gitdir="$(git rev-parse --git-common-dir)"
case $gitdir in
  /*) ;;
  *) gitdir="$PWD/$gitdir"
esac
GIT_COMMON_DIR=$(cd "$gitdir" && pwd)
MAIN_REPO_DIR=$(dirname "$GIT_COMMON_DIR")

# --- Copy .worktreeinclude files ---

copy_from_include_file() {
  local include_file="$1" target_root="$2"
  [[ -f "$include_file" ]] || return 0

  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    (
      cd "$MAIN_REPO_DIR"
      shopt -s dotglob nullglob
      shopt -s globstar 2>/dev/null || true
      for f in $line; do
        [[ -f "$f" ]] || continue
        mkdir -p "${target_root}/$(dirname "$f")"
        cp "$f" "${target_root}/${f}"
        echo "[devcontainer-wt] Copied: ${f}"
      done
    )
  done < "$include_file"
}

copy_from_include_file "${MAIN_REPO_DIR}/.worktreeinclude" "$PWD"
copy_from_include_file "${MAIN_REPO_DIR}/.worktreeinclude.local" "$PWD"

echo "[devcontainer-wt] on-create complete."
```

### `.worktree/hooks/on-delete.sh`

Runs on the **host** before a worktree is removed. Stops the container and runs project-specific cleanup.

```bash
#!/bin/bash
set -euo pipefail

# --- Resolve project info ---

gitdir="$(git rev-parse --git-common-dir)"
case $gitdir in
  /*) ;;
  *) gitdir="$PWD/$gitdir"
esac
GIT_COMMON_DIR=$(cd "$gitdir" && pwd)
MAIN_REPO_DIR=$(dirname "$GIT_COMMON_DIR")
MAIN_REPO_NAME=$(basename "$MAIN_REPO_DIR")
PROJECT_NAME="${PROJECT_NAME:-$MAIN_REPO_NAME}"

WORKTREE_DIR_NAME=$(basename "$PWD")
WORKTREE_NAME=$(echo "$WORKTREE_DIR_NAME" | sed 's/[^a-zA-Z0-9-]/_/g' | tr '[:upper:]' '[:lower:]')

CONTAINER_NAME="app-${PROJECT_NAME}-${WORKTREE_NAME}"

# --- Stop and remove container ---

if docker inspect "$CONTAINER_NAME" > /dev/null 2>&1; then
  echo "[devcontainer-wt] Removing container ${CONTAINER_NAME}..."
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
fi

# =============================================================================
# PROJECT-SPECIFIC CLEANUP — customize below
# =============================================================================

# Examples:
#   # Drop per-worktree PostgreSQL database
#   docker exec "postgres-${PROJECT_NAME}" dropdb -U dev --if-exists "${PROJECT_NAME}_${WORKTREE_NAME}" 2>/dev/null || true

# --- Prune orphaned containers ---

echo "[devcontainer-wt] Checking for orphaned containers..."
containers=$(docker ps -a --filter "label=devcontainer-wt.project=${PROJECT_NAME}" \
  --format '{{.Names}}\t{{.Label "devcontainer-wt.worktree-dir"}}' 2>/dev/null) || true

if [[ -n "$containers" ]]; then
  while IFS=$'\t' read -r name worktree_dir; do
    [[ -z "$name" ]] && continue
    if [[ ! -d "$worktree_dir" ]]; then
      echo "[devcontainer-wt] Removing orphaned container: ${name}"
      docker rm -f "$name" 2>/dev/null || true
    fi
  done <<< "$containers"
fi

git worktree prune 2>/dev/null || true

echo "[devcontainer-wt] on-delete complete."
```

### Wiring Hooks to Worktree Tools

#### git-wt

Configure hooks via `git config`:

```bash
# On worktree creation: copy .worktreeinclude files
git config --add wt.hook ".worktree/hooks/on-create.sh"

# On worktree deletion: stop container, cleanup, prune orphans
git config --add wt.deletehook ".worktree/hooks/on-delete.sh"
```

#### wtp

See [wtp documentation](https://github.com/satococoa/wtp) for hook configuration.

#### Raw `git worktree`

Call hooks manually:

```bash
# Create
git worktree add ../myapp-feature-x -b feature-x
cd ../myapp-feature-x && .worktree/hooks/on-create.sh

# Delete
cd ../myapp-feature-x && .worktree/hooks/on-delete.sh
cd ../myapp && git worktree remove ../myapp-feature-x
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

### The Solution (Same-Path Volume Mount)

The template mounts the git common directory at the same absolute host path inside the container, so the `.git` file's host path references resolve directly:

1. **`init.sh` (host-side):** Resolves the main repo's `.git` directory path and writes it to `.env` as `GIT_COMMON_DIR`.

2. **`docker-compose.yml`:** Mounts the git common directory at the same absolute path:
   ```
   Host: /Users/you/projects/myapp/.git/  →  Container: /Users/you/projects/myapp/.git/
   ```

3. **Git resolves directly:** The `.git` file's host path now exists inside the container at the exact same path:
   ```
   .git file says:  gitdir: /Users/you/projects/myapp/.git/worktrees/feature-x
   Container has:   /Users/you/projects/myapp/.git/worktrees/feature-x  ✓
   ```

4. **`commondir` (no change needed):** Inside `.git/worktrees/feature-x/commondir`, the relative path `../..` still resolves correctly to the git common directory.

### Why Same-Path Mount

- **No post-start script needed.** Git works immediately when the container starts.
- **Never modifies any files.** The host's `.git` file stays untouched.
- **Transparent to all git tools.** Path resolution happens at the filesystem level.
- **Simpler architecture.** No symlink creation, no sudo, no verification step.

### Git Concurrency with Parallel Agents

Git worktrees are designed for parallel work on different branches. Each worktree has its own:
- Working tree (files)
- Index (staging area)
- HEAD (current commit)

The shared parts (objects, refs, packed-refs) use lock files for safe concurrent access. Since Docker bind mounts go through the host filesystem, lock files work correctly — the same as running multiple terminals on the host.

**Safe for parallel AI agents:** Each agent in its own worktree can commit, branch, and push independently. Repo-wide operations like `git gc` or `git repack` use exclusive locks and will fail with a lock error if another operation holds the lock (retry-safe, not data-corrupting).

Note: The back-pointer file (`.git/worktrees/feature-x/gitdir`) still contains the host path. This only affects `git worktree list` and `git worktree prune`, which are typically run on the host — not inside containers.

## Multi-Service Per Worktree

For projects with multiple services (frontend, backend, worker), define them all in `.devcontainer/docker-compose.yml`:

```yaml
services:
  frontend:
    build:
      context: ..
      dockerfile: .devcontainer/Dockerfile.frontend
    container_name: "frontend-${PROJECT_NAME}-${WORKTREE_NAME}"
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${PROJECT_NAME}-${WORKTREE_NAME}-web.rule=Host(`${BRANCH_NAME}.${PROJECT_NAME}.localhost`)"
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
      - "traefik.http.routers.${PROJECT_NAME}-${WORKTREE_NAME}-api.rule=Host(`api.${BRANCH_NAME}.${PROJECT_NAME}.localhost`)"
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

Each service gets its own Traefik route: the frontend at `feature-x.myapp.localhost` (branch name), the API at `api.feature-x.myapp.localhost`.

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

# 2. Start infrastructure on the host (no devcontainer needed)
docker compose up -d
# Traefik dashboard: http://traefik.myapp.localhost

# 3. (Recommended) Configure your worktree tool
# For git-wt:
git config --add wt.hook ".worktree/hooks/on-create.sh"
git config --add wt.deletehook ".worktree/hooks/on-delete.sh"

# 4. Open in VS Code and "Reopen in Container"
code .

# 5. Access via browser
#    http://main.myapp.localhost (or http://main.myapp.localhost:PORT if custom TRAEFIK_PORT)
```

### Create a Feature Worktree

```bash
# Using git-wt (recommended):
cd myapp
git wt feature-x
# → creates worktree, runs on-create.sh (copies .worktreeinclude files)

# Or using raw git worktree:
git worktree add ../myapp-feature-x -b feature-x
cd ../myapp-feature-x && .worktree/hooks/on-create.sh

# Open in VS Code and "Reopen in Container"
code ../myapp-feature-x

# Access via browser:
#   http://feature-x.myapp.localhost
```

Each worktree opens as a **separate VS Code window** with its own devcontainer. This is the intended UX — clean separation between worktrees.

### PR Review Flow

```bash
# Fetch and create worktree for the PR branch
cd myapp
git fetch origin
git wt feature-branch    # or: git worktree add ../myapp-pr-123 origin/feature-branch

# Open, test, review
code ../myapp-feature-branch
# Browser: http://feature-branch.myapp.localhost

# Cleanup when done
git wt -d feature-branch  # or manual: on-delete.sh + git worktree remove
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

#### Remove a worktree (git-wt)

```bash
git wt -d feature-x
# 1. Runs on-delete.sh (stops container, project-specific cleanup, prunes orphans)
# 2. Removes the worktree directory
# 3. Deletes the branch
```

#### Remove a worktree (manual)

```bash
cd ../myapp-feature-x
.worktree/hooks/on-delete.sh
cd ../myapp
git worktree remove ../myapp-feature-x
```

#### Cleanup hook

Project-specific cleanup goes in `.worktree/hooks/on-delete.sh`. Edit the "PROJECT-SPECIFIC CLEANUP" section. It receives project context from git and environment detection.

```bash
# Example: Drop per-worktree PostgreSQL database
docker exec "postgres-${PROJECT_NAME}" dropdb -U dev --if-exists "${PROJECT_NAME}_${WORKTREE_NAME}" 2>/dev/null || true
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
  # /etc/hosts (manual per branch)
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
- **Infrastructure must be started separately.** Run `docker compose up -d` from the project root before opening devcontainers. Infrastructure is decoupled from devcontainer lifecycle.
- **Name collision risk.** Branch name sanitization may cause collisions (e.g., `feature/login` and `feature-login` both become `feature-login`). Use distinct branch names.
- **GitHub Codespaces not supported.** Different constraints (no Traefik, no sibling worktrees). Out of scope.

## Open Questions

- **Compose V2 `.env` location.** Docker Compose V2 reads `.env` from the compose file's directory. Need to verify this works consistently when devcontainer CLI invokes compose.
- **Hot reload.** File watchers inside containers may need tuning (e.g. `inotify` limits on Linux, polling on macOS via Docker Desktop). This is a general devcontainer concern, not specific to worktrees.
- **Git worktree back-pointer.** The `.git/worktrees/{name}/gitdir` file contains the host path to the worktree. Since we mount the git common directory at the same host path, this resolves correctly inside the container.
- **`envsubst` availability.** The `init.sh` script uses `envsubst` to expand `.env.app.template`. This is available on most Linux systems (part of `gettext`) and on macOS via Homebrew. Need to verify availability or provide a fallback.
