// MilkShape3D (.ms3d) loader, mirroring GeometryLoaderDX11::loadMS3DFile2
// (Source/GeometryLoaderDX11.cpp): reads the vertex and triangle sections of
// the binary format, then expands to three unique vertices per triangle —
// interleaved POSITION/TEXCOORD/NORMAL, exactly the element order the engine
// adds them in — negating Z (the format is right-handed) and flipping the
// winding (indices i, i+2, i+1).
package main

import "core:fmt"
import "core:os"
import "glyph:paths"

// Interleaved as the engine's GeometryDX11 lays it out: position, texcoord,
// normal (stride 32, offsets 0/12/20).
Ms3d_Vertex :: struct {
	position:  [3]f32,
	texcoords: [2]f32,
	normal:    [3]f32,
}

Ms3d_Mesh :: struct {
	vertices: [dynamic]Ms3d_Vertex,
	indices:  [dynamic]u32,
}

ms3d_destroy :: proc(m: ^Ms3d_Mesh) {
	delete(m.vertices)
	delete(m.indices)
}

@(private = "file")
read_u16 :: proc(data: []u8, off: int) -> u16 {
	return u16(data[off]) | u16(data[off + 1]) << 8
}

@(private = "file")
read_f32 :: proc(data: []u8, off: int) -> f32 {
	bits := u32(data[off]) | u32(data[off + 1]) << 8 | u32(data[off + 2]) << 16 | u32(data[off + 3]) << 24
	return transmute(f32)bits
}

ms3d_load :: proc(filename: string) -> (mesh: Ms3d_Mesh, ok: bool) {
	path, found := paths.find_data_file("Models", filename)
	if !found {
		fmt.eprintln("model not found:", filename)
		return
	}
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		fmt.eprintln("failed to read", path, read_err)
		return
	}
	defer delete(data)

	// Header: 10-byte id + i32 version (3 or 4).
	if len(data) < 14 || string(data[0:10]) != "MS3D000000" {
		fmt.eprintln(filename, "is not an MS3D file")
		return
	}

	// Vertex section: u16 count, then 15-byte records
	// (u8 flags, 3 x f32 position, i8 bone, u8 refcount).
	VERTEX_SIZE :: 15
	pos := 14
	vertex_count := int(read_u16(data, pos))
	pos += 2
	if len(data) < pos + vertex_count * VERTEX_SIZE {
		fmt.eprintln(filename, "has truncated vertex data")
		return
	}
	positions := make([][3]f32, vertex_count)
	defer delete(positions)
	for i in 0 ..< vertex_count {
		o := pos + i * VERTEX_SIZE + 1 // skip flags byte
		positions[i] = {read_f32(data, o), read_f32(data, o + 4), read_f32(data, o + 8)}
	}
	pos += vertex_count * VERTEX_SIZE

	// Triangle section: u16 count, then 70-byte records (u16 flags,
	// 3 x u16 indices, 3 x 3 x f32 normals, 3 x f32 s, 3 x f32 t,
	// u8 smoothing group, u8 group index).
	TRIANGLE_SIZE :: 70
	triangle_count := int(read_u16(data, pos))
	pos += 2
	if len(data) < pos + triangle_count * TRIANGLE_SIZE {
		fmt.eprintln(filename, "has truncated triangle data")
		return
	}

	reserve(&mesh.vertices, triangle_count * 3)
	reserve(&mesh.indices, triangle_count * 3)

	for i in 0 ..< triangle_count {
		o := pos + i * TRIANGLE_SIZE
		normals_at := o + 8
		s_at := o + 44
		t_at := o + 56

		for corner in 0 ..< 3 {
			idx := int(read_u16(data, o + 2 + corner * 2))
			if idx >= vertex_count {
				fmt.eprintln(filename, "has a vertex index out of range")
				ms3d_destroy(&mesh)
				mesh = {}
				return
			}
			p := positions[idx]
			n := normals_at + corner * 12
			append(&mesh.vertices, Ms3d_Vertex{
				position = {p.x, p.y, -p.z},
				texcoords = {read_f32(data, s_at + corner * 4), read_f32(data, t_at + corner * 4)},
				normal = {read_f32(data, n), read_f32(data, n + 4), -read_f32(data, n + 8)},
			})
		}

		// Winding flipped along with the Z negation.
		base := u32(i * 3)
		append(&mesh.indices, base, base + 2, base + 1)
	}

	return mesh, true
}
