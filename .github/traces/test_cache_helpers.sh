#!/usr/bin/env bash
# Functional regression test for the P3b cache helpers in utils.sh
# (_cache_target_vc/_cache_probe_apk/_cache_all_archs_present/_cache_touch_apks).
# The trace goldens don't exercise build_rv's cache section, so this covers it.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
# shellcheck disable=SC1091
source utils.sh >/dev/null 2>&1
apk_cache_dir=$(mktemp -d)
pkg_name="com.test"
declare -A args=([version_code]="" [cli_source]="")
cli_jar=""; patches_jar=""; cli_lv_extra=""
arch_list=(all)
fail() { echo "FAIL: $*"; rm -rf "$apk_cache_dir"; exit 1; }
mkdir -p "$apk_cache_dir"

: > "$apk_cache_dir/com.test-1.2.3-all.apk"
_cache_probe_apk 1.2.3 all || true
[[ "$_CACHE_CHECK_APK" == *"-1.2.3-all.apk" ]] || fail "probe all-variant"
_cache_all_archs_present 1.2.3 || fail "all_present single"
rm "$apk_cache_dir/com.test-1.2.3-all.apk"

: > "$apk_cache_dir/com.test-1.2.3-arm64-v8a.apk"
_cache_probe_apk 1.2.3 arm64-v8a || true
[[ "$_CACHE_CHECK_APK" == *"-1.2.3-arm64-v8a.apk" ]] || fail "probe stock"
_cache_probe_apk 1.2.3 arm-v7a || true
[[ -z "$_CACHE_CHECK_APK" ]] || fail "probe miss"
arch_list=(arm64-v8a arm-v7a)
_cache_all_archs_present 1.2.3 && fail "all_present should miss v7a"
arch_list=(all)

: > "$apk_cache_dir/com.test-1.2.3-all.apk"
_cache_all_archs_present 1.2.3 validate || fail "validate without vc target"

args[version_code]="123"
: > "$apk_cache_dir/com.test-1.2.3-123-all.apk"
_cache_probe_apk 1.2.3 all || true
[[ "$_CACHE_VC" == "123" ]] || fail "vc from mapping"
[[ "$_CACHE_CHECK_APK" == *"-1.2.3-123-all.apk" ]] || fail "vc filename preference"

args[version_code]=""
: > "$apk_cache_dir/com.test-2.0.0-all.apk"
_cache_probe_apk 2.0.0 all || true
[[ "$_CACHE_CHECK_APK" == *"-2.0.0-all.apk" ]] || fail "legacy fallback"

: > "$apk_cache_dir/com.test-3.0.0-all.apk"; touch -d "2020-01-01" "$apk_cache_dir/com.test-3.0.0-all.apk"
_cache_touch_apks 3.0.0 all
[[ $(find "$apk_cache_dir/com.test-3.0.0-all.apk" -newermt "2021-01-01") ]] || fail "touch refresh"

rm -rf "$apk_cache_dir"
echo "CACHE HELPER TESTS: PASS"
