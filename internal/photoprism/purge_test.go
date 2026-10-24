package photoprism

import (
	"testing"

	"github.com/stretchr/testify/assert"

	"github.com/photoprism/photoprism/internal/config"
)

func TestPurge_Start(t *testing.T) {
	t.Run("SkipIndex", func(t *testing.T) {
		w := NewPurge(config.TestConfig(), NewFiles())
		files, photos, updated, err := w.Start(PurgeOptions{Path: "purge-skip-index", Force: true, SkipIndex: true})
		assert.NoError(t, err)
		assert.Empty(t, files)
		assert.Empty(t, photos)
		assert.Equal(t, 0, updated)
	})
}
