#!/usr/bin/env bash
# Golden tests for the archive page generator (.github/scripts/build_archive_pages.py).
#
# Fixtures cover the rules that are easy to break silently: brand and variant
# section order, the folded patch list above its own build table, the whole-kind
# delta line, a per-arch difference that must NOT be presented as a whole-kind one,
# page splitting with absolute navigation, and the index's optional Downloads column
# with its compact labels.
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
COUNTS=".github/traces/fixtures/archive_pages/counts.json"
GOLD=".github/traces/goldens/archive_pages"
MODE="${1:-verify}"
fail() { echo "FAIL: $*"; exit 1; }

t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
# Pinned so the hub URL in the goldens is the test's, not the developer's.
export NULLSTORE_URL="https://nullstore.example/hub"

run() { # $1 generator, $2 cap, $3 out, rest goes to the generator
	local gen=$1 cap=$2 out=$3
	shift 3
	python3 "$gen" --manifests "$FIX" --out "$out" --cap "$cap" "$@" >/dev/null \
		|| fail "generator exited non-zero ($gen cap $cap)"
}

run "$GEN" 50 "$t/a" --counts "$COUNTS"
run "$GEN" 50 "$t/b" --counts "$COUNTS"

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
run "$t/gen.py" 50 "$t/p" --counts "$COUNTS"
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

# Scope tags. A patch every module lacks is tagged by kind; a patch one arch of
# APKs lacks is tagged by arch, the case the old whole-kind rule silently dropped.
grep -q '<li>GmsCore support <code>module omit</code></li>' \
	"$t/a/apps/youtube/README.md" \
	|| fail "the module scope tag is missing"
grep -q '<li>gamma <code>arm omit</code></li>' "$t/a/apps/youtube/README.md" \
	|| fail "the arch scope tag is missing"

# The scope app covers the three harder shapes: one audience lacking, one audience
# carrying, and a lacking set that no single phrase describes.
grep -q '<li>Beta <code>arm apk omit</code></li>' "$t/a/apps/scope/README.md" \
	|| fail "a single audience lacking is not named"
grep -q '<li>Delta <code>arm64 only</code></li>' "$t/a/apps/scope/README.md" \
	|| fail "a patch carried by one audience is not marked only"
grep -q '<li>Echo <code>arm64 module</code> <code>arm apk omit</code></li>' \
	"$t/a/apps/scope/README.md" || fail "the multi-audience list is wrong"

# The folded list is HTML on purpose: kramdown leaves markdown inside a <details>
# block unparsed, which is how the published site showed 108 patches as one run of
# text. A stray "- " line would mean that regression came back.
grep -q '<li>' "$t/a/apps/youtube/README.md" || fail "the patch list is not an HTML list"
grep -q '^- ' "$t/a/apps/youtube/README.md" \
	&& fail "a markdown list leaked into the details block"

# The home table marks each date so the site's script can render a label in the
# reader's time zone. Without JS the UTC date must stay readable, so the text is
# the date part of the timestamp.
grep -q '<time datetime="[^"]*" data-relative>[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]</time>' \
	"$t/a/README.md" || fail "index dates are not marked for relative rendering"

# A beta build gets a test-tube after its link, stable rows stay bare, and the
# index carries no marker. The emoji is built from bytes, and grep runs under
# LC_ALL=C because MSYS grep silently fails to match a multibyte pattern in a
# UTF-8 locale.
beta=$(printf '\xf0\x9f\xa7\xaa')
LC_ALL=C grep -q "releases/tag/260002) $beta" "$t/a/apps/youtube/README.md" \
	|| fail "beta build 260002 is not marked"
LC_ALL=C grep -q "releases/tag/260001) $beta" "$t/a/apps/youtube/README.md" \
	&& fail "stable build 260001 was marked"
LC_ALL=C grep -q "$beta" "$t/a/README.md" && fail "the index carries a beta marker"

# The index's Downloads column, from the counters file. Each row shape is a case:
# 1,204 collapses to 1.2k, a round 2,000 loses its .0, 999 stays plain digits, a
# real zero prints 0, and Prime Video, which the fixture never mentions, gets an
# empty cell rather than a false 0.
grep -q '^| App | Last build | Downloads |$' "$t/a/README.md" \
	|| fail "the Downloads column header is missing"
grep -q '^|---|---|---:|$' "$t/a/README.md" \
	|| fail "the Downloads column is not right-aligned"
grep -q '| 1\.2k |$' "$t/a/README.md" || fail "1204 did not render as 1.2k"
grep -q '| 2k |$' "$t/a/README.md" || fail "2000 kept its .0 instead of reading 2k"
grep -q '| 999 |$' "$t/a/README.md" || fail "999 was not left as plain digits"
grep -q '| 0 |$' "$t/a/README.md" || fail "a genuine zero is not printed as 0"
grep -q '</time> | |$' "$t/a/README.md" \
	|| fail "an app with no counters did not get a blank cell"
# The app pages head their link column Download, not Downloads: it offers files,
# and borrowing the index's word would make a reader look for a number. Matched on
# the header line, because a real YouTube patch is named `Downloads`.
grep -q '^| Build | Date | Version | Download |$' "$t/a/apps/youtube/README.md" \
	|| fail "the build table's link column is not headed Download"
grep -q '^| Build | Date | Version | Downloads |$' "$t/a/apps/youtube/README.md" \
	&& fail "an app page still heads its link column Downloads"
# Negative control: the column is the flag's doing, not a default someone can drop
# by accident, and dropping it leaves the index exactly as it was.
run "$GEN" 50 "$t/nocounts"
grep -q 'Downloads' "$t/nocounts/README.md" \
	&& fail "the index grew a Downloads column without --counts"
# The header totals under the title: the fixture's five apps and the same downloads
# the table adds up to, 1,204 + 2,000 + 999 + 0 = 4,203, printed in the same compact
# form as a cell because the mirror never prunes. Matched as bytes with -F because the
# separator is multibyte and MSYS grep mis-handles a multibyte pattern in a UTF-8
# locale.
stats_counted=$(printf '<p class="stats"><b>5</b> apps \xc2\xb7 <b>4.2k</b> downloads</p>')
stats_bare=$(printf '<p class="stats"><b>5</b> apps</p>')
LC_ALL=C grep -qF "$stats_counted" "$t/a/README.md" \
	|| fail "the header totals are wrong or missing"
LC_ALL=C grep -qF "$stats_bare" "$t/nocounts/README.md" \
	|| fail "the uncounted index lost the app total instead of dropping just the rest"

# Variant sections: Standard first, then alphabetical.
first_two=$(awk '/^### /{print $2}' "$t/a/apps/youtube/README.md" | head -2 | tr '\n' ' ')
[ "$first_two" = "Standard Experimental " ] \
	|| fail "variants not Standard-first then alphabetical: [$first_two]"

# Sub-variants: a named sub below a variant is an h4, but a sub with no variant
# of its own is promoted to the variant heading, so Piko's Clone and Instafel's
# variant Clone read the same.
grep -q '^### Android TV$' "$t/a/apps/primevideo/README.md" \
	|| fail "the variant heading is missing"
grep -q '^#### Clone$' "$t/a/apps/primevideo/README.md" \
	|| fail "the named sub-variant is not an h4 under its variant"
grep -q '^#### Standard$' "$t/a/apps/primevideo/README.md" \
	&& fail "the base build gained a sub-variant heading"
grep -q '^### Standard$' "$t/a/apps/instagram/README.md" \
	|| fail "a null variant did not fall back to Standard"
grep -q '^### Clone$' "$t/a/apps/instagram/README.md" \
	|| fail "a lone sub-variant was not promoted to a variant heading"
grep -q '^#### Clone$' "$t/a/apps/instagram/README.md" \
	&& fail "a lone sub-variant kept an h4 under Standard"

# Pagination splits on block boundaries and navigates absolutely.
run "$GEN" 1 "$t/split"
[ -f "$t/split/apps/youtube/2.md" ] || fail "cap 1 did not paginate the YouTube app"
grep -q 'newer builds →](https://github.com/nullcpy/archive/blob/main/apps/youtube/README.md)' \
	"$t/split/apps/youtube/2.md" || fail "page 2 lacks an absolute link back to page 1"

# Second surface: with a pages base set, index.md mirrors each page for Jekyll.
# GitHub renders front matter as a metadata table, so only the index.md copies may
# carry it, and only they may link at the published site.
PAGES="https://pages.example/archive"
ARCHIVE_PAGES_BASE="$PAGES" run "$GEN" 1 "$t/two"
[ -f "$t/two/index.md" ] || fail "no root index.md for the pages surface"
[ -f "$t/two/apps/youtube/index.md" ] || fail "no app index.md for the pages surface"
[ "$(head -1 "$t/two/apps/youtube/index.md")" = "---" ] \
	|| fail "index.md lacks the front matter Jekyll needs to render it"
[ "$(head -1 "$t/two/apps/youtube/README.md")" = "# YouTube" ] \
	|| fail "README.md gained front matter, which GitHub would render as a table"
grep -q "($PAGES/apps/youtube/)" "$t/two/index.md" \
	|| fail "root index.md does not link at the pages base"
grep -q "($PAGES/apps/youtube/page-2.html)" "$t/two/apps/youtube/index.md" \
	|| fail "paginated index.md does not use the .html page URL"
# Both surfaces write into one directory, so their continuation files must differ:
# a shared 2.md would let the second surface overwrite the first.
[ -f "$t/two/apps/youtube/2.md" ] && [ -f "$t/two/apps/youtube/page-2.md" ] \
	|| fail "the two surfaces collide on continuation file names"
[ "$(head -1 "$t/two/apps/youtube/2.md")" = "# YouTube" ] \
	|| fail "2.md was overwritten by the pages surface"
# Each surface must stay on its own host: the README is read on github.com and the
# index on the published site, so a link crossing over sends the reader elsewhere.
grep -q "($PAGES" "$t/two/apps/youtube/README.md" \
	&& fail "README.md leaked pages-base links"
grep -q 'blob/main' "$t/two/apps/youtube/index.md" \
	&& fail "index.md leaked blob/main links"
grep -q 'https://github.com/nullcpy/archive/blob/main/apps/youtube/README.md' \
	"$t/two/apps/youtube/2.md" || fail "README surface page 2 lacks a link back to page 1"
grep -q 'https://github.com/nullcpy/archive/releases/download/' \
	"$t/two/apps/youtube/index.md" || fail "index.md lost the absolute release links"

# The two surfaces must be the same page: strip the front matter and normalise the
# differing link base, then require the bodies to match. This is what stops the
# mirror from silently drifting into a second, smaller page.
sed '1,4d' "$t/two/apps/youtube/index.md" \
	| sed -e "s#$PAGES/apps/youtube/#BASE#g" \
	      -e 's#page-\([0-9]*\)\.html#\1.md#g' > "$t/b_index"
sed -e 's#https://github.com/nullcpy/archive/blob/main/apps/youtube/#BASE#g' \
	"$t/two/apps/youtube/README.md" > "$t/b_readme"
cmp -s "$t/b_index" "$t/b_readme" || fail "index.md and README.md bodies diverged"

echo "PASS: archive page generation"
