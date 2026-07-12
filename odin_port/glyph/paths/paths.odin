// Data-file lookup, standing in for the engine's FileSystem class. Files
// resolve to the repository's original Applications/Data tree — the same
// shaders, textures, and models the C++ demos use — so nothing is copied
// into odin_port.
//
// The data directory is baked in at COMPILE TIME from this file's own path
// (`#file`), so lookup never depends on the working directory. This file
// lives at <repo>/odin_port/glyph/paths/paths.odin, so four parent hops
// reach the repo root, where Applications/Data lives. run.bat is the only
// supported launcher, and the repo doesn't move between build and run.
package paths

import "core:fmt"
import "core:os"
import "core:path/filepath"

// <repo>/odin_port/glyph/paths/paths.odin  ->  <repo>
@(private)
repo_root :: proc(allocator := context.temp_allocator) -> string {
	context.allocator = allocator
	dir := filepath.dir(#file) // .../glyph/paths
	dir = filepath.dir(dir) // .../glyph
	dir = filepath.dir(dir) // .../odin_port
	dir = filepath.dir(dir) // repo root
	return dir
}

// Locate Applications/Data/<subdir>/<filename>. Returns a temp-allocated
// absolute path and whether it exists.
find_data_file :: proc(subdir, filename: string) -> (path: string, ok: bool) {
	path = fmt.tprintf("%s/Applications/Data/%s/%s", repo_root(), subdir, filename)
	return path, os.exists(path)
}
