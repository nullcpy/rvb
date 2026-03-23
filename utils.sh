#!/usr/bin/env bash

MODULE_TEMPLATE_DIR="module"
CWD=$(pwd)
TEMP_DIR="temp"
BIN_DIR="bin"
BUILD_DIR="build"

if [ "${GITHUB_TOKEN-}" ]; then GH_HEADER="Authorization: token ${GITHUB_TOKEN}"; else GH_HEADER=; fi
NEXT_VER_CODE=${NEXT_VER_CODE:-$(date +'%Y%m%d')}
OS=$(uname -o)

toml_prep() {
	if [ ! -f "$1" ]; then return 1; fi
	if [ "${1##*.}" == toml ]; then
		__TOML__=$($TOML --output json --file "$1" .)
	elif [ "${1##*.}" == json ]; then
		__TOML__=$(cat "$1")
	else abort "config extension not supported"; fi
}
toml_get_table_names() { jq -r -e 'to_entries[] | select(.value | type == "object") | .key' <<<"$__TOML__"; }
toml_get_table_main() { jq -r -e 'to_entries | map(select(.value | type != "object")) | from_entries' <<<"$__TOML__"; }
toml_get_table() { jq -r -e ".\"${1}\"" <<<"$__TOML__"; }
toml_get() {
	local op quote_placeholder=$'\001'
	op=$(jq -r ".\"${2}\" | values" <<<"$1")
	if [ "$op" ]; then
		op="${op#"${op%%[![:space:]]*}"}"
		op="${op%"${op##*[![:space:]]}"}"
		op=${op//\\\'/$quote_placeholder}
		op=${op//"''"/$quote_placeholder}
		op=${op//"'"/'"'}
		op=${op//$quote_placeholder/$'\''}
		echo "$op"
	else return 1; fi
}

pr() { echo -e "\033[0;32m[+] ${1}\033[0m"; }
epr() {
	echo >&2 -e "\033[0;31m[-] ${1}\033[0m"
	if [ "${GITHUB_REPOSITORY-}" ]; then echo >&2 -e "::error::utils.sh [-] ${1}\n"; fi
}
wpr() {
	echo >&2 -e "\033[0;33m[!] ${1}\033[0m"
	if [ "${GITHUB_REPOSITORY-}" ]; then echo >&2 -e "::warning::utils.sh [!] ${1}\n"; fi
}
abort() {
	epr "ABORT: ${1-}"
	rm -rf ./${TEMP_DIR}/*tmp.* ./${TEMP_DIR}/*/*tmp.* ./${TEMP_DIR}/*-temporary-files
	kill -TERM 0 2>/dev/null || :
	exit 1
}
java() { env -i java "$@"; }

run_with_timeout() {
	local timeout_seconds="$1"
	shift
	if command -v timeout >/dev/null 2>&1; then
		timeout --signal=TERM --kill-after=15 "${timeout_seconds}" "$@"
	else
		"$@"
	fi
}

get_prebuilts() {
	local cli_src=$1 cli_ver=$2 patches_src=$3 patches_ver=$4
	pr "Getting prebuilts (${patches_src%/*})" >&2
	local cl_dir=${patches_src%/*}
	cl_dir=${TEMP_DIR}/${cl_dir,,}-rv
	[ -d "$cl_dir" ] || mkdir "$cl_dir"

	for src_ver in "$cli_src CLI $cli_ver cli" "$patches_src Patches $patches_ver patches"; do
		set -- $src_ver
		local src=$1 tag=$2 ver=${3-} fprefix=$4

		if [ "$tag" = "CLI" ]; then
			local grab_cl=false
		elif [ "$tag" = "Patches" ]; then
			local grab_cl=true
		else abort unreachable; fi

		local dir=${src%/*}
		dir=${TEMP_DIR}/${dir,,}-rv
		[ -d "$dir" ] || mkdir "$dir"

		local rv_rel="https://api.github.com/repos/${src}/releases" name_ver
		if [ "$ver" = "dev" ]; then
			local resp
			resp=$(gh_req "$rv_rel" -) || return 1
			ver=$(jq -e -r '.[] | .tag_name' <<<"$resp" | get_highest_ver) || return 1
		fi
		if [ "$ver" = "latest" ]; then
			rv_rel+="/latest"
			name_ver="*"
		else
			rv_rel+="/tags/${ver}"
			name_ver="$ver"
		fi

		local url file tag_name matches
		file=$(find "$dir" -name "*${fprefix}-${name_ver#v}.*" -type f 2>/dev/null)
		if [ -z "$file" ]; then
			local resp asset name
			resp=$(gh_req "$rv_rel" -) || return 1
			tag_name=$(jq -r '.tag_name' <<<"$resp")
			matches=$(jq -e '.assets | map(select(.name | (endswith("asc") or endswith("json")) | not))' <<<"$resp")
			if [ "$(jq 'length' <<<"$matches")" -gt 1 ]; then
				local matches_new
				matches_new=$(jq -e -r 'map(select(.name | contains("-dev") | not))' <<<"$matches")
				if [ "$(jq 'length' <<<"$matches_new")" -eq 1 ]; then
					matches=$matches_new
				fi
			fi
			if [ "$(jq 'length' <<<"$matches")" -eq 0 ]; then
				epr "No asset was found"
				return 1
			elif [ "$(jq 'length' <<<"$matches")" -ne 1 ]; then
				wpr "More than 1 asset was found for this release. Falling back to the first one found..."
			fi
			asset=$(jq -r ".[0]" <<<"$matches")
			url=$(jq -r .url <<<"$asset")
			name=$(jq -r .name <<<"$asset")
			file="${dir}/${name}"
			gh_dl "$file" "$url" >&2 || return 1
			echo "$tag: $(cut -d/ -f1 <<<"$src")/${name}  " >>"${cl_dir}/changelog.md"
		else
			grab_cl=false
			local for_err=$file
			if [ "$ver" = "latest" ]; then
				file=$(grep -v '/[^/]*dev[^/]*$' <<<"$file" | head -1)
			else file=$(grep "/[^/]*${ver#v}[^/]*\$" <<<"$file" | head -1); fi
			if [ -z "$file" ]; then abort "filter fail: '$for_err' with '$ver'"; fi
			name=$(basename "$file")
			tag_name=$(cut -d'-' -f3- <<<"$name")
			tag_name=v${tag_name%.*}
		fi

		if [ "$tag" = "Patches" ]; then
			if [ $grab_cl = true ]; then echo -e "[Changelog](https://github.com/${src}/releases/tag/${tag_name})\n" >>"${cl_dir}/changelog.md"; fi
			if [ "$REMOVE_RV_INTEGRATIONS_CHECKS" = true ]; then
				local extensions_ext
				extensions_ext=$(unzip -l "${file}" "extensions/shared.*" 2>/dev/null | grep -o "shared\..*" || :)
				extensions_ext="${extensions_ext#*.}"
				if [ -z "$extensions_ext" ]; then
					wpr "Skipping revanced-integrations check patch for ${file}: extensions/shared.* not found"
				elif ! (
					mkdir -p "${file}-zip" || return 1
					unzip -qo "${file}" -d "${file}-zip" || return 1
					run_with_timeout "${JAVA_QUERY_TIMEOUT:-300}" java -cp "${BIN_DIR}/paccer.jar:${BIN_DIR}/dexlib2.jar" com.jhc.Main "${file}-zip/extensions/shared.${extensions_ext}" "${file}-zip/extensions/shared-patched.${extensions_ext}" || return 1
					mv -f "${file}-zip/extensions/shared-patched.${extensions_ext}" "${file}-zip/extensions/shared.${extensions_ext}" || return 1
					rm "${file}" || return 1
					cd "${file}-zip" || abort
					zip -0rq "${CWD}/${file}" . || return 1
				) >&2; then
					echo >&2 "Patching revanced-integrations failed"
				fi
				rm -r "${file}-zip" || :
			fi
		fi
		echo -n "$file "
	done
	echo
}

set_prebuilts() {
	APKSIGNER="${BIN_DIR}/apksigner.jar"
	local arch
	arch=$(uname -m)
	if [ "$arch" = aarch64 ]; then arch=arm64; elif [ "${arch:0:5}" = "armv7" ]; then arch=arm; fi
	HTMLQ="${BIN_DIR}/htmlq/htmlq-${arch}"
	AAPT2="${BIN_DIR}/aapt2/aapt2-${arch}"
	TOML="${BIN_DIR}/toml/tq-${arch}"
}

config_update() {
	if [ ! -f build.md ]; then abort "build.md not available"; fi
	declare -A sources
	: >"$TEMP_DIR"/skipped
	local upped=()
	local prcfg=false
	for table_name in $(toml_get_table_names); do
		if [ -z "$table_name" ]; then continue; fi
		t=$(toml_get_table "$table_name")
		enabled=$(toml_get "$t" enabled) || enabled=true
		if [ "$enabled" = "false" ]; then continue; fi
		PATCHES_SRC=$(toml_get "$t" patches-source) || PATCHES_SRC=$DEF_PATCHES_SRC
		PATCHES_VER=$(toml_get "$t" patches-version) || PATCHES_VER=$DEF_PATCHES_VER
		if [[ -v sources["$PATCHES_SRC/$PATCHES_VER"] ]]; then
			if [ "${sources["$PATCHES_SRC/$PATCHES_VER"]}" = 1 ]; then upped+=("$table_name"); fi
		else
			sources["$PATCHES_SRC/$PATCHES_VER"]=0
			local rv_rel="https://api.github.com/repos/${PATCHES_SRC}/releases"
			if [ "$PATCHES_VER" = "dev" ]; then
				last_patches=$(gh_req "$rv_rel" - | jq -e -r '.[0]')
			elif [ "$PATCHES_VER" = "latest" ]; then
				last_patches=$(gh_req "$rv_rel/latest" -)
			else
				last_patches=$(gh_req "$rv_rel/tags/${ver}" -)
			fi
			if ! last_patches=$(jq -e -r '.assets[] | select(.name | (endswith("asc") or endswith("json")) | not) | .name' <<<"$last_patches"); then
				abort "config_update error: '$last_patches'"
			fi
			if [ "$last_patches" ]; then
				if ! OP=$(grep "^Patches: ${PATCHES_SRC%%/*}/" build.md | grep -m1 "$last_patches"); then
					sources["$PATCHES_SRC/$PATCHES_VER"]=1
					prcfg=true
					upped+=("$table_name")
				else
					echo "$OP" >>"$TEMP_DIR"/skipped
				fi
			fi
		fi
	done
	if [ "$prcfg" = true ]; then
		local query=""
		for table in "${upped[@]}"; do
			if [ -n "$query" ]; then query+=" or "; fi
			query+=".key == \"$table\""
		done
		jq "to_entries | map(select(${query} or (.value | type != \"object\"))) | from_entries" <<<"$__TOML__"
	fi
}

_req() {
	local ip="$1" op="$2"
	shift 2
	local curl_max_time="${CURL_MAX_TIME:-600}"
	local lock_wait_timeout="${DL_LOCK_WAIT_TIMEOUT:-300}"
	if [ "$op" = - ]; then
		if ! curl -L --compressed -c "$TEMP_DIR/cookie.txt" -b "$TEMP_DIR/cookie.txt" --connect-timeout 5 --max-time "$curl_max_time" --retry 0 --fail -s -S "$@" "$ip"; then
			epr "Request failed: $ip"
			return 1
		fi
	else
		if [ -f "$op" ]; then return 0; fi
		local dlp
		dlp="$(dirname "$op")/tmp.$(basename "$op")"
		local lockdir="$(dirname "$op")/lock.$(basename "$op")"

		if mkdir "$lockdir" 2>/dev/null; then
			if ! curl -L --compressed -c "$TEMP_DIR/cookie.txt" -b "$TEMP_DIR/cookie.txt" --connect-timeout 5 --max-time "$curl_max_time" --retry 0 --fail -s -S "$@" "$ip" -o "$dlp"; then
				rm -f "$dlp"
				rmdir "$lockdir"
				epr "Request failed: $ip"
				return 1
			fi
			mv -f "$dlp" "$op"
			rmdir "$lockdir"
		else
			local waited=0
			while [ -d "$lockdir" ]; do
				if ((waited >= lock_wait_timeout)); then
					epr "Timed out waiting for download lock '$lockdir'"
					return 1
				fi
				sleep 1
				waited=$((waited + 1))
			done
			if [ -f "$op" ]; then
				return 0
			fi
			epr "Download lock released but output file missing: $op"
			return 1
		fi
	fi
}
req() { _req "$1" "$2" -H "User-Agent: Mozilla/5.0 (X11; Linux x86_64; rv:108.0) Gecko/20100101 Firefox/108.0"; }
gh_req() { _req "$1" "$2" -H "$GH_HEADER"; }
gh_dl() {
	if [ ! -f "$1" ]; then
		pr "Getting '$1' from '$2'"
		_req "$2" "$1" -H "$GH_HEADER" -H "Accept: application/octet-stream"
	fi
}

log() { echo -e "$1  " >>"build.md"; }
get_highest_ver() {
	local vers m
	vers=$(tee)
	m=$(head -1 <<<"$vers")
	if ! semver_validate "$m"; then echo "$m"; else sort -rV <<<"$vers" | head -1; fi
}
semver_validate() {
	local a="${1%-*}"
	local a="${a#v}"
	local ac="${a//[.0-9]/}"
	[ ${#ac} = 0 ]
}
get_patch_last_supported_ver() {
	local list_patches=$1 pkg_name=$2 inc_sel=$3 _exc_sel=$4 _exclusive=$5 # TODO: resolve using all of these
	local op
	if [ "$inc_sel" ]; then
		if ! op=$(awk '{$1=$1}1' <<<"$list_patches"); then
			epr "list-patches: '$op'"
			return 1
		fi
		local ver vers="" NL=$'\n'
		while IFS= read -r line; do
			line="${line:1:${#line}-2}"
			ver=$(sed -n "/^Name: $line\$/,/^\$/p" <<<"$op" | sed -n "/^Compatible versions:\$/,/^\$/p" | tail -n +2)
			vers=${ver}${NL}
		done <<<"$(list_args "$inc_sel")"
		vers=$(awk '{$1=$1}1' <<<"$vers")
		if [ "$vers" ]; then
			get_highest_ver <<<"$vers"
			return
		fi
	fi
	op=$(patches_list_versions "$cli_jar" "$patches_jar" "$pkg_name") || return 1
	op=$(tail -n +3 <<<"$op" | awk '{$1=$1}1')
	if [ "$op" = "Any" ]; then return; fi
	pcount=$(head -1 <<<"$op") pcount=${pcount#*(} pcount=${pcount% *}
	if [ -z "$pcount" ]; then
		abort "No patches found for '$pkg_name' in patches '$patches_jar'"
	fi
	grep -F "($pcount patch" <<<"$op" | sed 's/ (.* patch.*//' | get_highest_ver || return 1
}

patches_list_versions() {
	local cli_jar=$1 patches_jar=$2 pkg_name=$3 op
	local query_timeout="${JAVA_QUERY_TIMEOUT:-300}"
	if ! op=$(run_with_timeout "$query_timeout" java -jar "$cli_jar" list-versions -p "$patches_jar" -f "$pkg_name" -b 2>&1); then
		if ! op=$(run_with_timeout "$query_timeout" java -jar "$cli_jar" list-versions "$patches_jar" -f "$pkg_name" 2>&1); then
			epr "Could not list versions $cli_jar: '$op'"
			return 1
		fi
	fi
	echo "$op"
}

patches_list() {
	local cli_jar=$1 patches_jar=$2 pkg_name=$3 op
	local query_timeout="${JAVA_QUERY_TIMEOUT:-300}"
	local cache_file="${patches_jar}.cache.txt"

	if [ ! -f "$cache_file" ]; then
		if ! run_with_timeout "$query_timeout" java -jar "$cli_jar" list-patches -p "$patches_jar" --with-versions --with-packages > "$cache_file" 2>&1; then
			run_with_timeout "$query_timeout" java -jar "$cli_jar" list-patches --patches "$patches_jar" --with-versions --with-packages > "$cache_file" 2>&1 || {
				epr "Could not generate patches cache."
				rm -f "$cache_file"
				return 1
			}
		fi
	fi

	op=$(awk -v pkg="$pkg_name" '
		/^INFO:/ { next }
		/^Patch:/ { print_patch=0 }
		$0 ~ "Package:.*"pkg { print_patch=1 }
		print_patch { print }
	' "$cache_file")
	
	echo "$op"
}

isoneof() {
	local i=$1 v
	shift
	for v; do [ "$v" = "$i" ] && return 0; done
	return 1
}

merge_splits() {
	local bundle=$1 output=$2
	pr "Merging splits"
	if ! OP=$(java -jar "$TEMP_DIR/apkeditor.jar" merge -i "${bundle}" -o "${bundle}.mzip" -clean-meta -f 2>&1); then
		epr "Apkeditor ERROR: $OP"
		return 1
	fi
	# sign the merged apk properly
	patch_apk "${bundle}.mzip" "${output}" "--exclusive" "${args[cli]}" "${args[ptjar]}"
	local ret=$?
	rm -f "${bundle}.mzip"
	return $ret
}

# -------------------- apkmirror --------------------
apkmirror_search() {
	local resp="$1" dpi="$2" arch="$3" apk_bundle="$4"
	local apparch dlurl="" node app_table emptyCheck
	if [ "$arch" = all ]; then
		apparch=(universal noarch 'arm64-v8a + armeabi-v7a')
	else apparch=("$arch" universal noarch 'arm64-v8a + armeabi-v7a'); fi
	for ((n = 1; n < 40; n++)); do
		node=$($HTMLQ "div.table-row.headerFont:nth-last-child($n)" -r "span:nth-child(n+3)" <<<"$resp")
		if [ -z "$node" ]; then break; fi
		emptyCheck=$($HTMLQ -t -w "div.table-cell:nth-child(1) > a:nth-child(1)" <<<"$node" | xargs)
		if [ "$emptyCheck" ]; then
			dlurl=$($HTMLQ --base https://www.apkmirror.com --attribute href "div:nth-child(1) > a:nth-child(1)" <<<"$node")
		else break; fi
		app_table=$($HTMLQ --text --ignore-whitespace <<<"$node")
		if [ "$(sed -n 3p <<<"$app_table")" = "$apk_bundle" ] &&
			[ "$(sed -n 6p <<<"$app_table")" = "$dpi" ] &&
			isoneof "$(sed -n 4p <<<"$app_table")" "${apparch[@]}"; then
			echo "$dlurl"
			return 0
		fi
	done
	if [ "$n" -eq 2 ] && [ "$dlurl" ]; then
		# only one apk exists, return it
		echo "$dlurl"
		return 0
	fi
	return 1
}
dl_apkmirror() {
	local url=$1 version=${2// /-} output=$3 arch=$4 dpi=$5 is_bundle=false
	if [ -f "${output}.apkm" ]; then
		is_bundle=true
	else
		if [ "$arch" = "arm-v7a" ]; then arch="armeabi-v7a"; fi
		local resp node app_table apkmname dlurl=""
		apkmname=$($HTMLQ "h1.marginZero" --text <<<"$__APKMIRROR_RESP__")
		apkmname="${apkmname,,}" apkmname="${apkmname// /-}" apkmname="${apkmname//[^a-z0-9-]/}"
		url="${url}/${apkmname}-${version//./-}-release/"
		resp=$(req "$url" -) || return 1
		node=$($HTMLQ "div.table-row.headerFont:nth-last-child(1)" -r "span:nth-child(n+3)" <<<"$resp")
		if [ "$node" ]; then
			for current_dpi in $dpi; do
				for type in APK BUNDLE; do
					if dlurl=$(apkmirror_search "$resp" "$current_dpi" "${arch}" "$type"); then
						[[ "$type" == "BUNDLE" ]] && is_bundle=true || is_bundle=false
						break 2
					fi
				done
			done
			[ -z "$dlurl" ] && return 1
			resp=$(req "$dlurl" -)
		fi
		url=$(echo "$resp" | $HTMLQ --base https://www.apkmirror.com --attribute href "a.btn") || return 1
		url=$(req "$url" - | $HTMLQ --base https://www.apkmirror.com --attribute href "span > a[rel = nofollow]") || return 1
	fi

	if [ "$is_bundle" = true ]; then
		req "$url" "${output}.apkm" || return 1
		merge_splits "${output}.apkm" "${output}"
	else
		req "$url" "${output}" || return 1
	fi
}
get_apkmirror_vers() {
	local vers apkm_resp
	apkm_resp=$(req "https://www.apkmirror.com/uploads/?appcategory=${__APKMIRROR_CAT__}" -)
	vers=$(sed -n 's;.*Version:</span><span class="infoSlide-value">\(.*\) </span>.*;\1;p' <<<"$apkm_resp" | awk '{$1=$1}1')
	if [ "$__AAV__" = false ]; then
		local IFS=$'\n'
		vers=$(grep -iv "\(beta\|alpha\)" <<<"$vers")
		local v r_vers=()
		for v in $vers; do
			grep -iq "${v} \(beta\|alpha\)" <<<"$apkm_resp" || r_vers+=("$v")
		done
		echo "${r_vers[*]}"
	else
		echo "$vers"
	fi
}
get_apkmirror_pkg_name() { sed -n 's;.*id=\(.*\)" class="accent_color.*;\1;p' <<<"$__APKMIRROR_RESP__"; }
get_apkmirror_resp() {
	local err_file="${TEMP_DIR}/apkmirror_err_$$.txt"
	if ! __APKMIRROR_RESP__=$(req "${1}" - 2>"$err_file"); then
		epr "APKMirror request failed for ${1} (possible rate limiting/403): $(cat "$err_file")"
		rm -f "$err_file"
		return 1
	fi
	rm -f "$err_file"
	__APKMIRROR_CAT__="${1##*/}"
}

# -------------------- uptodown --------------------
get_uptodown_resp() {
	local err_file="${TEMP_DIR}/uptodown_err_$$.txt"
	if ! __UPTODOWN_RESP__=$(req "${1}/versions" - 2>"$err_file"); then
		epr "Uptodown request failed for ${1}: $(cat "$err_file")"
		rm -f "$err_file"
		return 1
	fi
	if ! __UPTODOWN_RESP_PKG__=$(req "${1}/download" - 2>"$err_file"); then
		epr "Uptodown download page request failed for ${1}: $(cat "$err_file")"
		rm -f "$err_file"
		return 1
	fi
	rm -f "$err_file"
}
get_uptodown_vers() { $HTMLQ --text ".version" <<<"$__UPTODOWN_RESP__"; }
dl_uptodown() {
	local uptodown_dlurl=$1 version=$2 output=$3 arch=$4 _dpi=$5
	local apparch
	if [ "$arch" = "arm-v7a" ]; then arch="armeabi-v7a"; fi
	if [ "$arch" = all ]; then
		apparch=('arm64-v8a, armeabi-v7a, x86_64' 'arm64-v8a, armeabi-v7a, x86, x86_64' 'arm64-v8a, armeabi-v7a')
	else apparch=("$arch" 'arm64-v8a, armeabi-v7a, x86_64' 'arm64-v8a, armeabi-v7a, x86, x86_64' 'arm64-v8a, armeabi-v7a'); fi

	local op resp data_code
	data_code=$($HTMLQ "#detail-app-name" --attribute data-code <<<"$__UPTODOWN_RESP__")
	local versionURL=""
	local is_bundle=false
	for i in {1..20}; do
		resp=$(req "${uptodown_dlurl}/apps/${data_code}/versions/${i}" -)
		if ! op=$(jq -e -r ".data | map(select(.version == \"${version}\")) | .[0]" <<<"$resp"); then
			continue
		fi
		if [ "$(jq -e -r ".kindFile" <<<"$op")" = "xapk" ]; then is_bundle=true; fi
		if versionURL=$(jq -e -r '.versionURL' <<<"$op"); then break; else return 1; fi
	done
	if [ -z "$versionURL" ]; then return 1; fi
	versionURL=$(jq -e -r '.url + "/" + .extraURL + "/" + (.versionID | tostring)' <<<"$versionURL")
	resp=$(req "$versionURL" -) || return 1

	local data_version files node_arch="" data_file_id node_class
	data_version=$($HTMLQ '.button.variants' --attribute data-version <<<"$resp") || return 1
	if [ "$data_version" ]; then
		files=$(req "${uptodown_dlurl%/*}/app/${data_code}/version/${data_version}/files" - | jq -e -r .content) || return 1
		for ((n = 1; n < 12; n += 1)); do
			node_class=$($HTMLQ -w -t ".content > :nth-child($n)" --attribute class <<<"$files") || return 1
			if [ "$node_class" != "variant" ]; then
				node_arch=$($HTMLQ -w -t ".content > :nth-child($n)" <<<"$files" | xargs) || return 1
				continue
			fi
			if [ -z "$node_arch" ]; then return 1; fi
			if ! isoneof "$node_arch" "${apparch[@]}"; then continue; fi

			file_type=$($HTMLQ -w -t ".content > :nth-child($n) > .v-file > span" <<<"$files") || return 1
			if [ "$file_type" = "xapk" ]; then is_bundle=true; else is_bundle=false; fi
			data_file_id=$($HTMLQ ".content > :nth-child($n) > .v-report" --attribute data-file-id <<<"$files") || return 1
			resp=$(req "${uptodown_dlurl}/download/${data_file_id}-x" -)
			break
		done
		if [ $n -eq 12 ]; then return 1; fi
	fi
	local data_url
	data_url=$($HTMLQ "#detail-download-button" --attribute data-url <<<"$resp") || return 1
	if [ $is_bundle = true ]; then
		req "https://dw.uptodown.com/dwn/${data_url}" "$output.apkm" || return 1
		merge_splits "${output}.apkm" "${output}"
	else
		req "https://dw.uptodown.com/dwn/${data_url}" "$output"
	fi
}
get_uptodown_pkg_name() { $HTMLQ --text "tr.full:nth-child(1) > td:nth-child(3)" <<<"$__UPTODOWN_RESP_PKG__"; }

# -------------------- archive --------------------
dl_archive() {
	local url=$1 version=$2 output=$3 arch=$4
	local path version=${version// /}
	while IFS= read -r p; do
		case "$p" in
			*"${version_f#v}-${arch// /}.apk"|*"${version_f#v}-${arch// /}.apkm"|*"${version_f#v}-${arch// /}.xapk"|*"${version_f#v}-${arch// /}.apks")
				path="$p"
				break
				;;
		esac
	done <<<"$__ARCHIVE_RESP__"
	if [ -z "$path" ]; then
		epr "Version ${version} with arch ${arch} not found in archive"
		return 1
	fi
	case "${path##*.}" in
		apk)
			req "${url}/${path}" "$output"
			;;
		apkm|xapk|apks)
			req "${url}/${path}" "${output}.${path##*.}" || return 1
			merge_splits "${output}.${path##*.}" "${output}"
			;;
		*)
			epr "Unsupported archive file type for ${path}"
			return 1
			;;
	esac
}
get_archive_resp() {
	local r err_file="${TEMP_DIR}/archive_err_$$.txt"
	if ! r=$(req "$1" - 2>"$err_file") || [ -z "$r" ]; then
		epr "Archive request failed for ${1}: $(cat "$err_file")"
		rm -f "$err_file"
		return 1
	fi
	rm -f "$err_file"
	__ARCHIVE_RESP__=$(sed -n 's;^<a href="\(.*\)"[^"]*;\1;p' <<<"$r")
	__ARCHIVE_PKG_NAME__=$(awk -F/ '{print $NF}' <<<"$1")
}
get_archive_vers() { sed 's/^[^-]*-//;s/-\(all\|arm64-v8a\|arm-v7a\|x86\|x86_64\)\.\(apk\|apkm\|xapk\|apks\)$//g' <<<"$__ARCHIVE_RESP__"; }
get_archive_pkg_name() { echo "$__ARCHIVE_PKG_NAME__"; }

# -------------------- direct --------------------
dl_direct() {
	local url=$1 version=${2// /-} output=$3 arch=$4 dpi=$5
	req "$url" "${output}" || return 1
}
get_direct_vers() { cut -d- -f2 <<<"$__DIRECT_APKNAME__"; }
get_direct_pkg_name() { cut -d- -f1 <<<"$__DIRECT_APKNAME__"; }
get_direct_resp() { __DIRECT_APKNAME__=$(awk -F/ '{print $NF}' <<<"$1"); }
# --------------------------------------------------

patch_apk() {
	local stock_input=$1 patched_apk=$2 patcher_args=$3 cli_jar=$4 patches_jar=$5
	local cmd="java -jar '$cli_jar' patch '$stock_input' --purge -o '$patched_apk' -p '$patches_jar' --keystore=ks.keystore \
--keystore-entry-password=123456789 --keystore-password=123456789 --signer=jhc --keystore-entry-alias=jhc $patcher_args"

	# TODO: remove this later
	local cli_name
	cli_name=$(basename "$cli_jar")
	if [ "${cli_name::8}" = revanced ]; then cmd+=" -b"; fi

	if [ "$OS" = Android ]; then cmd+=" --custom-aapt2-binary='${AAPT2}'"; fi
	pr "$cmd"
	if eval "$cmd"; then [ -f "$patched_apk" ]; else
		rm "$patched_apk" 2>/dev/null || :
		return 1
	fi
}

check_sig() {
	local file=$1 pkg_name=$2
	local sig
	if grep -q "$pkg_name" sig.txt; then
		sig=$(java -jar --enable-native-access=ALL-UNNAMED "$APKSIGNER" verify --print-certs "$file" | grep ^Signer | grep SHA-256 | tail -1 | awk '{print $NF}')
		echo "$pkg_name signature: ${sig}"
		grep -qFx "$sig $pkg_name" sig.txt
	fi
}

list_args() { tr -d '\t\r' <<<"$1" | tr -s ' ' | sed 's/" "/"\n"/g' | sed 's/\([^"]\)"\([^"]\)/\1'\''\2/g' | grep -v '^$' || :; }
join_args() { list_args "$1" | sed "s/^/${2} /" | paste -sd " " - || :; }

module_config() {
	local ma=""
	if [ "$4" = "arm64-v8a" ]; then
		ma="arm64"
	elif [ "$4" = "arm-v7a" ]; then
		ma="arm"
	fi
	echo "PKG_NAME=$2
PKG_VER=$3
MODULE_ARCH=$ma" >"$1/config"
}
module_prop() {
	echo "id=${1}
name=${2}
version=v${3}
versionCode=${NEXT_VER_CODE}
author=j-hc
description=${4}" >"${6}/module.prop"

	if [ "$ENABLE_MODULE_UPDATE" = true ]; then echo "updateJson=${5}" >>"${6}/module.prop"; fi
}
