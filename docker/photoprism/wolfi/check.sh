#!/usr/bin/env bash

# Checks a built photoprism-index image: no shell, the PhotoPrism and parallel-index
# binaries run, the media tools are found, and the index workers follow the memory limit.
# Usage: check.sh <image>

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: ${0##*/} <image>" >&2
  exit 1
fi

img="$1"
failed=0

pass() { echo "ok   $*"; }
fail() { echo "FAIL $*"; failed=1; }

# pp runs photoprism with the given arguments; extra docker run options go in PP_OPTS.
pp() {
  # shellcheck disable=SC2086
  docker run --rm ${PP_OPTS:-} --entrypoint /opt/photoprism/bin/photoprism "$img" "$@"
}

if ! docker image inspect "$img" >/dev/null 2>&1; then
  echo "FAIL no such image: $img"
  exit 1
fi

# The image must not contain a shell. Each path must fail with a "no such file" style error,
# so that a docker or daemon error does not count as a pass.
for sh in /bin/sh /bin/bash /usr/bin/bash /bin/ash /bin/busybox; do
  out="$(docker run --rm --entrypoint "$sh" "$img" -c true 2>&1)" && code=0 || code=$?
  if [[ $code -eq 0 ]]; then
    fail "$sh runs"
  elif grep -Eqi 'no such file or directory|executable file not found' <<<"$out"; then
    pass "no $sh"
  else
    fail "$sh: unexpected error: $out"
  fi
done

# photoprism --version prints "<build date>-<commit>-Linux-<ARCH>"; the commit must be the
# image's source revision, which is release 261007 with this fork's patches.
version="$(pp --version 2>&1 || true)"
revision="$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$img")" ||
  { fail "image inspect: could not read the revision label"; revision=""; }
if [[ $version =~ ^photoprism\ version\ [0-9]{6}-([0-9a-f]{7,40})-Linux-(AMD64|ARM64)$ ]] &&
  [[ -n $revision && $revision == "${BASH_REMATCH[1]}"* ]]; then
  pass "version: $version (revision $revision)"
else
  fail "version: '$version' does not match revision label '$revision'"
fi

# parallel-index without arguments prints its usage and exits 2.
set +e
usage="$(docker run --rm --entrypoint /opt/parallel-index/bin/parallel-index "$img" 2>&1)"
code=$?
set -e
if [[ $code -eq 2 ]] && grep -qi 'usage' <<<"$usage"; then
  pass "parallel-index usage, exit 2"
else
  fail "parallel-index exited $code: $usage"
fi

# The config report must list a found path for each media tool. The full report is captured
# first, so photoprism does not write to a closed pipe.
report="$(pp show config --tsv)" || { fail "show config --tsv failed"; report=""; }
for key in ffmpeg-bin exiftool-bin darktable-bin rawtherapee-bin heifconvert-bin imagemagick-bin \
  rsvgconvert-bin jpegxldecoder-bin; do
  value="$(awk -F'\t' -v k="$key" '$1 == k { print $2; exit }' <<<"$report")"
  if [[ $value == /* ]]; then
    pass "$key: $value"
  else
    fail "$key: '$value'"
  fi
done

# libvips must convert embedded color profiles, which needs its lcms2 support.
ops="$(docker run --rm --entrypoint /usr/bin/vips "$img" -l)" || { fail "vips -l failed"; ops=""; }
if grep -q 'icc_transform' <<<"$ops"; then
  pass "vips lists icc_transform"
else
  fail "vips does not list icc_transform"
fi

# Indexing a Display P3 JPEG must not log ICC transform errors.
sample="$(cd "$(dirname "$0")/../../.." && pwd)/pkg/media/colors/testdata/DisplayP3.jpg"
log="$(docker run --rm --tmpfs /photoprism/storage -v "$sample:/photoprism/originals/DisplayP3.jpg:ro" \
  --entrypoint /opt/photoprism/bin/photoprism "$img" index 2>&1 || true)"
if grep -qi 'icc.transform' <<<"$log"; then
  fail "Display P3 index logged an ICC transform error"
elif grep -Eq 'library: indexed [1-9][0-9]* files? ' <<<"$log"; then
  pass "Display P3 indexed without ICC errors"
else
  fail "Display P3 index: $(tail -n 3 <<<"$log")"
fi

# The image runs as root.
user="$(docker image inspect --format '{{.Config.User}}' "$img")" || { fail "image inspect: could not read the user"; user=""; }
if [[ $user == "0:0" ]]; then
  pass "user 0:0"
else
  fail "user '$user'"
fi

# The index workers follow the container memory limit, as in image.yml's smoke test.
report="$(docker run --rm --entrypoint /opt/photoprism/bin/photoprism -e PHOTOPRISM_INDEX_WORKERS= \
  --memory 2g "$img" show config)" || { fail "2 GB limit: show config failed"; report=""; }
line="$(grep -m1 'index-workers' <<<"$report" || true)"
if grep -q '(low-memory)' <<<"$line"; then
  pass "2 GB limit: $line"
else
  fail "2 GB limit: '$line'"
fi

if [[ $failed -ne 0 ]]; then
  echo "checks failed"
  exit 1
fi

echo "all checks passed"
