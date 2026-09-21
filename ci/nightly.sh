#!/bin/bash
# Downloads the latest Yazi nightly build, yazi and ya, into DIR.
#
#     bash ci/nightly.sh DIR
set -euo pipefail
readonly dir=${1:?usage: nightly.sh DIR}
readonly url=https://github.com/sxyazi/yazi/releases/download/nightly/yazi-x86_64-unknown-linux-musl.zip
tmp=$(mktemp -d)
readonly tmp
trap 'rm -rf "$tmp"' EXIT

curl -fsSL --connect-timeout 20 --max-time 120 --retry 3 -o "$tmp/yazi.zip" "$url"
unzip -tq "$tmp/yazi.zip"
unzip -q "$tmp/yazi.zip" -d "$tmp"
mkdir -p "$dir"
install -m 755 "$tmp"/yazi-*/yazi "$tmp"/yazi-*/ya "$dir/"
