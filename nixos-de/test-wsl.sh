#!/usr/bin/env bash
# Run NixOS config tests via WSL from Git Bash
# Usage: ./test-wsl.sh

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Convert Windows/MINGW path to WSL path
if [[ "$SCRIPT_DIR" == /c/* ]]; then
    # Git Bash style: /c/Users/... -> /mnt/c/Users/...
    WSL_PATH="/mnt${SCRIPT_DIR}"
elif [[ "$SCRIPT_DIR" == C:* ]] || [[ "$SCRIPT_DIR" == c:* ]]; then
    # Windows style: C:\Users\... -> /mnt/c/Users/...
    WSL_PATH=$(echo "$SCRIPT_DIR" | sed 's|^[Cc]:|/mnt/c|' | sed 's|\\|/|g')
else
    # Already a Unix-style path or unknown format
    WSL_PATH="$SCRIPT_DIR"
fi

echo "Running tests in WSL..."
echo "Path: $WSL_PATH"
echo ""

# Run the test script in WSL as user ireed (where Nix is installed)
wsl.exe -u ireed bash -lc "cd '$WSL_PATH' && ./test.sh"
