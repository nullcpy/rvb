#!/usr/bin/env bash
set -euo pipefail

# Guard the build pool's memory headroom on the standard hosted runner.
#
# The build job runs on the free public-repo runner, which is 4-core/16 GB (the
# shape scripts/build.sh assumes when it caps PARALLEL_JOBS at 8). Pool children
# used to run with no heap flag at all, so each was allowed the JVM default of a
# quarter of RAM and six of them asked for more memory than the VM has; going over
# that ceiling is what tears the runner agent down and kills the step with SIGTERM,
# logged as exit 143 plus "The runner has received a shutdown signal" - observed on
# run 41533052163 (build_stable) and run 41566179123 (Manual CI), both ~13 min into
# a full pool, both losing every artifact the pool had already built because the
# abort also skips the publish chain. The pool is now bounded (PARALLEL_JOBS with
# RVB_JVM_MAX_HEAP, see docs/ci-pipelines.md item 1b); this step is what is left of
# the swap idea after learning that today's image already ships its own 3 GiB
# /swapfile, which the "already active" branch below detects and reports.
# It remains useful for two things: recording the runner's memory baseline at the
# start of every run, and covering an image generation that drops that file.
# Larger runners are the other fix for the ceiling and are not reachable from a
# personal account, nor free for public repos. Swap does not make a starved machine
# fast; it only makes it finish.
#
# RVB_SWAP_MB (job env in build.yml, per docs/decisions/0005): size in MiB.
# Unset, non-numeric or 0 means "do not add swap" and the step says so - the
# size is a tuning value, never something this script invents.
#
# The step is soft by design: a runner image that refuses swapon is a worse
# problem than a build running with one less safety net, so every skip path
# writes a ::warning:: naming what it gave up on and exits 0. It never writes
# ::error::. Wherever it acts it prints `swapon --show` and `free -h`, because an
# unproven swap step is indistinguishable from a missing one.

swap_mb="${RVB_SWAP_MB-}"

if [ -z "$swap_mb" ]; then
	echo "[!] RVB_SWAP_MB is unset - not adding swap."
	exit 0
fi
if [[ ! "$swap_mb" =~ ^[0-9]+$ ]]; then
	echo "::warning::RVB_SWAP_MB '$swap_mb' is not a number - not adding swap."
	exit 0
fi
if ((swap_mb < 1)); then
	echo "[+] RVB_SWAP_MB is 0 - swap disabled for this run."
	exit 0
fi

# -n so a runner that somehow needs a password fails here in milliseconds
# instead of hanging the step waiting for stdin.
if ! sudo -n true 2>/dev/null; then
	echo "::warning::passwordless sudo is not available on this runner - cannot add swap."
	exit 0
fi

if swapon --show --noheadings 2>/dev/null | grep -q .; then
	echo "[+] swap is already active; leaving it as it is:"
	swapon --show
	free -h
	exit 0
fi

swapfile=/swapfile

# Never plan a file that cannot fit: leave the space the build itself needs for
# APKs and per-build temp dirs.
free_mb=$(df -Pm --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9' || true)
if [ -n "$free_mb" ] && ((free_mb < swap_mb + 4096)); then
	kept=$((free_mb - 4096))
	if ((kept < 1)); then
		echo "::warning::less than 1 GiB free on / - cannot add swap."
		exit 0
	fi
	echo "::warning::requested ${swap_mb} MiB does not fit in ${free_mb} MiB free - using ${kept} MiB."
	swap_mb=$kept
fi

echo "[+] creating ${swap_mb} MiB swap file"
# fallocate is instant; ext4 without punch-through support falls back to dd.
if ! sudo fallocate -l "${swap_mb}M" "$swapfile" 2>/dev/null; then
	echo "[!] fallocate failed - writing the file with dd instead."
	if ! sudo dd if=/dev/zero of="$swapfile" bs=1M count="$swap_mb" status=none; then
		echo "::warning::could not create $swapfile - continuing without swap."
		exit 0
	fi
fi

# swapon refuses a file that is group/world readable.
if ! sudo chmod 600 "$swapfile" 2>/dev/null; then
	echo "::warning::could not set permissions on $swapfile - continuing without swap."
	exit 0
fi
if ! sudo mkswap "$swapfile" >/dev/null; then
	echo "::warning::mkswap rejected $swapfile - continuing without swap."
	exit 0
fi
if ! sudo swapon "$swapfile"; then
	echo "::warning::swapon rejected $swapfile - continuing without swap."
	exit 0
fi

echo "[+] swap active:"
swapon --show
echo "[+] memory after:"
free -h
