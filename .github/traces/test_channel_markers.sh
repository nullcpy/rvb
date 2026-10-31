#!/usr/bin/env bash
# Parity tests for the pre-release marker vocabulary that four places have to agree
# on: the engine's release picker (scripts/utils.sh, GitLab arm), the CI watcher
# (.github/scripts/sync_patch_sources.py), the config pool router
# (.github/scripts/compile_patch_configs.py) and the module that owns the words
# (.github/scripts/channels.py).
#
# Copies that merely happen to agree are one edit away from disagreeing silently, so
# each rule is asserted twice over: the shell and the module must build the SAME
# pattern string, and the two regex engines must classify the SAME tags the same way.
# The controls are what make the negative assertions mean something - the pre-guard
# pattern is re-run to prove a tag the guard rejects was really rejected by the guard,
# and a flagged GitHub release with an unmarked tag proves the engine reads the flag
# and not the name.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$REPO" || exit 1
# shellcheck disable=SC1091
source scripts/utils.sh >/dev/null 2>&1

fail() { echo "FAIL: $*"; exit 1; }
command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"

# Import by running from the scripts dir, the way test_config_rearm.sh does: a Git
# Bash path means nothing to a Windows python, so sys.path juggling would work in CI
# and fail on a laptop.
py() { (cd .github/scripts && python3 -c "$1" "${@:2}"); }

# ---------------------------------------------------------------- one pattern string
sh_re=$(channel_beta_re)
py_re=$(py "import channels as c; print(c.TAG_MARKER_PATTERN, end='')")
[ -n "$sh_re" ] || fail "channel_beta_re emitted nothing"
[ -n "$py_re" ] || fail "channels.TAG_MARKER_PATTERN is empty"
[ "$sh_re" = "$py_re" ] || fail "engine and channels.py build different patterns
  shell: $sh_re
  py   : $py_re"
# The words themselves, not only the assembled string: a reordered or reworded list
# changes the pattern too, but membership is what a reader compares.
sh_words=$(printf '%s\n' ${RVB_CHANNEL_MARKERS} | sort | paste -sd' ' -)
py_words=$(py "import channels as c; print(' '.join(sorted(c.PRE_RELEASE_MARKERS)))")
[ "$sh_words" = "$py_words" ] || fail "marker words disagree
  shell: $sh_words
  py   : $py_words"

# ---------------------------------------------------------------- same verdicts
jq_pre() { jq -rn --arg re "$1" --arg tag "$2" '$tag | test($re; "i")'; }
py_pre() { py "import sys, channels as c; print(str(c.is_pre_release_tag(sys.argv[1])).lower())" "$1"; }

CASES=(
	'v1.20.0-dev.4|true'
	'v2.9.0-experimental.5|true'
	'v2.10.0-experimental.9|true'
	'v1.0.0-exp.3|true'
	'v1.0.0-EXP|true'
	'v1.0.0.pre.2|true'
	'v1.0.0_rc1|true'
	'v1.2.3-beta|true'
	'v2.0.0-rc|true'
	'v1.0.0-Alpha.1|true'
	'v1.0.0-pre|true'
	'v2.9.0|false'
	'1.2.3|false'
	'v1.0.0-express.1|false'
	'v1.0.0-preview|false'
	'v1.0.0-arch|false'
	'v1.0.0-search|false'
	'v1.0.0-device|false'
	'v1.0.0-alphabet|false'
	'v1.2.3beta1|false'
	'|false'
)
n_true=0
n_false=0
for entry in "${CASES[@]}"; do
	tag=${entry%|*}
	want=${entry##*|}
	got=$(jq_pre "$sh_re" "$tag") || fail "jq could not test '$tag'"
	[ "$got" = "$want" ] || fail "engine pattern on '$tag': got $got, want $want"
	got=$(py_pre "$tag") || fail "channels.py could not test '$tag'"
	[ "$got" = "$want" ] || fail "channels.py on '$tag': got $got, want $want"
	[ "$want" = true ] && n_true=$((n_true + 1)) || n_false=$((n_false + 1))
done
# A table that is one-sided proves nothing about the other side.
[ "$n_true" -ge 8 ] && [ "$n_false" -ge 8 ] ||
	fail "case table is one-sided: $n_true prerelease, $n_false not"

# ------------------------------------------------- the guard is what bites, control
# The filter the engine used before the guard: a bare word search. Every tag below
# matched it and must not match the guarded one, so a regression that drops the
# classes cannot pass this suite by re-declaring them prerelease.
LOOSE='(dev|alpha|beta|rc)'
for tag in v1.0.0-arch v1.0.0-search v1.0.0-device v1.0.0-alphabet v1.2.3beta1; do
	[ "$(jq_pre "$LOOSE" "$tag")" = "true" ] ||
		fail "control broken: the pre-guard pattern no longer matches '$tag'"
	[ "$(jq_pre "$sh_re" "$tag")" = "false" ] ||
		fail "the separator guard does not bite on '$tag'"
done

# ---------------------------------------------------------------- engine: channel heads
# GitLab has no pre-release flag, so these verdicts come from the tag alone.
# "-exp.3" is the word this suite exists for; "-search" is the tag the old loose
# filter claimed as a pre-release and the guard hands back to stable.
LIST=$(cat <<'JSON'
[
	{"tag_name": "v1.0.0", "released_at": "2026-01-01T00:00:00Z"},
	{"tag_name": "v1.0.2-exp.3", "released_at": "2026-01-02T00:00:00Z"},
	{"tag_name": "v1.0.1-search", "released_at": "2026-01-03T00:00:00Z"}
]
JSON
)
beta=$(source_release_pick_from_list gitlab beta <<<"$LIST" | jq -r '.tag_name') ||
	fail "gitlab beta pick failed"
stable=$(source_release_pick_from_list gitlab stable <<<"$LIST" | jq -r '.tag_name') ||
	fail "gitlab stable pick failed"
[ "$beta" = "v1.0.2-exp.3" ] || fail "gitlab beta head: got $beta, want v1.0.2-exp.3"
[ "$stable" = "v1.0.1-search" ] || fail "gitlab stable head: got $stable, want v1.0.1-search"

# GitHub and Forgejo: the flag alone decides, by design. The flagged release with an
# unmarked tag is the beta head, and the unflagged release with a marked tag is the
# stable head, so this arm cannot start reading tags without failing here first.
GH_LIST=$(cat <<'JSON'
[
	{"tag_name": "v1.5.0", "prerelease": true, "draft": false, "published_at": "2026-01-05T00:00:00Z"},
	{"tag_name": "v1.6.0-beta.1", "prerelease": false, "draft": false, "published_at": "2026-01-06T00:00:00Z"}
]
JSON
)
beta=$(source_release_pick_from_list github beta <<<"$GH_LIST" | jq -r '.tag_name') ||
	fail "github beta pick failed"
stable=$(source_release_pick_from_list github stable <<<"$GH_LIST" | jq -r '.tag_name') ||
	fail "github stable pick failed"
[ "$beta" = "v1.5.0" ] || fail "github beta head must follow the flag: got $beta"
[ "$stable" = "v1.6.0-beta.1" ] || fail "github stable head must follow the flag: got $stable"

# ---------------------------------------------------------------- watcher: same words
# parse_releases is driven for real over a mirror whose publisher never ticked the
# box: the marker has to route it to beta there, and to beta on GitLab too, where
# there is no flag to consult at all.
for host in github gitlab; do
	out=$(py "
import sync_patch_sources as s
rels = [
    {'tag_name': 'v2.0.0', 'prerelease': False, 'draft': False,
     'published_at': '2026-01-01', 'released_at': '2026-01-01'},
    {'tag_name': 'v2.1.0-experimental.3', 'prerelease': False, 'draft': False,
     'published_at': '2026-01-02', 'released_at': '2026-01-02'},
]
print(' '.join(s.parse_releases(rels, '$host')))
") || fail "could not run parse_releases for $host"
	[ "$out" = "v2.0.0 2026-01-01 v2.1.0-experimental.3 2026-01-02" ] ||
		fail "$host watcher heads: got [$out]"
done

# ------------------------------------------------------------- pool router: same words
# A pin and the tag it names must not be read by different lists, or an app lands in
# the stable pool while its own tag says pre-release.
for pair in 'v2.1.0-experimental.3:true' 'v1.0.0-exp.3:true' 'v1.0.0-preview:false' \
	'v1.0.0-arch:false' 'v1.20.0-dev.4:true'; do
	pin=${pair%:*}
	want=${pair##*:}
	got=$(py "import channels as c; print(str(c.is_pre_release_tag('$pin')).lower())")
	[ "$got" = "$want" ] || fail "pool routing of pin '$pin': got $got, want $want"
done

# ------------------------------------------------- pool router, driven for real
# The compiler is run over a sandbox configs dir (nothing here touches the repo's
# own configs/ or the emitted pools), so the wiring is tested and not just the
# module it now imports. Exp-pin is the added word, Alphabet-pin is the guard: its
# pre-guard spelling of the same tag was a beta pin, because `alpha` matched without
# having to end at a separator.
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
cfg="$t/pins"
mkdir -p "$cfg"
cat >"$cfg/pins.toml" <<'TOML'
[Exp-pin]
pkg-name = "com.exp.pin"
patches-version = "v2.1.0-experimental.3"

[Alphabet-pin]
pkg-name = "com.alphabet.pin"
patches-version = "v1.0.0-alphabet"

[Plain-pin]
pkg-name = "com.plain.pin"
patches-version = "v2.9.0"

[Kw-beta]
pkg-name = "com.kw.beta"
patches-version = "beta"
TOML
(cd "$t" && python3 "$REPO/.github/scripts/compile_patch_configs.py" "$cfg") \
	>/dev/null 2>&1 || fail "compile_patch_configs.py exited non-zero"
[ -f "$t/config.beta.json" ] && [ -f "$t/config.stable.json" ] ||
	fail "the compiler wrote no pools into $t"
pool_has() { jq -e --arg k "$2" '.[$k] != null' "$t/config.$1.json" >/dev/null; }
pool_absent() { jq -e --arg k "$2" '.[$k] == null' "$t/config.$1.json" >/dev/null; }
pool_has beta Exp-pin || fail "an -experimental.3 pin must compile into the beta pool"
pool_absent stable Exp-pin || fail "an -experimental.3 pin also landed in stable"
pool_has stable Alphabet-pin || fail "a -alphabet pin is not a marker and must be stable"
pool_absent beta Alphabet-pin || fail "the guard did not reach the pool router"
pool_has stable Plain-pin || fail "an unmarked pin lost its stable pool"
pool_has beta Kw-beta || fail "the beta keyword stopped routing to beta"
pool_absent stable Kw-beta || fail "the beta keyword landed in both pools"

echo "OK: channel markers agree across engine, watcher and pool router"
