package photoprism

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
)

func TestThumbsProgress(t *testing.T) {
	interval := thumbsProgressInterval
	t.Cleanup(func() { thumbsProgressInterval = interval })

	t.Run("CountsFiles", func(t *testing.T) {
		thumbsProgressInterval = time.Hour
		p := newThumbsProgress("2021")
		last := p.last
		p.Add()
		p.Add()
		assert.Equal(t, 2, p.files)
		assert.Equal(t, last, p.last)
		p.Done()
	})
	t.Run("LogsAfterInterval", func(t *testing.T) {
		thumbsProgressInterval = 0
		p := newThumbsProgress("2021")
		last := p.last
		p.Add()
		assert.Equal(t, 1, p.files)
		assert.False(t, p.last.Before(last))
	})
}
