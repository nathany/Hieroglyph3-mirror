// Minimal ASCII Stanford PLY loader, mirroring the subset of
// GeometryLoaderDX11::loadStanfordPlyFile the chapter-9 demos use: an
// `element vertex` with float properties x y z nx ny nz, and an
// `element face` of uchar-counted index lists (triangles). The engine's
// withAdjacency path is not ported — the demos load with the default
// (adjacency-less) 3-control-point patches.
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "glyph:paths"

// POSITION + NORMAL, stride 24 — the loader's element order.
Ply_Vertex :: struct {
	position: [3]f32,
	normal:   [3]f32,
}

Ply_Mesh :: struct {
	vertices: [dynamic]Ply_Vertex,
	indices:  [dynamic]u32,
}

ply_destroy :: proc(m: ^Ply_Mesh) {
	delete(m.vertices)
	delete(m.indices)
}

ply_load :: proc(filename: string) -> (mesh: Ply_Mesh, ok: bool) {
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

	text := string(data)
	vertex_count := 0
	face_count := 0
	in_header := true

	next_line :: proc(text: ^string) -> (line: string, found: bool) {
		for {
			line = strings.trim_space(strings.split_lines_iterator(text) or_return)
			if len(line) > 0 {
				return line, true
			}
		}
	}

	// Header.
	for in_header {
		line := next_line(&text) or_return
		fields := strings.fields(line, context.temp_allocator)
		switch {
		case len(fields) >= 3 && fields[0] == "element" && fields[1] == "vertex":
			vertex_count = strconv.parse_int(fields[2]) or_else 0
		case len(fields) >= 3 && fields[0] == "element" && fields[1] == "face":
			face_count = strconv.parse_int(fields[2]) or_else 0
		case fields[0] == "end_header":
			in_header = false
		}
	}
	if vertex_count == 0 || face_count == 0 {
		fmt.eprintln(filename, "has no vertex/face elements")
		return
	}

	// Vertex lines: x y z nx ny nz.
	for _ in 0 ..< vertex_count {
		line := next_line(&text) or_return
		fields := strings.fields(line, context.temp_allocator)
		if len(fields) < 6 {
			fmt.eprintln(filename, "has a malformed vertex line")
			return
		}
		v: Ply_Vertex
		for i in 0 ..< 3 {
			v.position[i] = f32(strconv.parse_f64(fields[i]) or_else 0)
			v.normal[i] = f32(strconv.parse_f64(fields[i + 3]) or_else 0)
		}
		append(&mesh.vertices, v)
	}

	// Face lines: <count> i0 i1 i2 (triangles only). The indices are emitted
	// flat, exactly as for a triangle list — the caller reinterprets them as
	// 3-control-point patches purely via the IA topology.
	for _ in 0 ..< face_count {
		line := next_line(&text) or_return
		fields := strings.fields(line, context.temp_allocator)
		if len(fields) < 4 || (strconv.parse_int(fields[0]) or_else 0) != 3 {
			fmt.eprintln(filename, "has a non-triangle face")
			return
		}
		for i in 1 ..= 3 {
			append(&mesh.indices, u32(strconv.parse_int(fields[i]) or_else 0))
		}
	}

	return mesh, true
}
