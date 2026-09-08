#!/usr/bin/env bash

set -euo pipefail
shopt -s nullglob

source utils.sh
echo '{}' > "$BUILD_JSON_FILE"

trap "abort" INT

if [ "${1-}" = "clean" ]; then
	rm -r "$TEMP_DIR" "$BUILD_DIR" build.md
	exit 0
fi

jq --version >/dev/null || abort "\`jq\` is not installed. install it with 'apt install jq' or equivalent"
java --version >/dev/null || abort "\`java\` is not installed. install it with 'apt install openjdk-21-jre' or equivalent"
zip --version >/dev/null || abort "\`zip\` is not installed. install it with 'apt install zip' or equivalent"

set_prebuilts

vtf() { if ! isoneof "${1}" "true" "false"; then abort "ERROR: '${1}' is not a valid option for '${2}': only true or false is allowed"; fi; }

# -- Main config --
toml_prep "${1:-config.toml}" || abort "could not find config file '${1:-config.toml}'\n\tUsage: $0 <config.toml>"
main_config_t=$(toml_get_table_main)
COMPRESSION_LEVEL=$(toml_get "$main_config_t" compression-level) || COMPRESSION_LEVEL="9"
REMOVE_RV_INTEGRATIONS_CHECKS=$(toml_get "$main_config_t" remove-rv-integrations-checks) || REMOVE_RV_INTEGRATIONS_CHECKS="false"
DEF_PATCHES_VER=$(toml_get "$main_config_t" patches-version) || DEF_PATCHES_VER="stable"
[ "$DEF_PATCHES_VER" = "both" ] && { if [[ "${1:-}" == *"beta"* ]] || [[ "${1:-}" == *"dev"* ]]; then DEF_PATCHES_VER="beta"; else DEF_PATCHES_VER="stable"; fi; }
DEF_CLI_VER=$(toml_get "$main_config_t" cli-version) || DEF_CLI_VER="stable"
DEF_PATCHES_SRC=$(toml_get "$main_config_t" patches-source) || DEF_PATCHES_SRC="MorpheApp/morphe-patches"
DEF_PATCHES_SRC_HOST=$(toml_get "$main_config_t" patches-source-host) || DEF_PATCHES_SRC_HOST="github"
DEF_CLI_SRC=$(toml_get "$main_config_t" cli-source) || DEF_CLI_SRC="MorpheApp/morphe-desktop"
DEF_BRAND=$(toml_get "$main_config_t" brand) || DEF_BRAND=""
DEF_DPI=$(toml_get "$main_config_t" dpi) || DEF_DPI="nodpi anydpi auto"
DEF_ARCH=$(toml_get "$main_config_t" arch) || DEF_ARCH="both"
DEF_BUILD_MODE=$(toml_get "$main_config_t" build-mode) || DEF_BUILD_MODE="apk"
DEF_AUTHOR_NAME=$(toml_get "$main_config_t" author) || DEF_AUTHOR_NAME="nullcpy"
DEF_AUTHOR_PAGE=$(toml_get "$main_config_t" author-page) || DEF_AUTHOR_PAGE="github.com/nullcpy/rvb"
mkdir -p "$TEMP_DIR" "$BUILD_DIR"

: >build.md
ENABLE_MODULE_UPDATE=$(toml_get "$main_config_t" enable-module-update) || ENABLE_MODULE_UPDATE=true
if [ "$ENABLE_MODULE_UPDATE" = true ] && [ -z "${GITHUB_REPOSITORY-}" ]; then
	pr "You are building locally. Module updates will not be enabled."
	ENABLE_MODULE_UPDATE=false
fi
if ((COMPRESSION_LEVEL > 9)) || ((COMPRESSION_LEVEL < 0)); then abort "compression-level must be within 0-9"; fi

rm -rf module/bin/*/tmp.*
for file in "$TEMP_DIR"/*/changelog.md; do
	[ -f "$file" ] && : >"$file"
done

mkdir -p ${MODULE_TEMPLATE_DIR}/bin/arm64 ${MODULE_TEMPLATE_DIR}/bin/arm ${MODULE_TEMPLATE_DIR}/bin/x86 ${MODULE_TEMPLATE_DIR}/bin/x64
echo "${DEF_AUTHOR_NAME}${DEF_AUTHOR_PAGE:+ ($DEF_AUTHOR_PAGE)}" > "${MODULE_TEMPLATE_DIR}/maintainer.txt"

for table_name in $(toml_get_table_names); do
	if [ -z "$table_name" ]; then continue; fi
	t=$(toml_get_table "$table_name")
	enabled=$(toml_get "$t" enabled) || enabled=true
	vtf "$enabled" "enabled"
	if [ "$enabled" = false ]; then continue; fi

	declare -A app_args
	patches_src=$(toml_get "$t" patches-source) || patches_src=$DEF_PATCHES_SRC
	patches_src_host=$(toml_get "$t" patches-source-host) || patches_src_host=$DEF_PATCHES_SRC_HOST
	patches_ver=$(toml_get "$t" patches-version) || patches_ver=$DEF_PATCHES_VER
	[ "$patches_ver" = "both" ] && { if [[ "${1:-}" == *"beta"* ]] || [[ "${1:-}" == *"dev"* ]] || [ "$DEF_PATCHES_VER" = "beta" ] || [ "$DEF_PATCHES_VER" = "dev" ]; then patches_ver="beta"; else patches_ver="stable"; fi; }
	cli_src=$(toml_get "$t" cli-source) || cli_src=$DEF_CLI_SRC
	cli_src_host=$(toml_get "$t" cli-source-host) || cli_src_host=$DEF_CLI_SRC_HOST
	cli_ver=$(toml_get "$t" cli-version) || cli_ver=$DEF_CLI_VER
	if ! isoneof "$cli_src_host" github gitlab; then abort "ERROR: cli-source-host '$cli_src_host' is not a valid option for '$table_name': only 'github' or 'gitlab' is allowed"; fi

	# Parse patch sources: may be a single string or multiline (quoted list)
	IFS=$'\n'
	p_srcs=($(list_args "$patches_src" | tr -d \"\')); [ ${#p_srcs[@]} -eq 0 ] && p_srcs=("$patches_src")
	p_hosts=($(list_args "$patches_src_host" | tr -d \"\')); [ ${#p_hosts[@]} -eq 0 ] && p_hosts=("$patches_src_host")
	p_vers=($(list_args "$patches_ver" | tr -d \"\')); [ ${#p_vers[@]} -eq 0 ] && p_vers=("$patches_ver")
	unset IFS
	for h in "${p_hosts[@]}"; do
		if ! isoneof "$h" github gitlab; then abort "ERROR: patches-source-host '$h' is not a valid option for '$table_name': only 'github' or 'gitlab' is allowed"; fi
	done

	if ! PREBUILTS="$(get_prebuilts "$cli_src_host" "$cli_src" "$cli_ver" "$patches_src_host" "$patches_src" "$patches_ver")"; then
		epr "Could not get prebuilts"
		continue
	fi
	read -r cli_jar patches_jar_all <<< "$PREBUILTS"
	app_args[cli]=$cli_jar
	app_args[ptjar]=$patches_jar_all
	app_args[cli_source]=$cli_src
	app_args[patches_sources_all]="${p_srcs[*]}"

	# Build aggregated patches_ref and changelog_url from all sources
	patches_ref_all="" changelog_url_all=""
	for i in "${!p_srcs[@]}"; do
		psrc="${p_srcs[$i]}"
		phost="${p_hosts[$i]:-${p_hosts[0]}}"
		# Find the downloaded jar/apk for this source to get actual version
		pdir=${psrc%/*}; pdir=${TEMP_DIR}/${pdir,,}-rv
		pfile=$(find "$pdir" -name 'patches-*.rvp' -o -name 'patches-*.jar' -o -name '*.mpp' -o -name '*.apk' 2>/dev/null | sort | tail -1)
		if [ -n "$pfile" ]; then
			pfilename=${pfile##*/}
			
			if [ -f "${pdir}/tag_name.txt" ]; then
				ptag=$(cat "${pdir}/tag_name.txt")
			else
				pver_actual=${pfilename#*-}; pver_actual=${pver_actual%.*}
				ptag="v${pver_actual#v}"
			fi
			
			patches_ref_all+="${psrc%%/*}/${pfilename} "
			if [ "$phost" = github ]; then
				changelog_url_all+="https://github.com/${psrc}/releases/tag/${ptag} "
			else
				changelog_url_all+="https://gitlab.com/${psrc}/-/releases/${ptag} "
			fi
		fi
	done
	app_args[patches_src]=${p_srcs[0]}
	app_args[patches_ref]="${patches_ref_all% }"
	app_args[changelog_url]="${changelog_url_all% }"
	app_args[brand]=$(toml_get "$t" brand) || app_args[brand]="${DEF_BRAND:-${p_srcs[0]%%/*}}"
	app_args[variant]=$(toml_get "$t" variant) || app_args[variant]=""
	app_args[sub_variant]=$(toml_get "$t" sub-variant) || app_args[sub_variant]=""
	[ -z "${app_args[sub_variant]}" ] && { app_args[sub_variant]=$(toml_get "$t" sub_variant) || app_args[sub_variant]=""; }

	app_args[excluded_patches]=$(toml_get "$t" excluded-patches) || app_args[excluded_patches]=""
	if [ -n "${app_args[excluded_patches]}" ] && [[ ${app_args[excluded_patches]} != *'"'* ]]; then abort "patch names inside excluded-patches must be quoted"; fi
	app_args[included_patches]=$(toml_get "$t" included-patches) || app_args[included_patches]=""
	if [ -n "${app_args[included_patches]}" ] && [[ ${app_args[included_patches]} != *'"'* ]]; then abort "patch names inside included-patches must be quoted"; fi
	app_args[exclusive_patches]=$(toml_get "$t" exclusive-patches) || app_args[exclusive_patches]=false
	app_args[version]=$(toml_get "$t" version) || app_args[version]="auto"
	app_args[version_code]=$(toml_get "$t" version-code) || app_args[version_code]=""
	app_args[app_name]=$(toml_get "$t" app-name) || app_args[app_name]=$table_name
	app_args[patcher_args]=$(toml_get "$t" patcher-args) || app_args[patcher_args]=""
	app_args[table]=$table_name
	app_args[build_mode]=$(toml_get "$t" build-mode) || app_args[build_mode]="$DEF_BUILD_MODE"
	if ! isoneof "${app_args[build_mode]}" both apk module; then
		abort "ERROR: build-mode '${app_args[build_mode]}' is not a valid option for '${table_name}': only 'both', 'apk' or 'module' is allowed"
	fi
	app_args[include_stock]=$(toml_get "$t" include-stock) && {
		if ! isoneof "${app_args[include_stock]}" disable merged split; then
			abort "ERROR: include-stock '${app_args[include_stock]}' is not a valid option for '${table_name}': only 'disable', 'merged' or 'split' is allowed"
		fi
	} || app_args[include_stock]=merged

	for dl_from in "${DL_SRCS[@]}"; do
		if app_args[${dl_from}_dlurl]=$(toml_get "$t" "${dl_from}-dlurl"); then
			app_args[${dl_from}_dlurl]=${app_args[${dl_from}_dlurl]%/}
			app_args[${dl_from}_dlurl]=${app_args[${dl_from}_dlurl]%download}
			app_args[${dl_from}_dlurl]=${app_args[${dl_from}_dlurl]%/}
			app_args[dl_from]=${dl_from}
		else
			app_args[${dl_from}_dlurl]=""
		fi
	done
	if [ -z "${app_args[dl_from]-}" ]; then abort "ERROR: no 'dlurl' option was set for '$table_name'. (${DL_SRCS[*]})"; fi
	app_args[arch]=$(toml_get "$t" arch) || app_args[arch]="$DEF_ARCH"
	if ! isoneof "${app_args[arch]}" "auto" "both" "all" "arm64-v8a" "arm-v7a" "x86_64" "x86"; then
		abort "wrong arch '${app_args[arch]}' for '$table_name'"
	fi

	app_args[pkg_name]=$(toml_get "$t" pkg-name) || app_args[pkg_name]=""
	app_args[patched_pkg_name]=$(toml_get "$t" patched-pkg-name) || app_args[patched_pkg_name]=""
	app_args[dpi]=$(toml_get "$t" dpi) || app_args[dpi]="$DEF_DPI"
	app_args[github_regex]=$(toml_get "$t" github-regex) || app_args[github_regex]=""
	app_args[github_release_regex]=$(toml_get "$t" github-release-regex) || app_args[github_release_regex]=""
	table_name_f=${table_name,,}
	table_name_f=${table_name_f// /-}
	app_args[module_prop_name]=$(toml_get "$t" module-prop-name) || app_args[module_prop_name]="${table_name_f}-${DEF_AUTHOR_NAME}"

	# Automatically append -beta to the module ID for pre-release builds
	# so they have an independent update channel in Magisk
	if { [[ "${1:-}" == *"beta"* ]] || [[ "${1:-}" == *"dev"* ]] || [ "${DEF_PATCHES_VER:-}" = "beta" ] || [ "${DEF_PATCHES_VER:-}" = "dev" ] || [ "${patches_ver:-}" = "beta" ] || [ "${patches_ver:-}" = "dev" ]; } && [[ "${app_args[module_prop_name]}" != *"-beta"* ]]; then
		app_args[module_prop_name]="${app_args[module_prop_name]}-beta"
	fi

	if [ "${app_args[arch]}" = both ]; then
		app_args[table]="$table_name (arm64-v8a)"
		app_args[arch]="arm64-v8a"
		module_prop_name_b=${app_args[module_prop_name]}
		app_args[module_prop_name]="${module_prop_name_b}-arm64"
		if [ -n "${GITHUB_REPOSITORY:-}" ]; then echo "::group::Building ${app_args[table]}"; fi
		build_rv "$(declare -p app_args)"
		if [ -n "${GITHUB_REPOSITORY:-}" ]; then echo "::endgroup::"; fi
		app_args[table]="$table_name (arm-v7a)"
		app_args[arch]="arm-v7a"
		app_args[module_prop_name]="${module_prop_name_b}-arm"
		if [ -n "${GITHUB_REPOSITORY:-}" ]; then echo "::group::Building ${app_args[table]}"; fi
		build_rv "$(declare -p app_args)"
		if [ -n "${GITHUB_REPOSITORY:-}" ]; then echo "::endgroup::"; fi
	else
		if [ "${app_args[arch]}" = "arm64-v8a" ]; then
			app_args[module_prop_name]="${app_args[module_prop_name]}-arm64"
		elif [ "${app_args[arch]}" = "arm-v7a" ]; then
			app_args[module_prop_name]="${app_args[module_prop_name]}-arm"
		fi
		if [ -n "${GITHUB_REPOSITORY:-}" ]; then echo "::group::Building ${app_args[table]}"; fi
		build_rv "$(declare -p app_args)"
		if [ -n "${GITHUB_REPOSITORY:-}" ]; then echo "::endgroup::"; fi
	fi
done
rm -rf temp/tmp.*
if [ -z "$(ls -A1 "${BUILD_DIR}")" ]; then abort "All builds failed."; fi

if command -v python3 >/dev/null 2>&1; then
	python3 .github/scripts/generate_release_notes.py
fi

pr "Done"
