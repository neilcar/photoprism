#!/usr/bin/env bash
# Splits the originals folder into balanced partitions for parallel indexing.
#
# Prints one "PLAN<TAB>partition<TAB>weight<TAB>folder" line per folder and a summary.
# A folder whose weight exceeds the per-partition target is replaced by its subfolders;
# files directly inside a split folder are left to the finalize pass.
#
# Environment:
#   PARTITIONS     number of partitions (required)
#   ORIGINALS_PATH originals folder (default: /photoprism/originals)
#   BYTES_PER_FILE bytes that weigh as much as one file, so large videos count more (default: 20000000)

set -euo pipefail

: "${PARTITIONS:?PARTITIONS must be set}"
ORIGINALS_PATH="${ORIGINALS_PATH:-/photoprism/originals}"
BYTES_PER_FILE="${BYTES_PER_FILE:-20000000}"

cd "$ORIGINALS_PATH"

echo "plan: scanning ${ORIGINALS_PATH} for ${PARTITIONS} partitions" >&2

# Skip hidden, system, and recycle bin folders, which the indexer ignores as well.
find . -mindepth 1 \
  \( -name '.*' -o -name '@*' -o -name '#*' -o -name '__*' \) -prune \
  -o -type f -printf '%h\t%s\n' |
  awk -F '\t' -v partitions="$PARTITIONS" -v bpf="$BYTES_PER_FILE" '
    function parent(p,   i) {
      i = match(p, /\/[^\/]*$/)
      return i > 1 ? substr(p, 1, i - 1) : "."
    }
    NF == 2 {
      files[$1]++
      bytes[$1] += $2
    }
    END {
      # Add each folder to the totals of all its ancestors and record the folder tree.
      for (d in files) {
        p = d
        while (1) {
          tf[p] += files[d]
          tb[p] += bytes[d]
          if (p == ".") break
          q = parent(p)
          if (!((q, p) in linked)) {
            linked[q, p] = 1
            kids[q] = kids[q] "\n" p
          }
          p = q
        }
      }

      for (d in tf) w[d] = tf[d] + int(tb[d] / bpf)

      total = w["."]
      if (total == 0) {
        print "plan: no files found" > "/dev/stderr"
        exit 0
      }

      target = total / partitions
      leftover = files["."] + int(bytes["."] / bpf)

      # Start with the top-level folders and split any folder above the target.
      n = split(substr(kids["."], 2), queue, "\n")
      units = 0
      while (n > 0) {
        u = queue[n--]
        if (w[u] > target && kids[u] != "") {
          leftover += files[u] + int(bytes[u] / bpf)
          m = split(substr(kids[u], 2), sub_, "\n")
          for (k = 1; k <= m; k++) queue[++n] = sub_[k]
        } else {
          unit[++units] = u
        }
      }

      # Assign the heaviest folders first, each to the lightest partition.
      for (i = 1; i <= units; i++) {
        for (j = i + 1; j <= units; j++) {
          if (w[unit[j]] > w[unit[i]]) { t = unit[i]; unit[i] = unit[j]; unit[j] = t }
        }
      }
      for (p = 0; p < partitions; p++) load[p] = 0
      for (i = 1; i <= units; i++) {
        best = 0
        for (p = 1; p < partitions; p++) if (load[p] < load[best]) best = p
        load[best] += w[unit[i]]
        printf "PLAN\t%d\t%d\t%s\n", best, w[unit[i]], substr(unit[i], 3)
      }

      printf "plan: %d files, %.1f GB, weight %d, %d folders\n", tf["."], tb["."] / 1e9, total, units > "/dev/stderr"
      for (p = 0; p < partitions; p++) printf "plan: partition %d weight %d (%.0f%%)\n", p, load[p], 100 * load[p] / total > "/dev/stderr"
      printf "plan: weight %d (%.1f%%) left to the finalize pass\n", leftover, 100 * leftover / total > "/dev/stderr"
    }'
