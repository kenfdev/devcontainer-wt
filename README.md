# devcontainer-wt

Seamless devcontainer + git worktree workflows. Run multiple feature branches simultaneously, each in its own isolated devcontainer with its own database, routed via Traefik subdomains.

## What You Get

- **Git works inside containers** -- worktree `.git` file resolution is fixed automatically via symlink (no file mutation).
- **No port conflicts** -- Traefik routes by subdomain, so every worktree container can listen on the same internal port.
- **Per-worktree database** -- each worktree gets its own database, created automatically on startup.
- **Per-worktree env vars** -- `.env.app.template` is expanded per worktree with `${WORKTREE_NAME}`, `${PROJECT_NAME}`, etc.
- **Orphan detection** -- stale containers from deleted worktrees are detected on every startup.

## Install

Run this from your project's root directory:

```bash
curl -fsSL https://raw.githubusercontent.com/kenfdev/devcontainer-wt/main/install.sh | bash
```

The installer will:
- Download the template files from GitHub
- Set up `.devcontainer/` with all required configuration
- Prompt to backup if `.devcontainer/` already exists
- Optionally install AI skill files for agent-assisted customization

After installing, see **[CUSTOMIZING.md](.agents/skills/devcontainer-wt/references/CUSTOMIZING.md)** for which files to edit and which to leave alone.

## URL Pattern

All URLs follow this pattern:

```
http://{WORKTREE_NAME}.{PROJECT_NAME}.localhost
```

- **`PROJECT_NAME`** = your main repo's directory name (e.g., if you cloned into `myapp/`, the project name is `myapp`).
- **`WORKTREE_NAME`** = the worktree's directory name (e.g., `myapp` for the main worktree, `myapp-feature-x` for a worktree).

For example, if you clone the repo into a directory called `myapp`:

| What | URL |
|---|---|
| Main worktree app | `http://myapp.myapp.localhost` |
| Feature worktree `myapp-feature-x` | `http://myapp-feature-x.myapp.localhost` |
| Traefik dashboard | `http://traefik.myapp.localhost` |

> **Tip:** After the container starts, check `.devcontainer/.env` to see the resolved values for `PROJECT_NAME` and `WORKTREE_NAME`. These determine your URLs.

## Prerequisites

| Requirement | Notes |
|---|---|
| **Docker Desktop** (macOS) or **Docker Engine** (Linux) | Must be running before you start. |
| **VS Code** + **Dev Containers extension** | Install [ms-vscode-remote.remote-containers](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers). |
| **git** | Any recent version with worktree support. |
| **envsubst** | Pre-installed on most Linux. On macOS: `brew install gettext`. |

## Directory Structure

```
myapp/                              # <-- you are here (main worktree)
  .git/                             # git database (directory)
  .devcontainer/
    devcontainer.json               # devcontainer configuration
    docker-compose.yml              # per-worktree app service
    docker-compose.infra.yml        # shared infra (Traefik, Postgres) -- profiles-gated
    Dockerfile                      # container image
    init.sh                         # host-side init script
    hooks/
      post-start.sh                 # in-container setup script
    .env                            # generated (gitignored)
    .env.app                        # generated (gitignored)
  .env.app.template                 # per-worktree env var template (tracked)
  package.json
  src/
    server.js                       # sample app

myapp-feature-x/                    # worktree (sibling directory)
  .git                              # file pointing to ../myapp/.git/worktrees/feature-x
  .devcontainer/                    # same files (tracked in git)
  src/                              # same code, different branch
```

## Step 1: Clone and Open the Main Worktree

The main worktree **must be started first**. It runs the shared infrastructure (Traefik, Postgres).

```bash
# Clone the repo (the directory name becomes your PROJECT_NAME)
git clone <your-repo-url> myapp
cd myapp
```

Open the folder in VS Code:

```bash
code .
```

VS Code will detect `.devcontainer/devcontainer.json` and show a notification:

> **Folder contains a Dev Container configuration file.** Reopen folder to develop in a container.

Click **"Reopen in Container"** (or run the command palette: `Dev Containers: Reopen in Container`).

### What Happens Behind the Scenes

1. **`init.sh` runs on the host** (via `initializeCommand`):
   - Detects this is the main worktree (`.git` is a directory).
   - Derives `PROJECT_NAME` from the directory name (e.g., `myapp`).
   - Sets `WORKTREE_NAME` to the directory name (e.g., `myapp`).
   - Writes all resolved values to `.devcontainer/.env`.
   - Sets `COMPOSE_PROFILES=infra` so Traefik (and any infrastructure services you've added) start.
   - Creates Docker network `devnet-{PROJECT_NAME}`.
   - Expands `.env.app.template` into `.devcontainer/.env.app`.

2. **Docker Compose brings up containers**:
   - `traefik-{PROJECT_NAME}` -- reverse proxy on port 80 (configurable).
   - Any infrastructure services you've added (Postgres, Redis, etc.).
   - `app-{PROJECT_NAME}-{WORKTREE_NAME}` -- your app container.

3. **`post-start.sh` runs inside the container** (via `postStartCommand`):
   - Applies the git worktree symlink fix (for worktree containers).
   - Runs your project setup (dependency installation, DB init, migrations, dev server -- see [CUSTOMIZING.md](CUSTOMIZING.md)).

### Verify It Works

First, check the generated values:

```bash
cat .devcontainer/.env
# Look for PROJECT_NAME and WORKTREE_NAME -- these determine your URLs.
```

Then open your browser. Assuming you cloned into `myapp/`:

| URL | What It Shows |
|---|---|
| http://myapp.myapp.localhost | Your app (main worktree) |
| http://traefik.myapp.localhost | Traefik dashboard (shows all routes) |

If you've set up a dev server in `post-start.sh`, your app should be reachable. The sample app shows project/worktree info.

> **Note (macOS):** `*.localhost` resolves to `127.0.0.1` out of the box. No `/etc/hosts` changes needed.
>
> **Note (Linux):** If subdomains don't resolve, see [Platform Notes: Linux](#linux-native-docker).

## Step 2: Create a Feature Worktree

With the main worktree running, create a new worktree from the **host terminal** (not inside the container):

```bash
# From the main repo directory
cd myapp

# Create a worktree in a sibling directory with a new branch
git worktree add ../myapp-feature-x -b feature-x
```

This creates `myapp-feature-x/` next to `myapp/` with a `.git` **file** (not directory) pointing back to the main repo's git database.

Now open it in VS Code:

```bash
code ../myapp-feature-x
```

Click **"Reopen in Container"** again.

### What Happens This Time

1. **`init.sh` runs on the host**:
   - Detects this is a worktree (`.git` is a file, not a directory).
   - Sets `PROJECT_NAME=myapp` (derived from the main repo, not the worktree directory).
   - Sets `WORKTREE_NAME=myapp-feature-x` (from the worktree directory name).
   - Does **not** set `COMPOSE_PROFILES=infra` -- infrastructure services are NOT started again.
   - Joins the existing `devnet-myapp` network.

2. **Only the app container starts**: `app-myapp-myapp-feature-x`.

3. **`post-start.sh` runs inside the container**:
   - **Creates a symlink** so the host path in `.git` resolves inside the container. This is the key worktree fix -- git commands (`log`, `blame`, `status`, `commit`) now work.
   - Runs your project setup (same as the main worktree).

### Verify the Feature Worktree

| URL | What It Shows |
|---|---|
| http://myapp-feature-x.myapp.localhost | Your app (feature-x worktree) |

Check the Traefik dashboard at `http://traefik.myapp.localhost` -- you should see routes for both worktrees.

### Verify Git Works Inside the Container

Open a terminal inside the feature worktree's VS Code window and run:

```bash
git status
git log --oneline -5
git branch
```

All commands should work normally, even though this is a worktree inside a container.

## Step 3: Work on Multiple Worktrees Simultaneously

Repeat Step 2 for as many branches as you need:

```bash
# Another feature
git worktree add ../myapp-feature-y -b feature-y
code ../myapp-feature-y

# PR review
git fetch origin
git worktree add ../myapp-pr-42 origin/some-pr-branch
code ../myapp-pr-42
```

Each one gets:
- Its own VS Code window and devcontainer.
- Its own Traefik route: `http://myapp-feature-y.myapp.localhost`, `http://myapp-pr-42.myapp.localhost`.
- Its own database (if you've configured one).
- Full git support inside the container.

## Step 4: Clean Up a Worktree

Just use standard git:

```bash
git worktree remove ../myapp-feature-x
```

`git worktree remove` will refuse to delete if there are uncommitted changes (use `--force` to override).

The orphaned container is automatically cleaned up the next time **any** worktree's devcontainer starts -- `init.sh` detects containers whose worktree directory no longer exists and removes them.

> **Note:** Per-worktree databases are **not** automatically deleted. If you've set up a database, drop it manually (e.g., `docker exec -it postgres-myapp psql -U dev -c "DROP DATABASE IF EXISTS myapp_feature_x;"`).

## Customization

### Change the Traefik Port

If port 80 is in use, set `TRAEFIK_PORT` before opening the main worktree:

```bash
export TRAEFIK_PORT=8000
code myapp
```

Then access your app at `http://{WORKTREE_NAME}.{PROJECT_NAME}.localhost:8000`.

### Change the Postgres Host Port

```bash
export POSTGRES_HOST_PORT=25432
```

The default is `15432` to avoid conflicts with a host Postgres on `5432`.

### Override the Project Name

By default, the project name is derived from the main repo's directory name. Override it:

```bash
export PROJECT_NAME=my-custom-name
```

This changes all routes (`*.my-custom-name.localhost`), container names, database names, and the Docker network name.

### Add Environment Variables

Edit `.env.app.template` (tracked in git) to add per-worktree variables:

```bash
DATABASE_URL=postgres://dev:dev@postgres-${PROJECT_NAME}:5432/${PROJECT_NAME}_${WORKTREE_NAME}
REDIS_URL=redis://redis-${PROJECT_NAME}:6379/0
APP_NAME=${PROJECT_NAME}-${WORKTREE_NAME}
MY_SECRET=${MY_SECRET}  # reads from host env var
```

Each worktree's `init.sh` expands this into `.devcontainer/.env.app` (gitignored).

### Add Infrastructure Services

Edit `.devcontainer/docker-compose.infra.yml` to add services under the `infra` profile. For example, to add Redis:

```yaml
  redis:
    profiles: [infra]
    image: redis:7-alpine
    container_name: "redis-${PROJECT_NAME}"
    networks:
      - devnet
    restart: unless-stopped
```

### Change the App Port

If your app listens on a port other than 3000, update the Traefik label in `.devcontainer/docker-compose.yml`:

```yaml
- "traefik.http.services.${PROJECT_NAME}-${WORKTREE_NAME}.loadbalancer.server.port=4000"
```

### Headless Usage (devcontainer CLI / AI Agents)

The template works without VS Code. All lifecycle hooks run the same way:

```bash
# Start a worktree container
devcontainer up --workspace-folder ../myapp-feature-x

# Run commands inside
devcontainer exec --workspace-folder ../myapp-feature-x bash
```

For git authentication, set `GITHUB_TOKEN` on the host:

```bash
export GITHUB_TOKEN=ghp_xxx
devcontainer up --workspace-folder ../myapp-feature-x
```

## How It Works

### The Git Worktree Problem

A git worktree's `.git` is a **file** containing an absolute host path:

```
gitdir: /Users/you/myapp/.git/worktrees/feature-x
```

When mounted into a container at `/workspaces/myapp-feature-x`, this host path doesn't exist. All git commands fail.

### The Symlink Fix

Instead of rewriting the `.git` file (which would mutate the bind-mounted file and break host-side git), `post-start.sh` creates a symlink:

```
/Users/you/myapp/.git  -->  /workspaces/myapp/.git  (symlink)
```

Now when git reads the `.git` file and follows `/Users/you/myapp/.git/worktrees/feature-x`, the symlink transparently redirects it to `/workspaces/myapp/.git/worktrees/feature-x`, which exists because `docker-compose.yml` mounts the git common directory there.

The `.git` file is **never modified**. The host is unaffected.

### Infrastructure Isolation

- **Main worktree** starts with `COMPOSE_PROFILES=infra`, which activates Traefik and Postgres.
- **Feature worktrees** do not set this profile, so they only start the app container.
- All containers join the same Docker network (`devnet-{PROJECT_NAME}`), so they can reach each other by container name.
- Traefik auto-discovers app containers via Docker labels and routes traffic by subdomain.

## Architecture

```
  Browser
    |
    v
  Traefik (port 80)
    |
    |-- {WORKTREE}.{PROJECT}.localhost  --> app-{PROJECT}-{WORKTREE}:3000
    |-- traefik.{PROJECT}.localhost     --> Traefik dashboard
    |
  Docker Network: devnet-{PROJECT}
    |
    |-- postgres-{PROJECT}:5432
    |     |-- DB: {PROJECT}_{WORKTREE_1}
    |     |-- DB: {PROJECT}_{WORKTREE_2}
    |
    |-- app-{PROJECT}-{WORKTREE_1}   (main worktree container)
    |-- app-{PROJECT}-{WORKTREE_2}   (feature worktree container)
```

## Platform Notes

### macOS (Docker Desktop)

- `*.localhost` resolves to `127.0.0.1` by default. No configuration needed.
- Chrome works out of the box. Firefox may require `about:config` -> set `network.dns.localDomains` to include your subdomains, or use `/etc/hosts`.

### Linux (Native Docker)

`*.localhost` wildcard resolution may not work. Two options:

**Option A: `/etc/hosts` (manual, per worktree)**

```
127.0.0.1 myapp.myapp.localhost
127.0.0.1 myapp-feature-x.myapp.localhost
127.0.0.1 traefik.myapp.localhost
```

**Option B: `dnsmasq` (automatic wildcard)**

```
# /etc/dnsmasq.d/localhost.conf
address=/localhost/127.0.0.1
```

## Troubleshooting

### "Reopen in Container" does nothing or fails immediately

Check that Docker Desktop is running:
```bash
docker ps
```

### App not reachable at `*.localhost`

1. Check your actual URLs: `cat .devcontainer/.env` to see `PROJECT_NAME` and `WORKTREE_NAME`.
2. Check Traefik is running: `docker ps | grep traefik`
3. Check the Traefik dashboard: `http://traefik.{PROJECT_NAME}.localhost`
4. Test with curl: `curl -H "Host: {WORKTREE}.{PROJECT}.localhost" http://localhost/`
5. On Linux, check DNS resolution (see [Platform Notes](#linux-native-docker)).

### Git commands fail inside a worktree container

Check if the symlink was created:
```bash
# Inside the container
ls -la /Users/  # should see your host path structure
```

Check `post-start.sh` output in the VS Code terminal panel.

### Database connection refused

The main worktree must be running (it hosts Postgres). Check:
```bash
docker ps | grep postgres
```

### Port 80 already in use

Set a custom Traefik port before starting:
```bash
export TRAEFIK_PORT=8000
```

Then access apps at `http://{WORKTREE}.{PROJECT}.localhost:8000`.

### `envsubst: command not found` (macOS)

```bash
brew install gettext
```

`envsubst` is included in the `gettext` package.

## Limitations

- **Main worktree must start first.** Infrastructure services (Traefik, Postgres) only run from the main worktree.
- **Docker Compose only.** The template requires Docker Compose as the devcontainer backend.
- **Name collisions.** Branch names like `feature/login` and `feature-login` both sanitize to `feature_login`. Use distinct directory names.
- **GitHub Codespaces not supported.** Different constraints (no Traefik, no sibling worktrees).
