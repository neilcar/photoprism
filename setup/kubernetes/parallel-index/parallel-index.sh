#!/usr/bin/env bash
# Indexes a PhotoPrism library with Kubernetes Jobs that run in parallel across the cluster.
#
# Usage: parallel-index.sh [preflight|plan|index|finalize|run|status|clean]
#
#   preflight  checks the deployment, storage, node capacity, and running operations
#   plan       scans the originals and splits them into balanced partitions
#   index      indexes the partitions with an Indexed Job
#   finalize   indexes the whole library once to pick up remaining files
#   run        preflight, plan, index, and finalize (default)
#   status     shows the jobs, pods, and resource usage reported by finished pods
#   clean      deletes the jobs and config maps created by this script
#   render     prints the job manifests without applying them
#
# The Jobs copy the image, environment, volumes, and security context of the PhotoPrism
# StatefulSet, so they use the same database, settings, and storage. See README.md.

set -euo pipefail

NAMESPACE="${NAMESPACE:-photoprism}"
STATEFULSET="${STATEFULSET:-photoprism-photoprism}"
NAME="${NAME:-photoprism-index}"
PARTITIONS="${PARTITIONS:-12}"
PARALLELISM="${PARALLELISM:-4}"
MEMORY="${MEMORY:-6Gi}"
CPU="${CPU:-4}"
BASE_MEM_MB="${BASE_MEM_MB:-1500}"
WORKER_MEM_MB="${WORKER_MEM_MB:-1000}"
MAX_WORKERS="${MAX_WORKERS:-}"
PLAN_MEMORY="${PLAN_MEMORY:-512Mi}"
FINALIZE_MEMORY="${FINALIZE_MEMORY:-$MEMORY}"
FINALIZE_CPU="${FINALIZE_CPU:-$CPU}"
STORAGE_MODE="${STORAGE_MODE:-auto}"
BLOCKING_LOCKS="${BLOCKING_LOCKS:-/photoprism/storage/faces-job/lock}"
MARIADB_POD="${MARIADB_POD:-mariadb-0}"
FORCE="${FORCE:-false}"
STATE_DIR="${STATE_DIR:-${TMPDIR:-/tmp}/${NAME}}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="app.kubernetes.io/part-of=${NAME}"

log() { printf '%s\n' "$*" >&2; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

k() { kubectl -n "$NAMESPACE" "$@"; }

# bytes converts a Kubernetes quantity such as 6Gi, 512M, or 1.5G to bytes.
bytes() {
  awk -v q="$1" 'BEGIN {
    n = q + 0; s = q; sub(/^[0-9.]+/, "", s)
    m["Ki"] = 1024; m["Mi"] = 1024^2; m["Gi"] = 1024^3; m["Ti"] = 1024^4
    m["k"] = 1e3; m["K"] = 1e3; m["M"] = 1e6; m["G"] = 1e9; m["T"] = 1e12; m[""] = 1
    if (!(s in m)) exit 1
    printf "%.0f\n", n * m[s]
  }' || die "invalid quantity: $1"
}

# millicores converts a Kubernetes CPU quantity such as 4 or 7500m to millicores.
millicores() {
  case "$1" in
  *m) echo "${1%m}" ;;
  *) awk -v q="$1" 'BEGIN { printf "%.0f\n", q * 1000 }' ;;
  esac
}

# workers_for mirrors the worker calculation in scripts/index.sh.
workers_for() {
  local mem cpus base per n
  mem="$(bytes "$1")"
  cpus="$2"
  base=$((BASE_MEM_MB * 1000000))
  per=$((WORKER_MEM_MB * 1000000))
  if [ "$mem" -lt $((base + per)) ]; then
    echo 0
    return
  fi
  n=$(((mem - base) / per))
  [ "$n" -gt "$cpus" ] && n="$cpus"
  [ -n "$MAX_WORKERS" ] && [ "$n" -gt "$MAX_WORKERS" ] && n="$MAX_WORKERS"
  echo "$n"
}

# load_deployment reads the settings the Jobs copy from the StatefulSet.
load_deployment() {
  [ -n "${STS_JSON:-}" ] && return
  command -v jq >/dev/null || die "jq is required"
  STS_JSON="$(k get statefulset "$STATEFULSET" -o json)" || die "statefulset ${NAMESPACE}/${STATEFULSET} not found"

  IMAGE="$(jq -r '.spec.template.spec.containers[0].image' <<<"$STS_JSON")"

  # A volume is either a regular claim or created from a claim template of the StatefulSet.
  claim_for() {
    jq -r --arg path "$1" --arg sts "$STATEFULSET" '
      .spec.template.spec as $pod
      | ($pod.containers[0].volumeMounts[] | select(.mountPath == $path) | .name) as $vol
      | ([$pod.volumes[]? | select(.name == $vol) | .persistentVolumeClaim.claimName] | first)
        // ([.spec.volumeClaimTemplates[]? | select(.metadata.name == $vol) | "\(.metadata.name)-\($sts)-0"] | first)
        // empty' <<<"$STS_JSON"
  }

  ORIGINALS_CLAIM="$(claim_for /photoprism/originals)"
  STORAGE_CLAIM="$(claim_for /photoprism/storage)"
  [ -n "$ORIGINALS_CLAIM" ] || die "no claim mounted at /photoprism/originals in ${STATEFULSET}"
  [ -n "$STORAGE_CLAIM" ] || die "no claim mounted at /photoprism/storage in ${STATEFULSET}"

  MAIN_POD="${STATEFULSET}-0"
  MAIN_NODE="$(k get pod "$MAIN_POD" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"

  STORAGE_RWX="$(k get pvc "$STORAGE_CLAIM" -o json | jq -r '[.status.accessModes[]?] | index("ReadWriteMany") != null')"

  case "$STORAGE_MODE" in
  auto) [ "$STORAGE_RWX" = true ] && PIN_NODE="" || PIN_NODE="$MAIN_NODE" ;;
  shared) PIN_NODE="" ;;
  pin) PIN_NODE="$MAIN_NODE" ;;
  *) die "STORAGE_MODE must be auto, shared, or pin" ;;
  esac
}

# pod_spec prints the pod spec for a job as JSON. Arguments: mode, memory, cpu, mounts storage.
pod_spec() {
  local mode="$1" memory="$2" cpu="$3" storage="$4" pin="${PIN_NODE}"
  # The plan only reads the originals, so it can run on any node.
  [ "$storage" = true ] || pin=""

  jq -n \
    --argjson sts "$STS_JSON" \
    --arg name "$NAME" --arg mode "$mode" --arg image "$IMAGE" \
    --arg memory "$memory" --arg cpu "$cpu" --argjson storage "$storage" \
    --arg originals "$ORIGINALS_CLAIM" --arg storageClaim "$STORAGE_CLAIM" \
    --arg pin "$pin" --arg partitions "$PARTITIONS" \
    --arg baseMem "$BASE_MEM_MB" --arg workerMem "$WORKER_MEM_MB" --arg maxWorkers "$MAX_WORKERS" '
    def env_var($n; $v): {name: $n, value: $v};
    def overridden: ["PHOTOPRISM_INDEX_WORKERS", "PHOTOPRISM_WORKERS", "PHOTOPRISM_DATABASE_CONNS",
      "PHOTOPRISM_DATABASE_CONNS_IDLE", "PHOTOPRISM_LOG_LEVEL", "GOMAXPROCS"];
    ($sts.spec.template.spec) as $p
    | ($p.containers[0]) as $c
    | {
        restartPolicy: "Never",
        enableServiceLinks: false,
        securityContext: ($p.securityContext // {}),
        topologySpreadConstraints: [{
          maxSkew: 1,
          topologyKey: "kubernetes.io/hostname",
          whenUnsatisfiable: "ScheduleAnyway",
          labelSelector: {matchLabels: {"app.kubernetes.io/part-of": $name, "app.kubernetes.io/component": $mode}}
        }],
        containers: [{
          name: "index",
          image: $image,
          imagePullPolicy: "IfNotPresent",
          command: ["bash", "/opt/parallel-index/scripts/\(if $mode == "plan" then "plan" else "index" end).sh"],
          env: ([($c.env // [])[] | select(.name as $n | overridden | index($n) | not)]
            + [env_var("PHOTOPRISM_LOG_LEVEL"; "info"),
               env_var("MODE"; $mode),
               env_var("PARTITIONS"; $partitions),
               env_var("BASE_MEM_MB"; $baseMem),
               env_var("WORKER_MEM_MB"; $workerMem),
               {name: "MEMORY_LIMIT", valueFrom: {resourceFieldRef: {containerName: "index", resource: "limits.memory"}}},
               {name: "CPU_LIMIT", valueFrom: {resourceFieldRef: {containerName: "index", resource: "limits.cpu", divisor: "1"}}}]
            + (if $maxWorkers != "" then [env_var("MAX_WORKERS"; $maxWorkers)] else [] end)),
          envFrom: ($c.envFrom // []),
          resources: {
            requests: {memory: $memory, cpu: $cpu},
            limits: {memory: $memory, cpu: $cpu}
          },
          volumeMounts: ([
            {name: "originals", mountPath: "/photoprism/originals", readOnly: ($storage | not)},
            {name: "scripts", mountPath: "/opt/parallel-index/scripts", readOnly: true}]
            + (if $storage then [
                {name: "storage", mountPath: "/photoprism/storage"},
                {name: "plan", mountPath: "/opt/parallel-index/plan", readOnly: true}] else [] end))
        }],
        volumes: ([
          {name: "originals", persistentVolumeClaim: {claimName: $originals}},
          {name: "scripts", configMap: {name: "\($name)-scripts"}}]
          + (if $storage then [
              {name: "storage", persistentVolumeClaim: {claimName: $storageClaim}},
              {name: "plan", configMap: {name: "\($name)-plan", optional: true}}] else [] end))
      }
    | if $pin != "" then .affinity = {nodeAffinity: {requiredDuringSchedulingIgnoredDuringExecution: {
        nodeSelectorTerms: [{matchExpressions: [{key: "kubernetes.io/hostname", operator: "In", values: [$pin]}]}]}}}
      else . end
    | .imagePullSecrets = ($p.imagePullSecrets // [])'
}

# job prints a Job manifest as JSON. Arguments: component, pod spec, completions, parallelism.
job() {
  local component="$1" spec="$2" completions="$3" parallelism="$4"
  jq -n --arg name "$NAME" --arg ns "$NAMESPACE" --arg component "$component" \
    --argjson spec "$spec" --argjson completions "$completions" --argjson parallelism "$parallelism" '
    {"app.kubernetes.io/part-of": $name, "app.kubernetes.io/component": $component} as $labels
    | {
        apiVersion: "batch/v1",
        kind: "Job",
        metadata: {name: "\($name)-\($component)", namespace: $ns, labels: $labels},
        spec: {
          completions: $completions,
          parallelism: $parallelism,
          ttlSecondsAfterFinished: 604800,
          podFailurePolicy: {rules: [
            {action: "FailJob", onExitCodes: {containerName: "index", operator: "In", values: [3, 4]}},
            {action: "Ignore", onPodConditions: [{type: "DisruptionTarget"}]}
          ]},
          template: {metadata: {labels: $labels}, spec: $spec}
        }
      }
    | if $component == "partition" then
        .spec.completionMode = "Indexed" | .spec.backoffLimitPerIndex = 1 | .spec.maxFailedIndexes = $completions
      else .spec.backoffLimit = 1 end'
}

# check_idle fails if the main pod is indexing or holds one of the blocking locks.
check_idle() {
  local busy
  # The command names are split, so this script does not match its own command line.
  busy="$(k exec "$MAIN_POD" -- bash -c '
    bin="photo""prism"
    for p in /proc/[0-9]*; do
      c="$(tr "\0" " " < "$p/cmdline" 2>/dev/null)"
      case "$c" in *"$bin index"*|*"$bin import"*|*"$bin faces"*) echo "process: $c";; esac
    done
    for l in '"$BLOCKING_LOCKS"'; do
      [ -e "$l" ] && ! flock -n "$l" true 2>/dev/null && echo "lock held: $l"
    done
    exit 0' 2>/dev/null)" || {
    warn "could not check ${MAIN_POD} for running operations"
    return 0
  }

  if [ -n "$busy" ]; then
    log "$busy"
    [ "$FORCE" = true ] || die "the main pod is busy, wait for it to finish or set FORCE=true"
    warn "continuing because FORCE=true"
  fi
}

preflight() {
  load_deployment
  local mem_bytes workers pods_per_node conns max_conns

  log "deployment: ${NAMESPACE}/${STATEFULSET} on ${MAIN_NODE:-unknown node}, image ${IMAGE}"
  log "volumes: originals ${ORIGINALS_CLAIM}, storage ${STORAGE_CLAIM} (rwx: ${STORAGE_RWX})"

  if [ -n "$PIN_NODE" ]; then
    warn "storage claim ${STORAGE_CLAIM} is not ReadWriteMany, so all index pods are pinned to ${PIN_NODE};"
    warn "move the storage to a ReadWriteMany volume to spread indexing across the cluster (see README.md)"
  elif [ "$STORAGE_RWX" != true ]; then
    warn "STORAGE_MODE=shared with a storage claim that is not ReadWriteMany; pods on other nodes will not start"
  fi

  workers="$(workers_for "$MEMORY" "$CPU")"
  [ "$workers" -ge 1 ] || die "MEMORY=${MEMORY} is below the $((BASE_MEM_MB + WORKER_MEM_MB)) MB needed for one worker"
  log "pods: ${PARALLELISM} at a time, ${MEMORY} memory and ${CPU} cpus each, ${workers} indexing workers per pod"

  # Each pod requests and is limited to the same memory and CPUs, so a node only takes the pods that fit.
  mem_bytes="$(bytes "$MEMORY")"
  local fits=0 slots=0 node mem cpu by_mem by_cpu
  while read -r node mem cpu; do
    [ -n "$PIN_NODE" ] && [ "$node" != "$PIN_NODE" ] && continue
    by_mem=$(($(bytes "$mem") / mem_bytes))
    by_cpu=$(($(millicores "$cpu") / $(millicores "$CPU")))
    pods_per_node=$((by_mem < by_cpu ? by_mem : by_cpu))
    [ "$pods_per_node" -ge 1 ] && fits=$((fits + 1))
    slots=$((slots + pods_per_node))
    log "  node ${node}: ${mem} memory, ${cpu} cpus, up to ${pods_per_node} pods before other workloads"
  done < <(kubectl get nodes -o json | jq -r '.items[] | select(.spec.unschedulable != true) | "\(.metadata.name) \(.status.allocatable.memory) \(.status.allocatable.cpu)"')
  [ "$fits" -ge 1 ] || die "no node has ${MEMORY} memory and ${CPU} cpus allocatable"
  [ "$slots" -ge "$PARALLELISM" ] || warn "only ${slots} pods fit at a time, the others wait until a pod finishes"

  # Every pod opens up to 2 connections per worker plus a few for its own queries.
  conns=$((PARALLELISM * (workers * 2 + 4)))
  max_conns="$(k exec "$MARIADB_POD" -- sh -c 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -N -e "select @@max_connections - (select count(*) from information_schema.processlist)"' 2>/dev/null || true)"
  if [ -n "$max_conns" ]; then
    log "database: up to ${conns} connections needed, ${max_conns} available"
    [ "$conns" -lt "$max_conns" ] || warn "lower PARALLELISM or raise max_connections in MariaDB"
  else
    log "database: up to ${conns} connections needed (could not read max_connections from ${MARIADB_POD})"
  fi

  check_idle

  if k get jobs -l "$LABEL" -o jsonpath='{range .items[?(@.status.active>0)]}{.metadata.name}{"\n"}{end}' | grep -q .; then
    die "jobs from a previous run are still active, see: $0 status"
  fi
}

upload_scripts() {
  k create configmap "${NAME}-scripts" --from-file="${SCRIPT_DIR}/scripts" --dry-run=client -o yaml |
    kubectl label --local -f - "$LABEL" -o yaml | k apply -f - >/dev/null
}

# wait_job waits until a job completes or fails and returns 1 if it failed.
wait_job() {
  local name="$1" status
  while true; do
    status="$(k get job "$name" -o json | jq -r '
      [(.status.conditions // [])[] | select(.status == "True") | .type] as $c
      | if ($c | index("Complete")) then "complete"
        elif ($c | index("Failed")) then "failed"
        else "running \(.status.succeeded // 0)/\(.spec.completions) done, \(.status.active // 0) active, \(.status.failed // 0) failed" end')"
    case "$status" in
    complete) log "${name}: complete"; return 0 ;;
    failed) log "${name}: failed"; return 1 ;;
    *) log "$(date +%H:%M:%S) ${name}: ${status}" ;;
    esac
    sleep 30
  done
}

run_job() {
  local component="$1" manifest="$2"
  k delete job "${NAME}-${component}" --ignore-not-found --wait=true >/dev/null
  k apply -f - <<<"$manifest" >/dev/null
  wait_job "${NAME}-${component}"
}

plan() {
  load_deployment
  upload_scripts
  mkdir -p "$STATE_DIR"

  run_job plan "$(job plan "$(pod_spec plan "$PLAN_MEMORY" 1 false)" 1 1)" || die "planning failed, see: kubectl -n ${NAMESPACE} logs job/${NAME}-plan"

  local logs
  logs="$(k logs "job/${NAME}-plan")"
  grep '^plan:' <<<"$logs" >&2 || true
  grep '^PLAN' <<<"$logs" | cut -f2- >"${STATE_DIR}/plan.tsv"
  [ -s "${STATE_DIR}/plan.tsv" ] || die "the plan is empty"

  k create configmap "${NAME}-plan" --from-file=plan.tsv="${STATE_DIR}/plan.tsv" --dry-run=client -o yaml |
    kubectl label --local -f - "$LABEL" -o yaml | k apply -f - >/dev/null
  log "plan: saved to ${STATE_DIR}/plan.tsv and config map ${NAME}-plan"
}

index() {
  load_deployment
  upload_scripts
  k get configmap "${NAME}-plan" >/dev/null 2>&1 || die "no plan found, run: $0 plan"
  local partitions
  partitions="$(k get configmap "${NAME}-plan" -o jsonpath='{.data.plan\.tsv}' | awk -F '\t' 'NF >= 3 && $1 + 1 > n {n = $1 + 1} END {print n + 0}')"
  [ "$partitions" -ge 1 ] || die "the plan has no partitions"

  run_job partition "$(job partition "$(pod_spec partition "$MEMORY" "$CPU" true)" "$partitions" "$PARALLELISM")" || {
    warn "some partitions failed, see: $0 status"
    return 1
  }
}

finalize() {
  load_deployment
  upload_scripts
  run_job finalize "$(job finalize "$(pod_spec finalize "$FINALIZE_MEMORY" "$FINALIZE_CPU" true)" 1 1)"
}

status() {
  k get jobs,pods -l "$LABEL" -o wide
  log ""
  for pod in $(k get pods -l "$LABEL" -o jsonpath='{.items[*].metadata.name}'); do
    k logs "$pod" 2>/dev/null | grep -E 'resources:|^PEAK_MEMORY|warning:|error:' | sed "s|^|${pod}: |" || true
  done
}

clean() {
  k delete jobs,configmaps -l "$LABEL" --ignore-not-found
}

case "${1:-run}" in
preflight) preflight ;;
plan) plan ;;
index) index ;;
finalize) finalize ;;
run)
  preflight
  plan
  index || warn "continuing with the finalize pass, which indexes the remaining files"
  check_idle
  finalize
  ;;
status) status ;;
clean) clean ;;
render)
  # Prints the manifests without applying them, for review and validation.
  load_deployment
  job plan "$(pod_spec plan "$PLAN_MEMORY" 1 false)" 1 1
  job partition "$(pod_spec partition "$MEMORY" "$CPU" true)" "$PARTITIONS" "$PARALLELISM"
  job finalize "$(pod_spec finalize "$FINALIZE_MEMORY" "$FINALIZE_CPU" true)" 1 1
  ;;
*) die "unknown command: $1" ;;
esac
