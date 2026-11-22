# 0018 — GitHub Discussions are an additive build log

**Status:** accepted (2026-11-22)
**Affects:** `build.yml`, `build_report_failures.sh`, `build_notify_gh.sh`,
`notify_gh.sh`, `build_gh_download_table.py`, `GH_BUILDLOG_CATEGORY`, the
`discussions: write` permission, the `Build Log` discussion category and the
`build_log`, `stable`, `beta` and `build_issue` labels.

## Context

Build and failure notices already go to Telegram topics and mirrored Discord
channels. Those are push surfaces with short memory: a message scrolls away,
and the xi.pe links in the failure report expire after seven days. The archive
repo (ADR 0015) keeps the *files* permanently, but there was no durable,
readable place that tied one build's failures to its logs and its downloads.

GitHub Discussions can hold that record in the same repo, but it is a different
medium: GFM rather than Telegram HTML, a category rather than a forum topic,
and a body that GitHub caps at roughly 65k characters. Editing a shared body
from several runs of the same day would also race.

## Decision

Add a **third, additive** sink. Telegram and Discord are untouched. Each build
gets its own discussion in the category named by the `GH_BUILDLOG_CATEGORY`
repository variable (unset means the feature is off), titled
`Build <tag> · <Stable|Beta> · <UTC date>`. The **build number is the identity**,
the date is display metadata from when the discussion was first created: an
exact title match is tried first, then a `Build <tag> ·` prefix match so a retry
after UTC midnight reuses the existing discussion instead of creating a second
one. Zero creates, one reuses, more than one is an error. Every discussion is
labelled `build_log` plus `stable` or `beta` (from the workflow's own channel
context — an unrecognised value is refused, not guessed), and `build_issue`
whenever the build has failure records; a clean retry removes that label so it
cannot go stale. Labels are cosmetic, so a fork missing them only warns and
still gets the body and logs.

The body is written in one pass, with `## 📦 Downloads` above `## 🚨 Build
Report`. The download table is rendered from `build.archive.md`, so its URLs
already point at the permanent mirror and cannot break when rvb prunes a
numbered release. A shipped build whose archive mirror did not land is an
error — no silent fallback to rvb links. Failure details are derived from the
record class the engine already wrote (`_pf`, `_lb`, `_dl`, `_np`, `_npa`),
never invented prose.

Full failure logs go into a dedicated `## 📄 Failure Log` comment, one
sanitised `<details>` block per app+arch, fenced longer than any backtick run
in the log. The comment is created first so its `#discussioncomment-…` URL can
be linked from the failure row; retries find the anchored comment and edit it
in place. No other comment is posted.

The assembled body is measured in UTF-16 code units against a 65000 budget and
fails loudly when over it. No truncation, no overflow-to-comment path: current
configs keep the body around 25–40k, and a guard that fires is the signal to
redesign, not permission to guess a cut point.

## Rejected alternatives

- **One discussion per UTC day with a live failure table in the body.** Several
  builds would read-modify-write one body (stable/beta and manual runs), and
  the body would grow all day. Per-build discussions make identity the already
  unique build number and remove the race entirely.
- **Replacing Telegram/Discord.** Discussions do not push-notify unless a reader
  watches the thread. The existing sinks stay the alerting path; this one is
  the durable record.
- **Embedding logs in the body.** That is what makes the body hit its limit and
  what made the daily-edit design fragile. Comments are the durable copy.
- **Deriving download URLs from the build tag and filenames.** That duplicates
  `generate_release_notes.py`'s URL ownership and would silently point at a
  mirror that never received the files. Parsing `build.archive.md` follows the
  note that actually shipped.
- **Overflowing an oversized body into comments.** Extra write mode, extra
  idempotency and tests, for a size current configs cannot reach.

## Consequences

- The `Build Log` category accumulates roughly two discussions per scheduled
  day plus manual builds, and `gh` has no discussion-delete command. Pruning,
  if ever needed, requires a GraphQL `deleteDiscussion` call; it is deliberately
  out of scope.
- Readers must watch the category or a discussion to be notified. This is a
  record, not a pager.
- The discussion only exists for builds that shipped files or had failures; a
  clean all-duplicate run writes nothing.

## Verification

`bash .github/traces/test_build_log_gh.sh` — stubbed `gh`/`curl`, with negative
controls for an unset category, an ambiguous title, a missing archive note, an
oversized body and a no-op; it also asserts retry edits in place.
`bash .github/traces/test_failure_report.sh` still covers the Telegram message
whose machine-readable twin feeds this log.
