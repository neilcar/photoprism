package photoprism

import "github.com/photoprism/photoprism/pkg/fs"

// PurgeOptions controls behavior of the purge worker.
type PurgeOptions struct {
	Path   string
	Ignore fs.Done
	Dry    bool
	Hard   bool
	Force  bool
	// SkipIndex skips the library-wide index update after purging, e.g. when folders are indexed
	// in parallel; a later purge without it runs the update for the whole library.
	SkipIndex bool
}
