package env

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// useCgroupFixture points cgroupRoot at a temporary directory containing the given files.
func useCgroupFixture(t *testing.T, files map[string]string) {
	t.Helper()

	dir := t.TempDir()

	for name, content := range files {
		fileName := filepath.Join(dir, name)
		require.NoError(t, os.MkdirAll(filepath.Dir(fileName), 0o700))
		require.NoError(t, os.WriteFile(fileName, []byte(content), 0o600))
	}

	original := cgroupRoot
	cgroupRoot = dir
	t.Cleanup(func() { cgroupRoot = original })
}

const testGiB = uint64(1024 * 1024 * 1024)

// useHostMemory replaces the host memory readers with fixed values.
func useHostMemory(t *testing.T, total, free uint64) {
	t.Helper()

	originalTotal, originalFree := hostTotalMemory, hostFreeMemory
	hostTotalMemory = func() uint64 { return total }
	hostFreeMemory = func() uint64 { return free }
	t.Cleanup(func() { hostTotalMemory, hostFreeMemory = originalTotal, originalFree })
}

func TestMemoryLimit(t *testing.T) {
	t.Run("V2", func(t *testing.T) {
		useCgroupFixture(t, map[string]string{"memory.max": "4294967296\n"})
		assert.Equal(t, 4*testGiB, MemoryLimit())
	})
	t.Run("V2Unlimited", func(t *testing.T) {
		useCgroupFixture(t, map[string]string{"memory.max": "max\n"})
		assert.Equal(t, uint64(0), MemoryLimit())
	})
	t.Run("V1", func(t *testing.T) {
		useCgroupFixture(t, map[string]string{"memory/memory.limit_in_bytes": "2147483648"})
		assert.Equal(t, 2*testGiB, MemoryLimit())
	})
	t.Run("V1Unlimited", func(t *testing.T) {
		useCgroupFixture(t, map[string]string{"memory/memory.limit_in_bytes": "9223372036854771712"})
		assert.Equal(t, uint64(0), MemoryLimit())
	})
	t.Run("None", func(t *testing.T) {
		useCgroupFixture(t, nil)
		assert.Equal(t, uint64(0), MemoryLimit())
	})
}

func TestTotalMemory(t *testing.T) {
	useHostMemory(t, 16*testGiB, 8*testGiB)

	t.Run("Limited", func(t *testing.T) {
		useCgroupFixture(t, map[string]string{"memory.max": "1073741824"})
		assert.Equal(t, testGiB, TotalMemory())
	})
	t.Run("AboveHost", func(t *testing.T) {
		useCgroupFixture(t, map[string]string{"memory.max": "34359738368"})
		assert.Equal(t, 16*testGiB, TotalMemory())
	})
	t.Run("Unlimited", func(t *testing.T) {
		useCgroupFixture(t, map[string]string{"memory.max": "max"})
		assert.Equal(t, 16*testGiB, TotalMemory())
	})
}

func TestFreeMemory(t *testing.T) {
	useHostMemory(t, 16*testGiB, 8*testGiB)

	t.Run("V2", func(t *testing.T) {
		useCgroupFixture(t, map[string]string{
			"memory.max":     "4294967296",
			"memory.current": "3221225472",
			"memory.stat":    "anon 1073741824\ninactive_file 2147483648\nactive_file 0\n",
		})
		// 4 GiB limit - (3 GiB charged - 2 GiB reclaimable cache) = 3 GiB.
		assert.Equal(t, 3*testGiB, FreeMemory())
	})
	t.Run("V1", func(t *testing.T) {
		useCgroupFixture(t, map[string]string{
			"memory/memory.limit_in_bytes": "2147483648",
			"memory/memory.usage_in_bytes": "1073741824",
			"memory/memory.stat":           "cache 0\ntotal_inactive_file 536870912\n",
		})
		assert.Equal(t, 2*testGiB-testGiB/2, FreeMemory())
	})
	t.Run("Exhausted", func(t *testing.T) {
		useCgroupFixture(t, map[string]string{
			"memory.max":     "1073741824",
			"memory.current": "1073741824",
			"memory.stat":    "inactive_file 0\n",
		})
		assert.Equal(t, uint64(0), FreeMemory())
	})
	t.Run("HostLower", func(t *testing.T) {
		useCgroupFixture(t, map[string]string{"memory.max": "17179869184", "memory.current": "0"})
		assert.Equal(t, 8*testGiB, FreeMemory())
	})
	t.Run("Unlimited", func(t *testing.T) {
		useCgroupFixture(t, map[string]string{"memory.max": "max"})
		assert.Equal(t, 8*testGiB, FreeMemory())
	})
}

func TestCgroupWorkingSet(t *testing.T) {
	t.Run("CacheExceedsUsage", func(t *testing.T) {
		useCgroupFixture(t, map[string]string{
			"memory.current": "100",
			"memory.stat":    "inactive_file 200\n",
		})
		assert.Equal(t, uint64(0), cgroupWorkingSet())
	})
	t.Run("NoStat", func(t *testing.T) {
		useCgroupFixture(t, map[string]string{"memory.current": "100"})
		assert.Equal(t, uint64(100), cgroupWorkingSet())
	})
	t.Run("None", func(t *testing.T) {
		useCgroupFixture(t, nil)
		assert.Equal(t, uint64(0), cgroupWorkingSet())
	})
}

func TestReadCgroupBytes(t *testing.T) {
	useCgroupFixture(t, map[string]string{"zero": "0", "junk": "abc", "ok": " 42\n"})

	t.Run("Zero", func(t *testing.T) {
		_, ok := readCgroupBytes("zero")
		assert.False(t, ok)
	})
	t.Run("Junk", func(t *testing.T) {
		_, ok := readCgroupBytes("junk")
		assert.False(t, ok)
	})
	t.Run("Missing", func(t *testing.T) {
		_, ok := readCgroupBytes("missing")
		assert.False(t, ok)
	})
	t.Run("Value", func(t *testing.T) {
		value, ok := readCgroupBytes("ok")
		assert.True(t, ok)
		assert.Equal(t, uint64(42), value)
	})
}

func TestReadCgroupStat(t *testing.T) {
	useCgroupFixture(t, map[string]string{"memory.stat": "anon 5\ninactive_file 7\nbroken\n"})

	assert.Equal(t, uint64(7), readCgroupStat("memory.stat", "inactive_file"))
	assert.Equal(t, uint64(0), readCgroupStat("memory.stat", "missing"))
	assert.Equal(t, uint64(0), readCgroupStat("missing.stat", "anon"))
}

func TestLowerLimit(t *testing.T) {
	assert.Equal(t, uint64(5), lowerLimit(0, 5))
	assert.Equal(t, uint64(5), lowerLimit(5, 0))
	assert.Equal(t, uint64(3), lowerLimit(3, 5))
	assert.Equal(t, uint64(3), lowerLimit(5, 3))
	assert.Equal(t, uint64(0), lowerLimit(0, 0))
}
