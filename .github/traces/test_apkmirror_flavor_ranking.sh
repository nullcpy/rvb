#!/usr/bin/env bash
# Regression tests for the flavour ranking in _apkmirror_version_hrefs: when a version
# request carries a suffix (2.1.5-nogms, 1.7.0-lite, 4.50.1_tv), a release page whose slug
# names that suffix has to be chosen over one that names a different flavour of the same
# number, and the loose tier must still answer when the store spells no suffix at all.
#
# Why this exists as its own gate: run 41314721427 asked Proton Lumo 2.1.5-nogms while
# APKMirror ships only 2.1.5-gms (same versionCode 79). The exact-suffix tier is what makes
# that request take a nogms page whenever one exists, and the loose tier is what keeps
# apps whose store drops the suffix building; both are load-bearing, and neither was pinned
# by a test. Reordering the tiers, or widening the loose regex past the version, breaks one
# of the two silently. _rekey_to_bytes judges the fetched bytes afterwards, so the loose
# tier is allowed to be wrong about the flavour but never about the version.
#
# Pure function, real data: hrefs in, ordered hrefs out. No network, no stubs.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
# shellcheck disable=SC1091
source scripts/utils.sh >/dev/null 2>&1
fail() { echo "FAIL: $*"; exit 1; }

LIST="/apk/proton-technologies-ag/lumo-by-proton"

# order <search_version> <clean_search_version> <short> <hrefs> -> position of each hit
run_rank() {
	local sv=$1 csv=$2 ssv=$3 links=$4
	_apkmirror_version_hrefs "$links" "$LIST" "$sv" "$csv" "$ssv"
}

# --- 1. the exact flavour wins over another flavour of the same number --------------
links="$LIST/lumo-by-proton-2-1-5-gms-release/
$LIST/lumo-by-proton-2-1-5-nogms-release/"
out=$(run_rank "2-1-5-nogms" "2-1-5" "2-1" "$links") || fail "flavour ranking returned nothing"
first=$(printf '%s\n' "$out" | head -1)
# The store writes its release links with a trailing slash, and the tier keeps them verbatim.
[ "$first" = "$LIST/lumo-by-proton-2-1-5-nogms-release/" ] ||
	fail "requested nogms but the field starts with: $first"
[ "$(printf '%s\n' "$out" | grep -c .)" = 2 ] ||
	fail "the gms page must stay in the field as the fallback: $(printf '%s\n' "$out" | tr '\n' ' ')"

# --- 2. no flavour page exists: the loose tier still answers ------------------------
# This is the case that keeps suffixed versions building where the store prints no suffix
# (InternetSpeedMeterLite asks 1.7.0-lite, APKMirror ships 1.7.0). Refusing it would lose a
# buildable app, which is why the answer is a warning plus the byte gate, not a rejection.
links="$LIST/lumo-by-proton-2-1-5-gms-release/"
out=$(run_rank "2-1-5-nogms" "2-1-5" "2-1" "$links") || fail "loose tier refused a same-version page"
[ "$out" = "$LIST/lumo-by-proton-2-1-5-gms-release/" ] || fail "loose tier changed the field: $out"

links="$LIST/meter-lite-1-7-0-release/"
run_rank "1-7-0-lite" "1-7-0" "1-7" "$links" >/dev/null ||
	fail "suffix-less slug refused a 1.7.0-lite request"

# --- 3. a flavour match never outranks the version ----------------------------------
# Negative control for case 1: if the ranking keyed on the suffix alone, this older nogms
# release would be preferred and the build would fetch the wrong app version.
links="$LIST/lumo-by-proton-2-1-4-nogms-release/
$LIST/lumo-by-proton-2-1-5-gms-release/"
out=$(run_rank "2-1-5-nogms" "2-1-5" "2-1" "$links") || fail "no candidate for the requested number"
first=$(printf '%s\n' "$out" | head -1)
case "$first" in
*2-1-5-gms-release*) : ;;
*) fail "2.1.4-nogms outranked the requested 2.1.5: $first" ;;
esac

# --- 4. an unrelated version is not dragged in by a shared suffix -------------------
links="$LIST/other-app-9-9-9-nogms-release/
$LIST/lumo-by-proton-2-1-5-nogms-release/"
out=$(run_rank "2-1-5-nogms" "2-1-5" "2-1" "$links") || fail "flavour match lost"
[ "$(printf '%s\n' "$out" | grep -c .)" = 1 ] ||
	fail "a different version with the same flavour joined the field: $(printf '%s\n' "$out" | tr '\n' ' ')"

# --- 5. listing order and duplicates survive the reordering -------------------------
links="$LIST/b-2-1-5-nogms-release/
$LIST/a-2-1-5-nogms-release/
$LIST/b-2-1-5-nogms-release/"
out=$(run_rank "2-1-5-nogms" "2-1-5" "2-1" "$links") || fail "ordering run returned nothing"
[ "$(printf '%s\n' "$out" | grep -c .)" = 2 ] || fail "duplicate not collapsed: $out"
[ "$(printf '%s\n' "$out" | head -1)" = "$LIST/b-2-1-5-nogms-release/" ] ||
	fail "reordering disturbed the field: $(printf '%s\n' "$out" | tr '\n' ' ')"

# --- 6. reading the flavour off the request ---------------------------------------
# dl_apkmirror hands this the version with its spaces already folded to dashes, which is
# the shape asserted below. An empty answer must mean "no flavour to honour", so a plain
# numeric version never trips the warning that follows a loose tier.
check_flavor() { # $1=version  $2=expected flavour
	local got
	got=$(_apkmirror_flavor_of "$1")
	[ "$got" = "$2" ] || fail "_apkmirror_flavor_of '$1' gave '$got', expected '$2'"
}
check_flavor "2.1.5-nogms" "nogms"
check_flavor "2.1.5-NOGMS" "nogms"
check_flavor "1.7.0-lite" "lite"
check_flavor "4.50.1-tv" "tv"
check_flavor "348.10---stable" "stable"
check_flavor "14.0.39" ""
check_flavor "v2.0.0" ""

echo "apkmirror flavour ranking: all cases passed"
