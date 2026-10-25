#!/usr/bin/env bash

# Proves that every media format converts in a PhotoPrism image: RAW (darktable, then RawTherapee
# with darktable disabled), HEIC, an Apple live photo pair, JPEG XL, 16-bit TIFF, PSD and MP4.
# The fixtures in fixtures.txt are downloaded and verified into a temp dir; the image is only run
# through its photoprism binary, never a shell.
# Usage: formats.sh <image>

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: ${0##*/} <image>" >&2
  exit 1
fi

img="$1"
here="$(cd "$(dirname "$0")" && pwd)"
failed=0

pass() { echo "ok   $*"; }
fail() { echo "FAIL $*"; failed=1; }

if ! docker image inspect "$img" >/dev/null 2>&1; then
  echo "FAIL no such image: $img"
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/originals"

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print $1 }'
  else
    shasum -a 256 "$1" | awk '{ print $1 }'
  fi
}

# Download and verify the fixtures.
names=()
while read -r sum url name; do
  [[ -z $sum || $sum == \#* ]] && continue
  file="$work/originals/$name"
  if ! curl -fsSL --retry 3 -o "$file" "$url"; then
    echo "FAIL $name: download failed ($url)"
    exit 1
  fi
  if [[ "$(sha256 "$file")" != "$sum" ]]; then
    echo "FAIL $name: sha256 mismatch ($url)"
    exit 1
  fi
  names+=("$name")
done <"$here/fixtures.txt"

# convert runs "photoprism convert [args]" against the fixtures with a fresh storage and sidecar
# in $work/<run>, as the current user so the temp dir stays removable. The log goes to
# $work/<run>.log. Extra docker run options go in CONVERT_ENV.
convert() {
  local run="$1"
  shift
  mkdir -p "$work/$run/storage" "$work/$run/sidecar"
  # shellcheck disable=SC2086
  docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp --tmpfs /photoprism:mode=1777 ${CONVERT_ENV:-} \
    -e PHOTOPRISM_DATABASE_DRIVER=sqlite \
    -e PHOTOPRISM_STORAGE_PATH=/storage -e PHOTOPRISM_SIDECAR_PATH=/sidecar \
    -e PHOTOPRISM_ORIGINALS_PATH=/originals -e PHOTOPRISM_IMPORT_PATH=/storage/import \
    -v "$work/originals:/originals:ro" -v "$work/$run/storage:/storage" -v "$work/$run/sidecar:/sidecar" \
    --entrypoint /opt/photoprism/bin/photoprism "$img" convert "$@" >"$work/$run.log" 2>&1 || {
    echo "FAIL $run: photoprism convert exited non-zero"
    tail -n 20 "$work/$run.log"
    failed=1
  }
}

# has_preview asserts a non-empty JPEG <name>.jpg in the run's sidecar.
has_preview() {
  local run="$1" name="$2" preview="$work/$1/sidecar/$2.jpg"
  if [[ -s $preview && "$(od -An -tx1 -N3 "$preview" | tr -d ' \n')" == ffd8ff ]]; then
    pass "$run: $name preview"
  else
    fail "$run: $name has no JPEG preview"
  fi
}

# Run 1: everything, with darktable as the RAW converter.
convert all
for name in "${names[@]}"; do
  has_preview all "$name"
done
if grep -q 'darktable' "$work/all.log"; then
  pass "all: log names darktable"
else
  fail "all: log does not name darktable"
fi

# Run 2: the RAW only, darktable disabled, a fresh sidecar, so RawTherapee converts it.
CONVERT_ENV="-e PHOTOPRISM_DISABLE_DARKTABLE=true" convert rawtherapee --ext nef
has_preview rawtherapee raw.nef
if grep -qi 'rawtherapee' "$work/rawtherapee.log"; then
  pass "rawtherapee: log names rawtherapee"
else
  fail "rawtherapee: log does not name rawtherapee"
fi

if [[ $failed -ne 0 ]]; then
  echo "format checks failed"
  exit 1
fi

echo "all formats converted"
