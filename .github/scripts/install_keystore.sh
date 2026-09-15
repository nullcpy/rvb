#!/usr/bin/env bash
set -euo pipefail

# Materialize signing keystore from CI secrets, overriding the upstream
# ks.keystore / ks-p12.keystore committed in the repo. Each secret is
# independent; unset = keep the repo default (byte-identical pre-cutover).
#
# KEYSTORE_B64        base64 of the BKS keystore passed to patch CLIs (ks.keystore)
# KEYSTORE_P12_B64    base64 of the PKCS12 keystore used by apksigner (ks-p12.keystore)
# KEYSTORE_PASSWORD   password for both (engine has a single pass var)
# KEY_ALIAS           key alias for both

if [ -z "${KEYSTORE_B64:-}" ] && [ -z "${KEYSTORE_P12_B64:-}" ]; then
  echo "No KEYSTORE_B64/KEYSTORE_P12_B64 secrets — using repo keystores."
  exit 0
fi

if [ -z "${KEYSTORE_PASSWORD:-}" ] || [ -z "${KEY_ALIAS:-}" ]; then
  echo "::error::KEYSTORE_B64/KEYSTORE_P12_B64 are set but KEYSTORE_PASSWORD or KEY_ALIAS are missing." >&2
  exit 1
fi

if [ -n "${KEYSTORE_B64:-}" ]; then
  printf '%s' "$KEYSTORE_B64" | base64 -d > ks.keystore
  echo "Installed custom ks.keystore ($(stat -c%s ks.keystore) bytes)."
fi
if [ -n "${KEYSTORE_P12_B64:-}" ]; then
  printf '%s' "$KEYSTORE_P12_B64" | base64 -d > ks-p12.keystore
  echo "Installed custom ks-p12.keystore ($(stat -c%s ks-p12.keystore) bytes)."
fi

{
  echo "RVB_KEYSTORE_PASS=$KEYSTORE_PASSWORD"
  echo "RVB_KEY_ALIAS=$KEY_ALIAS"
} >> "$GITHUB_ENV"
echo "Signing identity exported (alias: $KEY_ALIAS)."
