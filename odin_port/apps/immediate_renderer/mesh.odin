// Immediate-mode geometry, mirroring the engine's
// DrawIndexedExecutorDX11<BasicVertexDX11::Vertex> (the dynamic vertex/index
// buffer pair every GeometryActor renders through) and the shape-building
// methods of GeometryActor (Source/GeometryActor.cpp).
//
// The chapter-3 lesson lives here: vertices and indices are plain dynamic
// arrays that get rewritten into DYNAMIC buffers (Map/WRITE_DISCARD) each
// time they change — redefining geometry every frame instead of baking it.
package main

import "core:math"
import "core:math/linalg"
import d3d11 "vendor:directx/d3d11"
import dm "glyph:d3d_math"

// Mirrors BasicVertexDX11::Vertex: POSITION, NORMAL, COLOR, TEXCOORD with
// appended offsets (0/12/24/40, stride 48).
Basic_Vertex :: struct {
	position:  [3]f32,
	normal:    [3]f32,
	color:     [4]f32,
	texcoords: [2]f32,
}

Immediate_Mesh :: struct {
	vertices:        [dynamic]Basic_Vertex,
	indices:         [dynamic]u32,
	topology:        d3d11.PRIMITIVE_TOPOLOGY,
	// Current color applied by the helpers, mirroring GeometryActor::SetColor.
	color:           [4]f32,
	dirty:           bool,
	vertex_buffer:   ^d3d11.IBuffer,
	vertex_capacity: int,
	index_buffer:    ^d3d11.IBuffer,
	index_capacity:  int,
}

mesh_init :: proc(m: ^Immediate_Mesh, topology: d3d11.PRIMITIVE_TOPOLOGY) {
	m^ = {
		topology = topology,
		color    = {1, 1, 1, 1},
	}
}

mesh_destroy :: proc(m: ^Immediate_Mesh) {
	if m.index_buffer != nil {m.index_buffer->Release()}
	if m.vertex_buffer != nil {m.vertex_buffer->Release()}
	delete(m.vertices)
	delete(m.indices)
	m^ = {}
}

mesh_reset :: proc(m: ^Immediate_Mesh) {
	clear(&m.vertices)
	clear(&m.indices)
	m.dirty = true
}

add_vertex_full :: proc(m: ^Immediate_Mesh, position, normal: [3]f32, color: [4]f32, texcoords: [2]f32) {
	append(&m.vertices, Basic_Vertex{position, normal, color, texcoords})
	m.dirty = true
}

// GeometryActor::AddVertex(position) — default normal (0,1,0), current
// color, zero texcoords; plus the other overloads the samples use.
add_vertex :: proc(m: ^Immediate_Mesh, position: [3]f32) {
	add_vertex_full(m, position, {0, 1, 0}, m.color, {0, 0})
}

add_vertex_tex :: proc(m: ^Immediate_Mesh, position: [3]f32, texcoords: [2]f32) {
	add_vertex_full(m, position, {0, 1, 0}, m.color, texcoords)
}

add_vertex_normal :: proc(m: ^Immediate_Mesh, position, normal: [3]f32) {
	add_vertex_full(m, position, normal, m.color, {0, 0})
}

add_vertex_normal_tex :: proc(m: ^Immediate_Mesh, position, normal: [3]f32, texcoords: [2]f32) {
	add_vertex_full(m, position, normal, m.color, texcoords)
}

add_index :: proc(m: ^Immediate_Mesh, index: u32) {
	append(&m.indices, index)
	m.dirty = true
}

@(private = "file")
create_dynamic_buffer :: proc(device: ^d3d11.IDevice, byte_width: u32, bind: d3d11.BIND_FLAGS) -> ^d3d11.IBuffer {
	desc := d3d11.BUFFER_DESC {
		ByteWidth      = byte_width,
		Usage          = .DYNAMIC,
		BindFlags      = bind,
		CPUAccessFlags = {.WRITE},
	}
	buffer: ^d3d11.IBuffer
	device->CreateBuffer(&desc, nil, &buffer)
	return buffer
}

// Upload to the GPU if anything changed, growing the DYNAMIC buffers when
// the data outgrows them.
mesh_commit :: proc(m: ^Immediate_Mesh, device: ^d3d11.IDevice, ctx: ^d3d11.IDeviceContext) {
	// Static meshes go dirty once, on construction, and never map again — the
	// per-frame Map cost is paid only by the grid.
	if !m.dirty || len(m.vertices) == 0 {
		m.dirty = false
		return
	}

	// Capacity only grows: a smaller rebuild reuses the existing buffer and
	// just leaves the tail bytes stale, which is fine because the draw call
	// is bounded by len(m.indices), not by the buffer size.
	if len(m.vertices) > m.vertex_capacity {
		if m.vertex_buffer != nil {m.vertex_buffer->Release()}
		m.vertex_buffer = create_dynamic_buffer(device, u32(len(m.vertices) * size_of(Basic_Vertex)), {.VERTEX_BUFFER})
		m.vertex_capacity = len(m.vertices)
	}
	if len(m.indices) > m.index_capacity {
		if m.index_buffer != nil {m.index_buffer->Release()}
		m.index_buffer = create_dynamic_buffer(device, u32(len(m.indices) * size_of(u32)), {.INDEX_BUFFER})
		m.index_capacity = len(m.indices)
	}

	// WRITE_DISCARD rather than NO_OVERWRITE: the whole contents are being
	// replaced, so let the driver rename the buffer instead of waiting for
	// the GPU to finish reading last frame's copy.
	mapped: d3d11.MAPPED_SUBRESOURCE
	if m.vertex_buffer != nil && ctx->Map((^d3d11.IResource)(m.vertex_buffer), 0, .WRITE_DISCARD, {}, &mapped) >= 0 {
		copy(([^]Basic_Vertex)(mapped.pData)[:len(m.vertices)], m.vertices[:])
		ctx->Unmap((^d3d11.IResource)(m.vertex_buffer), 0)
	}
	if m.index_buffer != nil && ctx->Map((^d3d11.IResource)(m.index_buffer), 0, .WRITE_DISCARD, {}, &mapped) >= 0 {
		copy(([^]u32)(mapped.pData)[:len(m.indices)], m.indices[:])
		ctx->Unmap((^d3d11.IResource)(m.index_buffer), 0)
	}

	m.dirty = false
}

// --- Shape builders, ported from GeometryActor ------------------------------

// Vector3f::Perpendicular: any unit vector perpendicular to v; the exact
// choice only moves the tessellation seam, which is not visible.
@(private = "file")
perpendicular :: proc(v: [3]f32) -> [3]f32 {
	axis: [3]f32
	if abs(v.x) < abs(v.y) && abs(v.x) < abs(v.z) {
		axis = {1, 0, 0}
	} else if abs(v.y) < abs(v.z) {
		axis = {0, 1, 0}
	} else {
		axis = {0, 0, 1}
	}
	return linalg.cross(v, axis)
}

// The GridTessellator2f::TessellateTriGrid pattern: (rows+1)*(cols+1)
// vertices sampled over [0,xmax] x [0,ymax], two triangles per cell.
@(private = "file")
tessellate_tri_grid :: proc(
	m: ^Immediate_Mesh,
	rows, cols: u32,
	xmax, ymax: f32,
	sample: proc(user: rawptr, x, y: f32) -> (position, normal: [3]f32, tex: [2]f32),
	user: rawptr,
) {
	// Every builder offsets its indices by the current vertex count, so shapes
	// accumulate into one shared mesh (and one draw call) rather than each
	// owning a buffer.
	base := u32(len(m.vertices))
	// The +1 row/column duplicates the seam: at theta = 0 and theta = 2pi the
	// positions coincide but the texcoords differ, so the vertices cannot be
	// shared.
	col_step := xmax / f32(cols)
	row_step := ymax / f32(rows)

	for row in 0 ..= rows {
		for col in 0 ..= cols {
			position, normal, tex := sample(user, col_step * f32(col), row_step * f32(row))
			add_vertex_full(m, position, normal, m.color, tex)
		}
	}

	for z in 0 ..< rows {
		for x in 0 ..< cols {
			add_index(m, base + z * (cols + 1) + x)
			add_index(m, base + z * (cols + 1) + x + 1)
			add_index(m, base + (z + 1) * (cols + 1) + x)

			add_index(m, base + z * (cols + 1) + x + 1)
			add_index(m, base + (z + 1) * (cols + 1) + x + 1)
			add_index(m, base + (z + 1) * (cols + 1) + x)
		}
	}
}

// GeometryActor::DrawSphere: grid-tessellated over theta 0..2pi (cols =
// slices) and phi 0..pi (rows = stacks), sampled per Sphere3f.
Sphere_Model :: struct {
	center: [3]f32,
	radius: f32,
}

draw_sphere :: proc(m: ^Immediate_Mesh, center: [3]f32, radius: f32, stacks, slices: u32) {
	model := Sphere_Model{center, radius}
	tessellate_tri_grid(m, max(stacks, 2), max(slices, 4), 2 * math.PI, math.PI,
		proc(user: rawptr, theta, phi: f32) -> (position, normal: [3]f32, tex: [2]f32) {
			// On a unit sphere the outward normal *is* the surface direction,
			// so one spherical-coordinate evaluation gives both. The phi = 0
			// and phi = pi rows collapse onto the poles, leaving a ring of
			// degenerate triangles there — harmless, and preserved.
			s := (^Sphere_Model)(user)
			normal = {math.sin(phi) * math.cos(theta), math.cos(phi), math.sin(phi) * math.sin(theta)}
			position = s.center + normal * s.radius
			tex = {theta / (2 * math.PI), phi / math.PI}
			return
		}, &model)
}

// GeometryActor::DrawCylinder: a Cone3f (two endpoints, two radii)
// grid-tessellated over theta 0..2pi and height factor 0..1.
Cone_Model :: struct {
	p1, p2:  [3]f32,
	r1, r2:  f32,
	vnorm:   [3]f32,
	unit:    [3]f32,
	height:  f32,
	slope:   f32,
}

draw_cylinder :: proc(m: ^Immediate_Mesh, p1, p2: [3]f32, r1, r2: f32, stacks: u32 = 2, slices: u32 = 10) {
	// Axis points p2 -> p1, so h = 0 is the p2 end (radius r2) and h = 1 is
	// the p1 end (radius r1). draw_arrow relies on that ordering to taper the
	// head to a point by passing r2 = 0.
	axis := p1 - p2
	model := Cone_Model {
		p1 = p1, p2 = p2, r1 = r1, r2 = r2,
		vnorm = linalg.normalize(axis),
		unit = linalg.normalize(perpendicular(axis)),
		height = linalg.length(axis),
	}
	model.slope = (r1 - r2) / model.height

	tessellate_tri_grid(m, max(stacks, 2), max(slices, 4), 2 * math.PI, 1.0,
		proc(user: rawptr, theta, h: f32) -> (position, normal: [3]f32, tex: [2]f32) {
			c := (^Cone_Model)(user)
			rot := dm.matrix3_rotate_f32(theta, c.vnorm)
			radius := c.r2 + (c.r1 - c.r2) * h
			// Row-vector `unit * rot`, which is what the C++'s `r * unit`
			// actually computes: Matrix3f::operator*(Vector3f) sums over
			// rows (m[iRow][iCol] * v[iRow]), so it is a row-vector product
			// despite reading matrix-first.
			position = c.p2 + c.vnorm * c.height * h + c.unit * rot * radius
			// Tilt the radial direction back along the axis by the taper
			// slope (r1-r2)/height; for a plain cylinder slope is 0 and the
			// normal stays purely radial.
			normal = linalg.normalize(c.unit * rot - c.vnorm * c.slope)
			// TexcoordsFromCone: (height, theta) with theta left in raw
			// radians, not divided by 2pi — preserved from the C++, and
			// invisible here since these shapes use the vertex-color material.
			tex = {h, theta}
			return
		}, &model)
}

// GeometryActor::DrawDisc: a triangle fan around a center vertex.
draw_disc :: proc(m: ^Immediate_Mesh, center, normal: [3]f32, radius: f32, slices: u32 = 12) {
	slices := max(slices, 4)
	vnorm := linalg.normalize(normal)
	up := [3]f32{0, 1, 0}

	// The rim start direction is the perpendicular to the axis pointing
	// closest to +Y; when the axis is already +/-Y that is undefined, so fall
	// back to +X. (Exact float equality is the C++ test, kept as-is.)
	unit: [3]f32
	if vnorm == up || vnorm == -up {
		unit = {1, 0, 0}
	} else {
		unit = linalg.normalize(linalg.cross(linalg.cross(vnorm, up), vnorm))
	}

	slice_step := 2 * math.PI / f32(slices)
	base := u32(len(m.vertices))

	add_vertex_normal(m, center, vnorm)

	for slice in 0 ..= slices {
		theta := slice_step * f32(slice)
		rot := dm.matrix3_rotate_f32(theta, vnorm)
		add_vertex_normal(m, center + unit * rot * radius, vnorm)
	}

	// The fan reaches base+slices+1, in range only because the rim loop emits
	// slices+1 vertices — the duplicate at theta = 2pi is what closes the
	// circle without a modulo.
	for x in 1 ..= slices {
		add_index(m, base)
		add_index(m, base + x)
		add_index(m, base + x + 1)
	}
}

// GeometryActor::DrawRect: one quad with a shared face normal.
draw_rect :: proc(m: ^Immediate_Mesh, center, xdir, ydir: [3]f32, extents: [2]f32) {
	base := u32(len(m.vertices))
	x := xdir * extents.x
	y := ydir * extents.y
	normal := linalg.cross(xdir, ydir)

	add_vertex_normal_tex(m, center + x + y, normal, {0, 0})
	add_vertex_normal_tex(m, center - x + y, normal, {1, 0})
	add_vertex_normal_tex(m, center - x - y, normal, {1, 1})
	add_vertex_normal_tex(m, center + x - y, normal, {0, 1})

	add_index(m, base)
	add_index(m, base + 1)
	add_index(m, base + 2)
	add_index(m, base)
	add_index(m, base + 2)
	add_index(m, base + 3)
}

// GeometryActor::DrawBox: six rects. Each face negates one of xdir/ydir/zdir
// so cross(xdir, ydir) — and hence the winding draw_rect produces — always
// faces outward.
draw_box :: proc(m: ^Immediate_Mesh, center, extents: [3]f32) {
	xdir := [3]f32{1, 0, 0}
	ydir := [3]f32{0, 1, 0}
	zdir := [3]f32{0, 0, 1}
	x := xdir * extents.x
	y := ydir * extents.y
	z := zdir * extents.z

	draw_rect(m, center + z, xdir, ydir, {extents.x, extents.y})
	draw_rect(m, center - z, -xdir, ydir, {extents.x, extents.y})
	draw_rect(m, center + x, -zdir, ydir, {extents.z, extents.y})
	draw_rect(m, center - x, zdir, ydir, {extents.z, extents.y})
	draw_rect(m, center + y, xdir, -zdir, {extents.x, extents.z})
	draw_rect(m, center - y, xdir, zdir, {extents.x, extents.z})
}

// GeometryActor::DrawArrow: shaft cylinder + head cone + backing disc (the
// C++ calls DrawCylinder/DrawDisc with their default stack/slice counts).
draw_arrow :: proc(m: ^Immediate_Mesh, base_pt, point: [3]f32, shaft_radius, head_radius, head_length: f32) {
	arrow := point - base_pt
	arrow_length := linalg.length(arrow)
	unit_arrow := arrow / arrow_length
	shaft_end := base_pt + unit_arrow * (arrow_length - head_length)

	draw_cylinder(m, base_pt, shaft_end, shaft_radius, shaft_radius)
	draw_cylinder(m, shaft_end, point, head_radius, 0.0)
	// The head cone is open at its wide end; this disc caps it, facing back
	// down the shaft so it is visible from behind the arrowhead.
	draw_disc(m, shaft_end, -unit_arrow, head_radius)
}

// GeometryActor::DrawBezierCurve (LINELIST topology expected).
draw_bezier_curve :: proc(m: ^Immediate_Mesh, points: [4][3]f32, t0, t1: f32, segments: u32) {
	base := u32(len(m.vertices))
	step := (t1 - t0) / f32(segments)

	for i in 0 ..= segments {
		t := t0 + step * f32(i)
		mt := 1.0 - t
		point :=
			points[0] * (mt * mt * mt) +
			points[1] * (3 * t * mt * mt) +
			points[2] * (3 * t * t * mt) +
			points[3] * (t * t * t)
		// add_vertex leaves the default (0,1,0) normal — the curve still runs
		// through the lit material, so it shades as a flat up-facing surface.
		add_vertex(m, point)
	}

	for i in 0 ..< segments {
		add_index(m, base + i)
		add_index(m, base + i + 1)
	}
}
