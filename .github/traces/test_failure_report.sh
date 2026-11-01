#!/usr/bin/env bash
# Regression tests for .github/scripts/build_report_failures.sh: which sections a set of
# temp/failures records produces, in what order, and what each app line says.
#
# The report is the only thing a maintainer reads when a build silently does not ship, so
# the shape of its message is a contract. Everything here runs offline: `curl` is replaced
# by a stub that records the Telegram text it was handed (and answers a log upload with a
# fixed URL), so the assertions read exactly what would have been posted.
#
# Negative controls are part of the deal: an empty records dir must produce no send at all
# (a stub that always "succeeded" would otherwise make every case pass vacuously), and a
# record type the script does not know must not be mistaken for a plain build record.
#
# Assertions anchor on ASCII substrings only and run with LC_ALL=C: the section glyphs
# (🔩 🧩 🚨 📱 ⚠️) and the ╰ connector come from the script's own bytes, and Git Bash's grep
# is unreliable at matching a multibyte pattern against UTF-8 input under a non-UTF-8
# locale, which would make the suite machine-dependent rather than testing anything.
set -u
export LC_ALL=C
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

mkdir -p "$t/bin" "$t/work/temp"
# Stub curl: record Telegram message bodies in order, answer xi.pe uploads with a URL.
cat > "$t/bin/curl" << 'STUB'
#!/usr/bin/env bash
out=${REPORT_OUT:?}
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
	case "${args[i]}" in
	*sendMessage*) sending=1 ;;
	https://xi.pe*|*xi.pe/*) printf 'https://xi.pe/deadbeef\n'; sending=0; break ;;
	esac
done
[[ "${sending:-0}" = 1 ]] || exit 0
for ((i = 0; i < ${#args[@]}; i++)); do
	case "${args[i]}" in
	text=*) printf '%s\n----MESSAGE----\n' "${args[i]#text=}" >> "$out" ;;
	esac
done
exit 0
STUB
chmod +x "$t/bin/curl"

run_report() { # $1=label for the captured messages
	rm -f "$t/out"
	: > "$t/out"
	(
		cd "$t/work" || exit 1
		PATH="$t/bin:$PATH" REPORT_OUT="$t/out" GITHUB_OUTPUT="$t/gh_out" \
			TG_TOKEN=dummy TG_CHAT_ID=-100123 TG_THREAD_NOTIFY=7 \
			APKS_REPO=nullcpy/apks GITHUB_REPOSITORY=nullcpy/rvb \
			GITHUB_SERVER_URL=https://github.com GITHUB_RUN_ID=1 \
			DISCORD_WEBHOOK_GITHUB_LOG="" \
			bash "$ROOT/.github/scripts/build_report_failures.sh"
	) > "$t/stdout" 2>&1
}

# ---- 1. no records: nothing is sent -------------------------------------------
mkdir -p "$t/work/temp/failures"
run_report empty
grep -q "nothing to report" "$t/stdout" || fail "empty dir did not say 'nothing to report'"
[ -s "$t/out" ] && fail "empty records dir still posted a message"

# ---- 2. a zero-patch record renders the CLI Issue section ----------------------
rm -f "$t/work/temp/failures/"*.json
jq -n '{type:"no_patches_applied", app:"ProtonLumo-hxreborn (arm64-v8a)", version:"2.1.5-nogms",
        vc:"79", arch:"arm64-v8a", patches_src:"hxreborn/morphe-patches",
        pkg:"me.proton.android.lumo",
        patch_url:"https://github.com/hxreborn/morphe-patches/releases/tag/v1.68.0"}' \
	> "$t/work/temp/failures/protonlumo_npa.json"
run_report npa
msg=$(cat "$t/out")
grep -qF 'CLI Issue (1 app)*' <<< "$msg" || fail "CLI Issue heading missing: $msg"
grep -qF 'ProtonLumo-hxreborn*' <<< "$msg" || fail "app name lost the arch suffix: $msg"
grep -qF 'arm64-v8a `v2.1.5-nogms (79)`: hxreborn/morphe-patches ([v1.68.0](https://github.com/hxreborn/morphe-patches/releases/tag/v1.68.0))' <<< "$msg" ||
	fail "zero-patch app line wrong: $msg"
grep -qF 'The patcher applied 0 patches to these builds.' <<< "$msg" || fail "hint missing"
grep -qF '[View Run](https://github.com/nullcpy/rvb/actions/runs/1)' <<< "$msg" || fail "run footer missing"
grep -q 'reported_failures=true' "$t/gh_out" || fail "job output not set when a report is sent"

# ---- 3. section order: patch compatibility, then CLI issue ---------------------
jq -n '{type:"no_compatible_patches", app:"ProtonLumo-hxreborn (arm-v7a)", tried:"2.1.5-nogms",
        version:"2.1.5-nogms", vc:"", arch:"arm-v7a", patches_src:"hxreborn/morphe-patches",
        pkg:"me.proton.android.lumo",
        patch_url:"https://github.com/hxreborn/morphe-patches/releases/tag/v1.68.0",
        bytesVersion:"2.1.5-gms"}' > "$t/work/temp/failures/protonlumo_np.json"
run_report order
msg=$(cat "$t/out")
np_pos=$(grep -n 'Patch Compatibility' <<< "$msg" | head -1 | cut -d: -f1)
npa_pos=$(grep -n 'CLI Issue' <<< "$msg" | head -1 | cut -d: -f1)
[ -n "$np_pos" ] && [ -n "$npa_pos" ] || fail "one of the two sections is gone: $msg"
[ "$np_pos" -lt "$npa_pos" ] || fail "Patch Compatibility must precede CLI Issue ($np_pos vs $npa_pos)"
# The bytes column A added, rendered as its own clause.
grep -qF 'arm-v7a `v2.1.5-nogms`, file is `v2.1.5-gms`: hxreborn/morphe-patches ([v1.68.0]' <<< "$msg" ||
	fail "bytesVersion clause not rendered: $msg"

# ---- 4. a build record wins over its zero-patch twin ---------------------------
rm -f "$t/work/temp/failures/"*.json
jq -n '{type:"build_failed", app:"SomeApp-brand (arm64-v8a)", version:"1.0", vc:"10",
        arch:"arm64-v8a", patches_src:"o/r"}' > "$t/work/temp/failures/someapp.json"
jq -n '{type:"no_patches_applied", app:"SomeApp-brand (arm64-v8a)", version:"1.0", vc:"10",
        arch:"arm64-v8a", patches_src:"o/r", pkg:"com.example", patch_url:""}' \
	> "$t/work/temp/failures/someapp_npa.json"
run_report twin
msg=$(cat "$t/out")
grep -qF 'Build Failed (1 app)*' <<< "$msg" || fail "build section count wrong: $msg"
grep -qF 'CLI Issue (1 app)*' <<< "$msg" && fail "the twin was not dropped"
[ -f "$t/work/temp/failures/someapp_npa.json" ] && fail "twin file left on disk"

# ---- 5. an unknown suffix is not silently read as a build record ---------------
# Negative control for the case list at the top of the collector: a record type the script
# has never heard of must not appear as an app whose name ends in that suffix.
rm -f "$t/work/temp/failures/"*.json
jq -n '{type:"zzz", app:"GhostApp-brand (arm64-v8a)", version:"1.0", vc:"", arch:"arm64-v8a",
        patches_src:"o/r"}' > "$t/work/temp/failures/ghost_zz.json"
run_report unknown
msg=$(cat "$t/out")
grep -qF 'GhostApp-brand_zz' <<< "$msg" && fail "unknown suffix leaked into an app name"
grep -qF 'GhostApp-brand*' <<< "$msg" || fail "an unclassified record stopped being reported at all: $msg"

echo "failure report: all cases passed"
