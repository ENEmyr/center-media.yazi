# Compatibility checks

These scripts check the plugin against the tools it depends on: Yazi,
mediainfo, FFmpeg, ImageMagick, Ghostscript and resvg. The goal is to notice
when an update to one of them breaks the plugin before users do. They run on
Arch Linux, where these tools are packaged in recent versions, and are driven
by `.github/workflows/compat.yml`.

`ya pkg` installs the Lua files, `LICENSE` and `README.md` at the repository
root and the `assets` directory, so nothing in this directory reaches users.

## What runs

`check.sh` runs the checks against whichever `yazi` and `ya` come first on
`PATH`, cheapest first:

1. `tests/metadata.lua`, the unit tests, against stubs of Yazi's Lua API and
   recorded `mediainfo` output.
2. `samples.sh` generates one small file for each preview path: PNG, TIFF, SVG
   and EPS images, MP3 audio with cover art, WAV audio without, an MP4 video
   and a SubRip subtitle, plus a wide PNG.
3. `contract.sh` checks that `mediainfo`, `ffprobe`, `ffmpeg`, `magick` and
   `identify` still print what the plugin parses from them. Each check names
   the code that depends on it.
4. `e2e.sh` starts Yazi in tmux with the plugin installed, moves through the
   samples with `ya emit-to`, and reads the screen with `tmux capture-pane`.
   Without a graphical terminal Yazi draws images with chafa as text, so the
   image can be found on screen as well as the metadata. It checks that each
   file shows its own metadata, that audio leaves out its cover art's `Image`
   section and `Cover` lines, that the image and the metadata are centered,
   and that the F3, F4 and F5 keymaps from the README hide and restore them.
   A Lua error in a preview shows on screen and fails the run at once, a
   broken keymap action fails the check that waits for its effect, and errors
   Yazi logs for the plugin fail the run at the end. The one exception is
   "send failed", which Yazi logs when it cancels a preview that waits for an
   answer from Yazi, as it does when moving on to the next file.

Two things about the end-to-end check are worth knowing before changing it.
The other images fill the pane together with their metadata, so only the wide
PNG leaves room to tell whether a preview is centered top to bottom. And chafa
always fills the rect in one direction, so the plugin never learns the cell
size there and every image takes its redraw path: the prediction that
graphical terminals use is not covered. The layout parsing also takes the
first row of the screen for Yazi's header and the last for its status bar.

## When it runs

- On a push to `main` and on pull requests, the `pinned` job checks the change
  against fixed versions: the Arch Linux container image of one day and the
  packages of the same day from the Arch Linux Archive. That day has Yazi
  26.9.1, the version `main.lua` declares. Changes to documentation alone do
  not start it.
- Every Monday, the `upstream` job checks the plugin against the current Arch
  packages, then against the latest Yazi nightly build on top of them.
- Both run when the workflow is started by hand from the Actions tab.

To move the pinned versions forward, change the container image tag and
`ARCH_SNAPSHOT` in the workflow to the same date. The tags are listed on
[Docker Hub](https://hub.docker.com/r/archlinux/archlinux/tags?name=base-2),
and a snapshot exists for every day at
[archive.archlinux.org](https://archive.archlinux.org/repos/).

## Running it locally

With Docker, from the repository root:

```sh
# the pinned versions
docker run --rm -e ARCH_SNAPSHOT=2026/09/20 -v "$PWD:/src:ro" \
  docker.io/archlinux/archlinux:base-20260920.0.597023 \
  bash -c 'bash /src/ci/install.sh && bash /src/ci/check.sh'

# the current packages, then the Yazi nightly build
docker run --rm -v "$PWD:/src:ro" docker.io/archlinux/archlinux:latest \
  bash -c 'bash /src/ci/install.sh && bash /src/ci/check.sh &&
    bash /src/ci/nightly.sh /opt/yazi && PATH=/opt/yazi:$PATH bash /src/ci/check.sh'
```

`install.sh` changes the system's package mirror and packages, so run it only
in a container.

## Notifications and upkeep

When the scheduled run fails, GitHub emails the person who last changed the
`cron` line in the workflow. The workflow has read access only and opens no
issues.

GitHub turns off scheduled workflows in a public repository after 60 days
without activity in it. To turn it back on, use the button on the workflow's
page in the Actions tab, or run:

```sh
gh workflow enable compat.yml
```

Dependabot keeps the actions the workflow uses up to date. They are pinned to
full commit SHAs, and Dependabot opens a pull request once a month when there
is a newer release.
