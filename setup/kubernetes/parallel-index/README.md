# Parallel Indexing on Kubernetes

`parallel-index.sh` indexes a PhotoPrism library with Kubernetes Jobs that run in parallel across the cluster. It splits the originals folder into balanced partitions, indexes each partition in its own pod with `photoprism index <folder>`, and then runs one `photoprism index` over the whole library to pick up the remaining files.

The Jobs copy the image, environment, volumes, and security context from the PhotoPrism StatefulSet, so they use the same database, settings, and storage as the running instance. They use the stock PhotoPrism image; no custom build is required.

## Requirements

- A PhotoPrism StatefulSet that uses MariaDB or MySQL. SQLite does not support writes from several pods.
- Originals on a `ReadWriteMany` volume, such as NFS.
- Storage on a `ReadWriteMany` volume to spread the pods across nodes. With a `ReadWriteOnce` storage volume, all pods are pinned to the node of the PhotoPrism pod (see [Storage](#storage)).
- `kubectl` and `jq` on the machine that runs the script.

## Usage

```bash
./parallel-index.sh preflight   # check the deployment, nodes, database, and running operations
./parallel-index.sh run         # plan, index, and finalize
./parallel-index.sh status      # jobs, pods, and peak memory reported by each pod
./parallel-index.sh clean       # delete the jobs and config maps
```

The steps can also be run one at a time with `plan`, `index`, and `finalize`, and `render` prints the Job manifests without applying them.

## Settings

| Variable           | Default                              | Description                                                        |
|--------------------|--------------------------------------|--------------------------------------------------------------------|
| `NAMESPACE`        | `photoprism`                         | Namespace of the PhotoPrism StatefulSet                            |
| `STATEFULSET`      | `photoprism-photoprism`              | PhotoPrism StatefulSet to copy the configuration from              |
| `PARTITIONS`       | `12`                                 | Number of partitions; more than `PARALLELISM` evens out the tail   |
| `PARALLELISM`      | `4`                                  | Number of index pods running at the same time                      |
| `MEMORY`           | `6Gi`                                | Memory request and limit of each index pod                         |
| `CPU`              | `4`                                  | CPU request and limit of each index pod                            |
| `BASE_MEM_MB`      | `1500`                               | Memory reserved for the process, its AI models, and caches         |
| `WORKER_MEM_MB`    | `1000`                               | Estimated peak memory per indexing worker                          |
| `MAX_WORKERS`      |                                      | Upper bound for the workers per pod                                |
| `STORAGE_MODE`     | `auto`                               | `shared` spreads pods, `pin` keeps them on the PhotoPrism node     |
| `BLOCKING_LOCKS`   | `/photoprism/storage/faces-job/lock` | Lock files in the PhotoPrism pod that must be free before starting |
| `FORCE`            | `false`                              | Start even if the PhotoPrism pod is indexing or holds a lock       |

## Memory and Workers

Every pod has the same memory request and limit, so the scheduler only places it on a node with enough free memory, and the pod is never overcommitted. Before indexing, each pod reads its memory limit from the downward API and its cgroup, and derives the number of indexing workers from it:

```
workers = min(CPU, (memory limit - BASE_MEM_MB) / WORKER_MEM_MB, MAX_WORKERS)
```

With the defaults, a `6Gi` pod with 4 CPUs runs 4 workers, and a `4Gi` pod runs 2. The pod sets `PHOTOPRISM_INDEX_WORKERS`, `GOMAXPROCS`, and `PHOTOPRISM_DATABASE_CONNS` to match, and sets `MALLOC_ARENA_MAX=2` to keep glibc from reserving memory per thread. It refuses to start (exit code 3) when no memory limit is set or the limit is too small for one worker.

While indexing, each pod samples its working set every 10 seconds, logs a warning above 90% of the limit, and reports its peak when it is done:

```
resources: peak working set 4.1Gi of 6.0Gi (68%) with 4 workers
```

Use `./parallel-index.sh status` after a run to compare the peaks. If they stay well below the limit, lower `WORKER_MEM_MB` to run more workers per pod; if a pod is killed for running out of memory, raise it.

The preflight step checks how many pods fit on each node by memory and CPU, and how many database connections the run needs compared with what MariaDB has available.

## Storage

Index pods write thumbnails, sidecar files, and converted previews to the storage volume, and read the library settings from it, so they must mount the same storage as the PhotoPrism pod.

If the storage volume is `ReadWriteOnce`, `STORAGE_MODE=auto` pins all index pods to the node of the PhotoPrism pod. That still isolates the memory of each partition, but it does not spread the load. To use the whole cluster, move the storage to a `ReadWriteMany` volume, for example an NFS share or a Longhorn volume with `accessModes: [ReadWriteMany]`, and update the StatefulSet to use it.

## Limitations

- Duplicate detection and stacking rely on locks inside one PhotoPrism process. Identical files, or files that should stack by UUID or by time and place, in folders of different partitions can end up as separate photos.
- The PhotoPrism pod does not know about the index pods. Do not start indexing or imports in the web interface while a run is in progress, and do not run other index jobs at the same time; the preflight step checks for running `index`, `import`, and `faces` commands and for `BLOCKING_LOCKS`.
- Files directly inside a folder that the plan split into its subfolders, and files directly in the originals folder, are only indexed in the finalize pass. The plan reports how much of the library that is.
- Progress of the index pods is not shown in the web interface. Library counts are updated by the finalize pass.
- The entrypoint of the PhotoPrism image restarts a command that exits with code 1, so the Jobs run `bash` directly, with the security context of the PhotoPrism pod, instead of using the entrypoint.

## Exit Codes

| Code | Meaning                                                      | Job behavior                 |
|------|--------------------------------------------------------------|------------------------------|
| 0    | The partition was indexed                                    | Done                         |
| 1    | At least one folder failed, e.g. the process ran out of memory | Retried once per partition |
| 3    | The pod has no memory limit or is too small for one worker   | The whole Job fails          |
| 4    | Indexing is blocked by another operation, such as a face migration | The whole Job fails    |
