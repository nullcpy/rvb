#!/usr/bin/env bash
# Golden tests for the archive page generator (.github/scripts/build_archive_pages.py).
#
# Fixtures cover the rules that are easy to break silently: brand and variant
# section order, the folded patch list above its own build table, the whole-kind
# delta line, a per-arch difference that must NOT be presented as a whole-kind one,
# and page splitting with absolute navigation.
#
# Three separate claims, because a byte comparison alone proves little:
#   1. output equals the committed goldens;
#   2. two runs are identical to each other (determinism: a wobbling generator would
#      rewrite archive files whose data never changed, and every rebuild would land
#      as churn in the archive repo's history);
#   3. a perturbed sort key changes the output (negative control; without it a
#      generator that ignored its ordering entirely would still pass test 1).
#
# Usage: bash test_archive_pages.sh [--capture]   # --capture rewrites the goldens
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
GEN=".github/scripts/build_archive_pages.py"
FIX=".github/traces/fixtures/archive_pages/manifests"
GOLD=".github/traces/goldens/archive_pages"
MODE="${1:-verify}"
fail() { echo "FAIL: $*"; exit 1; }

t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
# Pinned so the hub URL in the goldens is the test's, not the developer's.
export NULLSTORE_URL="https://nullstore.example/hub"

run() { # $1 generator, $2 cap, $3 out
	python3 "$1" --manifests "$FIX" --out "$3" --cap "$2" >/dev/null \
		|| fail "generator exited non-zero ($1 cap $2)"
}

run "$GEN" 50 "$t/a"
run "$GEN" 50 "$t/b"

if [ "$MODE" = "--capture" ]; then
	rm -rf "$GOLD"
	mkdir -p "$GOLD"
	cp -r "$t/a/." "$GOLD/"
	echo "captured goldens:"
	find "$GOLD" -type f | sort | sed 's/^/  /'
	exit 0
fi
[ -d "$GOLD" ] || fail "no goldens in $GOLD; run: bash $0 --capture"

diff -r "$GOLD" "$t/a" || fail "output drifted from the goldens"
diff -r "$t/a" "$t/b" || fail "two runs differ; output is not deterministic"

sed 's/ARCH_ORDER = {"arm64": 0, "arm": 1/ARCH_ORDER = {"arm": 0, "arm64": 1/' \
	"$GEN" > "$t/gen.py"
run "$t/gen.py" 50 "$t/p"
diff -r "$t/a" "$t/p" >/dev/null \
	&& fail "swapping the arch order changed nothing; arch sorting is not applied"

# No relative links anywhere: they 404 when a README is read while logged out of
# github.com, which is most of this site's audience.
targets=$(grep -rho ']([^)]*)' "$t/a" | sed -e 's/^](//' -e 's/)$//')
[ -n "$targets" ] || fail "no links found at all; the scan would pass vacuously"
bad=$(printf '%s\n' "$targets" | grep -vc '^http' || true)
[ "$bad" = 0 ] || fail "$bad relative link(s): $(printf '%s\n' "$targets" | grep -v '^http' | head -3)"

# Both hosts the pages use must appear as absolute URLs.
grep -q 'https://github.com/nullcpy/archive/releases/download/260002/' \
	"$t/a/apps/youtube/README.md" || fail "download links are not absolute"
grep -q 'https://github.com/nullcpy/archive/blob/main/apps/' \
	"$t/a/README.md" || fail "index links are not absolute blob/main URLs"

# Delta rule: a kind that deviates uniformly is stated; a kind that deviates for one
# arch only is left out rather than claimed for the whole kind.
grep -q '^- Module omit `GmsCore support`$' "$t/a/apps/youtube/README.md" \
	|| fail "uniform module delta missing from the Standard block"
grep -q '^- APK' "$t/a/apps/youtube/README.md" \
	&& fail "a one-arch APK difference was presented as a whole-kind delta"

# Variant sections: Standard first, then alphabetical.
first_two=$(awk '/^### /{print $2}' "$t/a/apps/youtube/README.md" | head -2 | tr '\n' ' ')
[ "$first_two" = "Standard Experimental " ] \
	|| fail "variants not Standard-first then alphabetical: [$first_two]"

# Pagination splits on block boundaries and navigates absolutely.
run "$GEN" 1 "$t/split"
[ -f "$t/split/apps/youtube/2.md" ] || fail "cap 1 did not paginate the YouTube app"
grep -q 'newer builds](https://github.com/nullcpy/archive/blob/main/apps/youtube/README.md)' \
	"$t/split/apps/youtube/2.md" || fail "page 2 lacks an absolute link back to page 1"

echo "PASS: archive page generation"
