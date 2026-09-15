#!/usr/bin/env bash
# Trace harness: exercises the tool-decision functions of utils.sh for one
# fixture config per patcher kind, with stubbed curl/java (no network, no real
# patching). The golden trace (ARGS records + result markers) is the
# regression gate for the P1 patcher-registry refactor: after restructuring,
# "verify" here must match goldens byte-for-byte.
#
# Covered functions (the ~25 branch-site surface):
#   _get_prebuilts (cli+bundle asset filtering, download, tag_name),
#   _patches_list_versions, _patches_list, has_compatible_patches, patch_apk.
# Not executed (documented in README): the exp-version guard and the module
# --mount decision inside build_rv — the P1 author must diff those by eye.
set -uo pipefail

RVB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TRACES_DIR="$RVB_ROOT/.github/traces"
RUN_ROOT="${RUN_ROOT:-$RVB_ROOT/temp/trace_run}"
MODE="${1:-capture}"   # capture | verify
shift 2>/dev/null || true
FIXTURES=("${@:-}")

rm -rf "$RUN_ROOT"
mkdir -p "$RUN_ROOT/out" "$RUN_ROOT/bin"
for s in curl java; do
	tr -d '\r' < "$TRACES_DIR/stubs/$s" > "$RUN_ROOT/bin/$s"
	chmod +x "$RUN_ROOT/bin/$s"
done
export PATH="$RUN_ROOT/bin:$PATH"
export TRACE_FIXTURES="$TRACES_DIR/fixtures"
export GITHUB_TOKEN="trace-dummy-token"
export NEXT_VER_CODE="000000"
export GITHUB_REPOSITORY=""
# utils.sh is sourced via process substitution, so its own BASH_SOURCE path
# lookup for the patcher registry can't work; point it explicitly.
export RVB_PATCHERS_SH="$RVB_ROOT/.github/scripts/patchers.sh"
# normally set by build.sh before get_prebuilts; harness defaults to the common config
export REMOVE_RV_INTEGRATIONS_CHECKS="${REMOVE_RV_INTEGRATIONS_CHECKS:-false}"

cd "$RUN_ROOT"
# Windows checkouts carry CRLF working copies; strip CR so WSL/bash can source
# shellcheck disable=SC1091
source <(tr -d '\r' < "$RVB_ROOT/utils.sh") 2>/dev/null || { echo "FATAL: sourcing utils.sh failed"; exit 1; }

if [ ${#FIXTURES[@]} -eq 0 ] || [ -z "${FIXTURES[0]:-}" ]; then
	FIXTURES=("$TRACES_DIR"/fixtures/configs/*.toml)
fi

overall=0
for fx in "${FIXTURES[@]}"; do
	name=$(basename "$fx" .toml)
	run_dir="$RUN_ROOT/runs/$name"
	rm -rf "$run_dir"; mkdir -p "$run_dir/temp"
	(
		cd "$run_dir"
		export TRACE_OUT="$run_dir/rvb_trace.txt"
		# utils.sh wraps java as `env -i PATH HOME LANG java ...`; the stub
		# recovers its trace path via HOME, so point HOME at the run dir.
		export HOME="$run_dir"
		: > "$TRACE_OUT"
		printf 'FAKE-STOCK\n' > "$run_dir/stock.apk"

		echo "=== FIXTURE: $name ==="
		toml_prep "$fx" || { echo "RESULT: toml_prep failed"; exit 0; }
		m=$(toml_get_table_main)
		cli_src=$(toml_get "$m" cli-source) || cli_src="MorpheApp/morphe-desktop"
		cli_ver=$(toml_get "$m" cli-version) || cli_ver="stable"
		pt_src=$(toml_get "$m" patches-source) || pt_src="MorpheApp/morphe-patches"
		pt_ver=$(toml_get "$m" patches-version) || pt_ver="stable"

		# resolve prebuilts through the real path (stubbed network)
		PREBUILTS=$(get_prebuilts github "$cli_src" "$cli_ver" github "$pt_src" "$pt_ver") \
			|| { echo "RESULT: get_prebuilts failed"; exit 0; }
		read -r cli_jar patches_jar_all <<< "$PREBUILTS"
		echo "PREBUILT CLI: $cli_jar"
		echo "PREBUILT BUNDLES: $patches_jar_all"

		# iterate app tables
		for tn in $(toml_get_table_names); do
			[ -z "$tn" ] && continue
			t=$(toml_get_table "$tn")
			enabled=$(toml_get "$t" enabled) || enabled=true
			[ "$enabled" = false ] && continue
			pkg=$(toml_get "$t" pkg-name) || pkg="$tn"
			version=$(toml_get "$t" version) || version="1.95.101"
			echo "--- app: $tn ---"
			echo "PATCHES_LIST_VERSIONS:"
			_patches_list_versions "$cli_jar" "$patches_jar_all" "$pkg" "$cli_src" "" | sed 's/^/  /'
			echo "HAS_COMPATIBLE_PATCHES(hit): rc=$(has_compatible_patches "$cli_jar" "$patches_jar_all" "$pkg" "1.95.101" "$cli_src" && echo 0 || echo 1)"
			echo "HAS_COMPATIBLE_PATCHES(miss): rc=$(has_compatible_patches "$cli_jar" "$patches_jar_all" "$pkg" "9.9.9" "$cli_src" && echo 0 || echo 1)"
			echo "PATCHES_LIST:"
			_patches_list "$cli_jar" "$patches_jar_all" "$pkg" "$cli_src" | sed 's/^/  /'

			pargs=$(toml_get "$t" patcher-args) || pargs=""
			inc=$(toml_get "$t" included-patches) || inc=""
			exc=$(toml_get "$t" excluded-patches) || exc=""
			# Emulate build_rv's per-bundle ed string with the engine's own
			# helpers (utils.sh join_args/list_args), bundles joined by '|'.
			per_bundle_ed=""
			ed=""
			[ -n "$exc" ] && ed+=" $(join_args "$exc" -d)"
			[ -n "$inc" ] && ed+=" $(join_args "$inc" -e)"
			if [ -n "$ed" ]; then
				n_bundles=$(echo "$patches_jar_all" | wc -w)
				for ((bi=0; bi<n_bundles; bi++)); do
					[ $bi -gt 0 ] && per_bundle_ed+="|"
					per_bundle_ed+="$ed"
				done
			fi
			echo "PATCH_APK:"
			mkdir -p "$run_dir/build"
			patch_apk "stock.apk" "build/out-$tn.apk" "$pargs" \
				"$cli_jar" "$patches_jar_all" "$cli_src" "$per_bundle_ed" >/dev/null 2>&1
			echo "  rc=$? patched_exists=$([ -f "$run_dir/build/out-$tn.apk" ] && echo yes || echo no)"
			# instafel/npatch flows produce output via recovery, not -o; check
			# that some apk materialized, proving the branch ran end-to-end.
		done
	) > "$RUN_ROOT/out/$name.stdout" 2>&1
	cat "$RUN_ROOT/out/$name.stdout" > "$RUN_ROOT/$name.trace"
	cat "$RUN_ROOT/runs/$name/rvb_trace.txt" >> "$RUN_ROOT/$name.trace" 2>/dev/null
done

# normalization: strip run-root absolute paths, tempdir noise, ANSI colors
for f in "$RUN_ROOT"/*.trace; do
	[ -f "$f" ] || continue
	sed -i -E \
		-e "s|\x1b\[[0-9;]*m||g" \
		-e "s|$RUN_ROOT|<RUN>|g" \
		-e "s|/dev/fd/[0-9]+|<SRC>|g" \
		-e "s|/tmp/[^ ]*|<TMP>|g" \
		"$f"
done

mkdir -p "$TRACES_DIR/goldens"
if [ "$MODE" = capture ]; then
	cp "$RUN_ROOT"/*.trace "$TRACES_DIR/goldens/" 2>/dev/null
	echo "Captured goldens:"; ls -1 "$TRACES_DIR/goldens/"
else
	fail=0
	for f in "$RUN_ROOT"/*.trace; do
		b=$(basename "$f")
		if ! cmp -s "$f" "$TRACES_DIR/goldens/$b"; then
			echo "MISMATCH: $b"
			diff "$TRACES_DIR/goldens/$b" "$f" | head -20
			fail=1
		fi
	done
	[ $fail -eq 0 ] && echo "ALL GOLDEN TRACES MATCH"
	exit $fail
fi
