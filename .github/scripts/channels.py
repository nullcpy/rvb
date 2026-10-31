#!/usr/bin/env python3
"""The pre-release marker words of a patch source's release tag.

One owner for the vocabulary that answers "does this tag name a pre-release".
Three consumers need the same answer:

- `sync_patch_sources.py` records which release of a source is the stable head
  and which is the beta head,
- `compile_patch_configs.py` decides which pool a pinned `patches-version`
  belongs to, so a pin must be read by the rule its own tag would be read by,
- the engine's release picker (`scripts/utils.sh`, GitLab arm) resolves
  `patches-version = "beta"` / `"stable"` at build time.

The engine is shell and cannot import this module, so it keeps the same list as
a literal assembled by `channel_beta_re()`.
`.github/traces/test_channel_markers.sh` asserts the two strings are identical
and that both regexes classify the same tags, so the copies cannot drift apart
silently.

Why the guard around the word, and not a bare word search: the old loose filter
filed `v1.0.0-arch` and `v1.0.0-search` as pre-releases because `rc` is a
substring of them, and `v1.0.0-device` because `dev` is one. A marker has to be
its own component of the tag: preceded by a separator, not followed by another
letter. That is also what makes a short word like `exp` safe, since unanchored it
would match inside `-express`.

Kept stdlib-only, like `naming.py` (docs/decisions/0006).
"""

import re

# A marker is a lowercase word; the regex is applied case-insensitively, so a
# source that tags `v1.2.3-RC.1` is read the same way. `experimental` is listed
# before `exp` because it prefixes it: with the longest alternative first, no
# arm depends on the engine backtracking into the alternation.
PRE_RELEASE_MARKERS = ("dev", "alpha", "beta", "rc", "pre",
                       "experimental", "exp")

# `[-._]` opens the component (semver uses `-`; `_rc1` and `.pre.2` are typed in
# the wild); `([^a-zA-Z]|$)` closes it, so the word ends at a separator, a digit
# or the end of the tag rather than in the middle of a longer word.
TAG_MARKER_PATTERN = (
    r"[-._](" + "|".join(PRE_RELEASE_MARKERS) + r")([^a-zA-Z]|$)")

_TAG_MARKER_RE = re.compile(TAG_MARKER_PATTERN, re.IGNORECASE)


def is_pre_release_tag(tag):
    """True when `tag` carries a pre-release marker as its own component.

    This answers the tag question only. GitHub and Forgejo releases also carry an
    explicit `prerelease` flag that outranks the name, and GitLab releases carry
    no flag at all, so the name is the only signal there. Callers that hold a
    release object decide the precedence per host; see
    `sync_patch_sources.parse_releases`.
    """
    return bool(tag) and bool(_TAG_MARKER_RE.search(tag))
