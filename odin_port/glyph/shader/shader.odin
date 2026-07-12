// Runtime HLSL compilation mirroring ShaderFactoryDX11::GenerateShader
// (Source/ShaderFactoryDX11.cpp).
//
// The matrix story, settled once: like the engine, everything compiles with
// D3DCOMPILE_PACK_MATRIX_ROW_MAJOR, so HLSL reads cbuffer matrix memory as
// the matrix's ROWS. An Odin `matrix[4,4]f32` holding a column-vector-
// convention matrix M stores M's columns — which HLSL then reads as rows,
// i.e. it sees M-transposed, which is exactly what the book's row-vector
// `mul(v, M)` shaders need. Net result: plain Odin matrices, natural
// `proj * view * world` composition, zero transposes, book shaders
// unchanged.
//
// NOTE: this supersedes the guide's "Setup A" (#row_major fields): that
// trick assumes HLSL's *default* column-major packing. With the engine's
// row-major compile flag adopted here, cbuffer fields must be plain
// `matrix[4,4]f32` — adding #row_major on top would transpose twice.
//
// Shaders are found on disk at runtime, straight from the repository's
// Applications/Data/Shaders/ — the same files the C++ demos compile.
package shader

import "core:fmt"
import "core:os"
import d3dc "vendor:directx/d3d_compiler"
import "glyph:paths"

// Compile `entry` from Applications/Data/Shaders/<filename> for the given
// target (e.g. "vs_4_0"), returning the bytecode blob (caller releases).
// Compile errors are printed to stderr — drop -subsystem:windows to see them.
compile :: proc(filename, entry, target: string) -> (code: ^d3dc.ID3DBlob, ok: bool) {
	path, found := paths.find_data_file("Shaders", filename)
	if !found {
		fmt.eprintln("shader source not found:", filename)
		return nil, false
	}

	source, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		fmt.eprintln("failed to read", path, read_err)
		return nil, false
	}
	defer delete(source)

	flags := d3dc.D3DCOMPILE{.PACK_MATRIX_ROW_MAJOR}
	when ODIN_DEBUG {
		flags += {.DEBUG, .SKIP_OPTIMIZATION}
	}

	errors: ^d3dc.ID3DBlob
	hr := d3dc.Compile(
		raw_data(source),
		len(source),
		fmt.ctprintf("%s", filename),
		nil, // defines
		nil, // include handler
		fmt.ctprintf("%s", entry),
		fmt.ctprintf("%s", target),
		transmute(u32)flags,
		0,
		&code,
		&errors,
	)
	if errors != nil {
		fmt.eprintf("%s(%s): %s\n", filename, entry, cstring(errors->GetBufferPointer()))
		errors->Release()
	}
	if hr < 0 {
		return nil, false
	}
	return code, true
}
