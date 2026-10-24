package commands

import (
	"flag"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/urfave/cli/v2"
)

// newIndexContext parses args against the index command's own flags.
func newIndexContext(t *testing.T, args ...string) *cli.Context {
	t.Helper()

	set := flag.NewFlagSet("index", flag.ContinueOnError)

	for _, f := range IndexCommand.Flags {
		if err := f.Apply(set); err != nil {
			t.Fatal(err)
		}
	}

	if err := set.Parse(args); err != nil {
		t.Fatal(err)
	}

	ctx := cli.NewContext(cli.NewApp(), set, nil)
	ctx.Command = IndexCommand

	return ctx
}

func TestIndexPurgeOptions(t *testing.T) {
	t.Run("Default", func(t *testing.T) {
		opt := indexPurgeOptions(newIndexContext(t), "2021", nil, 0)
		assert.Equal(t, "2021", opt.Path)
		assert.False(t, opt.Force)
		assert.False(t, opt.SkipIndex)
	})
	t.Run("ForceWhenIndexed", func(t *testing.T) {
		opt := indexPurgeOptions(newIndexContext(t), "", nil, 3)
		assert.True(t, opt.Force)
	})
	t.Run("SkipLibraryUpdate", func(t *testing.T) {
		opt := indexPurgeOptions(newIndexContext(t, "--skip-library-update"), "2021", nil, 3)
		assert.True(t, opt.Force)
		assert.True(t, opt.SkipIndex)
	})
}

func TestIndexOptions(t *testing.T) {
	t.Run("Default", func(t *testing.T) {
		opt := indexOptions(newIndexContext(t), "2021", true, nil)
		assert.Equal(t, "2021", opt.Path)
		assert.True(t, opt.SkipArchived)
		assert.False(t, opt.SkipLibraryWide)
	})
	t.Run("SkipLibraryUpdate", func(t *testing.T) {
		opt := indexOptions(newIndexContext(t, "--skip-library-update"), "2021", true, nil)
		assert.True(t, opt.SkipLibraryWide)
	})
}
