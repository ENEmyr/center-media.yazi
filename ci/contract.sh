#!/bin/bash
# Checks that the tools the plugin runs still print what it parses. Each check
# names the code that depends on it.
#
#     bash ci/contract.sh SAMPLES_DIR
set -euo pipefail
readonly media=${1:?usage: contract.sh SAMPLES_DIR}
export LC_ALL=C
tmp=$(mktemp -d)
readonly tmp
trap 'rm -rf "$tmp"' EXIT

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

# expect_sections FILE SECTION...: mediainfo prints these sections for FILE.
expect_sections() {
	local file=$1 got section
	shift
	got=" $(mediainfo "$media/$file" | grep -E '^[A-Za-z]+( #[0-9]+)?$' | tr '\n' ' ' || true)"
	for section in "$@"; do
		[[ $got == *" $section "* ]] || fail "mediainfo $file has no $section section, only:$got"
	done
}

# utils.lua (section_of, metadata_lines): mediainfo prints section headings
# such as "Audio" or "Audio #2", and "Label   : value" lines, nothing else.
for file in "$media"/*; do
	bad=$(mediainfo "$file" | grep -Ev '^$|^[A-Za-z]+( #[0-9]+)?$|[^ ]  +: ' || true)
	[[ -z $bad ]] || fail "mediainfo ${file##*/} prints lines the plugin cannot parse:
$bad"
done

# const.lua (sections): audio shows only General and Audio, and hides Image.
expect_sections song.mp3 General Audio Image
expect_sections plain.wav General Audio
expect_sections video.mp4 General Video
expect_sections image.png General Image
expect_sections sub.srt General Text

# utils.lua (metadata_lines): audio drops the Cover lines under General.
mediainfo "$media/song.mp3" | grep -q '^Cover  *: ' || fail "mediainfo song.mp3 has no Cover line"

# audio.lua (get_cover_layers): ffprobe marks the cover art as attached_pic.
ffprobe -v error -select_streams v -show_entries stream=index:stream_disposition=attached_pic \
	-of json "$media/song.mp3" | tr -d ' \n' | grep -q '"attached_pic":1' ||
	fail "ffprobe does not mark the cover of song.mp3 as attached_pic"

# audio.lua (preload): for audio without cover art, ffmpeg says so in these
# words, and the plugin then draws a blank image with magick instead.
out=$(ffmpeg -v error -i "$media/plain.wav" -map '0:v:0?' -an -sn -dn -vframes 1 -f image2 -y "$tmp/cover.jpg" 2>&1 || true)
[[ $out == *"does not contain any stream"* ]] || fail "ffmpeg on audio without cover art says: $out"
out=$(magick -size 1x1 canvas:none "PNG32:$tmp/blank.png" 2>&1 || true)
[[ -z $out && -s $tmp/blank.png ]] || fail "magick cannot draw the blank image: $out"

# adobe.lua (image_layer_count): identify prints one line per layer.
(($(identify "$media/art.eps" | grep -c .) >= 1)) || fail "identify finds no layer in art.eps"

echo "contract: all passed"
