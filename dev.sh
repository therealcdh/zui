#!/usr/bin/env bash
# dev.sh - Run ZUI server from source directory using the flake devShell

# Get the absolute path of the project root
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export ZUI_FRONTEND_PATH="$PROJECT_ROOT/frontend"
export ZUI_INSTALLER_PATH="$PROJECT_ROOT/src/install.sh"

echo "Starting ZUI from: $PROJECT_ROOT"
echo "Frontend: $ZUI_FRONTEND_PATH"
echo "Installer: $ZUI_INSTALLER_PATH"

# Diagnostic check
nix develop --command bash -c "which zpool || echo 'WARNING: zpool command not found in nix develop environment'"

cd "$PROJECT_ROOT/src"
# Use 'nix develop' to ensure we have the exact environment from flake.nix
nix develop --command bash -c "go run main.go"
