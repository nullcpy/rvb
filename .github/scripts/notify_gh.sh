#!/bin/bash
# notify_gh.sh — transport library for the additive GitHub Discussions build log.
# Sourced, never executed: build_notify_gh.sh owns the body, this file owns every
# gh call and the guard in front of them.
#
# The build log is deliberately NOT a replacement for Telegram/Discord — those
# scripts own the messages they already send. This library writes one discussion
# per build under a category named by a repo variable, with the durable build
# report in the body and the full failure logs in comments.
#
# No target is guessed. An unset category is an error, not a fallback to a
# written-in name, the same rule notify_targets.sh applies to Telegram chats.
# A fuzzy --search result is accepted only on an exact title match; ambiguity
# (>1 match) fails loudly rather than picking one.

# GitHub caps a discussion body and a comment at 65536 characters. Leave a
# margin rather than writing to the edge: the body is measured in UTF-16 code
# units (the currency Discord already prices, and a safe over-estimate here).
GH_BODY_LIMIT=65000
GH_COMMENT_LIMIT=60000

GH_LOG_NUMBER=""
GH_LOG_FIND_COUNT=0

# gh_require_targets NAME=VALUE [NAME=VALUE ...]
# One ::error:: listing every unset name, returns 1. No defaults by design.
gh_require_targets() {
	local missing="" pair name value
	for pair in "$@"; do
		name=${pair%%=*}
		value=${pair#*=}
		[ -n "$value" ] || missing="${missing:+${missing}, }${name}"
	done
	if [ -n "$missing" ]; then
		echo "::error::GitHub build log target not configured: ${missing} unset. Set it under Settings -> Secrets and variables -> Actions -> Variables; nothing was written." >&2
		return 1
	fi
	return 0
}

# gh_log_find <exact-title> — set GH_LOG_NUMBER and GH_LOG_FIND_COUNT.
# List the category and match the title exactly in jq. --search was tried and
# removed: its index lags writes, so a discussion created moments earlier was
# invisible to the post-create lookup (run 45060205121). A high --limit keeps
# the whole category in one reply; the exact match rejects near-miss titles.
gh_log_list() {
	local out
	out=$(gh discussion list \
		--category "$GH_BUILDLOG_CATEGORY" \
		--state all \
		--json number,title,url \
		--limit 1000) || return 1
	# `gh discussion list --json` answers {"discussions":[...],"totalCount":N},
	# not a bare array. Fail loudly on any other shape rather than reading an
	# empty count from an error object and creating a duplicate discussion.
	if ! printf '%s' "$out" | jq -e 'type == "object" and (.discussions | type) == "array"' >/dev/null; then
		echo "::error::Unexpected gh discussion list output; cannot resolve the build discussion. Refusing to guess." >&2
		return 1
	fi
	GH_LOG_LIST=$out
	return 0
}

GH_LOG_LIST=""

# gh_log_find <exact-title> — exact title, used for the normal same-day retry.
gh_log_find() {
	local title=$1
	gh_log_list || return 1
	GH_LOG_FIND_COUNT=$(printf '%s' "$GH_LOG_LIST" | jq -r --arg t "$title" '[.discussions[] | select(.title == $t)] | length' | tr -d '\r')
	GH_LOG_NUMBER=""
	if [ "$GH_LOG_FIND_COUNT" -gt 1 ]; then
		echo "::error::More than one discussion is titled '${title}'. Refusing to guess which one belongs to this build." >&2
		return 1
	elif [ "$GH_LOG_FIND_COUNT" -eq 1 ]; then
		GH_LOG_NUMBER=$(printf '%s' "$GH_LOG_LIST" | jq -r --arg t "$title" '.discussions[] | select(.title == $t) | .number' | tr -d '\r')
	fi
	return 0
}

# gh_log_find_tag <build-tag> — fallback for a retry after UTC midnight: the
# title carries the date resolved when the discussion was first created, so the
# exact-title lookup would miss it and create a second discussion for one build.
# The build number is the identity; the date is display metadata.
gh_log_find_tag() {
	local tag=$1
	local prefix="Build ${tag} ·"
	gh_log_list || return 1
	GH_LOG_FIND_COUNT=$(printf '%s' "$GH_LOG_LIST" | jq -r --arg p "$prefix" '[.discussions[] | select(.title | startswith($p))] | length' | tr -d '\r')
	GH_LOG_NUMBER=""
	if [ "$GH_LOG_FIND_COUNT" -gt 1 ]; then
		echo "::error::More than one discussion starts with '${prefix}'. Refusing to guess which one belongs to this build." >&2
		return 1
	elif [ "$GH_LOG_FIND_COUNT" -eq 1 ]; then
		GH_LOG_NUMBER=$(printf '%s' "$GH_LOG_LIST" | jq -r --arg p "$prefix" '.discussions[] | select(.title | startswith($p)) | .number' | tr -d '\r')
	fi
	return 0
}

# gh_log_comments — every comment on the current discussion as GraphQL JSON.
# GraphQL is used rather than parsing gh's human output: the comment's node id
# is needed for --edit and its url for the in-body link.
gh_log_comments() {
	local owner=${GITHUB_REPOSITORY%%/*} name=${GITHUB_REPOSITORY#*/} resp
	resp=$(gh api graphql \
		-f owner="$owner" -f name="$name" -F number="$GH_LOG_NUMBER" \
		-f query='
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    discussion(number: $number) {
      comments(first: 100) {
        nodes { id url body }
      }
    }
  }
}') || return 1
	if printf '%s' "$resp" | jq -e 'has("errors")' >/dev/null; then
		echo "::error::GitHub API returned errors while reading discussion comments: $(printf '%s' "$resp" | jq -c '.errors')" >&2
		return 1
	fi
	printf '%s' "$resp"
}

# gh_log_comment_once <anchor> <body-file> — create the comment or edit the
# existing one carrying <anchor>, then echo its URL. Editing in place keeps the
# URL stable, which is what the body link points at across retries.
gh_log_comment_once() {
	local anchor=$1 file=$2 found id url
	found=$(gh_log_comments | jq -r --arg a "$anchor" \
		'.data.repository.discussion.comments.nodes[]
		 | select(.body | contains($a)) | [.id, .url] | @tsv' | head -1 | tr -d '\r')
	if [ -n "$found" ]; then
		id=${found%%$'\t'*}
		gh discussion comment "$id" --edit --body-file "$file" >/dev/null || return 1
	else
		gh discussion comment "$GH_LOG_NUMBER" --body-file "$file" >/dev/null || return 1
	fi
	url=$(gh_log_comments | jq -r --arg a "$anchor" \
		'.data.repository.discussion.comments.nodes[]
		 | select(.body | contains($a)) | .url' | head -1 | tr -d '\r')
	if [ -z "$url" ]; then
		echo "::error::Comment ${anchor} was written but could not be read back; no body link was recorded." >&2
		return 1
	fi
	printf '%s\n' "$url"
}

# gh_body_units <text> — jq counts one astral emoji as two code points; adding
# those makes the measure UTF-16 units. jq on Windows terminates with CRLF.
gh_body_units() {
	printf '%s' "$1" | jq -Rs '(length + ([explode[] | select(. >= 65536)] | length))' | tr -d '\r'
}

# gh_html_escape — the three characters that would end a <summary> early.
gh_html_escape() {
	printf '%s' "$1" | sed -e 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
}

# gh_table_cell — the one character that ends a GFM table cell.
gh_table_cell() {
	printf '%s' "${1:-—}" | sed -e 's/|/\\|/g'
}

# gh_sanitize_log <file> — drop NUL bytes, ANSI colour sequences and CR so a raw
# engine log cannot break a Markdown fence or the reader's terminal.
gh_sanitize_log() {
	tr -d '\000' < "$1" \
		| sed -e 's/\x1B\[[0-9;]*[A-Za-z]//g' -e 's/\r$//'
}

# gh_fence_for <text> — echo a backtick fence longer than the longest run inside
# the text, so a JVM stack trace containing ``` cannot end the code block early.
gh_fence_for() {
	local text=$1 longest cur line
	longest=0
	while IFS= read -r line || [ -n "$line" ]; do
		cur=$(printf '%s' "$line" | grep -o '[`]\{1,\}' | awk '{ if (length($0) > m) m = length($0) } END { print m+0 }')
		if [ "${cur:-0}" -gt "$longest" ]; then longest=$cur; fi
	done <<< "$text"
	local n=$((longest + 1))
	[ "$n" -lt 3 ] && n=3
	printf -v line '%*s' "$n" ''
	printf '%s' "${line// /\`}"
}
