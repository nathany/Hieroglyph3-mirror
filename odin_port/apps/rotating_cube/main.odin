// Odin port of the RotatingCube sample (Applications/RotatingCube/App.cpp).
//
// The book's first real render: an indexed color cube spun by a world matrix
// rebuilt every frame, drawn with VS -> GS -> PS from RotatingCube.hlsl
// (used unchanged). The vertex shader is a passthrough; the geometry shader
// "blows up" each face along its normal by 1/4 and applies the
// WorldViewProjMatrix — so the cbuffer is a *geometry* shader input, the one
// stage most samples don't use.
//
// Matrix conventions: see glyph:shader — with the engine's row-major compile
// flag, plain Odin matrices compose naturally (`proj * view * world` here
// equals the C++'s row-vector `World * View * Proj`) and upload with no
// transposes. The C++'s `RotationMatrixY(t) * RotationMatrixX(t)` (row-
// vector: Y first, then X) becomes `rotate_x * rotate_y` in column-vector
// convention.
//
// The window (and the Space screenshot prefix) is titled "BasicApplication"
// because the C++ App::GetName() returns exactly that — a copy-paste quirk
// in the original, preserved faithfully. 640x480, unlike BasicApplication's
// 640x320.
package main

import "core:fmt"
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

// Matches the C++ Vertex { XMFLOAT3 Pos; XMFLOAT4 Color; }: 28 bytes,
// color at offset 12, as the input layout below declares.
Vertex :: struct {
	position: [3]f32,
	color:    [4]f32,
}

// The shader's `Transforms` cbuffer. Plain matrix — no #row_major, no
// transpose (see glyph:shader's matrix note).
Transforms :: struct #align (16) {
	world_view_proj: matrix[4, 4]f32,
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
	vertex_buffer:       ^d3d11.IBuffer,
	index_buffer:        ^d3d11.IBuffer,
	constant_buffer:     ^d3d11.IBuffer,
	input_layout:        ^d3d11.IInputLayout,
	vertex_shader:       ^d3d11.IVertexShader,
	geometry_shader:     ^d3d11.IGeometryShader,
	pixel_shader:        ^d3d11.IPixelShader,
	rasterizer_state:    ^d3d11.IRasterizerState,
	depth_stencil_state: ^d3d11.IDepthStencilState,
	blend_state:         ^d3d11.IBlendState,
	view:                matrix[4, 4]f32,
	proj:                matrix[4, 4]f32,
}

scene_destroy :: proc(s: ^Scene) {
	if s.blend_state != nil {s.blend_state->Release()}
	if s.depth_stencil_state != nil {s.depth_stencil_state->Release()}
	if s.rasterizer_state != nil {s.rasterizer_state->Release()}
	if s.pixel_shader != nil {s.pixel_shader->Release()}
	if s.geometry_shader != nil {s.geometry_shader->Release()}
	if s.vertex_shader != nil {s.vertex_shader->Release()}
	if s.input_layout != nil {s.input_layout->Release()}
	if s.constant_buffer != nil {s.constant_buffer->Release()}
	if s.index_buffer != nil {s.index_buffer->Release()}
	if s.vertex_buffer != nil {s.vertex_buffer->Release()}
	s^ = {}
}

g_step: string // DIAG: last step attempted, shown in the failure box

setup :: proc(r: ^renderer.Renderer) -> (s: Scene, ok: bool) {
	device := r.device

	// Shaders — same file, entry points, and shader-model targets as the
	// C++ LoadShader calls (vs_4_0-class targets on the FL 10.0 device).
	g_step = "compile VS"
	vs_blob := shader.compile("RotatingCube.hlsl", "VSMain", "vs_4_0") or_return
	defer vs_blob->Release()
	g_step = "compile GS"
	gs_blob := shader.compile("RotatingCube.hlsl", "GSMain", "gs_4_0") or_return
	defer gs_blob->Release()
	g_step = "compile PS"
	ps_blob := shader.compile("RotatingCube.hlsl", "PSMain", "ps_4_0") or_return
	defer ps_blob->Release()

	g_step = "create shaders"
	if device->CreateVertexShader(vs_blob->GetBufferPointer(), vs_blob->GetBufferSize(), nil, &s.vertex_shader) < 0 {return}
	if device->CreateGeometryShader(gs_blob->GetBufferPointer(), gs_blob->GetBufferSize(), nil, &s.geometry_shader) < 0 {return}
	if device->CreatePixelShader(ps_blob->GetBufferPointer(), ps_blob->GetBufferSize(), nil, &s.pixel_shader) < 0 {return}
	g_step = "input layout / buffers"

	// Input layout — semantics and offsets exactly as the C++ declares them
	// ("SV_POSITION" as a vertex-input semantic name is unusual but matches
	// the shader's `float4 position : SV_Position`).
	layout := [2]d3d11.INPUT_ELEMENT_DESC{
		{"SV_POSITION", 0, .R32G32B32_FLOAT, 0, 0, .VERTEX_DATA, 0},
		{"COLOR", 0, .R32G32B32A32_FLOAT, 0, 12, .VERTEX_DATA, 0},
	}
	if device->CreateInputLayout(&layout[0], 2, vs_blob->GetBufferPointer(), vs_blob->GetBufferSize(), &s.input_layout) < 0 {return}

	// "just use default states" — the C++ creates state objects from the
	// engine's default configs (which mirror the D3D11 defaults), with
	// back-face culling set explicitly on the rasterizer.
	rasterizer_desc := d3d11.RASTERIZER_DESC {
		FillMode        = .SOLID,
		CullMode        = .BACK,
		DepthClipEnable = true,
	}
	if device->CreateRasterizerState(&rasterizer_desc, &s.rasterizer_state) < 0 {return}

	stencil_op := d3d11.DEPTH_STENCILOP_DESC {
		StencilFailOp      = .KEEP,
		StencilDepthFailOp = .KEEP,
		StencilPassOp      = .KEEP,
		StencilFunc        = .ALWAYS,
	}
	depth_desc := d3d11.DEPTH_STENCIL_DESC {
		DepthEnable      = true,
		DepthWriteMask   = .ALL,
		DepthFunc        = .LESS,
		StencilEnable    = false,
		StencilReadMask  = 0xff,
		StencilWriteMask = 0xff,
		FrontFace        = stencil_op,
		BackFace         = stencil_op,
	}
	if device->CreateDepthStencilState(&depth_desc, &s.depth_stencil_state) < 0 {return}

	blend_desc: d3d11.BLEND_DESC
	for &rt in blend_desc.RenderTarget {
		rt = {
			BlendEnable           = false,
			SrcBlend              = .ONE,
			DestBlend             = .ZERO,
			BlendOp               = .ADD,
			SrcBlendAlpha         = .ONE,
			DestBlendAlpha        = .ZERO,
			BlendOpAlpha          = .ADD,
			RenderTargetWriteMask = u8(d3d11.COLOR_WRITE_ENABLE_ALL),
		}
	}
	if device->CreateBlendState(&blend_desc, &s.blend_state) < 0 {return}

	// Cube geometry — vertices and winding copied from App::Initialize.
	vertices := [8]Vertex{
		{{-1.0, 1.0, -1.0}, {0.0, 0.0, 1.0, 1.0}},
		{{1.0, 1.0, -1.0}, {0.0, 1.0, 0.0, 1.0}},
		{{1.0, 1.0, 1.0}, {0.0, 1.0, 1.0, 1.0}},
		{{-1.0, 1.0, 1.0}, {1.0, 0.0, 0.0, 1.0}},
		{{-1.0, -1.0, -1.0}, {1.0, 0.0, 1.0, 1.0}},
		{{1.0, -1.0, -1.0}, {1.0, 1.0, 0.0, 1.0}},
		{{1.0, -1.0, 1.0}, {1.0, 1.0, 1.0, 1.0}},
		{{-1.0, -1.0, 1.0}, {0.0, 0.0, 0.0, 1.0}},
	}
	indices := [36]u32{
		3, 1, 0, 2, 1, 3,
		0, 5, 4, 1, 5, 0,
		3, 4, 7, 0, 4, 3,
		1, 6, 5, 2, 6, 1,
		2, 7, 6, 3, 7, 2,
		6, 4, 5, 7, 4, 6,
	}

	// Immutable vertex/index buffers, as BufferConfigDX11's non-dynamic
	// defaults produce.
	vb_desc := d3d11.BUFFER_DESC {
		ByteWidth = size_of(vertices),
		Usage     = .IMMUTABLE,
		BindFlags = {.VERTEX_BUFFER},
	}
	vb_data := d3d11.SUBRESOURCE_DATA {
		pSysMem = &vertices[0],
	}
	if device->CreateBuffer(&vb_desc, &vb_data, &s.vertex_buffer) < 0 {return}

	ib_desc := d3d11.BUFFER_DESC {
		ByteWidth = size_of(indices),
		Usage     = .IMMUTABLE,
		BindFlags = {.INDEX_BUFFER},
	}
	ib_data := d3d11.SUBRESOURCE_DATA {
		pSysMem = &indices[0],
	}
	if device->CreateBuffer(&ib_desc, &ib_data, &s.index_buffer) < 0 {return}

	// Constant buffer for the shader's Transforms cbuffer. The engine's
	// ParameterManager creates its cbuffers dynamic and maps them; same here.
	cb_desc := d3d11.BUFFER_DESC {
		ByteWidth      = size_of(Transforms),
		Usage          = .DYNAMIC,
		BindFlags      = {.CONSTANT_BUFFER},
		CPUAccessFlags = {.WRITE},
	}
	if device->CreateBuffer(&cb_desc, nil, &s.constant_buffer) < 0 {return}

	// The "camera" from App::Initialize: XMMatrixLookAtLH /
	// XMMatrixPerspectiveFovLH with the same arguments, via glyph:camera's
	// LH 0..1-depth helpers.
	s.view = camera.look_at_lh({0.0, 1.0, -5.0}, {0.0, 1.0, 0.0}, {0.0, 1.0, 0.0})
	s.proj = camera.perspective_fov_lh(linalg.PI / 2.0, f32(WIDTH) / f32(HEIGHT), 0.01, 100.0)

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
	// The C++ App::GetName() returns "BasicApplication" — a copy-paste quirk
	// in the original sample, preserved here.
	window.set_caption(&win, "BasicApplication")
	window.initialize(&win, &handler)
	defer window.shutdown(&win)

	r, renderer_ok := renderer.create(win.hwnd, WIDTH, HEIGHT, ._10_0)
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
			win32.utf8_to_wstring(fmt.tprintf("Scene setup failed at step: %s", g_step)),
			win32.L("RotatingCube setup failed"),
			win32.MB_ICONEXCLAMATION | win32.MB_SYSTEMMODAL,
		)
		return
	}
	defer scene_destroy(&scene)

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

		// App::Update — clear, animate the world matrix, draw, present.
		t := f32(time.duration_seconds(time.tick_since(start)))

		// C++ (row-vector): RotationMatrixY(t) * RotationMatrixX(t) — Y
		// first, then X. Column-vector equivalent: rotate_x * rotate_y.
		world := linalg.matrix4_rotate_f32(t, {1, 0, 0}) * linalg.matrix4_rotate_f32(t, {0, 1, 0})
		world_view_proj := scene.proj * scene.view * world

		color := [4]f32{0.0, 0.0, 0.0, 0.0}
		ctx->ClearRenderTargetView(r.rtv, &color)
		ctx->ClearDepthStencilView(r.dsv, {.DEPTH}, 1.0, 0)

		// Upload WorldViewProjMatrix (no transpose — see glyph:shader).
		mapped: d3d11.MAPPED_SUBRESOURCE
		if ctx->Map((^d3d11.IResource)(scene.constant_buffer), 0, .WRITE_DISCARD, {}, &mapped) >= 0 {
			(^Transforms)(mapped.pData).world_view_proj = world_view_proj
			ctx->Unmap((^d3d11.IResource)(scene.constant_buffer), 0)
		}

		// PipelineManagerDX11::Draw, unrolled: IA, shader stages, states,
		// then the indexed draw.
		ctx->IASetInputLayout(scene.input_layout)
		stride: u32 = size_of(Vertex)
		offset: u32 = 0
		ctx->IASetVertexBuffers(0, 1, &scene.vertex_buffer, &stride, &offset)
		ctx->IASetIndexBuffer(scene.index_buffer, .R32_UINT, 0)
		ctx->IASetPrimitiveTopology(.TRIANGLELIST)

		ctx->VSSetShader(scene.vertex_shader, nil, 0)
		ctx->GSSetShader(scene.geometry_shader, nil, 0)
		ctx->PSSetShader(scene.pixel_shader, nil, 0)

		// Only the geometry shader declares the Transforms cbuffer, so
		// that's the only stage it needs binding to.
		ctx->GSSetConstantBuffers(0, 1, &scene.constant_buffer)

		ctx->RSSetState(scene.rasterizer_state)
		// The C++ passes the depth-stencil state's *index* as the stencil
		// ref — harmless since stenciling is disabled; 0 here.
		ctx->OMSetDepthStencilState(scene.depth_stencil_state, 0)
		blend_factor := [4]f32{1, 1, 1, 1}
		ctx->OMSetBlendState(scene.blend_state, &blend_factor, 0xffffffff)

		ctx->DrawIndexed(36, 0, 0)

		renderer.present(&r)

		// Application::TakeScreenShot — Space; prefix is GetName(), i.e. the
		// "BasicApplication" quirk again.
		if state.save_screenshot {
			state.save_screenshot = false
			screenshot_number += 1
			renderer.save_backbuffer_png(&r, fmt.tprintf("BasicApplication%d.png", screenshot_number))
		}
	}
}
