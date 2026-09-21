#!/bin/bash
# Generates one small file per preview path of the plugin into DIR.
#
# Every image is patterned up to a black and white frame: chafa draws an area
# of one color as blank cells, which would hide where the image ends from
# e2e.sh, and the frame makes whatever it does the same on both sides.
#
#     bash ci/samples.sh DIR
set -euo pipefail
readonly out=${1:?usage: samples.sh DIR}
readonly frame=(-bordercolor black -border 3 -bordercolor white -border 3)
mkdir -p "$out"
cd "$out"

magick -size 314x314 pattern:checkerboard -fill red -draw "circle 157,157 157,57" "${frame[@]}" image.png
# Wide enough to leave rows free above and below it at any pane size, so that
# centering it top to bottom can be told from not centering it. The centering
# degrades once the metadata takes more than half of the pane, 29 rows in
# e2e.sh, and the check fails a few rows after that. -strip drops the dates
# magick stores, which keeps the metadata at 18 rows.
magick -size 314x44 pattern:checkerboard "${frame[@]}" -strip wide.png
magick image.png image.tiff
magick image.png art.eps
cat >image.svg <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" width="320" height="240">
  <defs>
    <pattern id="check" width="16" height="16" patternUnits="userSpaceOnUse">
      <rect width="8" height="8"/>
      <rect x="8" y="8" width="8" height="8"/>
    </pattern>
  </defs>
  <rect width="320" height="240" fill="white"/>
  <rect x="3" y="3" width="314" height="234"/>
  <rect x="6" y="6" width="308" height="228" fill="white"/>
  <rect x="6" y="6" width="308" height="228" fill="url(#check)"/>
  <circle cx="160" cy="120" r="80" fill="gold"/>
</svg>
EOF
ffmpeg -v error -y -f lavfi -i "sine=frequency=440:duration=2" -i image.png \
	-map 0:a -map 1:v -c:a libmp3lame -c:v mjpeg -id3v2_version 3 -disposition:v attached_pic song.mp3
ffmpeg -v error -y -f lavfi -i "sine=frequency=440:duration=2" plain.wav
# libx264 writes an "Encoding settings" line wider than the pane, as most videos
# have, which must not keep the metadata from being centered.
ffmpeg -v error -y -loop 1 -i image.png -vf scale=480:270 -t 2 -r 25 -c:v libx264 -pix_fmt yuv420p video.mp4
printf '1\n00:00:00,000 --> 00:00:01,000\nHello\n' >sub.srt
