FROM mcr.microsoft.com/devcontainers/base:ubuntu

# Install postgresql-client for per-worktree DB creation
RUN apt-get update && apt-get install -y postgresql-client && rm -rf /var/lib/apt/lists/*
