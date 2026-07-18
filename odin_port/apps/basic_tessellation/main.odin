// Odin port of the BasicTessellation sample
// (Applications/BasicTessellation/App.cpp).
//
// The chapter-4 hardware-tessellation demo: the hedra.ms3d model is drawn as
// a 3_CONTROL_POINT_PATCHLIST through the full VS -> HS -> tessellator ->
// DS -> PS pipeline of BasicTessellation.hlsl (used unchanged, all SM 5.0
// entry points):
//
//   - The VS transforms control points to world space.
//   - The HS passes control points through; its patch-constant function
//     feeds the fixed-function tessellator the animated EdgeFactors —
//     sin(t) * 6 + 7, sweeping the factors between 1 and 13 with
//     fractional_even partitioning, so triangles continuously split and
//     merge.
//   - The DS interpolates the barycentric points and applies
//     view-projection.
//
// Rendered as a wireframe (FILL_WIREFRAME) so the tessellation pattern is
// the whole show, while the model slowly spins (0.05 pi rad/s). The pixel
// shader outputs the FinalColor parameter, which the C++ never sets — the
// engine zero-initializes vector parameters, so the wireframe is black
// (alpha 0) on the 0.6-gray clear, and this port matches that faithfully
// rather than the shader's suggested white default.
//
// Register note: cbuffer registers are assigned PER STAGE — each stage's
// only used cbuffer lands in b0 for that stage (Transforms for VS and DS,
// EdgeFactors for the HS's patch-constant function, FinalColor for the PS).
//
// Esc quits; Space saves BasicTessellation<n>.png.
package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:time"
import win32 "core:sys/windows"
import d3d11 "vendor:directx/d3d11"
import "glyph:camera"
import "glyph:renderer"
import "glyph:shader"
import "glyph:window"

WIDTH :: 640
HEIGHT :: 480

Transforms :: struct #align (16) {
	world:     matrix[4, 4]f32,
	view_proj: matrix[4, 4]f32,
}

Tessellation_Parameters :: struct #align (16) {
	edge_factors: [4]f32,
}

Rendering_Parameters :: struct #align (16) {
	final_color: [4]f32,
}

App_State :: struct {
	save_screenshot: bool,
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
			return 0
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
	hull_shader:     ^d3d11.IHullShader,
	domain_shader:   ^d3d11.IDomainShader,
	pixel_shader:    ^d3d11.IPixelShader,
	wireframe:       ^d3d11.IRasterizerState,
	cb_transforms:   ^d3d11.IBuffer,
	cb_tessellation: ^d3d11.IBuffer,
	cb_rendering:    ^d3d11.IBuffer,
	view_proj:       matrix[4, 4]f32,
}

scene_destroy :: proc(s: ^Scene) {
	if s.cb_rendering != nil {s.cb_rendering->Release()}
	if s.cb_tessellation != nil {s.cb_tessellation->Release()}
	if s.cb_transforms != nil {s.cb_transforms->Release()}
	if s.wireframe != nil {s.wireframe->Release()}
	if s.pixel_shader != nil {s.pixel_shader->Release()}
	if s.domain_shader != nil {s.domain_shader->Release()}
	if s.hull_shader != nil {s.hull_shader->Release()}
	if s.vertex_shader != nil {s.vertex_shader->Release()}
	if s.input_layout != nil {s.input_layout->Release()}
	if s.index_buffer != nil {s.index_buffer->Release()}
	if s.vertex_buffer != nil {s.vertex_buffer->Release()}
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

	// All four stages from the one file, as the C++ LoadShader calls do.
	vs_blob := shader.compile("BasicTessellation.hlsl", "VSMAIN", "vs_5_0") or_return
	defer vs_blob->Release()
	hs_blob := shader.compile("BasicTessellation.hlsl", "HSMAIN", "hs_5_0") or_return
	defer hs_blob->Release()
	ds_blob := shader.compile("BasicTessellation.hlsl", "DSMAIN", "ds_5_0") or_return
	defer ds_blob->Release()
	ps_blob := shader.compile("BasicTessellation.hlsl", "PSMAIN", "ps_5_0") or_return
	defer ps_blob->Release()

	if device->CreateVertexShader(vs_blob->GetBufferPointer(), vs_blob->GetBufferSize(), nil, &s.vertex_shader) < 0 {return}
	if device->CreateHullShader(hs_blob->GetBufferPointer(), hs_blob->GetBufferSize(), nil, &s.hull_shader) < 0 {return}
	if device->CreateDomainShader(ds_blob->GetBufferPointer(), ds_blob->GetBufferSize(), nil, &s.domain_shader) < 0 {return}
	if device->CreatePixelShader(ps_blob->GetBufferPointer(), ps_blob->GetBufferSize(), nil, &s.pixel_shader) < 0 {return}

	// The MS3D loader's element order: POSITION, TEXCOORD, NORMAL (stride
	// 32). Only POSITION feeds the VS; the rest ride along in the layout.
	layout := [3]d3d11.INPUT_ELEMENT_DESC{
		{"POSITION", 0, .R32G32B32_FLOAT, 0, 0, .VERTEX_DATA, 0},
		{"TEXCOORD", 0, .R32G32_FLOAT, 0, 12, .VERTEX_DATA, 0},
		{"NORMAL", 0, .R32G32B32_FLOAT, 0, 20, .VERTEX_DATA, 0},
	}
	if device->CreateInputLayout(&layout[0], 3, vs_blob->GetBufferPointer(), vs_blob->GetBufferSize(), &s.input_layout) < 0 {return}

	// Wireframe rasterizer (RasterizerStateConfigDX11 defaults +
	// FILL_WIREFRAME).
	rs_desc := d3d11.RASTERIZER_DESC {
		FillMode        = .WIREFRAME,
		CullMode        = .BACK,
		DepthClipEnable = true,
	}
	if device->CreateRasterizerState(&rs_desc, &s.wireframe) < 0 {return}

	mesh := ms3d_load("hedra.ms3d") or_return
	defer ms3d_destroy(&mesh)
	s.index_count = u32(len(mesh.indices))

	vb_desc := d3d11.BUFFER_DESC {
		ByteWidth = u32(len(mesh.vertices) * size_of(Ms3d_Vertex)),
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

	s.cb_transforms = dynamic_cbuffer(device, size_of(Transforms)) or_return
	s.cb_tessellation = dynamic_cbuffer(device, size_of(Tessellation_Parameters)) or_return
	s.cb_rendering = dynamic_cbuffer(device, size_of(Rendering_Parameters)) or_return

	// The camera from App::Initialize; ViewProj is constant.
	view := camera.look_at_lh({5.0, 5.5, -5.0}, {0.0, 0.75, 0.0}, {0.0, 1.0, 0.0})
	proj := camera.perspective_fov_lh(linalg.PI / 2.0, f32(WIDTH) / f32(HEIGHT), 0.1, 25.0)
	s.view_proj = proj * view

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
	window.set_caption(&win, "BasicTessellation")
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
			win32.L("BasicTessellation setup failed"),
			win32.MB_ICONEXCLAMATION | win32.MB_SYSTEMMODAL,
		)
		return
	}
	defer scene_destroy(&scene)

	ctx := r.ctx

	// The C++ accumulates these with per-frame elapsed time; fTessellation
	// starts at 3pi/2 so the factor starts at its minimum of 1.
	f_rotation: f32 = 0.0
	f_tessellation: f32 = 3.0 * math.PI / 2.0
	last_frame := time.tick_now()

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

		now := time.tick_now()
		dt := f32(time.duration_seconds(time.tick_diff(last_frame, now)))
		last_frame = now

		// App::Update's animation.
		f_rotation += dt * 3.14 * 0.05
		f_tessellation += dt * 0.2 * 3.14
		factor := math.sin(f_tessellation) * 6.0 + 7.0

		color := [4]f32{0.6, 0.6, 0.6, 0.6}
		ctx->ClearRenderTargetView(r.rtv, &color)
		ctx->ClearDepthStencilView(r.dsv, {.DEPTH}, 1.0, 0)

		transforms := Transforms {
			world     = linalg.matrix4_rotate_f32(f_rotation, {0, 1, 0}),
			view_proj = scene.view_proj,
		}
		write_cbuffer(ctx, scene.cb_transforms, &transforms)
		tess := Tessellation_Parameters {
			edge_factors = {factor, factor, factor, factor},
		}
		write_cbuffer(ctx, scene.cb_tessellation, &tess)
		rendering := Rendering_Parameters{} // never set by the C++ → zero (black)
		write_cbuffer(ctx, scene.cb_rendering, &rendering)

		ctx->IASetInputLayout(scene.input_layout)
		stride: u32 = size_of(Ms3d_Vertex)
		offset: u32 = 0
		ctx->IASetVertexBuffers(0, 1, &scene.vertex_buffer, &stride, &offset)
		ctx->IASetIndexBuffer(scene.index_buffer, .R32_UINT, 0)
		ctx->IASetPrimitiveTopology(._3_CONTROL_POINT_PATCHLIST)

		// The full tessellation pipeline; per-stage b0 bindings (see the
		// register note in the header comment).
		ctx->VSSetShader(scene.vertex_shader, nil, 0)
		ctx->VSSetConstantBuffers(0, 1, &scene.cb_transforms)
		ctx->HSSetShader(scene.hull_shader, nil, 0)
		ctx->HSSetConstantBuffers(0, 1, &scene.cb_tessellation)
		ctx->DSSetShader(scene.domain_shader, nil, 0)
		ctx->DSSetConstantBuffers(0, 1, &scene.cb_transforms)
		ctx->PSSetShader(scene.pixel_shader, nil, 0)
		ctx->PSSetConstantBuffers(0, 1, &scene.cb_rendering)

		ctx->RSSetState(scene.wireframe)

		ctx->DrawIndexed(scene.index_count, 0, 0)

		renderer.present(&r)

		if state.save_screenshot {
			state.save_screenshot = false
			screenshot_number += 1
			renderer.save_backbuffer_png(&r, fmt.tprintf("BasicTessellation%d.png", screenshot_number))
		}
	}
}
