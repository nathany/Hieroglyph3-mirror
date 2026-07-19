// Odin port of the CurvedPointNormalTriangles sample
// (Applications/CurvedPointNormalTriangles/App.cpp) — chapter 9's curved PN
// triangles: a small PLY test mesh whose flat triangles are inflated into
// cubic Bezier patches in the hull/domain shaders
// (CurvedPointNormalTriangles.hlsl, used unchanged: 13 output control
// points per patch, position curving + normal interpolation in the DS).
//
// The camera orbits the mesh (one circuit per 30 seconds, radius 2.5,
// height 1.25). Keys, all key-up, matching the C++:
//   - W toggles wireframe (cull none) vs solid (cull back). Starts wireframe.
//   - +/- (numpad) adjust the tessellation factor by 0.25 in [1, 10].
//   - A swaps the hull shader between hsDefault and hsSilhouette. Preserved
//     C++ quirk: hsSilhouette expects 6-control-point (adjacency) patches,
//     but the app loads the mesh WITHOUT adjacency (3-point patches), so
//     silhouette mode doesn't render in the original either.
//   - Esc quits; Space screenshots (the on-screen help lists 'S', but the
//     C++ never handles it — Space is the real key).
//
// The pipeline-statistics text overlay is omitted (text is out of scope).
package main

import "core:fmt"
import "core:math"
import "core:time"
import win32 "core:sys/windows"
import d3d11 "vendor:directx/d3d11"
import "glyph:camera"
import "glyph:renderer"
import "glyph:shader"
import "glyph:window"

WIDTH :: 640
HEIGHT :: 480

// The shader's three cbuffers; registers are assigned per stage among the
// cbuffers each stage uses (declaration order): VS uses Transforms only
// (b0); both hull-shader constant functions use TessellationParameters (b0)
// + RenderingParameters (b1); the DS uses Transforms (b0) +
// RenderingParameters (b1); the GS and PS use none.
Transforms :: struct #align (16) {
	world:            matrix[4, 4]f32,
	view_proj:        matrix[4, 4]f32,
	inv_tpose_world:  matrix[4, 4]f32,
}

// xyz are the three SV_TessFactor edges, w the single SV_InsideTessFactor;
// the app writes the same slider value into all four. hsConstantFunc
// multiplies each by sign(0.2 + dot(faceNormal, viewDirection)), so
// back-facing patches get a negative factor and the tessellator culls the
// whole patch.
Tessellation_Parameters :: struct #align (16) {
	edge_factors: [4]f32,
}

// Used two ways: the hull constant function takes look_at - position as the
// view direction for the back-face test, and the DS lights with
// normalize(cameraPosition) — i.e. it treats the camera's POSITION as a
// light direction. Preserved; it is why the shading swings as the camera
// orbits.
Rendering_Parameters :: struct #align (16) {
	camera_position: [3]f32,
	_pad0:           f32,
	camera_look_at:  [3]f32,
	_pad1:           f32,
}

App_State :: struct {
	save_screenshot: bool,
	toggle_solid:    bool,
	toggle_hull:     bool,
	adjust:          f32,
}

message_callback :: proc(data: rawptr, hwnd: win32.HWND, msg: win32.UINT, wparam: win32.WPARAM, lparam: win32.LPARAM) -> win32.LRESULT {
	state := cast(^App_State)data

	switch msg {
	case win32.WM_DESTROY:
		win32.PostQuitMessage(0)
		return 0

	case win32.WM_KEYUP:
		switch wparam {
		case win32.WPARAM(win32.VK_ESCAPE):
			win32.PostQuitMessage(0)
			return 0
		case win32.WPARAM(win32.VK_SPACE):
			state.save_screenshot = true
		case win32.WPARAM('W'):
			state.toggle_solid = true
		case win32.WPARAM('A'):
			state.toggle_hull = true
		case win32.WPARAM(win32.VK_ADD):
			state.adjust += 0.25
		case win32.WPARAM(win32.VK_SUBTRACT):
			state.adjust -= 0.25
		}
	}

	return win32.DefWindowProcW(hwnd, msg, wparam, lparam)
}

Scene :: struct {
	vertex_buffer:   ^d3d11.IBuffer,
	index_buffer:    ^d3d11.IBuffer,
	index_count:     u32,
	input_layout:    ^d3d11.IInputLayout,
	vertex_shader:   ^d3d11.IVertexShader,
	hs_default:      ^d3d11.IHullShader,
	hs_silhouette:   ^d3d11.IHullShader,
	domain_shader:   ^d3d11.IDomainShader,
	geometry_shader: ^d3d11.IGeometryShader,
	pixel_shader:    ^d3d11.IPixelShader,
	rs_wireframe:    ^d3d11.IRasterizerState,
	rs_solid:        ^d3d11.IRasterizerState,
	cb_transforms:   ^d3d11.IBuffer,
	cb_tess:         ^d3d11.IBuffer,
	cb_rendering:    ^d3d11.IBuffer,
}

scene_destroy :: proc(s: ^Scene) {
	release :: proc(obj: ^$T) {
		if obj != nil {obj->Release()}
	}
	release(s.cb_rendering)
	release(s.cb_tess)
	release(s.cb_transforms)
	release(s.rs_solid)
	release(s.rs_wireframe)
	release(s.pixel_shader)
	release(s.geometry_shader)
	release(s.domain_shader)
	release(s.hs_silhouette)
	release(s.hs_default)
	release(s.vertex_shader)
	release(s.input_layout)
	release(s.index_buffer)
	release(s.vertex_buffer)
	s^ = {}
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

write_cbuffer :: proc(ctx: ^d3d11.IDeviceContext, buffer: ^d3d11.IBuffer, value: ^$T) {
	mapped: d3d11.MAPPED_SUBRESOURCE
	if ctx->Map((^d3d11.IResource)(buffer), 0, .WRITE_DISCARD, {}, &mapped) >= 0 {
		(^T)(mapped.pData)^ = value^
		ctx->Unmap((^d3d11.IResource)(buffer), 0)
	}
}

setup :: proc(r: ^renderer.Renderer) -> (s: Scene, ok: bool) {
	device := r.device

	vs_blob := shader.compile("CurvedPointNormalTriangles.hlsl", "vsMain", "vs_5_0") or_return
	defer vs_blob->Release()
	// Both hull shaders take a 3-point input patch and emit 13 output control
	// points — the cubic Bezier PN triangle. The control-point phase runs
	// once per output point and switches on SV_OutputControlPointID: 0-2 are
	// the original vertices b300/b030/b003; 3-8 are the two tangent points
	// per edge, each the source vertex nudged a third of the way along the
	// edge and then projected onto that vertex's tangent plane (hence the
	// dot-with-normal term in ComputeEdgePosition); 9 is the centre b111,
	// the average E of those six edge points pushed a further (E - V) / 2
	// away from the flat centroid V. Points 10-12 carry no position, only
	// the quadratically-varying edge NORMALS, which is what lets the DS
	// shade a curved surface instead of a faceted one.
	hs_default_blob := shader.compile("CurvedPointNormalTriangles.hlsl", "hsDefault", "hs_5_0") or_return
	defer hs_default_blob->Release()
	hs_sil_blob := shader.compile("CurvedPointNormalTriangles.hlsl", "hsSilhouette", "hs_5_0") or_return
	defer hs_sil_blob->Release()
	ds_blob := shader.compile("CurvedPointNormalTriangles.hlsl", "dsMain", "ds_5_0") or_return
	defer ds_blob->Release()
	gs_blob := shader.compile("CurvedPointNormalTriangles.hlsl", "gsMain", "gs_5_0") or_return
	defer gs_blob->Release()
	ps_blob := shader.compile("CurvedPointNormalTriangles.hlsl", "psMain", "ps_5_0") or_return
	defer ps_blob->Release()

	if device->CreateVertexShader(vs_blob->GetBufferPointer(), vs_blob->GetBufferSize(), nil, &s.vertex_shader) < 0 {return}
	if device->CreateHullShader(hs_default_blob->GetBufferPointer(), hs_default_blob->GetBufferSize(), nil, &s.hs_default) < 0 {return}
	if device->CreateHullShader(hs_sil_blob->GetBufferPointer(), hs_sil_blob->GetBufferSize(), nil, &s.hs_silhouette) < 0 {return}
	if device->CreateDomainShader(ds_blob->GetBufferPointer(), ds_blob->GetBufferSize(), nil, &s.domain_shader) < 0 {return}
	if device->CreateGeometryShader(gs_blob->GetBufferPointer(), gs_blob->GetBufferSize(), nil, &s.geometry_shader) < 0 {return}
	if device->CreatePixelShader(ps_blob->GetBufferPointer(), ps_blob->GetBufferSize(), nil, &s.pixel_shader) < 0 {return}

	mesh := ply_load("CPNTest.ply") or_return
	defer ply_destroy(&mesh)
	s.index_count = u32(len(mesh.indices))

	vb_desc := d3d11.BUFFER_DESC {
		ByteWidth = u32(len(mesh.vertices) * size_of(Ply_Vertex)),
		Usage     = .IMMUTABLE,
		BindFlags = {.VERTEX_BUFFER},
	}
	vb_data := d3d11.SUBRESOURCE_DATA {
		pSysMem = raw_data(mesh.vertices),
	}
	if device->CreateBuffer(&vb_desc, &vb_data, &s.vertex_buffer) < 0 {return}

	ib_desc := d3d11.BUFFER_DESC {
		ByteWidth = u32(len(mesh.indices) * size_of(u32)),
		Usage     = .IMMUTABLE,
		BindFlags = {.INDEX_BUFFER},
	}
	ib_data := d3d11.SUBRESOURCE_DATA {
		pSysMem = raw_data(mesh.indices),
	}
	if device->CreateBuffer(&ib_desc, &ib_data, &s.index_buffer) < 0 {return}

	elements := [2]d3d11.INPUT_ELEMENT_DESC{
		{"POSITION", 0, .R32G32B32_FLOAT, 0, 0, .VERTEX_DATA, 0},
		{"NORMAL", 0, .R32G32B32_FLOAT, 0, 12, .VERTEX_DATA, 0},
	}
	if device->CreateInputLayout(&elements[0], 2, vs_blob->GetBufferPointer(), vs_blob->GetBufferSize(), &s.input_layout) < 0 {return}

	// Wireframe/cull-none (initial) and solid/cull-back, per CreateShaders.
	rs_desc := d3d11.RASTERIZER_DESC {
		FillMode        = .WIREFRAME,
		CullMode        = .NONE,
		DepthClipEnable = true,
	}
	if device->CreateRasterizerState(&rs_desc, &s.rs_wireframe) < 0 {return}
	rs_desc.FillMode = .SOLID
	rs_desc.CullMode = .BACK
	if device->CreateRasterizerState(&rs_desc, &s.rs_solid) < 0 {return}

	s.cb_transforms = dynamic_cbuffer(device, size_of(Transforms)) or_return
	s.cb_tess = dynamic_cbuffer(device, size_of(Tessellation_Parameters)) or_return
	s.cb_rendering = dynamic_cbuffer(device, size_of(Rendering_Parameters)) or_return

	return s, true
}

main :: proc() {
	state: App_State
	handler := window.Handler {
		data     = &state,
		callback = message_callback,
	}

	win := window.render_window_default()
	window.set_position(&win, 25, 25)
	window.set_size(&win, WIDTH, HEIGHT)
	window.set_caption(&win, "Direct3D 11 Curved Point Normal Triangles Demo")
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

	scene, scene_ok := setup(&r)
	if !scene_ok {
		win32.MessageBoxW(
			nil,
			win32.L("Scene setup failed - see stderr for details (build without -subsystem:windows)."),
			win32.L("CurvedPointNormalTriangles setup failed"),
			win32.MB_ICONEXCLAMATION | win32.MB_SYSTEMMODAL,
		)
		return
	}
	defer scene_destroy(&scene)

	solid_render := false
	default_complexity := true
	tess_factor: f32 = 3.0

	ctx := r.ctx
	start := time.tick_now()
	screenshot_number := 100_000

	msg: win32.MSG
	for {
		for win32.PeekMessageW(&msg, nil, 0, 0, win32.PM_REMOVE) {
			if msg.message == win32.WM_QUIT {
				return
			}

			win32.TranslateMessage(&msg)
			win32.DispatchMessageW(&msg)
		}

		if state.toggle_solid {
			state.toggle_solid = false
			solid_render = !solid_render
		}
		if state.toggle_hull {
			state.toggle_hull = false
			default_complexity = !default_complexity
		}
		// Both hull shaders hard-code [partitioning("fractional_even")], so
		// the fractional part of this factor is meaningful and the surface
		// refines smoothly rather than in whole-segment jumps.
		for abs(state.adjust) >= 0.125 {
			step: f32 = 0.25 if state.adjust > 0 else -0.25
			state.adjust -= step
			tess_factor = clamp(tess_factor + step, 1.0, 10.0)
		}

		// UpdateViewState: the camera orbits the origin, one circuit per 30s.
		t := f32(time.duration_seconds(time.tick_since(start)))
		from_angle := math.mod(t / 30.0 * 2.0 * math.PI, 2.0 * math.PI)
		look_from := [3]f32{math.sin(from_angle) * 2.5, 1.25, math.cos(from_angle) * 2.5}
		look_at := [3]f32{0, 0, 0}

		view := camera.look_at_lh(look_from, look_at, {0, 1, 0})
		proj := camera.perspective_fov_lh(math.PI / 3.0, f32(WIDTH) / f32(HEIGHT), 1.0, 25.0)

		// inv_tpose_world is identity here and the VS ignores it anyway (the
		// mInvTposeWorld line is commented out in the HLSL) — preserved.
		transforms := Transforms {
			world           = 1,
			view_proj       = proj * view,
			inv_tpose_world = 1,
		}
		write_cbuffer(ctx, scene.cb_transforms, &transforms)
		tess := Tessellation_Parameters {
			edge_factors = {tess_factor, tess_factor, tess_factor, tess_factor},
		}
		write_cbuffer(ctx, scene.cb_tess, &tess)
		rendering := Rendering_Parameters {
			camera_position = look_from,
			camera_look_at  = look_at,
		}
		write_cbuffer(ctx, scene.cb_rendering, &rendering)

		clear_color := [4]f32{1, 1, 1, 1}
		ctx->ClearRenderTargetView(r.rtv, &clear_color)
		ctx->ClearDepthStencilView(r.dsv, {.DEPTH}, 1.0, 0)

		ctx->IASetInputLayout(scene.input_layout)
		stride: u32 = size_of(Ply_Vertex)
		offset: u32 = 0
		ctx->IASetVertexBuffers(0, 1, &scene.vertex_buffer, &stride, &offset)
		ctx->IASetIndexBuffer(scene.index_buffer, .R32_UINT, 0)
		// Each mesh triangle becomes one 3-control-point patch: the index
		// buffer is unchanged, only the interpretation differs from a plain
		// TRIANGLELIST. hsSilhouette wants 6 points here (see the header);
		// this topology is why it never draws.
		ctx->IASetPrimitiveTopology(._3_CONTROL_POINT_PATCHLIST)

		hs_cbuffers := [2]^d3d11.IBuffer{scene.cb_tess, scene.cb_rendering}
		ds_cbuffers := [2]^d3d11.IBuffer{scene.cb_transforms, scene.cb_rendering}
		ctx->VSSetShader(scene.vertex_shader, nil, 0)
		ctx->VSSetConstantBuffers(0, 1, &scene.cb_transforms)
		ctx->HSSetShader(scene.hs_default if default_complexity else scene.hs_silhouette, nil, 0)
		ctx->HSSetConstantBuffers(0, 2, &hs_cbuffers[0])
		ctx->DSSetShader(scene.domain_shader, nil, 0)
		ctx->DSSetConstantBuffers(0, 2, &ds_cbuffers[0])
		ctx->GSSetShader(scene.geometry_shader, nil, 0)
		ctx->PSSetShader(scene.pixel_shader, nil, 0)

		ctx->RSSetState(scene.rs_solid if solid_render else scene.rs_wireframe)

		ctx->DrawIndexed(scene.index_count, 0, 0)

		renderer.present(&r)

		if state.save_screenshot {
			state.save_screenshot = false
			screenshot_number += 1
			renderer.save_backbuffer_png(&r, fmt.tprintf("Direct3D 11 Curved Point Normal Triangles Demo%d.png", screenshot_number))
		}
	}
}
