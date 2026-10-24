package photoprism

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/photoprism/photoprism/internal/config"
	"github.com/photoprism/photoprism/internal/entity"
	"github.com/photoprism/photoprism/pkg/fs"
	"github.com/photoprism/photoprism/pkg/rnd"
)

func TestUseIndexedHash(t *testing.T) {
	conf := config.TestConfig()
	dir := filepath.Join(conf.OriginalsPath(), "thumbs-indexed-hash")
	require.NoError(t, os.MkdirAll(dir, fs.ModeDir))
	t.Cleanup(func() { _ = os.RemoveAll(dir) })

	fileName := filepath.Join(dir, "example.jpg")
	require.NoError(t, fs.Copy("../../pkg/fs/testdata/directory/example.jpg", fileName, false))
	info, err := os.Stat(fileName)
	require.NoError(t, err)

	const storedHash = "da39a3ee5e6b4b0d3255bfef95601890afd80709"

	file := &entity.File{
		FileUID:  rnd.GenerateUID('f'),
		PhotoUID: rnd.GenerateUID('p'),
		FileName: "thumbs-indexed-hash/example.jpg",
		FileRoot: entity.RootOriginals,
		FileHash: storedHash,
		FileSize: info.Size(),
		ModTime:  info.ModTime().UTC().Truncate(time.Second).Unix(),
	}
	require.NoError(t, entity.Db().Create(file).Error)
	t.Cleanup(func() { entity.UnscopedDb().Delete(file) })

	t.Run("Unchanged", func(t *testing.T) {
		mf, err := NewMediaFile(fileName)
		require.NoError(t, err)
		assert.True(t, useIndexedHash(mf))
		assert.Equal(t, storedHash, mf.Hash())
	})
	t.Run("Changed", func(t *testing.T) {
		require.NoError(t, entity.Db().Model(file).UpdateColumn("file_size", info.Size()+1).Error)
		t.Cleanup(func() { entity.Db().Model(file).UpdateColumn("file_size", info.Size()) })
		mf, err := NewMediaFile(fileName)
		require.NoError(t, err)
		assert.True(t, useIndexedHash(mf))
		assert.Equal(t, fs.Hash(fileName), mf.Hash())
	})
	t.Run("NotIndexed", func(t *testing.T) {
		other := filepath.Join(dir, "other.jpg")
		require.NoError(t, fs.Copy("../../pkg/fs/testdata/directory/example.jpg", other, false))
		mf, err := NewMediaFile(other)
		require.NoError(t, err)
		assert.False(t, useIndexedHash(mf))
		assert.Equal(t, fs.Hash(other), mf.Hash())
	})
}

func TestThumbs_IndexedOnly(t *testing.T) {
	conf := config.TestConfig()
	dir := filepath.Join(conf.OriginalsPath(), "thumbs-indexed-only")
	require.NoError(t, os.MkdirAll(dir, fs.ModeDir))
	t.Cleanup(func() { _ = os.RemoveAll(dir) })

	fileName := filepath.Join(dir, "unindexed.jpg")
	require.NoError(t, fs.Copy("testdata/2018-04-12 19_24_49.jpg", fileName, false))
	hash := fs.Hash(fileName)
	thumbs := filepath.Join(conf.ThumbCachePath(), hash[0:1], hash[1:2], hash[2:3], hash+"_*")
	removeThumbs := func() {
		names, _ := filepath.Glob(thumbs)
		for _, name := range names {
			_ = os.Remove(name)
		}
	}
	removeThumbs()
	t.Cleanup(removeThumbs)

	w := NewThumbs(conf)
	w.IndexedOnly = true
	_, err := w.Dir(dir, false)
	require.NoError(t, err)
	names, _ := filepath.Glob(thumbs)
	assert.Empty(t, names)

	w.IndexedOnly = false
	_, err = w.Dir(dir, false)
	require.NoError(t, err)
	names, _ = filepath.Glob(thumbs)
	assert.NotEmpty(t, names)
}
