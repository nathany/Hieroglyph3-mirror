// Data-file lookup, standing in for the engine's FileSystem class. Files
// resolve to the repository's original Applications/Data tree — the same
// shaders, textures, and models the C++ demos use — so nothing is copied
// into odin_port.
package paths

import "core:fmt"
import "core:os"
import "core:path/filepath"
import win32 "core:sys/windows"

// Locate Applications/Data/<subdir>/<filename>: try upward from the working
// directory (repository root, odin_port/, odin_port/bin/), then upward from
// the executable's directory (odin_port/bin/ regardless of where the app
// was launched from). Returns a temp-allocated path.
find_data_file :: proc(subdir, filename: string) -> (path: string, ok: bool) {
	tail := fmt.tprintf("Applications/Data/%s/%s", subdir, filename)

	candidates := [3]string{
		tail,
		fmt.tprintf("../%s", tail),
		fmt.tprintf("../../%s", tail),
	}
	for candidate in candidates {
		if os.exists(candidate) {
			return candidate, true
		}
	}

	// Fall back to the executable's location so the apps work from any
	// working directory (mirrors the Rust port's exe-ancestor walk).
	exe_buf: [win32.MAX_PATH]u16
	n := win32.GetModuleFileNameW(nil, &exe_buf[0], win32.MAX_PATH)
	if n > 0 {
		exe_path, err := win32.utf16_to_utf8(exe_buf[:n], context.temp_allocator)
		if err == nil {
			context.allocator = context.temp_allocator
			dir := filepath.dir(exe_path)
			for up in ([3]string{"..", "../..", "../../.."}) {
				candidate := fmt.tprintf("%s/%s/%s", dir, up, tail)
				if os.exists(candidate) {
					return candidate, true
				}
			}
		}
	}

	return "", false
}
