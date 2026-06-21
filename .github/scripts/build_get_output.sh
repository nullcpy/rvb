#!/bin/bash
set -euo pipefail
DELIM="$(openssl rand -hex 8)"
echo "BUILD_LOG<<${DELIM}" >> "$GITHUB_OUTPUT"
cat build.md >> "$GITHUB_OUTPUT"
echo "${DELIM}" >> "$GITHUB_OUTPUT"
cp -f build.md build.tmp
