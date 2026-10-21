#!/usr/bin/env bash
# Indexes the folders of one partition, or the whole library with MODE=finalize, with an
# indexing worker count that fits the memory and CPU limits of the pod.
#
# Exit codes: 0 done, 1 a folder failed, 3 the pod is too small or has no memory limit,
# 4 indexing is blocked by another operation (e.g. a face migration).
#
# Environment:
#   MODE              "partition" (default) or "finalize"
#   PLAN_FILE         plan written by plan.sh (default: /opt/parallel-index/plan/plan.tsv)
#   MEMORY_LIMIT      container memory limit in bytes, from the downward API
#   CPU_LIMIT         container CPU limit in cores, from the downward API
#   BASE_MEM_MB       memory reserved for the process, its AI models and caches (default: 1500)
#   WORKER_MEM_MB     estimated peak memory per indexing worker (default: 1000)
#   MAX_WORKERS       upper bound for the worker count (optional)
#   MEMORY_WARN_PCT   log a warning when the working set exceeds this share of the limit (default: 90)

set -uo pipefail

MODE="${MODE:-partition}"
PLAN_FILE="${PLAN_FILE:-/opt/parallel-index/plan/plan.tsv}"
BASE_MEM_MB="${BASE_MEM_MB:-1500}"
WORKER_MEM_MB="${WORKER_MEM_MB:-1000}"
MEMORY_WARN_PCT="${MEMORY_WARN_PCT:-90}"
CGROUP="${CGROUP:-/sys/fs/cgroup}"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

# cgroup_limit prints the cgroup memory limit in bytes, or nothing if there is none.
cgroup_limit() {
  local v
  for f in "$CGROUP/memory.max" "$CGROUP/memory/memory.limit_in_bytes"; do
    [ -r "$f" ] || continue
    v="$(cat "$f")"
    if [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -lt 4611686018427387904 ]; then
      echo "$v"
      return
    fi
  done
}

# working_set prints the memory charged to the cgroup minus the reclaimable page cache.
working_set() {
  local usage inactive
  if [ -r "$CGROUP/memory.current" ]; then
    usage="$(cat "$CGROUP/memory.current")"
    inactive="$(awk '$1 == "inactive_file" {print $2}' "$CGROUP/memory.stat")"
  else
    usage="$(cat "$CGROUP/memory/memory.usage_in_bytes" 2>/dev/null || echo 0)"
    inactive="$(awk '$1 == "total_inactive_file" {print $2}' "$CGROUP/memory/memory.stat" 2>/dev/null)"
  fi
  inactive="${inactive:-0}"
  if [ "$usage" -gt "$inactive" ]; then echo $((usage - inactive)); else echo 0; fi
}

# The downward API reports a missing limit as the node capacity, so the cgroup is checked as well.
mem_limit="$(cgroup_limit)"
if [ -n "${MEMORY_LIMIT:-}" ] && { [ -z "$mem_limit" ] || [ "$MEMORY_LIMIT" -lt "$mem_limit" ]; }; then
  mem_limit="$MEMORY_LIMIT"
fi

if [ -z "$mem_limit" ]; then
  log "error: no memory limit set, refusing to start since the worker count could not be bounded"
  exit 3
fi

cpus="${CPU_LIMIT:-$(nproc)}"
[ "$cpus" -ge 1 ] 2>/dev/null || cpus=1

base=$((BASE_MEM_MB * 1000000))
per_worker=$((WORKER_MEM_MB * 1000000))

if [ "$mem_limit" -lt $((base + per_worker)) ]; then
  log "error: memory limit $(numfmt --to=iec-i "$mem_limit") is below the $(numfmt --to=iec-i $((base + per_worker))) needed for one worker"
  exit 3
fi

workers=$(((mem_limit - base) / per_worker))
reason="memory"
if [ "$workers" -gt "$cpus" ]; then
  workers="$cpus"
  reason="cpu"
fi
if [ -n "${MAX_WORKERS:-}" ] && [ "$workers" -gt "$MAX_WORKERS" ]; then
  workers="$MAX_WORKERS"
  reason="max-workers"
fi

# The pod only indexes, so it may use all its CPUs; libvips uses the same number of threads.
export PHOTOPRISM_INDEX_WORKERS="$workers"
export PHOTOPRISM_WORKERS="$workers"
export GOMAXPROCS="$cpus"
export MALLOC_ARENA_MAX=2
export PHOTOPRISM_DATABASE_CONNS=$((workers * 2 + 4))
export PHOTOPRISM_DATABASE_CONNS_IDLE=$((workers + 1))

log "resources: memory limit $(numfmt --to=iec-i "$mem_limit"), ${cpus} cpus, ${workers} workers (limited by ${reason}, ${BASE_MEM_MB} MB base + ${WORKER_MEM_MB} MB per worker)"

# Track the peak working set so the per-worker estimate can be tuned from the logs.
peak_file="$(mktemp)"
echo 0 > "$peak_file"

sample() {
  local ws
  ws="$(working_set)"
  [ "$ws" -gt "$(cat "$peak_file")" ] && echo "$ws" > "$peak_file"
  echo "$ws"
}

(
  warned=0
  pause=""
  trap '[ -n "$pause" ] && kill "$pause" 2>/dev/null; exit 0' TERM
  while true; do
    ws="$(sample)"
    if [ "$warned" -eq 0 ] && [ $((ws * 100 / mem_limit)) -ge "$MEMORY_WARN_PCT" ]; then
      log "warning: working set $(numfmt --to=iec-i "$ws") is above ${MEMORY_WARN_PCT}% of the limit, raise WORKER_MEM_MB or the memory limit"
      warned=1
    fi
    sleep 10 &
    pause=$!
    wait "$pause"
  done
) &
monitor=$!

report() {
  kill "$monitor" 2>/dev/null
  wait "$monitor" 2>/dev/null
  sample >/dev/null
  local peak
  peak="$(cat "$peak_file")"
  rm -f "$peak_file"
  log "resources: peak working set $(numfmt --to=iec-i "$peak") of $(numfmt --to=iec-i "$mem_limit") ($((peak * 100 / mem_limit))%) with ${workers} workers"
  echo "PEAK_MEMORY_BYTES=${peak} WORKERS=${workers} MEMORY_LIMIT_BYTES=${mem_limit}"
}
trap report EXIT

# index_folder runs the indexer and fails if it was blocked by another operation,
# since the command exits with 0 in that case.
index_folder() {
  local out status
  out="$(mktemp)"
  photoprism index "$@" 2>&1 | tee "$out"
  status=${PIPESTATUS[0]}
  if grep -q 'index: waiting for the' "$out"; then
    rm -f "$out"
    return 4
  fi
  rm -f "$out"
  return "$status"
}

case "$MODE" in
finalize)
  log "finalize: indexing the whole library to pick up remaining files"
  index_folder
  exit $?
  ;;
partition)
  : "${JOB_COMPLETION_INDEX:?JOB_COMPLETION_INDEX must be set}"
  ;;
*)
  log "error: unknown mode ${MODE}"
  exit 2
  ;;
esac

mapfile -t folders < <(awk -F '\t' -v i="$JOB_COMPLETION_INDEX" '$1 == i {print $3}' "$PLAN_FILE")
log "partition ${JOB_COMPLETION_INDEX}: ${#folders[@]} folders"

failed=0
for i in "${!folders[@]}"; do
  folder="${folders[$i]}"
  log "partition ${JOB_COMPLETION_INDEX}: [$((i + 1))/${#folders[@]}] ${folder}"
  index_folder "$folder"
  status=$?
  case "$status" in
  0) ;;
  4)
    log "error: indexing is blocked by another operation, stopping"
    exit 4
    ;;
  *)
    log "error: indexing ${folder} failed with exit code ${status}"
    failed=1
    ;;
  esac
done

exit "$failed"
