// Odin port of the BasicComputeShader sample
// (Applications/BasicComputeShader/App.cpp).
//
// The book's first compute pipeline (chapter 5), and the first sample to
// need a feature level 11.0 device (cs_5_0). Each frame:
//
//   1. Compute pass — InvertColorCS.hlsl reads Outcrop.png through an SRV
//      (InputMap, t0) and writes the inverted color to a second texture
//      through a UAV (OutputMap, u0). Thread groups are 20x20 ([numthreads]
//      in the shader), dispatched 32x24 to cover the 640x480 image exactly.
//   2. Unbind — the CS's SRV and UAV are cleared so the output texture can
//      be read in step 3 (a resource can't be bound as UAV and SRV at once;
//      the C++ does this via ClearPipelineResources).
//   3. Fullscreen pass — a clip-space quad (TextureVS.hlsl passthrough) with
//      TexturePS.hlsl Loading the filtered texture per pixel (ColorMap00,
//      t0). The PS SRV is unbound after the draw so next frame's compute
//      pass can write the UAV again.
//
// Faithful details: the output texture is R16G16B16A16_FLOAT — the engine's
// SetColorBuffer default, not RGBA8. The input texture gets the _SRGB format
// because Outcrop.png carries sRGB/gAMA metadata (see glyph:renderer's
// loader) — without this the inverted output is uniformly wrong by a gamma
// curve. The C++'s fullscreen quad also carries a TEXCOORDS element that
// TextureVS never reads; the vertex buffer here keeps just the clip-space
// positions. Esc quits; Space saves BasicComputeShader<n>.png.
package main

import "core:fmt"
import win32 "core:sys/windows"
import d3d11 "vendor:directx/d3d11"
import "glyph:renderer"
import "glyph:shader"
import "glyph:window"

WIDTH :: 640
HEIGHT :: 480

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
	input_texture:  ^d3d11.ITexture2D,
	input_srv:      ^d3d11.IShaderResourceView,
	output_texture: ^d3d11.ITexture2D,
	output_uav:     ^d3d11.IUnorderedAccessView,
	output_srv:     ^d3d11.IShaderResourceView,
	compute_shader: ^d3d11.IComputeShader,
	vertex_shader:  ^d3d11.IVertexShader,
	pixel_shader:   ^d3d11.IPixelShader,
	input_layout:   ^d3d11.IInputLayout,
	vertex_buffer:  ^d3d11.IBuffer,
	index_buffer:   ^d3d11.IBuffer,
}

scene_destroy :: proc(s: ^Scene) {
	if s.index_buffer != nil {s.index_buffer->Release()}
	if s.vertex_buffer != nil {s.vertex_buffer->Release()}
	if s.input_layout != nil {s.input_layout->Release()}
	if s.pixel_shader != nil {s.pixel_shader->Release()}
	if s.vertex_shader != nil {s.vertex_shader->Release()}
	if s.compute_shader != nil {s.compute_shader->Release()}
	if s.output_srv != nil {s.output_srv->Release()}
	if s.output_uav != nil {s.output_uav->Release()}
	if s.output_texture != nil {s.output_texture->Release()}
	if s.input_srv != nil {s.input_srv->Release()}
	if s.input_texture != nil {s.input_texture->Release()}
	s^ = {}
}

setup :: proc(r: ^renderer.Renderer) -> (s: Scene, ok: bool) {
	device := r.device

	// The input image, loaded as in RendererDX11::LoadTexture.
	s.input_texture, s.input_srv = renderer.load_texture_png(r, "Outcrop.png") or_return

	// Shaders — same entry points and SM 5.0 targets as the C++ LoadShader
	// calls.
	cs_blob := shader.compile("InvertColorCS.hlsl", "CSMAIN", "cs_5_0") or_return
	defer cs_blob->Release()
	vs_blob := shader.compile("TextureVS.hlsl", "VSMAIN", "vs_5_0") or_return
	defer vs_blob->Release()
	ps_blob := shader.compile("TexturePS.hlsl", "PSMAIN", "ps_5_0") or_return
	defer ps_blob->Release()

	if device->CreateComputeShader(cs_blob->GetBufferPointer(), cs_blob->GetBufferSize(), nil, &s.compute_shader) < 0 {return}
	if device->CreateVertexShader(vs_blob->GetBufferPointer(), vs_blob->GetBufferSize(), nil, &s.vertex_shader) < 0 {return}
	if device->CreatePixelShader(ps_blob->GetBufferPointer(), ps_blob->GetBufferSize(), nil, &s.pixel_shader) < 0 {return}

	// Output texture for the compute shader, per Texture2dConfigDX11::
	// SetColorBuffer (R16G16B16A16_FLOAT) with the bind flags the app
	// overrides to UAV | SRV.
	output_desc := d3d11.TEXTURE2D_DESC {
		Width      = WIDTH,
		Height     = HEIGHT,
		MipLevels  = 1,
		ArraySize  = 1,
		Format     = .R16G16B16A16_FLOAT,
		SampleDesc = {Count = 1, Quality = 0},
		Usage      = .DEFAULT,
		BindFlags  = {.UNORDERED_ACCESS, .SHADER_RESOURCE},
	}
	if device->CreateTexture2D(&output_desc, nil, &s.output_texture) < 0 {return}
	if device->CreateUnorderedAccessView((^d3d11.IResource)(s.output_texture), nil, &s.output_uav) < 0 {return}
	if device->CreateShaderResourceView((^d3d11.IResource)(s.output_texture), nil, &s.output_srv) < 0 {return}

	// Fullscreen quad from GenerateFullScreenQuad: clip-space corner
	// positions, two triangles wound (0,2,1), (1,2,3).
	vertices := [4][4]f32{
		{-1.0, 1.0, 0.0, 1.0}, // upper left
		{-1.0, -1.0, 0.0, 1.0}, // lower left
		{1.0, 1.0, 0.0, 1.0}, // upper right
		{1.0, -1.0, 0.0, 1.0}, // lower right
	}
	indices := [6]u32{0, 2, 1, 1, 2, 3}

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

	layout := [1]d3d11.INPUT_ELEMENT_DESC{
		{"POSITION", 0, .R32G32B32A32_FLOAT, 0, 0, .VERTEX_DATA, 0},
	}
	if device->CreateInputLayout(&layout[0], 1, vs_blob->GetBufferPointer(), vs_blob->GetBufferSize(), &s.input_layout) < 0 {return}

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
	window.set_caption(&win, "BasicComputeShader")
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
			win32.L("BasicComputeShader setup failed"),
			win32.MB_ICONEXCLAMATION | win32.MB_SYSTEMMODAL,
		)
		return
	}
	defer scene_destroy(&scene)

	ctx := r.ctx
	screenshot_number := 100_000

	null_srv: ^d3d11.IShaderResourceView
	null_uav: ^d3d11.IUnorderedAccessView

	msg: win32.MSG
	for {
		for win32.PeekMessageW(&msg, nil, 0, 0, win32.PM_REMOVE) {
			if msg.message == win32.WM_QUIT {
				return
			}

			win32.TranslateMessage(&msg)
			win32.DispatchMessageW(&msg)
		}

		// Compute pass: PipelineManagerDX11::Dispatch(effect, 32, 24, 1).
		ctx->CSSetShader(scene.compute_shader, nil, 0)
		ctx->CSSetShaderResources(0, 1, &scene.input_srv)
		ctx->CSSetUnorderedAccessViews(0, 1, &scene.output_uav, nil)
		ctx->Dispatch(32, 24, 1)

		// ClearPipelineResources: release the CS bindings so the output
		// texture can be bound as the pixel shader's SRV below.
		ctx->CSSetShaderResources(0, 1, &null_srv)
		ctx->CSSetUnorderedAccessViews(0, 1, &null_uav, nil)

		// Fullscreen pass: clear, then draw the quad sampling the result.
		color := [4]f32{0.0, 0.0, 0.0, 0.0}
		ctx->ClearRenderTargetView(r.rtv, &color)
		ctx->ClearDepthStencilView(r.dsv, {.DEPTH}, 1.0, 0)

		ctx->IASetInputLayout(scene.input_layout)
		stride: u32 = size_of([4]f32)
		offset: u32 = 0
		ctx->IASetVertexBuffers(0, 1, &scene.vertex_buffer, &stride, &offset)
		ctx->IASetIndexBuffer(scene.index_buffer, .R32_UINT, 0)
		ctx->IASetPrimitiveTopology(.TRIANGLELIST)
		ctx->VSSetShader(scene.vertex_shader, nil, 0)
		ctx->PSSetShader(scene.pixel_shader, nil, 0)
		ctx->PSSetShaderResources(0, 1, &scene.output_srv)

		ctx->DrawIndexed(6, 0, 0)

		// Unbind the PS SRV so next frame's compute pass can write the UAV
		// without D3D force-unbinding it (and warning).
		ctx->PSSetShaderResources(0, 1, &null_srv)

		renderer.present(&r)

		// Application::TakeScreenShot — Space (GetName() is correct in this
		// sample, unlike RotatingCube's).
		if state.save_screenshot {
			state.save_screenshot = false
			screenshot_number += 1
			renderer.save_backbuffer_png(&r, fmt.tprintf("BasicComputeShader%d.png", screenshot_number))
		}
	}
}
