#!/bin/bash
# Installs the tools the plugin uses and the ones the checks need, on Arch Linux.
#
# With ARCH_SNAPSHOT=YYYY/MM/DD the packages come from that day of the Arch
# Linux Archive. The container image has to be from the same day, so that
# nothing is downgraded (see .github/workflows/compat.yml).
set -euo pipefail
readonly tools=(yazi mediainfo ffmpeg imagemagick ghostscript resvg)

pacman_quiet() {
	if ! pacman --noconfirm --needed "$@" >>/tmp/pacman.log 2>&1; then
		tail -n 30 /tmp/pacman.log >&2
		exit 1
	fi
}

if [[ -n ${ARCH_SNAPSHOT:-} ]]; then
	echo "Server = https://archive.archlinux.org/repos/$ARCH_SNAPSHOT/\$repo/os/\$arch" >/etc/pacman.d/mirrorlist
else
	# Packages signed with a key newer than the image's keyring would fail to
	# verify, so the keyring is updated first.
	pacman_quiet -Sy archlinux-keyring
fi
pacman_quiet -Syu "${tools[@]}" chafa tmux lua unzip
pacman -Q "${tools[@]}"
