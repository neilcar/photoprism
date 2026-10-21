#!/usr/bin/env bash
# Tests plan.sh and index.sh against a generated library, with a stub "photoprism" command and
# cgroup files in a temporary folder. Requires bash, GNU find, awk, and numfmt.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

failures=0

pass() { printf 'ok   %s\n' "$1"; }
fail() {
  printf 'FAIL %s\n' "$1"
  [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     /'
  failures=$((failures + 1))
}

# expect runs a check and reports it. Arguments: name, command.
expect() {
  local name="$1"
  shift
  if "$@"; then pass "$name"; else fail "$name"; fi
}

# Library with nested folders, names with spaces, ignored folders, and one large video folder.
O="$TMP/originals"
mk() {
  mkdir -p "$O/$1"
  for i in $(seq 1 "$2"); do head -c "${3:-1000}" /dev/zero >"$O/$1/f$i.jpg"; done
}
mk "Corin/2019" 40
mk "Corin/2020" 35
mk "Corin/2021/trip a" 30
mk "Corin" 5
mk "misc" 30
mk "PLG buildings" 10
mk "Lightroom Library.lrlibrary" 3
mk "#recycle" 50
mk ".hidden" 50
mk "@eaDir" 20
mk "video" 2 400000000
head -c 10 /dev/zero >"$O/loose.jpg"

# Plan
plan_out="$(PARTITIONS=3 ORIGINALS_PATH="$O" bash "$DIR/scripts/plan.sh" 2>&1)"
grep '^PLAN' <<<"$plan_out" | cut -f2- >"$TMP/plan.tsv"
folders="$(cut -f3 "$TMP/plan.tsv" | sort | tr '\n' '|')"

expect "plan: splits folders above the target" grep -qx 'Corin/2019|Corin/2020|Corin/2021|Lightroom Library.lrlibrary|PLG buildings|misc|video|' <<<"$folders"
expect "plan: skips hidden, system, and recycle folders" bash -c '! grep -qE "#recycle|\.hidden|@eaDir" "$1"' _ "$TMP/plan.tsv"
expect "plan: uses every partition" bash -c '[ "$(cut -f1 "$1" | sort -u | tr -d "\n")" = 012 ]' _ "$TMP/plan.tsv"
expect "plan: reports the finalize share" grep -q 'left to the finalize pass' <<<"$plan_out"

# Index
BIN="$TMP/bin"
CG="$TMP/cgroup"
mkdir -p "$BIN" "$CG"

stub() {
  printf '#!/usr/bin/env bash\n%s\n' "$1" >"$BIN/photoprism"
  chmod +x "$BIN/photoprism"
}

cgroup() {
  echo "$1" >"$CG/memory.max"
  echo "${2:-0}" >"$CG/memory.current"
  echo "inactive_file ${3:-0}" >"$CG/memory.stat"
}

index() {
  env PATH="$BIN:$PATH" CGROUP="$CG" PLAN_FILE="$TMP/plan.tsv" "$@" bash "$DIR/scripts/index.sh" 2>&1
}

stub 'echo "stub $* workers=$PHOTOPRISM_INDEX_WORKERS gomaxprocs=$GOMAXPROCS conns=$PHOTOPRISM_DATABASE_CONNS"'
cgroup 8589934592 2147483648 1073741824

out="$(index JOB_COMPLETION_INDEX=0 CPU_LIMIT=4)"
status=$?
expect "index: exits 0" test "$status" -eq 0
expect "index: limits workers by cpus" grep -q '4 workers (limited by cpu' <<<"$out"
expect "index: passes worker settings" grep -q 'workers=4 gomaxprocs=4 conns=12' <<<"$out"
expect "index: reports the peak working set" grep -q 'PEAK_MEMORY_BYTES=1073741824' <<<"$out"
expect "index: indexes folders with spaces as one argument" bash -c '[ "$(grep -c "^stub index " <<<"$1")" -eq "$(awk -F "\t" "\$1 == 0" "$2" | wc -l)" ]' _ "$out" "$TMP/plan.tsv"

cgroup 4294967296
out="$(index JOB_COMPLETION_INDEX=0 CPU_LIMIT=16)"
expect "index: limits workers by memory" grep -q '2 workers (limited by memory' <<<"$out"

out="$(index JOB_COMPLETION_INDEX=0 CPU_LIMIT=16 MEMORY_LIMIT=3000000000)"
expect "index: honors a lower downward API limit" grep -q '1 workers (limited by memory' <<<"$out"

out="$(index JOB_COMPLETION_INDEX=0 CPU_LIMIT=16 MAX_WORKERS=1)"
expect "index: honors MAX_WORKERS" grep -q '1 workers (limited by max-workers' <<<"$out"

cgroup 8589934592 8000000000 0
out="$(index JOB_COMPLETION_INDEX=0 CPU_LIMIT=4)"
expect "index: warns near the memory limit" grep -q 'warning: working set' <<<"$out"

cgroup 2147483648
index JOB_COMPLETION_INDEX=0 CPU_LIMIT=4 >/dev/null
expect "index: exits 3 below the minimum memory" test $? -eq 3

cgroup max
index JOB_COMPLETION_INDEX=0 CPU_LIMIT=4 >/dev/null
expect "index: exits 3 without a memory limit" test $? -eq 3

cgroup 8589934592
stub 'echo "index: waiting for the face migration to complete"'
index JOB_COMPLETION_INDEX=0 CPU_LIMIT=4 >/dev/null
expect "index: exits 4 when blocked" test $? -eq 4

stub 'exit 137'
out="$(index JOB_COMPLETION_INDEX=0 CPU_LIMIT=4)"
status=$?
expect "index: exits 1 when a folder fails" test "$status" -eq 1
expect "index: continues after a failed folder" bash -c '[ "$(grep -c "failed with exit code 137" <<<"$1")" -gt 1 ]' _ "$out"

stub 'echo "stub $*"'
out="$(index MODE=finalize CPU_LIMIT=4)"
expect "finalize: indexes the whole library" grep -qx 'stub index' <<<"$out"

if [ "$failures" -gt 0 ]; then
  printf '\n%d test(s) failed\n' "$failures"
  exit 1
fi

printf '\nall tests passed\n'
