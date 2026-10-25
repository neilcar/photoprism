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

# The image must not contain a shell.
if docker run --rm --entrypoint /bin/sh "$img" -c true >/dev/null 2>&1; then
  fail "/bin/sh runs"
else
  pass "no /bin/sh"
fi

# photoprism --version prints "<build date>-<commit>-Linux-<ARCH>"; the commit must be the
# image's source revision, which is release 261007 with this fork's patches.
version="$(pp --version 2>&1 || true)"
revision="$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$img")"
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
report="$(pp show config --tsv)"
for key in ffmpeg-bin exiftool-bin darktable-bin rawtherapee-bin heifconvert-bin imagemagick-bin \
  rsvgconvert-bin jpegxldecoder-bin; do
  value="$(awk -F'\t' -v k="$key" '$1 == k { print $2; exit }' <<<"$report")"
  if [[ $value == /* ]]; then
    pass "$key: $value"
  else
    fail "$key: '$value'"
  fi
done

# The image runs as root.
user="$(docker image inspect --format '{{.Config.User}}' "$img")"
if [[ $user == "0:0" ]]; then
  pass "user 0:0"
else
  fail "user '$user'"
fi

# The index workers follow the container memory limit, as in image.yml's smoke test.
report="$(docker run --rm --entrypoint /opt/photoprism/bin/photoprism -e PHOTOPRISM_INDEX_WORKERS= \
  --memory 2g "$img" show config)"
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
