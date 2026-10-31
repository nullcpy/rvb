# 0016 — The archive is generated markdown on its own branches

**Status:** accepted (2026-10-30)
**Affects:** `nullcpy/archive` `main` (README surface plus chrome) and its `site`
branch (Pages surface plus a synced chrome copy), that repo's `pages.yml`, the role
of its `website` branch, rvb `build.yml`'s `Notify archive pages` step,
`.github/scripts/build_archive_pages.py`.

## Context

[0015](0015-builds-are-mirrored-to-a-permanent-archive-repo.md) put a per-build
manifest on the archive repo's `website` branch and left the viewing question open.
The obvious answer, extending the `nullcpy.github.io` catalogue, was measured rather
than assumed: 1156 file entries across 98 builds, and one app's applied-patch lists
inlined per build reach 282 KB, of which 87 percent is the same list repeated. It
would also need a live Releases-API pass for existence and size, which a permanent
mirror does not have, plus another front end to keep in step with the first.

## Decision

Do not build a catalogue site for the archive. Generate a markdown tree and commit each
surface to its own branch:

- `README.md` is the index: a table of apps with each one's last build date, and a
  line sending anyone after the newest versions or one-tap Obtainium adds to
  NullStore.
- `apps/<appKey>/README.md`: brand section, then variant (`Standard` first, then
  alphabetical), then one folded block per distinct applied-patch list with that
  block's own build table beneath it, so the list sits above the builds it covers.
- Data stays on `website` (`manifests/` and nothing else). Nothing on `main` links
  into `website`, so the data layer can change shape without breaking a visible link.
- rvb triggers a rebuild with a `workflow_dispatch` gated on the manifest script's
  `PUBLISHED` output; the archive's own workflow renders and commits with its own
  `GITHUB_TOKEN`, so no cross-repo token is needed inside it.
- Every link is absolute. A relative link 404s for a reader who is logged out of
  github.com, which is most of the audience.
- The generator is stdlib-only and is imported through a sparse clone of rvb `main`,
  the same rule as `naming.py` ([0006](0006-filename-parsing-is-imported-not-mirrored.md)).
- Two surfaces come out of one pass. `README.md` is what github.com renders per
  folder, so it carries no front matter (GitHub would show it as a metadata table)
  and links at `blob/main`; it is committed to `main`. `index.md` mirrors it for
  Pages, with front matter (Jekyll ignores a markdown file without it) and links at
  the published site; it is committed to `site`, which also carries a synced copy of
  the chrome and is the only source the Jekyll build reads. Continuation pages differ
  per surface, `2.md` versus `page-2.html`, because both write into one app directory
  and a shared name let the second overwrite the first.

## Rejected alternatives

- **Extend the main catalogue site.** A second build pipeline, plus an API pass for
  mutability the archive does not have, for a view that does not need to be interactive.
- **Serve the pages from `website`.** Two indexes on two branches, and the repository
  landing page stays the human placeholder nobody sees past.
- **Append one line per build to a growing file.** An append that corrupts once stays
  corrupt, which is the 2026-09-24 lesson in [0002](0002-manifests-live-on-a-branch.md);
  regenerating from scratch converges instead, so a bad run is healed by the next one.
- **Per-row patch attribution.** A `Patches` column plus per-arch delta wording was
  built and reviewed, then reverted: it exists for 3 rows in 772. A kind-level delta is
  now stated only when that kind deviates identically everywhere in the block, and a
  difference confined to one arch is left unmentioned rather than misattributed.

## Consequences

- The archive repo's `main` and `site` branches are CI-owned. Hand-written prose
  belongs in `ABOUT.md` or in the generator's template, never in a generated page.
- A rebuild commits, so history grows. Commit-only-if-changed plus the golden
  determinism test is what keeps that from becoming noise; the same ordering rules are
  why every collection in the generator is sorted with a tie-break.
- Pages are as fresh as the last dispatch, with a weekly schedule as the backstop for a
  lost one.
- A wrong page is fixed by rerunning the generator over `manifests/`, never by editing
  a file on either branch.

## Verification

`bash .github/traces/test_archive_pages.sh` compares against goldens, asserts two runs
are identical, and asserts a perturbed sort key changes the output so the comparison
cannot pass vacuously. `.github/traces/test_archive_mirror.sh` block (c) covers the
`PUBLISHED` gate that starts the whole thing.
