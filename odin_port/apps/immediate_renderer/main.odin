// Odin port of the ImmediateRenderer sample
// (Applications/ImmediateRenderer/App.cpp) — core visual scope: all the
// rendered content and interaction except text (the 3D TextActor and the FPS
// overlay need the engine's sprite-font machinery; text is out of scope for
// these ports) and the Lua console. The missing Capsule.obj model is also
// omitted — the C++ loads zero triangles for it and draws nothing.
//
// What renders, mirroring App::Initialize:
//   - An animated paraboloid grid (the chapter's immediate-rendering
//     lesson): 20x20 vertices + indices rebuilt from scratch every frame
//     into dynamic buffers, textured with EyeOfHorus_128.png, at (3,0,0),
//     slowly spinning (-0.1 rad/s).
//   - A shape collection at (0,2.5,0), spinning at 0.4 rad/s, drawn in the
//     alpha-blended pass: translucent red sphere, green cone, yellow disc,
//     blue box, white arrow.
//   - The STL mesh MeshedReconstruction.stl at (5,5,0), spinning at
//     -1 rad/s, vertex color (0,1,0,0).
//   - A green Bezier curve as a line list.
//   - The skybox (TropicalSunnyDay.dds cube map).
//   - A point light circling at radius 50, height 50 (-1 rad/s), driving the
//     UE4-style PBR shading in the vertex-color/textured
//     .vertex-normal.point-light.perspective shader pairs (used unchanged).
//
// Interaction, mirroring RenderApplication + FirstPersonCamera: right-drag
// looks, W/S/A/D strafes, Q/E moves up/down, Ctrl speeds up, keys 1/2/3
// switch to the off-center projections from App::HandleEvent, Esc quits,
// Space screenshots, and resizing the window resizes the swap chain (and
// resets any 1/2/3 projection, as the C++'s SetAspectRatio does).
package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:time"
import win32 "core:sys/windows"
import d3d11 "vendor:directx/d3d11"
import dm "glyph:d3d_math"
import "glyph:renderer"
import "glyph:shader"
import "glyph:window"

WIDTH :: 800
HEIGHT :: 600

// --- cbuffer mirrors ---------------------------------------------------------

// Row-vector matrices (glyph:d3d_math) in #row_major fields, matching the
// row-vector HLSL (`mul(v, M)`) and glyph:shader's
// D3DCOMPILE_PACK_MATRIX_ROW_MAJOR packing — so the shader sees each matrix
// as built, and draw_object composes `world * view * proj` like the book.
World_Transforms :: struct #align (16) {
	world:           dm.Matrix4f32,
	world_view_proj: dm.Matrix4f32,
}

Point_Light_Info :: struct #align (16) {
	light_position: [4]f32,
	ia:             [4]f32,
	id:             [4]f32,
	is_:            [4]f32,
}

Scene_Info :: struct #align (16) {
	view_position: [4]f32,
}

// PBRMaterialParameters. object_material is (roughness, metallic, 0, 0) in
// the UE4-style PS. object_albedo is set here to match the C++ SetDiffuse
// calls but the vertex-color/textured pixel shaders never read it — albedo
// comes from the vertex COLOR (or the sampled texture) instead.
Pbr_Material :: struct #align (16) {
	object_albedo:   [4]f32,
	object_material: [4]f32,
}

Skybox_Data :: struct #align (16) {
	view:          dm.Matrix4f32,
	proj:          dm.Matrix4f32,
	view_position: [4]f32,
}

// --- window messages → input state ------------------------------------------

App_State :: struct {
	input:           Camera_Input,
	save_screenshot: bool,
	projection_key:  u8, // '1'..'3', 0 = none pending
	pending_resize:  [2]u32, // {0,0} = none pending
	last_mouse:      [2]i32,
	mouse_valid:     bool,
}

message_callback :: proc(data: rawptr, hwnd: win32.HWND, msg: win32.UINT, wparam: win32.WPARAM, lparam: win32.LPARAM) -> win32.LRESULT {
	state := cast(^App_State)data

	set_camera_key :: proc(state: ^App_State, key: win32.WPARAM, down: bool) {
		switch key {
		case win32.WPARAM('W'):
			state.input.forward = down
		case win32.WPARAM('S'):
			state.input.back = down
		case win32.WPARAM('A'):
			state.input.left = down
		case win32.WPARAM('D'):
			state.input.right = down
		case win32.WPARAM('Q'):
			state.input.up = down
		case win32.WPARAM('E'):
			state.input.down = down
		case win32.WPARAM(win32.VK_CONTROL):
			state.input.speed_up = down
		}
	}

	switch msg {
	case win32.WM_DESTROY:
		win32.PostQuitMessage(0)
		return 0

	case win32.WM_KEYDOWN:
		set_camera_key(state, wparam, true)

	case win32.WM_KEYUP:
		switch wparam {
		case win32.WPARAM(win32.VK_ESCAPE):
			win32.PostQuitMessage(0)
			return 0
		case win32.WPARAM(win32.VK_SPACE):
			state.save_screenshot = true
		case win32.WPARAM('1'), win32.WPARAM('2'), win32.WPARAM('3'):
			state.projection_key = u8(wparam)
		case:
			set_camera_key(state, wparam, false)
		}

	// FirstPersonCamera: rotate only while the right button drags.
	case win32.WM_MOUSEMOVE:
		x := i32(i16(lparam & 0xffff))
		y := i32(i16((lparam >> 16) & 0xffff))
		rbutton_down := wparam & 0x02 != 0 // MK_RBUTTON
		if rbutton_down && state.mouse_valid {
			state.input.mouse_dx += f32(x - state.last_mouse.x)
			state.input.mouse_dy += f32(y - state.last_mouse.y)
		}
		state.last_mouse = {x, y}
		state.mouse_valid = true

	// Invalidate on both the press and the release so the first move after a
	// button transition does not produce a jump from a stale last_mouse.
	case win32.WM_RBUTTONDOWN, win32.WM_RBUTTONUP:
		state.mouse_valid = false

	case win32.WM_SIZE:
		state.pending_resize = {u32(lparam & 0xffff), u32((lparam >> 16) & 0xffff)}
	}

	return win32.DefWindowProcW(hwnd, msg, wparam, lparam)
}

// --- scene -------------------------------------------------------------------

Material_Kind :: enum {
	Vertex_Color,
	Textured,
}

Scene_Object :: struct {
	mesh:            Immediate_Mesh,
	position:        [3]f32,
	spin_rate:       f32, // radians/second about +Y (a RotationController)
	material:        Material_Kind,
	material_params: Pbr_Material,
}

object_world_matrix :: proc(o: ^Scene_Object, t: f32) -> dm.Matrix4f32 {
	return dm.matrix4_rotate_f32(o.spin_rate * t, {0, 1, 0}) * dm.matrix4_translate_f32(o.position)
}

Pipeline :: struct {
	layout_vertex_color: ^d3d11.IInputLayout,
	layout_textured:     ^d3d11.IInputLayout,
	layout_skybox:       ^d3d11.IInputLayout,
	vs_vertex_color:     ^d3d11.IVertexShader,
	ps_vertex_color:     ^d3d11.IPixelShader,
	vs_textured:         ^d3d11.IVertexShader,
	ps_textured:         ^d3d11.IPixelShader,
	vs_skybox:           ^d3d11.IVertexShader,
	ps_skybox:           ^d3d11.IPixelShader,
	sampler:             ^d3d11.ISamplerState,
	alpha_blend:         ^d3d11.IBlendState,
	skybox_depth:        ^d3d11.IDepthStencilState,
	cb_world:            ^d3d11.IBuffer,
	cb_light:            ^d3d11.IBuffer,
	cb_scene:            ^d3d11.IBuffer,
	cb_material:         ^d3d11.IBuffer,
	cb_skybox:           ^d3d11.IBuffer,
	skybox_vb:           ^d3d11.IBuffer,
	skybox_ib:           ^d3d11.IBuffer,
	skybox_texture:      ^d3d11.ITexture2D,
	skybox_srv:          ^d3d11.IShaderResourceView,
	grid_texture:        ^d3d11.ITexture2D,
	grid_srv:            ^d3d11.IShaderResourceView,
}

pipeline_destroy :: proc(p: ^Pipeline) {
	release :: proc(obj: ^$T) {
		if obj != nil {obj->Release()}
	}
	release(p.grid_srv)
	release(p.grid_texture)
	release(p.skybox_srv)
	release(p.skybox_texture)
	release(p.skybox_ib)
	release(p.skybox_vb)
	release(p.cb_skybox)
	release(p.cb_material)
	release(p.cb_scene)
	release(p.cb_light)
	release(p.cb_world)
	release(p.skybox_depth)
	release(p.alpha_blend)
	release(p.sampler)
	release(p.ps_skybox)
	release(p.vs_skybox)
	release(p.ps_textured)
	release(p.vs_textured)
	release(p.ps_vertex_color)
	release(p.vs_vertex_color)
	release(p.layout_skybox)
	release(p.layout_textured)
	release(p.layout_vertex_color)
	p^ = {}
}

dynamic_cbuffer :: proc(device: ^d3d11.IDevice, byte_width: u32) -> (buffer: ^d3d11.IBuffer, ok: bool) {
	desc := d3d11.BUFFER_DESC {
		ByteWidth      = byte_width,
		Usage          = .DYNAMIC,
		BindFlags      = {.CONSTANT_BUFFER},
		CPUAccessFlags = {.WRITE},
	}
	if device->CreateBuffer(&desc, nil, &buffer) < 0 {
		return
	}
	return buffer, true
}

// WRITE_DISCARD (never NO_OVERWRITE) on every cbuffer write: the driver
// hands back a fresh region and renames the buffer, so overwriting one that
// earlier draws in this frame still reference costs no stall.
write_cbuffer :: proc(ctx: ^d3d11.IDeviceContext, buffer: ^d3d11.IBuffer, value: ^$T) {
	mapped: d3d11.MAPPED_SUBRESOURCE
	if ctx->Map((^d3d11.IResource)(buffer), 0, .WRITE_DISCARD, {}, &mapped) >= 0 {
		(^T)(mapped.pData)^ = value^
		ctx->Unmap((^d3d11.IResource)(buffer), 0)
	}
}

immutable_buffer :: proc(device: ^d3d11.IDevice, data: rawptr, byte_width: u32, bind: d3d11.BIND_FLAGS) -> (buffer: ^d3d11.IBuffer, ok: bool) {
	desc := d3d11.BUFFER_DESC {
		ByteWidth = byte_width,
		Usage     = .IMMUTABLE,
		BindFlags = bind,
	}
	init := d3d11.SUBRESOURCE_DATA {
		pSysMem = data,
	}
	if device->CreateBuffer(&desc, &init, &buffer) < 0 {
		return
	}
	return buffer, true
}

create_pipeline :: proc(r: ^renderer.Renderer) -> (p: Pipeline, ok: bool) {
	device := r.device

	// The material-template shader pairs, used unchanged (see
	// MaterialTemplate.cpp / MaterialGeneratorDX11.cpp for the C++ loads).
	vs_vc := shader.compile("vertex-color.vertex-normal.point-light.perspective.vs.hlsl", "VSMAIN", "vs_4_0") or_return
	defer vs_vc->Release()
	ps_vc := shader.compile("vertex-color.vertex-normal.point-light.perspective.ps.hlsl", "PSMAIN", "ps_4_0") or_return
	defer ps_vc->Release()
	vs_tex := shader.compile("textured.vertex-normal.point-light.perspective.vs.hlsl", "VSMAIN", "vs_4_0") or_return
	defer vs_tex->Release()
	ps_tex := shader.compile("textured.vertex-normal.point-light.perspective.ps.hlsl", "PSMAIN", "ps_4_0") or_return
	defer ps_tex->Release()
	vs_sky := shader.compile("Skybox.hlsl", "VSMAIN", "vs_4_0") or_return
	defer vs_sky->Release()
	ps_sky := shader.compile("Skybox.hlsl", "PSMAIN", "ps_4_0") or_return
	defer ps_sky->Release()

	if device->CreateVertexShader(vs_vc->GetBufferPointer(), vs_vc->GetBufferSize(), nil, &p.vs_vertex_color) < 0 {return}
	if device->CreatePixelShader(ps_vc->GetBufferPointer(), ps_vc->GetBufferSize(), nil, &p.ps_vertex_color) < 0 {return}
	if device->CreateVertexShader(vs_tex->GetBufferPointer(), vs_tex->GetBufferSize(), nil, &p.vs_textured) < 0 {return}
	if device->CreatePixelShader(ps_tex->GetBufferPointer(), ps_tex->GetBufferSize(), nil, &p.ps_textured) < 0 {return}
	if device->CreateVertexShader(vs_sky->GetBufferPointer(), vs_sky->GetBufferSize(), nil, &p.vs_skybox) < 0 {return}
	if device->CreatePixelShader(ps_sky->GetBufferPointer(), ps_sky->GetBufferSize(), nil, &p.ps_skybox) < 0 {return}

	// BasicVertexDX11's element list (appended offsets over the 48-byte
	// vertex); the skybox layout is position + texcoords over 20 bytes.
	basic_elements := [4]d3d11.INPUT_ELEMENT_DESC{
		{"POSITION", 0, .R32G32B32_FLOAT, 0, 0, .VERTEX_DATA, 0},
		{"NORMAL", 0, .R32G32B32_FLOAT, 0, 12, .VERTEX_DATA, 0},
		{"COLOR", 0, .R32G32B32A32_FLOAT, 0, 24, .VERTEX_DATA, 0},
		{"TEXCOORD", 0, .R32G32_FLOAT, 0, 40, .VERTEX_DATA, 0},
	}
	skybox_elements := [2]d3d11.INPUT_ELEMENT_DESC{
		{"POSITION", 0, .R32G32B32_FLOAT, 0, 0, .VERTEX_DATA, 0},
		{"TEXCOORD", 0, .R32G32_FLOAT, 0, 12, .VERTEX_DATA, 0},
	}
	if device->CreateInputLayout(&basic_elements[0], 4, vs_vc->GetBufferPointer(), vs_vc->GetBufferSize(), &p.layout_vertex_color) < 0 {return}
	if device->CreateInputLayout(&basic_elements[0], 4, vs_tex->GetBufferPointer(), vs_tex->GetBufferSize(), &p.layout_textured) < 0 {return}
	if device->CreateInputLayout(&skybox_elements[0], 2, vs_sky->GetBufferPointer(), vs_sky->GetBufferSize(), &p.layout_skybox) < 0 {return}

	// Linear/wrap sampler for "LinearSampler" (the engine's
	// SamplerStateConfigDX11 defaults).
	sampler_desc := d3d11.SAMPLER_DESC {
		Filter         = .MIN_MAG_MIP_LINEAR,
		AddressU       = .WRAP,
		AddressV       = .WRAP,
		AddressW       = .WRAP,
		MaxAnisotropy  = 1,
		ComparisonFunc = .NEVER,
		MaxLOD         = d3d11.FLOAT32_MAX,
	}
	if device->CreateSamplerState(&sampler_desc, &p.sampler) < 0 {return}

	// MaterialTemplate's alpha blend state: SRC_ALPHA / INV_SRC_ALPHA,
	// alpha channel ONE/ONE.
	blend_desc: d3d11.BLEND_DESC
	for &rt in blend_desc.RenderTarget {
		rt = {
			BlendEnable           = true,
			SrcBlend              = .SRC_ALPHA,
			DestBlend             = .INV_SRC_ALPHA,
			BlendOp               = .ADD,
			SrcBlendAlpha         = .ONE,
			DestBlendAlpha        = .ONE,
			BlendOpAlpha          = .ADD,
			RenderTargetWriteMask = u8(d3d11.COLOR_WRITE_ENABLE_ALL),
		}
	}
	if device->CreateBlendState(&blend_desc, &p.alpha_blend) < 0 {return}

	// SkyboxActor's depth state: default except LESS_EQUAL, so the far-plane
	// skybox passes where depth is still 1.0.
	stencil_op := d3d11.DEPTH_STENCILOP_DESC {
		StencilFailOp      = .KEEP,
		StencilDepthFailOp = .KEEP,
		StencilPassOp      = .KEEP,
		StencilFunc        = .ALWAYS,
	}
	depth_desc := d3d11.DEPTH_STENCIL_DESC {
		DepthEnable      = true,
		DepthWriteMask   = .ALL,
		DepthFunc        = .LESS_EQUAL,
		StencilReadMask  = 0xff,
		StencilWriteMask = 0xff,
		FrontFace        = stencil_op,
		BackFace         = stencil_op,
	}
	if device->CreateDepthStencilState(&depth_desc, &p.skybox_depth) < 0 {return}

	p.cb_world = dynamic_cbuffer(device, size_of(World_Transforms)) or_return
	p.cb_light = dynamic_cbuffer(device, size_of(Point_Light_Info)) or_return
	p.cb_scene = dynamic_cbuffer(device, size_of(Scene_Info)) or_return
	p.cb_material = dynamic_cbuffer(device, size_of(Pbr_Material)) or_return
	p.cb_skybox = dynamic_cbuffer(device, size_of(Skybox_Data)) or_return

	// Skybox geometry (scale 10, per the App's SkyboxActor).
	verts: [8]Skybox_Vertex
	for corner, i in skybox_corners {
		verts[i] = {corner.position * 10.0, corner.texcoords}
	}
	p.skybox_vb = immutable_buffer(device, &verts[0], size_of(verts), {.VERTEX_BUFFER}) or_return
	p.skybox_ib = immutable_buffer(device, &skybox_indices[0], size_of(skybox_indices), {.INDEX_BUFFER}) or_return

	p.skybox_texture, p.skybox_srv = load_cubemap_dds(r, "TropicalSunnyDay.dds") or_return
	p.grid_texture, p.grid_srv = renderer.load_texture_png(r, "EyeOfHorus_128.png") or_return

	return p, true
}

// --- scene construction (App::Initialize) ------------------------------------

build_scene :: proc() -> (grid, shapes, stl_object, curve: Scene_Object) {
	// Indexed paraboloid grid actor: textured, rebuilt per frame in the loop.
	mesh_init(&grid.mesh, .TRIANGLELIST)
	grid.position = {3, 0, 0}
	grid.spin_rate = -0.1
	grid.material = .Textured
	grid.material_params = {
		object_albedo   = {1, 1, 1, 1},
		object_material = {0.3, 0, 0, 0}, // GeometryActor default
	}

	// Shape collection (transparent material → alpha pass). All five shapes
	// share one mesh and therefore one draw call, so they blend strictly in
	// the order appended here, with no depth sorting — same as the C++, where
	// only the sphere is actually translucent (alpha 0.5).
	mesh_init(&shapes.mesh, .TRIANGLELIST)
	shapes.mesh.color = {1, 0, 0, 0.5}
	draw_sphere(&shapes.mesh, {2.5, 2, 0}, 1.5, 16, 24)
	shapes.mesh.color = {0, 1, 0, 1}
	draw_cylinder(&shapes.mesh, {-1.5, -1, 0}, {-1.5, 3, 0}, 1.5, 0.0, 8, 24)
	shapes.mesh.color = {1, 1, 0, 1}
	draw_disc(&shapes.mesh, {0, -3, 0}, {1, 1, 1}, 2.0)
	shapes.mesh.color = {0, 0, 1, 1}
	draw_box(&shapes.mesh, {0, 3, 0}, {1, 1, 1})
	shapes.mesh.color = {1, 1, 1, 1}
	draw_arrow(&shapes.mesh, {0, 0, 0}, {5, 0, 0}, 0.5, 1.0, 1.0)
	shapes.position = {0, 2.5, 0}
	shapes.spin_rate = 0.4
	shapes.material = .Vertex_Color
	shapes.material_params = {
		object_albedo   = {1, 1, 1, 1}, // SetDiffuse(1,1,1,1)
		object_material = {0.3, 0, 0, 0},
	}

	// STL mesh actor: triangle soup with per-face normals, color (0,1,0,0).
	// The alpha of 0 is preserved from the C++; it is harmless because this
	// object draws in the opaque pass, where blending is off.
	mesh_init(&stl_object.mesh, .TRIANGLELIST)
	stl_object.mesh.color = {0, 1, 0, 0}
	faces := stl_load("MeshedReconstruction.stl")
	defer delete(faces)
	// The C++ uses a non-indexed DrawExecutorDX11 here; this port has only the
	// indexed path, so it emits the trivial 0,1,2,... index run.
	i: u32 = 0
	for face in faces {
		add_vertex_normal(&stl_object.mesh, face.v0, face.normal)
		add_vertex_normal(&stl_object.mesh, face.v1, face.normal)
		add_vertex_normal(&stl_object.mesh, face.v2, face.normal)
		add_index(&stl_object.mesh, i)
		add_index(&stl_object.mesh, i + 1)
		add_index(&stl_object.mesh, i + 2)
		i += 3
	}
	stl_object.position = {5, 5, 0}
	stl_object.spin_rate = -1.0
	stl_object.material = .Vertex_Color
	stl_object.material_params = {
		object_albedo   = {0, 0, 0, 0},
		// GenerateImmediateGeometrySolidMaterial: roughness 1.0.
		object_material = {1, 0, 0, 0},
	}

	// Bezier curve actor: green line list at the origin, no controller.
	mesh_init(&curve.mesh, .LINELIST)
	curve.mesh.color = {0, 1, 0, 1}
	draw_bezier_curve(&curve.mesh, {{0, 0, 0}, {5, 5, 0}, {5, 10, 0}, {0, 10, 0}}, 0.0, 1.0, 200)
	curve.material = .Vertex_Color
	curve.material_params = {
		object_albedo   = {1, 1, 1, 1},
		object_material = {0.3, 0, 0, 0},
	}

	return
}

// Rebuild the animated paraboloid grid, mirroring the immediate-rendering
// block in App::Update verbatim.
rebuild_grid :: proc(m: ^Immediate_Mesh, runtime: f32) {
	GRIDSIZE :: 20
	FGRIDSIZE :: f32(GRIDSIZE)
	FSIZESCALE :: 5.0 / FGRIDSIZE

	scaling := 0.25 * math.sin(runtime * 0.75)

	// Discards last frame's vertices/indices outright and marks the mesh
	// dirty; mesh_commit then re-uploads both buffers. This is the chapter's
	// point — geometry is redefined per frame rather than baked once.
	mesh_reset(m)
	m.color = {1, 1, 1, 1}

	for z in 0 ..< GRIDSIZE {
		for x in 0 ..< GRIDSIZE {
			fx := f32(x)
			fz := f32(z)

			vx := fx - f32(GRIDSIZE / 2)
			vz := fz - f32(GRIDSIZE / 2)
			vy := (5.0 - 0.2 * (vx * vx + vz * vz)) * scaling

			// AddVertex(position, texcoords) leaves the normal at the default
			// (0,1,0) — preserved: the paraboloid is lit as if flat, so the
			// PBR highlight sweeps the whole surface uniformly.
			uv := [2]f32{fx / (FGRIDSIZE - 1), 1.0 - fz / (FGRIDSIZE - 1)}
			add_vertex_tex(m, [3]f32{vx, vy, vz} * FSIZESCALE, uv)
		}
	}

	G :: u32(GRIDSIZE)
	for z in 0 ..< G - 1 {
		for x in 0 ..< G - 1 {
			add_index(m, z * G + x)
			add_index(m, z * G + x + G)
			add_index(m, z * G + x + 1)

			add_index(m, z * G + x + 1)
			add_index(m, z * G + x + G)
			add_index(m, z * G + x + G + 1)
		}
	}
}

// Draw one scene object with the material-template pipeline.
draw_object :: proc(
	ctx: ^d3d11.IDeviceContext,
	p: ^Pipeline,
	o: ^Scene_Object,
	view, proj: dm.Matrix4f32,
	t: f32,
) {
	// An empty mesh is a legitimate state, not an error — a missing model file
	// yields zero triangles and simply draws nothing, exactly as the C++ does
	// for the absent Capsule.obj.
	if o.mesh.index_buffer == nil || len(o.mesh.indices) == 0 {
		return
	}

	world := object_world_matrix(o, t)
	transforms := World_Transforms {
		world           = world,
		world_view_proj = world * view * proj,
	}
	write_cbuffer(ctx, p.cb_world, &transforms)
	write_cbuffer(ctx, p.cb_material, &o.material_params)

	switch o.material {
	case .Vertex_Color:
		ctx->IASetInputLayout(p.layout_vertex_color)
		ctx->VSSetShader(p.vs_vertex_color, nil, 0)
		ctx->PSSetShader(p.ps_vertex_color, nil, 0)
	case .Textured:
		ctx->IASetInputLayout(p.layout_textured)
		ctx->VSSetShader(p.vs_textured, nil, 0)
		ctx->PSSetShader(p.ps_textured, nil, 0)
		ctx->PSSetShaderResources(0, 1, &p.grid_srv)
	}

	stride: u32 = size_of(Basic_Vertex)
	offset: u32 = 0
	ctx->IASetVertexBuffers(0, 1, &o.mesh.vertex_buffer, &stride, &offset)
	ctx->IASetIndexBuffer(o.mesh.index_buffer, .R32_UINT, 0)
	ctx->IASetPrimitiveTopology(o.mesh.topology)
	ctx->DrawIndexed(u32(len(o.mesh.indices)), 0, 0)
}

main :: proc() {
	state: App_State
	handler := window.Handler {
		data     = &state,
		callback = message_callback,
	}

	win := window.render_window_default()
	win.width = WIDTH
	win.height = HEIGHT
	window.set_caption(&win, "ImmediateRenderer")
	window.initialize(&win, &handler)
	defer window.shutdown(&win)

	r, renderer_ok := renderer.create(win.hwnd, WIDTH, HEIGHT, ._11_0)
	if !renderer_ok {
		win32.ShowWindow(win.hwnd, win32.SW_HIDE)
		win32.MessageBoxW(
			nil,
			win32.L("Could not create a hardware or software Direct3D 11 device - the program will now abort!"),
			win32.L("Hieroglyph 3 Rendering"),
			win32.MB_ICONEXCLAMATION | win32.MB_SYSTEMMODAL,
		)
		return
	}
	defer renderer.destroy(&r)

	pipeline, pipeline_ok := create_pipeline(&r)
	if !pipeline_ok {
		win32.MessageBoxW(
			nil,
			win32.L("Scene setup failed - see stderr for details (build without -subsystem:windows)."),
			win32.L("ImmediateRenderer setup failed"),
			win32.MB_ICONEXCLAMATION | win32.MB_SYSTEMMODAL,
		)
		return
	}
	defer pipeline_destroy(&pipeline)

	grid, shapes, stl_object, curve := build_scene()
	defer {
		mesh_destroy(&grid.mesh)
		mesh_destroy(&shapes.mesh)
		mesh_destroy(&stl_object.mesh)
		mesh_destroy(&curve.mesh)
	}

	// App::Initialize camera pose; RenderApplication projection params.
	cam := Fp_Camera {
		position = {-3, 12, -15},
		pitch    = 0.5,
		yaw      = 0.3,
	}
	proj := dm.perspective_fov_lh(math.PI / 4, f32(WIDTH) / f32(HEIGHT), 0.1, 1000.0)

	ctx := r.ctx
	start := time.tick_now()
	last_frame := start
	screenshot_number := 100_000 // 6 digits so filenames sort lexically

	null_srv: ^d3d11.IShaderResourceView

	msg: win32.MSG
	for {
		for win32.PeekMessageW(&msg, nil, 0, 0, win32.PM_REMOVE) {
			if msg.message == win32.WM_QUIT {
				return
			}

			win32.TranslateMessage(&msg)
			win32.DispatchMessageW(&msg)
		}

		now := time.tick_now()
		dt := f32(time.duration_seconds(time.tick_diff(last_frame, now)))
		last_frame = now
		runtime_s := f32(time.duration_seconds(time.tick_diff(start, now)))

		// RenderApplication::HandleWindowResize (also resets the projection
		// via SetAspectRatio, dropping any 1/2/3 offset mode — as in C++).
		if state.pending_resize != {0, 0} {
			renderer.resize(&r, state.pending_resize.x, state.pending_resize.y)
			state.pending_resize = {0, 0}
			proj = dm.perspective_fov_lh(math.PI / 4, f32(r.width) / f32(r.height), 0.1, 1000.0)
		}

		// App::HandleEvent keys 1/2/3: off-center projections. These specify
		// the frustum window directly on the near plane instead of by fov and
		// aspect, so 2 and 3 sit entirely to one side of the view axis — the
		// asymmetric frustum used for split/stereo views. They ignore the
		// window aspect ratio, so the image stretches on a non-4:3 window;
		// that is the C++ behaviour too.
		if state.projection_key != 0 {
			switch state.projection_key {
			case '1':
				proj = dm.perspective_off_center_lh(-0.4, 0.4, -0.3, 0.3, 0.5, 100.0)
			case '2':
				proj = dm.perspective_off_center_lh(0.0, 0.8, -0.3, 0.3, 0.5, 100.0)
			case '3':
				proj = dm.perspective_off_center_lh(-0.8, 0.0, -0.3, 0.3, 0.5, 100.0)
			}
			state.projection_key = 0
		}

		camera_update(&cam, &state.input, dt)
		view := camera_view_matrix(&cam)

		// Controllers: the point light circles at radius 50, height 50. This
		// flattens the C++ two-level transform — the rotating node at
		// (0,50,0) with the light body offset to (50,0,0) — into one
		// rotate-then-translate.
		light_angle := -runtime_s
		light_pos_3 := [3]f32{50, 0, 0} * dm.matrix3_rotate_f32(light_angle, [3]f32{0, 1, 0}) + {0, 50, 0}

		rebuild_grid(&grid.mesh, runtime_s)

		// All Map calls happen before any draw is issued this frame. Only the
		// grid is actually dirty after the first frame; the other three
		// commits fall straight through and keep their buffers.
		mesh_commit(&grid.mesh, r.device, ctx)
		mesh_commit(&shapes.mesh, r.device, ctx)
		mesh_commit(&stl_object.mesh, r.device, ctx)
		mesh_commit(&curve.mesh, r.device, ctx)

		// ViewPerspective: clear to the App's color, depth to 1.
		clear_color := [4]f32{0.2, 0.2, 0.4, 0.0}
		ctx->ClearRenderTargetView(r.rtv, &clear_color)
		ctx->ClearDepthStencilView(r.dsv, {.DEPTH}, 1.0, 0)

		// Frame-constant cbuffers: PointLightInfo (Light's defaults) and
		// SceneInfo (camera world position).
		light := Point_Light_Info {
			light_position = {light_pos_3.x, light_pos_3.y, light_pos_3.z, 1},
			ia             = {0.25, 0.25, 0.25, 0.25},
			id             = {0.5, 0.5, 0.5, 1},
			is_            = {1, 1, 1, 1},
		}
		write_cbuffer(ctx, pipeline.cb_light, &light)
		scene_info := Scene_Info {
			view_position = {cam.position.x, cam.position.y, cam.position.z, 1},
		}
		write_cbuffer(ctx, pipeline.cb_scene, &scene_info)

		// PS cbuffers in declaration order: PointLightInfo b0, SceneInfo b1,
		// PBRMaterialParameters b2. VS: WorldTransforms b0.
		ps_cbuffers := [3]^d3d11.IBuffer{pipeline.cb_light, pipeline.cb_scene, pipeline.cb_material}
		ctx->PSSetConstantBuffers(0, 3, &ps_cbuffers[0])
		ctx->VSSetConstantBuffers(0, 1, &pipeline.cb_world)
		ctx->PSSetSamplers(0, 1, &pipeline.sampler)

		// GEOMETRY pass, in scene-graph order: grid, STL mesh, curve — then
		// the skybox (added last, LESS_EQUAL depth).
		draw_object(ctx, &pipeline, &grid, view, proj, runtime_s)
		draw_object(ctx, &pipeline, &stl_object, view, proj, runtime_s)
		draw_object(ctx, &pipeline, &curve, view, proj, runtime_s)

		// Skybox (SkyboxActor): its own shader pair and cbuffer. Drawn after
		// the opaque geometry rather than first, so most of it is already
		// depth-rejected; the cube is translated to the camera and its depth
		// pinned at the far plane in the VS, which is why it needs the
		// LESS_EQUAL state to survive the 1.0 depth clear.
		skybox_data := Skybox_Data {
			view          = view,
			proj          = proj,
			view_position = {cam.position.x, cam.position.y, cam.position.z, 1},
		}
		write_cbuffer(ctx, pipeline.cb_skybox, &skybox_data)
		ctx->IASetInputLayout(pipeline.layout_skybox)
		sky_stride: u32 = size_of(Skybox_Vertex)
		sky_offset: u32 = 0
		ctx->IASetVertexBuffers(0, 1, &pipeline.skybox_vb, &sky_stride, &sky_offset)
		ctx->IASetIndexBuffer(pipeline.skybox_ib, .R32_UINT, 0)
		ctx->IASetPrimitiveTopology(.TRIANGLELIST)
		ctx->VSSetShader(pipeline.vs_skybox, nil, 0)
		ctx->PSSetShader(pipeline.ps_skybox, nil, 0)
		ctx->VSSetConstantBuffers(0, 1, &pipeline.cb_skybox)
		ctx->PSSetShaderResources(0, 1, &pipeline.skybox_srv)
		ctx->OMSetDepthStencilState(pipeline.skybox_depth, 0)
		ctx->DrawIndexed(u32(len(skybox_indices)), 0, 0)
		// Restore what the skybox displaced: default depth state, the shared
		// WorldTransforms cbuffer at VS b0, and t0 cleared so the cube map is
		// not left bound where the textured material expects the 2D grid
		// texture.
		ctx->OMSetDepthStencilState(nil, 0)
		ctx->VSSetConstantBuffers(0, 1, &pipeline.cb_world)
		ctx->PSSetShaderResources(0, 1, &null_srv)

		// ALPHA pass: the transparent shape collection, drawn last so it
		// blends over finished opaque geometry and the skybox. Depth writes
		// stay on (the C++ leaves them on too), so the shapes occlude each
		// other rather than blending among themselves in depth order.
		blend_factor := [4]f32{1, 1, 1, 1}
		ctx->OMSetBlendState(pipeline.alpha_blend, &blend_factor, 0xffffffff)
		draw_object(ctx, &pipeline, &shapes, view, proj, runtime_s)
		ctx->OMSetBlendState(nil, &blend_factor, 0xffffffff)

		renderer.present(&r)

		if state.save_screenshot {
			state.save_screenshot = false
			screenshot_number += 1
			renderer.save_backbuffer_png(&r, fmt.tprintf("ImmediateRenderer%d.png", screenshot_number))
		}
	}
}
