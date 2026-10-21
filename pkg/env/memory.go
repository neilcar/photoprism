package env

import (
	"bufio"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/pbnjay/memory"
)

// cgroupRoot is the mount point of the cgroup filesystem.
var cgroupRoot = "/sys/fs/cgroup"

// hostTotalMemory and hostFreeMemory read the memory of the host system.
var (
	hostTotalMemory = memory.TotalMemory
	hostFreeMemory  = memory.FreeMemory
)

// cgroupUnlimited is the smallest value treated as "no limit"; cgroup v1 reports an
// unlimited group as a page-aligned value close to the maximum int64.
const cgroupUnlimited = uint64(1) << 62

// TotalMemory returns the memory available to this process in bytes: the host memory,
// or the cgroup memory limit if one is set and lower, e.g. in a Kubernetes pod.
func TotalMemory() uint64 {
	return lowerLimit(hostTotalMemory(), MemoryLimit())
}

// FreeMemory returns the memory this process can still allocate in bytes: the free host
// memory, or the unused part of the cgroup memory limit if one is set and lower.
func FreeMemory() uint64 {
	free := hostFreeMemory()
	limit := MemoryLimit()

	if limit == 0 {
		return free
	}

	used := cgroupWorkingSet()

	if used >= limit {
		return 0
	}

	return lowerLimit(free, limit-used)
}

// MemoryLimit returns the cgroup memory limit of this process in bytes, or 0 if there is none.
func MemoryLimit() uint64 {
	// cgroup v2 reports "max" for an unlimited group.
	if limit, ok := readCgroupBytes("memory.max"); ok {
		return limit
	}

	// cgroup v1.
	if limit, ok := readCgroupBytes("memory/memory.limit_in_bytes"); ok {
		return limit
	}

	return 0
}

// cgroupWorkingSet returns the memory charged to the cgroup minus the inactive page cache, which
// the kernel reclaims before the limit is enforced, so reading large originals does not make the
// process look out of memory.
func cgroupWorkingSet() uint64 {
	usage, ok := readCgroupBytes("memory.current")
	statFile, inactiveKey := "memory.stat", "inactive_file"

	if !ok {
		if usage, ok = readCgroupBytes("memory/memory.usage_in_bytes"); !ok {
			return 0
		}

		statFile, inactiveKey = "memory/memory.stat", "total_inactive_file"
	}

	if inactive := readCgroupStat(statFile, inactiveKey); inactive < usage {
		return usage - inactive
	}

	return 0
}

// readCgroupBytes reads a byte value from a cgroup file and reports whether it is a limit.
func readCgroupBytes(name string) (uint64, bool) {
	data, err := os.ReadFile(filepath.Join(cgroupRoot, name))

	if err != nil {
		return 0, false
	}

	value, err := strconv.ParseUint(strings.TrimSpace(string(data)), 10, 64)

	if err != nil || value == 0 || value >= cgroupUnlimited {
		return 0, false
	}

	return value, true
}

// readCgroupStat returns the value of a key in a cgroup stat file, or 0 if it is missing.
func readCgroupStat(name, key string) uint64 {
	f, err := os.Open(filepath.Join(cgroupRoot, name))

	if err != nil {
		return 0
	}

	defer f.Close()

	scanner := bufio.NewScanner(f)

	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())

		if len(fields) == 2 && fields[0] == key {
			value, _ := strconv.ParseUint(fields[1], 10, 64)
			return value
		}
	}

	return 0
}

// lowerLimit returns the lower of two byte values, ignoring a value of 0 as unknown.
func lowerLimit(a, b uint64) uint64 {
	switch {
	case a == 0:
		return b
	case b == 0 || a < b:
		return a
	default:
		return b
	}
}
