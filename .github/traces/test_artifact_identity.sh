#!/usr/bin/env bash
# Functional regression tests for the artifact-identity gates in scripts/utils.sh:
# _rekey_to_bytes (a fetched file is re-named after the versionName its own manifest
# carries, and the patch gate runs again on that version) and _cached_identity_disagrees
# (a cached file whose name denies its bytes is dropped instead of adopted).
#
# The contract being guarded: a patch bundle pins version NAMES, not just codes, so a store
# that ships two flavours of one number under one code cannot answer a suffixed request. Run
# 41314721427 asked Proton Lumo 2.1.5-nogms, APKMirror served its 2.1.5-gms bundle, the
# cache and the release kept the requested label, and Morphe applied zero patches to a
# re-signed stock app. Every case below therefore asserts both halves: the honest label
# costs nothing, and the dishonest one is renamed or discarded rather than shipped.
#
# Stubs: _meta_field_of (identity from variables instead of aapt), has_compatible_patches
# (counts calls and returns a scripted rc, so the "no second JVM run on the happy path" and
# "the gate sees the byte version, not the label" claims are both measurable). _ver_key,
# mv/rm and the filesystem stay real.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
# shellcheck disable=SC1091
source scripts/utils.sh >/dev/null 2>&1
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
cd "$t" || exit 1

fail() { echo "FAIL: $*"; exit 1; }
pr() { :; }          # the engine chatter is not under test here
wpr() { :; }
epr() { :; }

META_VERSIONNAME=""
META_VERSIONCODE=""
GATE_CALLS=0
GATE_RC=0
GATE_VERSION=""
GATE_INC=""
_meta_field_of() { # $1=file  $2=field
	case "$2" in
	versionName) printf '%s' "$META_VERSIONNAME" ;;
	versionCode) printf '%s' "$META_VERSIONCODE" ;;
	esac
}
has_compatible_patches() { # $1=cli $2=bundles $3=pkg $4=version $5=source $6=included
	GATE_CALLS=$((GATE_CALLS + 1))
	GATE_VERSION="$4"
	GATE_INC="$6"
	return "$GATE_RC"
}

mkdir -p dl cache
declare -A args          # global on purpose: declare inside reset_scope would localise it
reset_scope() { # the build_rv variables _rekey_to_bytes reads and writes
	pkg_name="com.example.app"
	version="$1"
	version_f="$1"
	vc_infix="${2:+-$2}"
	target_version_code="${2:-}"
	arch_f="arm64-v8a"
	apk_dl_dir="$t/dl"
	apk_cache_dir="$t/cache"
	cli_jar="cli.jar"
	patches_jar="bundles.mpp"
	_vc_pinned_by_config=false
	_unsupported_bytes=""
	META_VERSIONNAME=""
	META_VERSIONCODE=""
	GATE_CALLS=0
	GATE_RC=0
	GATE_VERSION=""
	GATE_INC=""
	args=([cli_source]="morphe" [included_patches]="'A' 'B'" [direct_dlurl]="" [apkmirror_dlurl]="https://apkmirror.example/app")
	stock_apk="${apk_dl_dir}/${pkg_name}-${version_f}${vc_infix}-${arch_f}.apk"
	all_apk="${apk_dl_dir}/${pkg_name}-${version_f}${vc_infix}-all.apk"
	cached_stock_apk="${apk_cache_dir}/${pkg_name}-${version_f}${vc_infix}-${arch_f}.apk"
	cached_all_apk="${apk_cache_dir}/${pkg_name}-${version_f}${vc_infix}-all.apk"
	: >"$stock_apk"
	: >"$all_apk"
}

# --- 1. an honest label is free: no rename, no second gate -------------------------
# Negative control for the cost claim: a gate that ran on every download would show up as
# GATE_CALLS 1 here, and the file would still sit under the name the bytes agree with.
reset_scope "2.1.5" "79"
META_VERSIONNAME="2.1.5"
_rekey_to_bytes apkmirror "$META_VERSIONNAME" || fail "honest label dropped a buildable source"
[ "$GATE_CALLS" = 0 ] || fail "honest label re-ran the patch gate ($GATE_CALLS)"
[ -f "$stock_apk" ] || fail "honest label moved the artifact"
[ "$version_f" = "2.1.5" ] || fail "honest label re-keyed to '$version_f'"

# --- 2. a store serving another flavour is re-keyed and gated on the bytes ----------
reset_scope "2.1.5-nogms" "79"
META_VERSIONNAME="2.1.5-gms"
_rekey_to_bytes apkmirror "$META_VERSIONNAME" || fail "a buildable byte version was discarded"
[ -f "dl/com.example.app-2.1.5-gms-79-arm64-v8a.apk" ] || fail "artifact kept the requested label: $(ls dl | tr '\n' ' ')"
[ ! -f "$t/dl/com.example.app-2.1.5-nogms-79-arm64-v8a.apk" ] || fail "old label left behind beside the new one"
[ "$version_f" = "2.1.5-gms" ] || fail "version_f not re-keyed: '$version_f'"
[ "$version" = "2.1.5-gms" ] || fail "version not re-keyed: '$version'"
[ "$all_apk" = "$t/dl/com.example.app-2.1.5-gms-79-all.apk" ] || fail "all_apk: $all_apk"
[ "$cached_stock_apk" = "$t/cache/com.example.app-2.1.5-gms-79-arm64-v8a.apk" ] || fail "cache key: $cached_stock_apk"
[ "$GATE_CALLS" = 1 ] || fail "gate not re-run on the byte version ($GATE_CALLS)"
[ "$GATE_VERSION" = "2.1.5-gms" ] || fail "gate judged '$GATE_VERSION', not the bytes"
[ "$GATE_INC" = "'A' 'B'" ] || fail "included-patches lost: '$GATE_INC'"
# The code is NOT rewritten for a store: it was already checked against the target.
[ "$vc_infix" = "-79" ] || fail "store fetch rewrote the version-code infix: '$vc_infix'"
[ "$target_version_code" = "79" ] || fail "store fetch changed the target code: '$target_version_code'"
[ -n "${args[apkmirror_dlurl]}" ] || fail "store source was disabled"

# --- 3. the gate refusing the byte version discards it and restores the ask --------
reset_scope "2.1.5-nogms" "79"
META_VERSIONNAME="2.1.5-gms"
GATE_RC=1
_rekey_to_bytes apkmirror "$META_VERSIONNAME" && fail "an uncovered byte version was kept"
[ ! -e "$t/dl/com.example.app-2.1.5-gms-79-arm64-v8a.apk" ] || fail "discarded artifact survived"
[ "$version_f" = "2.1.5-nogms" ] || fail "version_f not restored: '$version_f'"
[ "$vc_infix" = "-79" ] || fail "infix not restored: '$vc_infix'"
[ "$target_version_code" = "79" ] || fail "target code not restored: '$target_version_code'"
[ "$stock_apk" = "$t/dl/com.example.app-2.1.5-nogms-79-arm64-v8a.apk" ] || fail "stock path: $stock_apk"
[ -n "${args[apkmirror_dlurl]}" ] || fail "a store that answered once must stay available"
[ "$_unsupported_bytes" = "2.1.5-gms" ] || fail "bytes not recorded for the _np record: '$_unsupported_bytes'"

# --- 4. a bare URL also re-keys its versionCode, unless the code was hand-pinned ----
reset_scope "1.0" ""
args[direct_dlurl]="https://host/nameless"
META_VERSIONNAME="1.0.1"
META_VERSIONCODE="500"
_rekey_to_bytes direct "$META_VERSIONNAME" || fail "direct re-key refused a buildable file"
[ "$vc_infix" = "-500" ] || fail "direct infix: '$vc_infix'"
[ "$target_version_code" = "500" ] || fail "direct target: '$target_version_code'"
[ -f "$t/dl/com.example.app-1.0.1-500-arm64-v8a.apk" ] || fail "direct artifact not renamed"
reset_scope "1.0" ""
args[direct_dlurl]="https://host/nameless"
META_VERSIONNAME="1.0.1"
META_VERSIONCODE="500"
_vc_pinned_by_config=true
GATE_RC=1
_rekey_to_bytes direct "$META_VERSIONNAME" && fail "pinned direct build kept an uncovered version"
[ "$target_version_code" = "" ] || fail "hand-pinned code was overwritten: '$target_version_code'"
[ -z "${args[direct_dlurl]}" ] || fail "direct source was not dropped after serving an uncovered build"
[ -n "${args[apkmirror_dlurl]}" ] || fail "dropping direct must not disable the versioned sources"

# --- 5. a vendor bundle keeps its extension through the rename ---------------------
# Morphe passthrough hands the patcher the .apkm itself. Composing an .apk name would
# leave the bundle under the old label for the sidecar scan to pick up as a second file.
reset_scope "2.1.5-nogms" "79"
rm -f "$stock_apk" "$all_apk"
stock_apk="$t/dl/com.example.app-2.1.5-nogms-79-arm64-v8a.apkm"
all_apk="$stock_apk"
: >"$stock_apk"
META_VERSIONNAME="2.1.5-gms"
_rekey_to_bytes apkmirror "$META_VERSIONNAME" || fail "bundle re-key dropped the source"
[ -f "$t/dl/com.example.app-2.1.5-gms-79-arm64-v8a.apkm" ] || fail "bundle not renamed: $(ls dl | tr '\n' ' ')"
[ ! -e "$t/dl/com.example.app-2.1.5-nogms-79-arm64-v8a.apkm" ] || fail "bundle left under the old label"
[ ! -e "$t/dl/com.example.app-2.1.5-gms-79-arm64-v8a.apk" ] || fail "rename invented an .apk beside the .apkm"

# --- 6. an unreadable manifest judges nothing and changes nothing ------------------
# Negative control for cases 2-5: a _meta_field_of that answers "" must not be read as a
# mismatch, or every app whose bundle aapt cannot parse would lose its fetch.
reset_scope "2.1.5" "79"
META_VERSIONNAME=""
_rekey_to_bytes apkmirror "$META_VERSIONNAME" || fail "unreadable identity dropped a source"
[ "$GATE_CALLS" = 0 ] || fail "unreadable identity re-ran the gate"
[ -f "$stock_apk" ] || fail "unreadable identity moved the artifact"

# --- 7. the two spellings of one version fold to the same key ----------------------
# Bundles print "348.10 - Stable" while the engine's label drops the spaces; comparing the
# raw strings would call every such app a mismatch and re-download the world.
reset_scope "348.10-Stable" "34810"
META_VERSIONNAME="348.10 - Stable"
_rekey_to_bytes uptodown "$META_VERSIONNAME" || fail "spacing difference was read as a mismatch"
[ "$GATE_CALLS" = 0 ] || fail "spacing difference re-ran the gate ($GATE_CALLS)"
[ "$version_f" = "348.10-Stable" ] || fail "label rewritten for nothing: '$version_f'"

# --- 8. a cached file is judged by its bytes too -----------------------------------
reset_scope "2.1.5-nogms" "79"
META_VERSIONNAME="2.1.5-gms"
_cached_identity_disagrees "$stock_apk" "$version_f" || fail "a mislabeled cache entry read as honest"
META_VERSIONNAME="2.1.5-nogms"
! _cached_identity_disagrees "$stock_apk" "$version_f" || fail "an honest cache entry read as a lie"
META_VERSIONNAME=""
! _cached_identity_disagrees "$stock_apk" "$version_f" || fail "unreadable cache identity read as a lie"
META_VERSIONNAME=" 2.1.5-nogms "
! _cached_identity_disagrees "$stock_apk" "2.1.5-nogms" || fail "surrounding spaces fooled the fold"

echo "artifact identity: all cases passed"
