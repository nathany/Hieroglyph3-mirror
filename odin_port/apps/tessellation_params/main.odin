// Odin port of the TessellationParams sample
// (Applications/TessellationParams) — the chapter-4 interactive tessellation
// parameter explorer. A single quad or triangle patch is drawn wireframe on
// white while you vary every tessellator input live:
//
//   - G toggles quad/triangle domain.
//   - P cycles partitioning: pow2 → integer → fractional_odd →
//     fractional_even (one hull shader compiled per mode from the same
//     source via preprocessor defines, exactly as the C++ does).
//   - E / I select edge/inside editing (pressing again cycles which
//     edge/inside factor is selected — 3/1 for tri, 4/2 for quad).
//   - Numpad +/- adjust the selected weight by 0.1, clamped to [1, 64].
//   - Esc quits, Space saves a numbered screenshot (prefixed with the C++'s
//     full GetName string, spaces and all).
//
// The C++ shows the current state as on-screen text; text rendering is out
// of scope for these ports, so the state lives in the window TITLE BAR
// instead — same information, no sprite fonts.
//
// TessellationParameters.hlsl is used unchanged: one `main` cbuffer
// (world/view-proj/weights, register b0 in every stage that uses it); the
// quad path runs the weights through Process2DQuadTessFactorsAvg.
package main

import "core:fmt"
import "core:math"
import win32 "core:sys/windows"
import d3d11 "vendor:directx/d3d11"
import "glyph:camera"
import "glyph:renderer"
import "glyph:shader"
import "glyph:window"

WIDTH :: 640
HEIGHT :: 480

// The shader's single `main` cbuffer (the float2 pads out to a 16-byte
// register).
Main_CBuffer :: struct #align (16) {
	world:          matrix[4, 4]f32,
	view_proj:      matrix[4, 4]f32,
	edge_weights:   [4]f32,
	inside_weights: [2]f32,
	_pad:           [2]f32,
}

Domain :: enum {
	Quad,
	Tri,
}

Editing :: enum {
	Edge,
	Inside,
}

PARTITION_NAMES := [4]string{"pow2", "integer", "fractional_odd", "fractional_even"}
PARTITION_DEFINES := [4]cstring{
	"POW2_PARTITIONING",
	"INTEGER_PARTITIONING",
	"FRAC_ODD_PARTITIONING",
	"FRAC_EVEN_PARTITIONING",
}

App_State :: struct {
	save_screenshot:   bool,
	toggle_geometry:   bool,
	next_partitioning: bool,
	press_e:           bool,
	press_i:           bool,
	adjust:            f32,
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
		case win32.WPARAM('G'):
			state.toggle_geometry = true
		case win32.WPARAM('P'):
			state.next_partitioning = true
		case win32.WPARAM('E'):
			state.press_e = true
		case win32.WPARAM('I'):
			state.press_i = true
		case win32.WPARAM(win32.VK_ADD):
			state.adjust += 0.1
		case win32.WPARAM(win32.VK_SUBTRACT):
			state.adjust -= 0.1
		}
	}

	return win32.DefWindowProcW(hwnd, msg, wparam, lparam)
}

// App state driven by the keyboard, mirroring the C++ members.
Tess_State :: struct {
	domain:         Domain,
	partitioning:   int,
	editing:        Editing,
	edge_index:     int,
	inside_index:   int,
	edge_weights:   [4]f32,
	inside_weights: [2]f32,
}

// The C++ SetEdgeWeight/SetInsideWeight guards: silently reject values
// outside [1, 64] and indices beyond the current domain's counts.
state_adjust :: proc(s: ^Tess_State, delta: f32) {
	switch s.editing {
	case .Edge:
		max_index := 2 if s.domain == .Tri else 3
		if s.edge_index <= max_index {
			weight := s.edge_weights[s.edge_index] + delta
			if weight >= 1.0 && weight <= 64.0 {
				s.edge_weights[s.edge_index] = weight
			}
		}
	case .Inside:
		max_index := 0 if s.domain == .Tri else 1
		if s.inside_index <= max_index {
			weight := s.inside_weights[s.inside_index] + delta
			if weight >= 1.0 && weight <= 64.0 {
				s.inside_weights[s.inside_index] = weight
			}
		}
	}
}

// The on-screen text of the C++, condensed for the title bar.
state_title :: proc(s: ^Tess_State) -> string {
	editing: string
	switch s.editing {
	case .Edge:
		editing = fmt.tprintf("editing edge %d", s.edge_index)
	case .Inside:
		editing = fmt.tprintf("editing inside %d", s.inside_index)
	}
	switch s.domain {
	case .Tri:
		return fmt.tprintf(
			"TessellationParams — tri | %s | edges [%.1f, %.1f, %.1f] inside [%.1f] | %s (G/P/E/I/+/-)",
			PARTITION_NAMES[s.partitioning],
			s.edge_weights[0], s.edge_weights[1], s.edge_weights[2],
			s.inside_weights[0], editing,
		)
	case .Quad:
		return fmt.tprintf(
			"TessellationParams — quad | %s | edges [%.1f, %.1f, %.1f, %.1f] inside [%.1f, %.1f] | %s (G/P/E/I/+/-)",
			PARTITION_NAMES[s.partitioning],
			s.edge_weights[0], s.edge_weights[1], s.edge_weights[2], s.edge_weights[3],
			s.inside_weights[0], s.inside_weights[1], editing,
		)
	}
	return ""
}

// A patch's control points: position + colour (the C++'s
// CONTROL_POINT_POSITION / COLOUR vertex elements, colours all black).
Control_Point :: struct {
	position: [3]f32,
	colour:   [4]f32,
}

Patch :: struct {
	vertex_buffer: ^d3d11.IBuffer,
	vertex_count:  u32,
	topology:      d3d11.PRIMITIVE_TOPOLOGY,
	hull_shaders:  [4]^d3d11.IHullShader,
	domain_shader: ^d3d11.IDomainShader,
}

patch_destroy :: proc(p: ^Patch) {
	if p.domain_shader != nil {p.domain_shader->Release()}
	for hs in p.hull_shaders {
		if hs != nil {hs->Release()}
	}
	if p.vertex_buffer != nil {p.vertex_buffer->Release()}
	p^ = {}
}

Scene :: struct {
	quad:            Patch,
	tri:             Patch,
	vertex_shader:   ^d3d11.IVertexShader,
	geometry_shader: ^d3d11.IGeometryShader,
	pixel_shader:    ^d3d11.IPixelShader,
	input_layout:    ^d3d11.IInputLayout,
	wireframe:       ^d3d11.IRasterizerState,
	cb_main:         ^d3d11.IBuffer,
	view_proj:       matrix[4, 4]f32,
}

scene_destroy :: proc(s: ^Scene) {
	if s.cb_main != nil {s.cb_main->Release()}
	if s.wireframe != nil {s.wireframe->Release()}
	if s.input_layout != nil {s.input_layout->Release()}
	if s.pixel_shader != nil {s.pixel_shader->Release()}
	if s.geometry_shader != nil {s.geometry_shader->Release()}
	if s.vertex_shader != nil {s.vertex_shader->Release()}
	patch_destroy(&s.tri)
	patch_destroy(&s.quad)
	s^ = {}
}

create_patch :: proc(
	device: ^d3d11.IDevice,
	points: []Control_Point,
	hs_entry, ds_entry: string,
	topology: d3d11.PRIMITIVE_TOPOLOGY,
) -> (
	p: Patch,
	ok: bool,
) {
	// One hull shader per partitioning mode, selected by a preprocessor
	// define — the [partitioning(...)] attribute can't be set at runtime.
	for define, i in PARTITION_DEFINES {
		defines := [1]cstring{define}
		blob := shader.compile_defines("TessellationParameters.hlsl", hs_entry, "hs_5_0", defines[:]) or_return
		defer blob->Release()
		if device->CreateHullShader(blob->GetBufferPointer(), blob->GetBufferSize(), nil, &p.hull_shaders[i]) < 0 {return}
	}
	ds_blob := shader.compile("TessellationParameters.hlsl", ds_entry, "ds_5_0") or_return
	defer ds_blob->Release()
	if device->CreateDomainShader(ds_blob->GetBufferPointer(), ds_blob->GetBufferSize(), nil, &p.domain_shader) < 0 {return}

	vb_desc := d3d11.BUFFER_DESC {
		ByteWidth = u32(len(points) * size_of(Control_Point)),
		Usage     = .IMMUTABLE,
		BindFlags = {.VERTEX_BUFFER},
	}
	vb_data := d3d11.SUBRESOURCE_DATA {
		pSysMem = raw_data(points),
	}
	if device->CreateBuffer(&vb_desc, &vb_data, &p.vertex_buffer) < 0 {return}

	p.vertex_count = u32(len(points))
	p.topology = topology
	return p, true
}

setup :: proc(r: ^renderer.Renderer) -> (s: Scene, ok: bool) {
	device := r.device

	vs_blob := shader.compile("TessellationParameters.hlsl", "vsMain", "vs_5_0") or_return
	defer vs_blob->Release()
	gs_blob := shader.compile("TessellationParameters.hlsl", "gsMain", "gs_5_0") or_return
	defer gs_blob->Release()
	ps_blob := shader.compile("TessellationParameters.hlsl", "psMain", "ps_5_0") or_return
	defer ps_blob->Release()

	if device->CreateVertexShader(vs_blob->GetBufferPointer(), vs_blob->GetBufferSize(), nil, &s.vertex_shader) < 0 {return}
	if device->CreateGeometryShader(gs_blob->GetBufferPointer(), gs_blob->GetBufferSize(), nil, &s.geometry_shader) < 0 {return}
	if device->CreatePixelShader(ps_blob->GetBufferPointer(), ps_blob->GetBufferSize(), nil, &s.pixel_shader) < 0 {return}

	black := [4]f32{0, 0, 0, 1}
	quad_points := [4]Control_Point{
		{{-1, 0, -1}, black},
		{{-1, 0, 1}, black},
		{{1, 0, -1}, black},
		{{1, 0, 1}, black},
	}
	tri_points := [3]Control_Point{
		{{-1, 0, -1}, black},
		{{-1, 0, 1}, black},
		{{1, 0, -1}, black},
	}

	s.quad = create_patch(device, quad_points[:], "hsQuadMain", "dsQuadMain", ._4_CONTROL_POINT_PATCHLIST) or_return
	s.tri = create_patch(device, tri_points[:], "hsTriangleMain", "dsTriangleMain", ._3_CONTROL_POINT_PATCHLIST) or_return

	elements := [2]d3d11.INPUT_ELEMENT_DESC{
		{"CONTROL_POINT_POSITION", 0, .R32G32B32_FLOAT, 0, 0, .VERTEX_DATA, 0},
		{"COLOUR", 0, .R32G32B32A32_FLOAT, 0, 12, .VERTEX_DATA, 0},
	}
	if device->CreateInputLayout(&elements[0], 2, vs_blob->GetBufferPointer(), vs_blob->GetBufferSize(), &s.input_layout) < 0 {return}

	rs_desc := d3d11.RASTERIZER_DESC {
		FillMode        = .WIREFRAME,
		CullMode        = .BACK,
		DepthClipEnable = true,
	}
	if device->CreateRasterizerState(&rs_desc, &s.wireframe) < 0 {return}

	cb_desc := d3d11.BUFFER_DESC {
		ByteWidth      = size_of(Main_CBuffer),
		Usage          = .DYNAMIC,
		BindFlags      = {.CONSTANT_BUFFER},
		CPUAccessFlags = {.WRITE},
	}
	if device->CreateBuffer(&cb_desc, nil, &s.cb_main) < 0 {return}

	// The camera from App::Initialize.
	view := camera.look_at_lh({-2, 2, -2}, {0, 0, 0}, {0, 1, 0})
	proj := camera.perspective_fov_lh(math.PI / 4, f32(WIDTH) / f32(HEIGHT), 0.1, 50.0)
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
	window.set_caption(&win, "Direct3D 11 Tessellation Parameters Demo")
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
			win32.L("TessellationParams setup failed"),
			win32.MB_ICONEXCLAMATION | win32.MB_SYSTEMMODAL,
		)
		return
	}
	defer scene_destroy(&scene)

	tess := Tess_State {
		domain         = .Quad,
		partitioning   = 1, // the C++ starts with SetPartitioningMode(Integer)
		editing        = .Edge,
		edge_weights   = {1, 1, 1, 1},
		inside_weights = {1, 1},
	}
	title_dirty := true

	ctx := r.ctx
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

		// Apply key presses to the state (App::HandleEvent).
		if state.toggle_geometry {
			state.toggle_geometry = false
			tess.domain = .Tri if tess.domain == .Quad else .Quad
			title_dirty = true
		}
		if state.next_partitioning {
			state.next_partitioning = false
			tess.partitioning = (tess.partitioning + 1) % 4
			title_dirty = true
		}
		if state.press_e {
			state.press_e = false
			if tess.editing == .Edge {
				count := 3 if tess.domain == .Tri else 4
				tess.edge_index = (tess.edge_index + 1) % count
			} else {
				tess.editing = .Edge
			}
			title_dirty = true
		}
		if state.press_i {
			state.press_i = false
			if tess.editing == .Inside {
				count := 1 if tess.domain == .Tri else 2
				tess.inside_index = (tess.inside_index + 1) % count
			} else {
				tess.editing = .Inside
			}
			title_dirty = true
		}
		for abs(state.adjust) >= 0.05 {
			step: f32 = 0.1 if state.adjust > 0 else -0.1
			state.adjust -= step
			state_adjust(&tess, step)
			title_dirty = true
		}

		if title_dirty {
			title_dirty = false
			win32.SetWindowTextW(win.hwnd, win32.utf8_to_wstring(state_title(&tess)))
		}

		patch := &scene.quad if tess.domain == .Quad else &scene.tri

		clear_color := [4]f32{1, 1, 1, 1}
		ctx->ClearRenderTargetView(r.rtv, &clear_color)
		ctx->ClearDepthStencilView(r.dsv, {.DEPTH}, 1.0, 0)

		cb := Main_CBuffer {
			world          = 1, // identity
			view_proj      = scene.view_proj,
			edge_weights   = tess.edge_weights,
			inside_weights = tess.inside_weights,
		}
		mapped: d3d11.MAPPED_SUBRESOURCE
		if ctx->Map((^d3d11.IResource)(scene.cb_main), 0, .WRITE_DISCARD, {}, &mapped) >= 0 {
			(^Main_CBuffer)(mapped.pData)^ = cb
			ctx->Unmap((^d3d11.IResource)(scene.cb_main), 0)
		}

		ctx->IASetInputLayout(scene.input_layout)
		stride: u32 = size_of(Control_Point)
		offset: u32 = 0
		ctx->IASetVertexBuffers(0, 1, &patch.vertex_buffer, &stride, &offset)
		ctx->IASetPrimitiveTopology(patch.topology)

		// The single `main` cbuffer is b0 in every stage that uses it.
		ctx->VSSetShader(scene.vertex_shader, nil, 0)
		ctx->VSSetConstantBuffers(0, 1, &scene.cb_main)
		ctx->HSSetShader(patch.hull_shaders[tess.partitioning], nil, 0)
		ctx->HSSetConstantBuffers(0, 1, &scene.cb_main)
		ctx->DSSetShader(patch.domain_shader, nil, 0)
		ctx->DSSetConstantBuffers(0, 1, &scene.cb_main)
		ctx->GSSetShader(scene.geometry_shader, nil, 0)
		ctx->GSSetConstantBuffers(0, 1, &scene.cb_main)
		ctx->PSSetShader(scene.pixel_shader, nil, 0)
		ctx->PSSetConstantBuffers(0, 1, &scene.cb_main)

		ctx->RSSetState(scene.wireframe)

		// The C++ geometry carries identity indices 0..n-1; a plain Draw is
		// equivalent.
		ctx->Draw(patch.vertex_count, 0)

		renderer.present(&r)

		if state.save_screenshot {
			state.save_screenshot = false
			screenshot_number += 1
			renderer.save_backbuffer_png(&r, fmt.tprintf("Direct3D 11 Tessellation Parameters Demo%d.png", screenshot_number))
		}
	}
}
