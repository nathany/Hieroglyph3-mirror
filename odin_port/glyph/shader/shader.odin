// Runtime HLSL compilation mirroring ShaderFactoryDX11::GenerateShader
// (Source/ShaderFactoryDX11.cpp).
//
// The matrix story: like the engine, everything compiles with
// D3DCOMPILE_PACK_MATRIX_ROW_MAJOR, so HLSL reads cbuffer matrix memory as
// the matrix's ROWS. The packing rule (see the guide's Matrices section):
// the shader sees your matrix transposed exactly when the Odin field's
// storage layout differs from this packing mode. Both conventions work with
// the flag — they just need matching field layouts:
//
//   - column-vector matrices (core:math/linalg — what these demos use) go
//     in PLAIN `matrix[4,4]f32` fields: column storage read as rows hands
//     the shader Mᵀ, which is what row-vector `mul(v, M)` needs. See the
//     guide's addendum.
//   - row-vector matrices (glyph:d3d_math — the guide's Setup A) go in
//     `#row_major` fields: matching layouts hand the shader M as built.
//
// Mixing the pairings ships a wrongly-transposed matrix and shears
// silently; the distinct #row_major type keeps the builders apart.
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
	return compile_defines(filename, entry, target, nil)
}

// `compile` with preprocessor defines, mirroring the LoadShader overload
// that takes a D3D_SHADER_MACRO array (TessellationParams uses it to build
// one hull shader per partitioning mode from a single source).
compile_defines :: proc(filename, entry, target: string, defines: []cstring) -> (code: ^d3dc.ID3DBlob, ok: bool) {
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

	return compile_source(string(source), filename, entry, target, defines)
}

// Compile from an in-memory HLSL string instead of a data file — for the
// rare support shader that has no C++ data-file counterpart (e.g. the
// fullscreen blit standing in for the engine's SpriteRenderer). `name` is
// only used in error messages.
compile_source :: proc(source: string, name, entry, target: string, defines: []cstring) -> (code: ^d3dc.ID3DBlob, ok: bool) {
	flags := d3dc.D3DCOMPILE{.PACK_MATRIX_ROW_MAJOR}
	when ODIN_DEBUG {
		flags += {.DEBUG, .SKIP_OPTIMIZATION}
	}

	// The macro array is NULL-terminated; each name is defined as "1".
	macros: [dynamic]d3dc.SHADER_MACRO
	defer delete(macros)
	for name in defines {
		append(&macros, d3dc.SHADER_MACRO{Name = name, Definition = "1"})
	}
	append(&macros, d3dc.SHADER_MACRO{})

	errors: ^d3dc.ID3DBlob
	hr := d3dc.Compile(
		raw_data(source),
		len(source),
		fmt.ctprintf("%s", name),
		raw_data(macros) if len(defines) > 0 else nil,
		nil, // include handler
		fmt.ctprintf("%s", entry),
		fmt.ctprintf("%s", target),
		transmute(u32)flags,
		0,
		&code,
		&errors,
	)
	if errors != nil {
		// Print the message blob only on failure — on success it just holds
		// warnings (e.g. X3206 truncation in the book's shaders, which the
		// C++ sees too).
		if hr < 0 {
			fmt.eprintf("%s(%s): %s\n", name, entry, cstring(errors->GetBufferPointer()))
		}
		errors->Release()
	}
	if hr < 0 {
		return nil, false
	}
	return code, true
}
