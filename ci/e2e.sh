#!/bin/bash
# Runs Yazi headless in tmux with the plugin, previews each sample and checks
# the preview pane: the file's metadata is there, and the image and the
# metadata are centered. Uses the yazi and ya first on PATH.
#
# Without a graphical terminal Yazi draws images with chafa as text, so the
# image can be located in `tmux capture-pane` output like the metadata.
#
#     bash ci/e2e.sh SAMPLES_DIR
set -euo pipefail
# awk counts columns in characters, whichever symbols chafa draws with.
export LC_ALL=C.UTF-8
readonly media=${1:?usage: e2e.sh SAMPLES_DIR}
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
readonly root work
readonly id=$$ # Yazi client id, for ya emit-to
readonly sock=center-media-$$
readonly W=100 H=60
readonly log=$work/state/yazi/yazi.log

cleanup() {
	tmux -L "$sock" kill-server 2>/dev/null || true
	rm -rf "$work"
}
trap cleanup EXIT

plugin=$work/config/plugins/center-media.yazi
mkdir -p "$plugin"
cp "$root"/*.lua "$plugin/"
cat >"$work/config/yazi.toml" <<EOF
[mgr]
ratio = [0, 0, 1] # the preview pane takes the whole width

[preview]
cache_dir = "$work/cache"

[[plugin.prepend_previewers]]
mime = "{audio,video,image}/*"
run  = "center-media"

[[plugin.prepend_previewers]]
mime = "application/{postscript,subrip}"
run  = "center-media"

[[plugin.prepend_preloaders]]
mime = "{audio,video,image}/*"
run  = "center-media"

[[plugin.prepend_preloaders]]
mime = "application/{postscript,subrip}"
run  = "center-media"
EOF
cat >"$work/config/keymap.toml" <<'EOF'
[mgr]
prepend_keymap = [
  { on = "<F3>", run = "plugin center-media -- toggle-metadata" },
  { on = "<F4>", run = "plugin center-media -- toggle-preview" },
  { on = "<F5>", run = "plugin center-media -- reset" },
]
EOF
# skip_labels = false keeps the "Complete name" line, which tells the preview
# of one file from the one before it.
echo 'require("center-media"):setup({ skip_labels = false })' >"$work/config/init.lua"

pane() { tmux -L "$sock" capture-pane -p -t e2e; }

fail() {
	{
		printf 'FAIL: %s\n' "$*"
		echo "--- pane"
		pane || true
		echo "--- plugin log"
		grep -a center-media "$log" 2>/dev/null | tail -n 20 || true
	} >&2
	exit 1
}

shows() { pane | grep -qF -- "$1"; }
hides() { ! shows "$1"; }
heading() { pane | grep -qx " *$1"; }
no_heading() { ! heading "$1"; }

# A Lua error in a previewer is shown in the pane instead of the preview.
broken() { pane | grep -qE 'Lua error|Unexpected error|stack traceback'; }

# until_ok DESCRIPTION COMMAND...: tries COMMAND up to 150 times, 0.2 seconds
# apart, which is 30 seconds plus the time COMMAND itself takes.
until_ok() {
	local what=$1 i
	shift
	for ((i = 0; i < 150; i++)); do
		"$@" && return 0
		broken && fail "error while waiting for $what"
		sleep 0.2
	done
	fail "timed out waiting for $what"
}

# layout: reads a pane capture and prints six numbers. The first row is the
# header and the last the status bar, the rows between are the preview. Of
# those, the rows above the "General" heading are the image and the rest the
# metadata. The numbers are the blank rows above and below both, the blank
# columns left and right of the image, and those of the metadata, or -1 for
# a part that is not there.
layout() {
	awk -v W="$W" -v H="$H" '
		function sides(from, to,   r, lead, left, right) {
			left = -1; right = -1
			for (r = from; r <= to; r++) {
				if (row[r] == "") continue
				lead = match(row[r], /[^ ]/) - 1
				if (left < 0 || lead < left) left = lead
				if (right < 0 || W - length(row[r]) < right) right = W - length(row[r])
			}
			printf " %d %d", left, right
		}
		{ sub(/[ \t]+$/, ""); row[NR] = $0 }
		END {
			first = 0; last = 0; meta = 0
			for (r = 2; r < H; r++) {
				if (row[r] == "") continue
				if (!first) first = r
				last = r
				if (!meta && row[r] ~ /^ *General$/) meta = r
			}
			if (!meta) meta = last + 1
			printf "%d %d", first ? first - 2 : H - 2, first ? H - 1 - last : 0
			sides(first, meta - 1)
			sides(meta, last)
			print ""
		}'
}

top=0 bottom=0 ileft=-1 iright=-1 tleft=-1 tright=-1

# settle: waits until the pane stops changing, then reads its layout.
settle() {
	local before after i
	before=$(pane)
	for ((i = 0; i < 30; i++)); do
		sleep 0.3
		after=$(pane)
		if [[ $after == "$before" ]]; then
			read -r top bottom ileft iright tleft tright < <(layout <<<"$after")
			return 0
		fi
		before=$after
	done
	fail "the pane kept changing"
}

# near A B: the gap on one side is at most two cells off the other.
near() { (($1 - $2 <= 2 && $2 - $1 <= 2)); }

has_image() { settle && ((ileft >= 0)); }
no_image() { settle && ((ileft < 0 && tleft >= 0)); }
centered_rows() { near "$top" "$bottom"; }
room() { ((top + bottom >= 4)); }
fits() { ((bottom > 0)); }
centered_image() { ((ileft >= 0)) && near "$ileft" "$iright"; }
centered_text() { ((tleft >= 0)) && near "$tleft" "$tright"; }

checks=0
# expect DESCRIPTION COMMAND...: fails the run with DESCRIPTION unless COMMAND succeeds.
expect() {
	local what=$1
	shift
	"$@" || fail "$what (layout: $top $bottom $ileft $iright $tleft $tright)"
	checks=$((checks + 1))
}

# preview FILE: moves to FILE and waits until its preview has settled.
preview() {
	ya emit-to "$id" reveal "$media/$1"
	until_ok "the preview of $1" shows "Complete name: $media/$1"
	settle
}

press() { tmux -L "$sock" send-keys -t e2e "$1"; }

printf -v yazi_cmd 'env YAZI_CONFIG_HOME=%q XDG_STATE_HOME=%q YAZI_LOG=debug yazi --client-id %q %q; echo yazi exited $?; sleep 600' \
	"$work/config" "$work/state" "$id" "$media/sub.srt"
tmux -L "$sock" new-session -d -s e2e -x "$W" -y "$H" "$yazi_cmd"
until_ok "Yazi to start" shows "Complete name: $media/sub.srt"

# The other images fill the pane together with their metadata, which leaves
# nothing to center top to bottom. wide.png leaves rows free, so it is the one
# that tells whether the preview is centered that way.
for f in wide.png image.png image.tiff image.svg art.eps video.mp4 song.mp3; do
	preview "$f"
	[[ $f != wide.png ]] || expect "wide.png: leaves no room to center top to bottom" room
	expect "$f: the image is not centered left to right" centered_image
	expect "$f: the metadata is not centered left to right" centered_text
	expect "$f: the preview is not centered top to bottom" centered_rows
done

# Audio without cover art shows a blank 1x1 image instead, which still takes
# up two rows above the metadata, so only left to right is checked there.
preview plain.wav
expect "plain.wav: the metadata is not centered left to right" centered_text
expect "plain.wav: no Audio section" heading Audio
preview sub.srt
expect "sub.srt: the metadata is not centered left to right" centered_text
expect "sub.srt: the metadata is not centered top to bottom" centered_rows
expect "sub.srt: no Text section" heading Text

# The keymaps switch the metadata and the image off and on, and whatever is
# left stays centered.
preview video.mp4
press F3
until_ok "the metadata to hide" hides "Complete name"
settle
expect "metadata hidden: the image is not centered left to right" centered_image
expect "metadata hidden: the image is not centered top to bottom" centered_rows
press F3
until_ok "the metadata to come back" shows "Complete name: $media/video.mp4"
press F4
until_ok "the image to hide" no_image
expect "image hidden: the metadata is not centered left to right" centered_text
expect "image hidden: the metadata is not centered top to bottom" centered_rows

# The image stays hidden for the next file, and then all of the audio's
# metadata fits: General and Audio only, without the cover's Image section or
# its Cover lines.
preview song.mp3
expect "song.mp3: shows its cover while the image is hidden" no_image
expect "song.mp3: the metadata does not fit" fits
expect "song.mp3: no Audio section" heading Audio
expect "song.mp3: shows the Image section" no_heading Image
expect "song.mp3: shows Cover lines" hides Cover
press F5
until_ok "the image to come back" has_image

ya emit-to "$id" quit
until_ok "Yazi to exit" shows "yazi exited 0"

# Errors from the preloader and the keymap actions go to the log. "send failed"
# is not one: Yazi logs it when it cancels a preview, for the next file or for
# quitting, while the preview waits for the answer of a ya.sync call.
errors=$(grep -aE "Error when running preloader|Failed to run|Sync plugin|stack traceback" "$log" |
	grep -a center-media | grep -av "failed: send failed$" || true)
[[ -z $errors ]] || fail "errors in the log:
$errors"

echo "e2e: $checks checks passed"
