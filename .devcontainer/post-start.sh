#!/usr/bin/env bash
set -euo pipefail

workspace_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$workspace_dir"

echo "Starting Docker Compose services..."
docker compose up -d

echo
echo "LiteLLM UI is available at: http://localhost:4000/ui"
echo "  login with username: admin and password: AdminIzK1ng" 
echo