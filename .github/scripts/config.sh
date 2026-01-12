#!/bin/bash
# Shared configuration for all workflow scripts
# Edit these values in one place to apply changes across all workflows

# Telegram Configuration
export TG_CHAT="@rvb27"
export TG_CHANNEL="@rvb28"
export TG_THREAD_ID_PRERELEASE="350"
export TG_THREAD_ID_STABLE="262"
export TG_THREAD_ID_PATCH_DETECTION="345"
export TG_THREAD_ID_GITHUB_RELEASES="267"

# Build Configuration
export BUILD_DIR="build"
export MAX_BUILDS=100
export MAX_MSG_LENGTH=9450

# BuzzHeavier Configuration
export BUZZHEAVIER_PARENT_ID="qapeaw1yzy6m"

# Filebin Configuration
export FILEBIN_URL="https://filebin.net"
export FILEBIN_CONNECT_TIMEOUT=30
export FILEBIN_MAX_TIMEOUT=300

# Mirrors Configuration
export MIRRORS_DIR=".github/pages"
export MIRRORS_FILE="$MIRRORS_DIR/mirrors.md"

# Config Files Paths
export CONFIGS_DIR=".github/configs"
export PATCH_SOURCES_FILE="$CONFIGS_DIR/patch_sources.json"
export REPOS_JSON_FILE="$CONFIGS_DIR/repos.json"
export APK_TIMESTAMPS_FILE="$CONFIGS_DIR/apk_timestamps.json"
export CURRENT_APKS_FILE="$CONFIGS_DIR/current_apks.json"
export CONFIG_MANUAL_TOML="$CONFIGS_DIR/config.manual.toml"
export CONFIG_STABLE_UPDATED="$CONFIGS_DIR/config.stable.updated.toml"
export CONFIG_DEV_UPDATED="$CONFIGS_DIR/config.dev.updated.toml"
export ACTIVE_STABLE_TXT="$CONFIGS_DIR/active.stable.txt"
export ACTIVE_PRERELEASE_TXT="$CONFIGS_DIR/active.prerelease.txt"
