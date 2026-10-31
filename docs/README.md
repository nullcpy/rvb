# Project documentation

The root [README](../README.md) speaks to users of the builds. This folder
describes the **system**: the repositories behind it, this repo's Git branches,
GitHub Releases, the site surfaces, and the CI that keeps them consistent. It is
written for people changing the pipeline and for AI agents asked to do so.

## Where to start

| You want to… | Read |
|---|---|
| understand the whole shape before touching anything | [architecture.md](architecture.md) |
| change CI behaviour, trigger gating, uploads | [ci-pipelines.md](ci-pipelines.md) |
| change how an APK is fetched, patched, packaged, signed | [build-engine.md](build-engine.md) |
| know where a file lives, who writes it, how to recover it | [storage-and-branches.md](storage-and-branches.md) |
| work on the catalogue the website renders (`data.json`) | [website-contract.md](website-contract.md) |
| understand or debug the stock-APK cache (`nullcpy/apks`) | [cache-repo.md](cache-repo.md) |
| make any change: setup, tests, commit and publish rules | [contributing.md](contributing.md) |
| brief an AI agent with the shortest correct context | [ai-context.md](ai-context.md) |
| know *why* a rule exists and what was rejected | [decisions/](decisions/) |

## What is deliberately not repeated here

Each fact has exactly one owner. Linking to it is fine; copying it is how it
rots.

| Topic | Owner |
|---|---|
| Every TOML key the builder accepts | [CONFIG.md](../CONFIG.md) |
| Release-manifest scripts, repair tooling, uploader knobs | [.github/scripts/README.md](../.github/scripts/README.md) |
| Offline regression harness (fixtures, goldens, stubs) | [.github/traces/README.md](../.github/traces/README.md) |
| Website UI, `data.json` schema v2, `script.js` config, Obtainium flow | [`nullcpy.github.io/CONFIG.md`](https://github.com/nullcpy/nullcpy.github.io/blob/main/CONFIG.md) |
| Contributing APKs to the cache (`upload_apks.*`, write access, renaming) | [`nullcpy/apks/README.md`](https://github.com/nullcpy/apks/blob/main/README.md) |
| Archive repo's site chrome, page grammar, `pages.yml` | [`nullcpy/archive/README.md`](https://github.com/nullcpy/archive/blob/main/README.md) |
| Gateway page template, build tokens, domain rotator, deploy setup | [`nullcpy/nullstore/README.md`](https://github.com/nullcpy/nullstore/blob/main/README.md) |

## How to keep these files honest

- Structure and boundaries belong here; behaviour details belong in the script
  they describe. If a paragraph here restates what the code already says, delete
  the paragraph.
- Anything with a wire format — file names, branch paths, JSON keys, URL shapes —
  is listed in [storage-and-branches.md](storage-and-branches.md) with its
  producer and consumer. Add to that table when you introduce one.
- When a decision is load-bearing (someone will be tempted to undo it), write a
  numbered file in [decisions/](decisions/) and link it from the code comment
  that guards it.
- Dates are written in full (`2026-09-25`). Incident dates are how the recovery
  notes in these files stay searchable.
