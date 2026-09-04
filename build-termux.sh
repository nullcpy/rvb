#!/usr/bin/env bash

set -e

pr() { echo -e "\033[0;32m[+] ${1}\033[0m"; }
ask() {
	local y
	for ((n = 0; n < 3; n++)); do
		pr "$1 [y/n]"
		if read -r y; then
			if [ "$y" = y ]; then
				return 0
			elif [ "$y" = n ]; then
				return 1
			fi
		fi
		pr "Asking again..."
	done
	return 1
}

pr "Ask for storage permission"
until
	yes | termux-setup-storage >/dev/null 2>&1
	ls /sdcard >/dev/null 2>&1
do sleep 1; done
if [ ! -f ~/.rvmm_"$(date '+%Y%m')" ]; then
	pr "Setting up environment..."
	yes "" | pkg update -y && pkg upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" && pkg install -y git curl jq openjdk-21 zip python
	: >~/.rvmm_"$(date '+%Y%m')"
fi
mkdir -p /sdcard/Download/rvb/

REPO_DIR="rvb"
[ -d revanced-magisk-module ] && REPO_DIR="revanced-magisk-module"

if [ -d "$REPO_DIR" ] || [ -f config.toml ]; then
	if [ -d "$REPO_DIR" ]; then cd "$REPO_DIR"; fi
	pr "Checking for updates"
	git fetch
	if git status | grep -q 'is behind\|fatal'; then
		pr "rvb is not synced with upstream."
		pr "Cloning rvb. config.toml will be preserved."
		cd ..
		cp -f "$REPO_DIR"/config.toml .
		rm -rf "$REPO_DIR"
		git clone https://github.com/nullcpy/rvb --recurse --depth 1
		mv -f config.toml rvb/config.toml
		cd rvb
	fi
else
	pr "Cloning rvb."
	git clone https://github.com/nullcpy/rvb --depth 1
	cd rvb
	sed -i '/^enabled.*/d; /^\[.*\]/a enabled = false' config.toml
	grep -q 'rvb' ~/.gitconfig 2>/dev/null ||
		git config --global --add safe.directory ~/rvb
fi

[ -f ~/storage/downloads/rvb/config.toml ] ||
	cp config.toml ~/storage/downloads/rvb/config.toml

if ask "Open rvmm-config-gen to generate a config?"; then
	am start -a android.intent.action.VIEW -d https://j-hc.github.io/rvmm-config-gen/
fi
printf "\n"
until
	if ask "Open 'config.toml' to configure builds?\nAll are disabled by default, you will need to enable at first time building"; then
		am start -a android.intent.action.VIEW -d file:///sdcard/Download/rvb/config.toml -t text/plain
	fi
	ask "Setup is done. Do you want to start building?"
do :; done
cp -f ~/storage/downloads/rvb/config.toml config.toml

./build.sh

cd build
PWD=$(pwd)
for op in *; do
	[ "$op" = "*" ] && {
		pr "glob fail"
		exit 1
	}
	mv -f "${PWD}/${op}" ~/storage/downloads/rvb/"${op}"
done

pr "Outputs are available in /sdcard/Download/rvb folder"
am start -a android.intent.action.VIEW -d file:///sdcard/Download/rvb -t resource/folder
sleep 2
am start -a android.intent.action.VIEW -d file:///sdcard/Download/rvb -t resource/folder
