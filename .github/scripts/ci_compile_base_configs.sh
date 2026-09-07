#!/bin/bash
set -euo pipefail

echo "--- Compiling base patch configs (JSON) ---"
python3 .github/scripts/compile_patch_configs.py

