// Odin port of the ImageProcessor sample (Applications/ImageProcessor) —
// the chapter-10 compute-shader image filters. Text overlay omitted (out of
// scope for these ports); everything else matches the C++:
//
//   - Five images (Outcrop, fruit, Hex, EyeOfHorus, Tiles), cycled with I.
//     Switching images resizes the intermediate/output textures.
//   - Five filter algorithms, cycled with N: brute-force Gaussian, separable
//     Gaussian, cached (groupshared) separable Gaussian, brute-force
//     bilateral, separable bilateral — the chapter's "correct compute → fast
//     compute" progression, shaders used unchanged. Separable variants run
//     an X pass into an intermediate texture and a Y pass into the output
//     (SRV/UAV unbinds between passes).
//   - Two samplers for the fullscreen viewer, cycled with Space (!) — linear
//     wrap vs. linear border-black. This app repurposes Space, so there is
//     no screenshot key, exactly like the C++.
//   - Left-drag pans, right-drag and the mouse wheel zoom — implemented in
//     ImageViewerVS.hlsl from the WindowSize/ImageSize/ViewingParams
//     constants this app maintains.
//   - Rendering is event-driven, mirroring the C++'s overridden MessageLoop:
//     a blocking GetMessage pump, re-rendering only when the window is
//     invalidated (input, resize, WM_PAINT). The CPU idles otherwise.
package main

import win32 "core:sys/windows"
import d3d11 "vendor:directx/d3d11"
import "glyph:renderer"
import "glyph:shader"
import "glyph:window"

WIDTH :: 1024
HEIGHT :: 640

// The viewer VS's ImageViewingData cbuffer.
Image_Viewing_Data :: struct #align (16) {
	window_size:    [4]f32,
	image_size:     [4]f32,
	viewing_params: [4]f32,
}

// Mouse pan/zoom state, mirroring the C++'s m_UIData + the pieces of
// App::HandleMouseMove / HandleMouseWheel.
App_State :: struct {
	render_requested: bool,
	next_image:       bool,
	next_algorithm:   bool,
	next_sampler:     bool,
	pending_resize:   [2]u32,
	viewing_params:   [4]f32,
	l_down:           bool,
	r_down:           bool,
	last:             [2]i32,
}

message_callback :: proc(data: rawptr, hwnd: win32.HWND, msg: win32.UINT, wparam: win32.WPARAM, lparam: win32.LPARAM) -> win32.LRESULT {
	state := cast(^App_State)data

	switch msg {
	case win32.WM_DESTROY:
		win32.PostQuitMessage(0)
		return 0

	// The C++ renders inside WM_PAINT; here the paint is validated and the
	// main loop renders right after dispatch.
	case win32.WM_PAINT:
		ps: win32.PAINTSTRUCT
		win32.BeginPaint(hwnd, &ps)
		win32.EndPaint(hwnd, &ps)
		state.render_requested = true
		return 0

	case win32.WM_KEYUP:
		invalidate := true
		switch wparam {
		case win32.WPARAM('N'):
			state.next_algorithm = true
		case win32.WPARAM('I'):
			state.next_image = true
		case win32.WPARAM(win32.VK_SPACE):
			state.next_sampler = true
		case win32.WPARAM(win32.VK_ESCAPE):
			win32.PostQuitMessage(0)
			return 0
		case:
			invalidate = false
		}
		if invalidate {
			win32.InvalidateRect(hwnd, nil, false)
		}

	case win32.WM_MOUSEMOVE:
		x := i32(i16(lparam & 0xffff))
		y := i32(i16((lparam >> 16) & 0xffff))
		l_button := wparam & 0x01 != 0 // MK_LBUTTON
		r_button := wparam & 0x02 != 0 // MK_RBUTTON

		if l_button {
			// Panning; deltas are last - current, divided by zoom.
			if state.l_down {
				state.viewing_params[0] += f32(state.last.x - x) / state.viewing_params[2]
				state.viewing_params[1] += f32(state.last.y - y) / state.viewing_params[3]
			}
			state.l_down = true
			state.r_down = false
			state.last = {x, y}
		} else {
			state.l_down = false
			if r_button {
				// Zooming on vertical drag.
				if state.r_down {
					dy := f32(state.last.y - y)
					state.viewing_params[2] += dy * 0.001
					state.viewing_params[3] += dy * 0.001
				}
				state.r_down = true
				state.last = {x, y}
			} else {
				state.r_down = false
			}
		}
		win32.InvalidateRect(hwnd, nil, false)

	case win32.WM_MOUSEWHEEL:
		delta := f32(i16((wparam >> 16) & 0xffff))
		state.viewing_params[2] += delta * 0.0001
		state.viewing_params[3] += delta * 0.0001
		win32.InvalidateRect(hwnd, nil, false)

	case win32.WM_SIZE:
		state.pending_resize = {u32(lparam & 0xffff), u32((lparam >> 16) & 0xffff)}
	}

	return win32.DefWindowProcW(hwnd, msg, wparam, lparam)
}

// A filterable image: the loaded texture's SRV plus its dimensions.
Source_Image :: struct {
	texture: ^d3d11.ITexture2D,
	srv:     ^d3d11.IShaderResourceView,
	width:   u32,
	height:  u32,
}

// An R16G16B16A16_FLOAT UAV+SRV texture (SetColorBuffer + the app's bind
// flags), used for the intermediate and output filter targets.
Filter_Target :: struct {
	texture: ^d3d11.ITexture2D,
	srv:     ^d3d11.IShaderResourceView,
	uav:     ^d3d11.IUnorderedAccessView,
}

filter_target_destroy :: proc(t: ^Filter_Target) {
	if t.uav != nil {t.uav->Release()}
	if t.srv != nil {t.srv->Release()}
	if t.texture != nil {t.texture->Release()}
	t^ = {}
}

create_filter_target :: proc(r: ^renderer.Renderer, width, height: u32) -> (t: Filter_Target, ok: bool) {
	desc := d3d11.TEXTURE2D_DESC {
		Width      = width,
		Height     = height,
		MipLevels  = 1,
		ArraySize  = 1,
		Format     = .R16G16B16A16_FLOAT,
		SampleDesc = {Count = 1, Quality = 0},
		Usage      = .DEFAULT,
		BindFlags  = {.UNORDERED_ACCESS, .SHADER_RESOURCE},
	}
	if r.device->CreateTexture2D(&desc, nil, &t.texture) < 0 {return}
	if r.device->CreateShaderResourceView((^d3d11.IResource)(t.texture), nil, &t.srv) < 0 {return}
	if r.device->CreateUnorderedAccessView((^d3d11.IResource)(t.texture), nil, &t.uav) < 0 {return}
	return t, true
}

Pipeline :: struct {
	// Compute shaders per algorithm; separable ones as {X, Y} pairs.
	cs_gaussian_brute:     ^d3d11.IComputeShader,
	cs_gaussian_separable: [2]^d3d11.IComputeShader,
	cs_gaussian_cached:    [2]^d3d11.IComputeShader,
	cs_bilateral_brute:    ^d3d11.IComputeShader,
	cs_bilateral_separable: [2]^d3d11.IComputeShader,
	// Fullscreen viewer.
	vertex_shader: ^d3d11.IVertexShader,
	pixel_shader:  ^d3d11.IPixelShader,
	input_layout:  ^d3d11.IInputLayout,
	quad_vb:       ^d3d11.IBuffer,
	quad_ib:       ^d3d11.IBuffer,
	cb_viewing:    ^d3d11.IBuffer,
	samplers:      [2]^d3d11.ISamplerState,
}

pipeline_destroy :: proc(p: ^Pipeline) {
	release :: proc(obj: ^$T) {
		if obj != nil {obj->Release()}
	}
	release(p.samplers[1])
	release(p.samplers[0])
	release(p.cb_viewing)
	release(p.quad_ib)
	release(p.quad_vb)
	release(p.input_layout)
	release(p.pixel_shader)
	release(p.vertex_shader)
	release(p.cs_bilateral_separable[1])
	release(p.cs_bilateral_separable[0])
	release(p.cs_bilateral_brute)
	release(p.cs_gaussian_cached[1])
	release(p.cs_gaussian_cached[0])
	release(p.cs_gaussian_separable[1])
	release(p.cs_gaussian_separable[0])
	release(p.cs_gaussian_brute)
	p^ = {}
}

create_compute :: proc(device: ^d3d11.IDevice, file, entry: string) -> (cs: ^d3d11.IComputeShader, ok: bool) {
	blob := shader.compile(file, entry, "cs_5_0") or_return
	defer blob->Release()
	if device->CreateComputeShader(blob->GetBufferPointer(), blob->GetBufferSize(), nil, &cs) < 0 {
		return
	}
	return cs, true
}

create_pipeline :: proc(r: ^renderer.Renderer) -> (p: Pipeline, ok: bool) {
	device := r.device

	p.cs_gaussian_brute = create_compute(device, "GaussianBruteForceCS.hlsl", "CSMAIN") or_return
	p.cs_gaussian_separable[0] = create_compute(device, "GaussianSeparableCS.hlsl", "CSMAINX") or_return
	p.cs_gaussian_separable[1] = create_compute(device, "GaussianSeparableCS.hlsl", "CSMAINY") or_return
	p.cs_gaussian_cached[0] = create_compute(device, "GaussianCachedCS.hlsl", "CSMAINX") or_return
	p.cs_gaussian_cached[1] = create_compute(device, "GaussianCachedCS.hlsl", "CSMAINY") or_return
	p.cs_bilateral_brute = create_compute(device, "BilateralBruteForceCS.hlsl", "CSMAIN") or_return
	p.cs_bilateral_separable[0] = create_compute(device, "BilateralSeparableCS.hlsl", "CSMAINX") or_return
	p.cs_bilateral_separable[1] = create_compute(device, "BilateralSeparableCS.hlsl", "CSMAINY") or_return

	vs_blob := shader.compile("ImageViewerVS.hlsl", "VSMAIN", "vs_5_0") or_return
	defer vs_blob->Release()
	ps_blob := shader.compile("ImageViewerPS.hlsl", "PSMAIN", "ps_5_0") or_return
	defer ps_blob->Release()

	if device->CreateVertexShader(vs_blob->GetBufferPointer(), vs_blob->GetBufferSize(), nil, &p.vertex_shader) < 0 {return}
	if device->CreatePixelShader(ps_blob->GetBufferPointer(), ps_blob->GetBufferSize(), nil, &p.pixel_shader) < 0 {return}

	// GenerateFullScreenQuad's vertices: clip-space float4 positions plus
	// texcoords — note the engine's "TEXCOORDS" semantic name, which the
	// viewer VS declares too.
	Quad_Vertex :: struct {
		position: [4]f32,
		tex:      [2]f32,
	}
	vertices := [4]Quad_Vertex{
		{{-1, 1, 0, 1}, {0, 0}},
		{{-1, -1, 0, 1}, {0, 1}},
		{{1, 1, 0, 1}, {1, 0}},
		{{1, -1, 0, 1}, {1, 1}},
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
	if device->CreateBuffer(&vb_desc, &vb_data, &p.quad_vb) < 0 {return}

	ib_desc := d3d11.BUFFER_DESC {
		ByteWidth = size_of(indices),
		Usage     = .IMMUTABLE,
		BindFlags = {.INDEX_BUFFER},
	}
	ib_data := d3d11.SUBRESOURCE_DATA {
		pSysMem = &indices[0],
	}
	if device->CreateBuffer(&ib_desc, &ib_data, &p.quad_ib) < 0 {return}

	elements := [2]d3d11.INPUT_ELEMENT_DESC{
		{"POSITION", 0, .R32G32B32A32_FLOAT, 0, 0, .VERTEX_DATA, 0},
		{"TEXCOORDS", 0, .R32G32_FLOAT, 0, 16, .VERTEX_DATA, 0},
	}
	if device->CreateInputLayout(&elements[0], 2, vs_blob->GetBufferPointer(), vs_blob->GetBufferSize(), &p.input_layout) < 0 {return}

	cb_desc := d3d11.BUFFER_DESC {
		ByteWidth      = size_of(Image_Viewing_Data),
		Usage          = .DYNAMIC,
		BindFlags      = {.CONSTANT_BUFFER},
		CPUAccessFlags = {.WRITE},
	}
	if device->CreateBuffer(&cb_desc, nil, &p.cb_viewing) < 0 {return}

	// Sampler 0: engine defaults (linear/wrap). Sampler 1: linear/border,
	// black border — cycled with Space.
	sampler_desc := d3d11.SAMPLER_DESC {
		Filter         = .MIN_MAG_MIP_LINEAR,
		AddressU       = .WRAP,
		AddressV       = .WRAP,
		AddressW       = .WRAP,
		MaxAnisotropy  = 1,
		ComparisonFunc = .NEVER,
		MaxLOD         = d3d11.FLOAT32_MAX,
	}
	if device->CreateSamplerState(&sampler_desc, &p.samplers[0]) < 0 {return}
	sampler_desc.AddressU = .BORDER
	sampler_desc.AddressV = .BORDER
	sampler_desc.AddressW = .BORDER
	if device->CreateSamplerState(&sampler_desc, &p.samplers[1]) < 0 {return}

	return p, true
}

// One compute pass: bind, dispatch, unbind (the C++'s Dispatch +
// ClearPipelineResources sequence, upholding the no-simultaneous-SRV-and-UAV
// rule before the next pass reads what this one wrote).
dispatch_filter :: proc(
	ctx: ^d3d11.IDeviceContext,
	cs: ^d3d11.IComputeShader,
	input: ^d3d11.IShaderResourceView,
	output: ^d3d11.IUnorderedAccessView,
	x, y: u32,
) {
	input := input
	output := output
	null_srv: ^d3d11.IShaderResourceView
	null_uav: ^d3d11.IUnorderedAccessView

	ctx->CSSetShader(cs, nil, 0)
	ctx->CSSetShaderResources(0, 1, &input)
	ctx->CSSetUnorderedAccessViews(0, 1, &output, nil)
	ctx->Dispatch(x, y, 1)
	ctx->CSSetShaderResources(0, 1, &null_srv)
	ctx->CSSetUnorderedAccessViews(0, 1, &null_uav, nil)
}

main :: proc() {
	state := App_State {
		viewing_params = {0.5, 0.5, 1.0, 1.0},
	}
	handler := window.Handler {
		data     = &state,
		callback = message_callback,
	}

	win := window.render_window_default()
	win.width = WIDTH
	win.height = HEIGHT
	window.set_caption(&win, "ImageProcessor")
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
			win32.L("ImageProcessor setup failed"),
			win32.MB_ICONEXCLAMATION | win32.MB_SYSTEMMODAL,
		)
		return
	}
	defer pipeline_destroy(&pipeline)

	// The five images.
	image_names := [5]string{"Outcrop.png", "fruit.png", "Hex.png", "EyeOfHorus.png", "Tiles.png"}
	images: [5]Source_Image
	defer for &img in images {
		if img.srv != nil {img.srv->Release()}
		if img.texture != nil {img.texture->Release()}
	}
	for name, i in image_names {
		texture, srv, load_ok := renderer.load_texture_png(&r, name)
		if !load_ok {
			win32.MessageBoxW(nil, win32.L("Failed to load an image - see stderr."), win32.L("ImageProcessor"), win32.MB_ICONEXCLAMATION)
			return
		}
		desc: d3d11.TEXTURE2D_DESC
		texture->GetDesc(&desc)
		images[i] = {texture, srv, desc.Width, desc.Height}
	}

	image_index := 0
	algorithm := 0
	sampler_index := 0

	intermediate, im_ok := create_filter_target(&r, images[0].width, images[0].height)
	output, out_ok := create_filter_target(&r, images[0].width, images[0].height)
	if !im_ok || !out_ok {
		return
	}
	defer filter_target_destroy(&intermediate)
	defer filter_target_destroy(&output)

	ctx := r.ctx
	null_srv: ^d3d11.IShaderResourceView

	// Blocking pump, mirroring the C++'s overridden MessageLoop: GetMessage
	// returns false on WM_QUIT. Window creation already queued the first
	// WM_PAINT.
	msg: win32.MSG
	// GetMessage: > 0 = message, 0 = WM_QUIT, -1 = error.
	for int(win32.GetMessageW(&msg, nil, 0, 0)) > 0 {
		win32.TranslateMessage(&msg)
		win32.DispatchMessageW(&msg)

		// App state changes requested by the handler.
		if state.pending_resize != {0, 0} {
			renderer.resize(&r, state.pending_resize.x, state.pending_resize.y)
			state.pending_resize = {0, 0}
		}
		if state.next_algorithm {
			state.next_algorithm = false
			algorithm = (algorithm + 1) % 5
		}
		if state.next_sampler {
			state.next_sampler = false
			sampler_index = (sampler_index + 1) % 2
		}
		if state.next_image {
			state.next_image = false
			image_index = (image_index + 1) % len(images)
			filter_target_destroy(&intermediate)
			filter_target_destroy(&output)
			img := &images[image_index]
			intermediate, _ = create_filter_target(&r, img.width, img.height)
			output, _ = create_filter_target(&r, img.width, img.height)
		}

		if !state.render_requested {
			continue
		}
		state.render_requested = false

		img := &images[image_index]
		iw := f32(img.width)
		ih := f32(img.height)

		// Filter pass(es) — dispatch sizes exactly as App::Update.
		switch algorithm {
		case 0:
			dispatch_filter(ctx, pipeline.cs_gaussian_brute, img.srv, output.uav,
				u32((iw + 31) / 32), u32((ih + 31) / 32))
		case 1, 2, 4:
			pair: [2]^d3d11.IComputeShader
			switch algorithm {
			case 1: pair = pipeline.cs_gaussian_separable
			case 2: pair = pipeline.cs_gaussian_cached
			case 4: pair = pipeline.cs_bilateral_separable
			}
			dispatch_filter(ctx, pair[0], img.srv, intermediate.uav,
				u32((iw + 639) / 640), img.height)
			dispatch_filter(ctx, pair[1], intermediate.srv, output.uav,
				img.width, u32((ih + 479) / 480))
		case 3:
			dispatch_filter(ctx, pipeline.cs_bilateral_brute, img.srv, output.uav,
				u32((iw + 31) / 32), u32((ih + 31) / 32))
		}

		// Viewer pass.
		clear_color := [4]f32{0.2, 0.2, 0.2, 0.2}
		ctx->ClearRenderTargetView(r.rtv, &clear_color)
		ctx->ClearDepthStencilView(r.dsv, {.DEPTH}, 1.0, 0)

		viewing := Image_Viewing_Data {
			window_size    = {f32(r.width), f32(r.height), 0, 0},
			image_size     = {iw, ih, 0, 0},
			viewing_params = state.viewing_params,
		}
		mapped: d3d11.MAPPED_SUBRESOURCE
		if ctx->Map((^d3d11.IResource)(pipeline.cb_viewing), 0, .WRITE_DISCARD, {}, &mapped) >= 0 {
			(^Image_Viewing_Data)(mapped.pData)^ = viewing
			ctx->Unmap((^d3d11.IResource)(pipeline.cb_viewing), 0)
		}

		ctx->IASetInputLayout(pipeline.input_layout)
		stride: u32 = 24
		offset: u32 = 0
		ctx->IASetVertexBuffers(0, 1, &pipeline.quad_vb, &stride, &offset)
		ctx->IASetIndexBuffer(pipeline.quad_ib, .R32_UINT, 0)
		ctx->IASetPrimitiveTopology(.TRIANGLELIST)
		ctx->VSSetShader(pipeline.vertex_shader, nil, 0)
		ctx->VSSetConstantBuffers(0, 1, &pipeline.cb_viewing)
		ctx->PSSetShader(pipeline.pixel_shader, nil, 0)
		ctx->PSSetShaderResources(0, 1, &output.srv)
		ctx->PSSetSamplers(0, 1, &pipeline.samplers[sampler_index])

		ctx->DrawIndexed(6, 0, 0)

		// Release the output SRV so the next frame's compute pass can write
		// the UAV without a forced unbind.
		ctx->PSSetShaderResources(0, 1, &null_srv)

		renderer.present(&r)
	}
}
