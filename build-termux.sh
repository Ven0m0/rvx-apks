#!/usr/bin/env bash
# ReVanced APK Builder for Termux (Android)
# This script sets up and runs the builder directly on Android devices

set -euo pipefail

pr() { echo -e "\033[0;32m[+] ${1}\033[0m"; }
epr() { echo -e "\033[0;31m[!] ${1}\033[0m" >&2; }
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

pr "Requesting storage permission..."
until
	yes | termux-setup-storage >/dev/null 2>&1
	ls /sdcard >/dev/null 2>&1
do
	sleep 1
done

pr "Storage permission granted"

# Check if environment setup is needed (monthly check)
if [ ! -f ~/.rvmm_"$(date '+%Y%m')" ]; then
	pr "Setting up Termux environment..."
	if ! yes "" | pkg update -y && pkg upgrade -y; then
		epr "Failed to update packages"
		exit 1
	fi
	if ! pkg install -y git curl jq openjdk-17 zip; then
		epr "Failed to install required packages"
		exit 1
	fi
	touch ~/.rvmm_"$(date '+%Y%m')"
	pr "Environment setup complete"
fi

mkdir -p /sdcard/Download/revanced-magisk-module/ || {
	epr "Failed to create output directory"
	exit 1
}

# Check if repository exists and update/clone as needed
if [ -d revanced-magisk-module ] || [ -f config.toml ]; then
	if [ -d revanced-magisk-module ]; then
		cd revanced-magisk-module || exit 1
	fi
	pr "Checking for updates..."
	if git fetch 2>/dev/null; then
		if git status | grep -q 'is behind\|fatal'; then
			pr "Repository is out of sync with upstream"
			pr "Re-cloning repository (config.toml will be preserved)"
			cd ..
			if [ -f revanced-magisk-module/config.toml ]; then
				cp -f revanced-magisk-module/config.toml . || exit 1
			fi
			rm -rf revanced-magisk-module
			if ! git clone https://github.com/j-hc/revanced-magisk-module --recurse --depth 1; then
				epr "Failed to clone repository"
				exit 1
			fi
			if [ -f config.toml ]; then
				mv -f config.toml revanced-magisk-module/config.toml || exit 1
			fi
			cd revanced-magisk-module || exit 1
		fi
	else
		epr "Failed to fetch updates"
	fi
else
	pr "Cloning revanced-magisk-module..."
	if ! git clone https://github.com/j-hc/revanced-magisk-module --depth 1; then
		epr "Failed to clone repository"
		exit 1
	fi
	cd revanced-magisk-module || exit 1
	# Disable all apps by default on first setup
	sed -i '/^enabled.*/d; /^\[.*\]/a enabled = false' config.toml
	grep -q 'revanced-magisk-module' ~/.gitconfig 2>/dev/null ||
		git config --global --add safe.directory ~/revanced-magisk-module
fi

# Ensure config is available in user-accessible location
if [ ! -f ~/storage/downloads/revanced-magisk-module/config.toml ]; then
	cp config.toml ~/storage/downloads/revanced-magisk-module/config.toml || {
		epr "Failed to copy config to downloads"
	}
fi

if ask "Open rvmm-config-gen to generate a config?"; then
	am start -a android.intent.action.VIEW -d https://j-hc.github.io/rvmm-config-gen/ 2>/dev/null || {
		epr "Failed to open config generator"
	}
fi

printf "\n"
until
	if ask "Open 'config.toml' to configure builds?\nAll are disabled by default, you will need to enable at first time building"; then
		am start -a android.intent.action.VIEW -d file:///sdcard/Download/revanced-magisk-module/config.toml -t text/plain 2>/dev/null || {
			epr "Failed to open config file"
		}
	fi
	ask "Setup is done. Do you want to start building?"
do :; done

# Copy user config back to working directory
if [ -f ~/storage/downloads/revanced-magisk-module/config.toml ]; then
	cp -f ~/storage/downloads/revanced-magisk-module/config.toml config.toml || {
		epr "Failed to copy config from downloads"
		exit 1
	}
fi

pr "Starting build process..."
if ! ./build.sh; then
	epr "Build failed!"
	exit 1
fi

pr "Build complete! Moving APKs to downloads..."

if [ ! -d build ] || [ -z "$(ls -A build 2>/dev/null)" ]; then
	epr "No APKs were built!"
	exit 1
fi

cd build || exit 1
PWD=$(pwd)
moved_count=0

for op in *; do
	if [ "$op" = "*" ]; then
		epr "No files found in build directory"
		exit 1
	fi
	if mv -f "${PWD}/${op}" ~/storage/downloads/revanced-magisk-module/"${op}" 2>/dev/null; then
		pr "Moved: ${op}"
		((moved_count++))
	else
		epr "Failed to move: ${op}"
	fi
done

pr "Successfully moved $moved_count APK(s)"
pr "Outputs are available in /sdcard/Download/revanced-magisk-module"

# Try to open file manager twice (sometimes fails first time on Android)
am start -a android.intent.action.VIEW -d file:///sdcard/Download/revanced-magisk-module -t resource/folder 2>/dev/null || true
sleep 2
am start -a android.intent.action.VIEW -d file:///sdcard/Download/revanced-magisk-module -t resource/folder 2>/dev/null || {
	pr "Note: Failed to open file manager automatically. Please open manually."
}
