#!/usr/bin/env bash
# Run test.sh inside WSL, from Git Bash on Windows.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "$SCRIPT_DIR" == /c/* ]]; then
    WSL_PATH="/mnt${SCRIPT_DIR}"
elif [[ "$SCRIPT_DIR" == C:* ]] || [[ "$SCRIPT_DIR" == c:* ]]; then
    WSL_PATH=$(echo "$SCRIPT_DIR" | sed 's|^[Cc]:|/mnt/c|' | sed 's|\\|/|g')
else
    WSL_PATH="$SCRIPT_DIR"
fi

echo "Running tests in WSL..."
echo "Path: $WSL_PATH"
echo ""

# ireed is the WSL user with Nix installed.
wsl.exe -u ireed bash -lc "cd '$WSL_PATH' && ./test.sh"
