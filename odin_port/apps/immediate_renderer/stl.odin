// Binary STL loader, mirroring STL::MeshSTL (Include/MeshSTL.h): 80-byte
// header, u32 face count, then 50-byte faces (normal + three vertices as
// 3 x f32 each, plus a 2-byte attribute count). Like the C++, a missing or
// malformed file just yields zero faces.
package main

import "core:os"
import "glyph:paths"

Stl_Face :: struct {
	normal: [3]f32,
	v0:     [3]f32,
	v1:     [3]f32,
	v2:     [3]f32,
}

stl_load :: proc(filename: string) -> (faces: [dynamic]Stl_Face) {
	FACE_SIZE :: 50

	path, found := paths.find_data_file("Models", filename)
	if !found {
		return
	}
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		return
	}
	defer delete(data)

	if len(data) < 84 {
		return
	}

	read_f32 :: proc(data: []u8, off: int) -> f32 {
		bits := u32(data[off]) | u32(data[off + 1]) << 8 | u32(data[off + 2]) << 16 | u32(data[off + 3]) << 24
		return transmute(f32)bits
	}
	read_vec3 :: proc(data: []u8, off: int) -> [3]f32 {
		return {read_f32(data, off), read_f32(data, off + 4), read_f32(data, off + 8)}
	}

	count := int(u32(data[80]) | u32(data[81]) << 8 | u32(data[82]) << 16 | u32(data[83]) << 24)
	if len(data) < 84 + count * FACE_SIZE {
		return
	}

	reserve(&faces, count)
	for i in 0 ..< count {
		o := 84 + i * FACE_SIZE
		append(&faces, Stl_Face{
			normal = read_vec3(data, o),
			v0 = read_vec3(data, o + 12),
			v1 = read_vec3(data, o + 24),
			v2 = read_vec3(data, o + 36),
		})
	}
	return
}
