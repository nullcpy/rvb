#!/usr/bin/env bash
set -euo pipefail

# Give the build pool swap headroom on the standard hosted runner.
#
# The build job runs on the free public-repo runner, which is 4-core/16 GB
# (the shape scripts/build.sh assumes when it caps PARALLEL_JOBS at 8). No
# `java` call in the engine carries a heap flag, so each morphe pool child gets
# the JVM default max heap of 1/4 of RAM: 6 concurrent children are a ~24 GB
# ceiling against 16 GB of real memory, before the Cloudflare sidecar's browsers
# and the apkeditor/apksigner JVMs. When the machine passes that point the
# runner agent is torn down and the step dies with SIGTERM, which the log shows
# as exit 143 plus "The runner has received a shutdown signal" - observed on
# run 41533052163 (build_stable) and run 41566179123 (Manual CI), both ~13 min
# into a full pool, both losing every artifact the pool had already built
# because the abort also skips the publish chain. This class is the hosted
# runner's own resource limit and has no proper error message
# (https://github.com/actions/runner-images/issues/6680); larger runners are the
# other fix but are not available to a personal account and are not free for
# public repos, so the runner stays as it is and the memory overflow is absorbed
# here instead. Swap does not make a starved machine fast; it makes it finish.
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
