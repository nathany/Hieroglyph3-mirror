// Odin port of the WaterSimulationI sample (Applications/WaterSimulationI/) —
// the chapter-12 compute-shader water simulation, no text overlay (the FPS
// readout lives in the title bar instead).
//
// A 256x256 grid of water columns (height + four outflow values) lives in a
// pair of ping-ponged structured buffers. Each frame:
//
//   1. Simulation pass (ViewSimulation / WaterSimulation.hlsl): a compute
//      shader dispatched as 16x16 groups of 18x18 threads (16x16 plus a
//      one-texel perimeter loaded into group shared memory) reads the current
//      state at t0 and writes the integrated flows and heights to the new
//      state at u0, then the buffers swap roles.
//   2. Visualization pass (HeightmapVisualization.hlsl): a 256x256-vertex
//      textured plane is drawn in wireframe; the VS looks each vertex's
//      height up in the water state buffer (t0) and displaces it, coloring
//      alternate 16x16 thread-group tiles green/blue.
//
// The initial state is a big sinc-shaped splash (amplitude 40) centered at
// grid cell (32, 96), which ripples outward and reflects off the edges.
//
// The plane's node spins about Y at 0.2 rad/s with the body offset
// (-128, 0, -128) centering the grid on the origin. The C++ reuses
// RenderApplication's default camera, whose *node* sits at (0, 10, -20)
// while the app positions the body at (-100, 30.5, -100) — so the effective
// first-person camera start is the sum, (-100, 40.5, -120), rotation
// (0.307, 0.707). Right-drag look, W/S/A/D/Q/E move, Ctrl sprint, Esc quits,
// Space screenshots, resize supported.
//
// The C++ requests feature level 10_0 and cs_4_0; here it's 11_0 and _5_0
// targets like the other ports (the shader uses nothing 11-specific). The
// app also initializes a "FinalColor" shader parameter that no shader in the
// demo references — omitted.
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

WIDTH :: 800
HEIGHT :: 600
NEAR_CLIP :: 0.1
FAR_CLIP :: 1000.0

// App::Initialize dispatch dimensions: 16x16 groups of 16x16 simulation
// points; the plane has one vertex per point.
//
// Note the group *thread* count is 18x18, not 16x16 (WaterSimulation.hlsl's
// padded_x/padded_y): the interior 16x16 threads own one grid cell each, and
// the extra one-cell perimeter exists only to stage neighbor state into
// groupshared memory. Each cell's height update needs the flow values of its
// left/upper-left/top/top-right neighbors, which for edge cells live in the
// adjacent group — so without the halo those threads would have no data to
// read. The shader guards the final store on 0 < GroupThreadID < 17 so the
// perimeter threads compute but never write, otherwise every boundary cell
// would be integrated twice.
DISPATCH_X :: 16
DISPATCH_Z :: 16
POINTS_X :: DISPATCH_X * 16
POINTS_Y :: DISPATCH_Z * 16

// --- cbuffer mirrors ---------------------------------------------------------

// WaterSimulation.hlsl `TimeParameters` (b0 in the compute shader).
Time_CB :: struct #align (16) {
	time_factors:  [4]f32, // x: elapsed*2, y: framerate, z: runtime, w: frame count
	dispatch_size: [4]f32, // (16, 16, 256, 256)
}

// HeightmapVisualization.hlsl `Transforms` (b0) and `DispatchParams` (b1).
Transforms_CB :: struct #align (16) {
	world_view_proj: matrix[4, 4]f32,
}

Dispatch_CB :: struct #align (16) {
	dispatch_size: [4]f32,
}

// --- simulation state --------------------------------------------------------

// The GridPoint structured-buffer element (height + flow to the four
// neighbors in the x/y/z/w directions).
//
// This is the chapter's pipe model: each cell is a water column connected to
// its right/lower-right/below/lower-left neighbors by virtual pipes. Flow is
// integrated from the height *difference* across each pipe (times a
// gravity/area/length factor), then each height is integrated by the net flow
// in and out. Flow carries over frame to frame, which is what gives the
// surface inertia and makes waves propagate instead of just relaxing.
Grid_Point :: struct {
	height: f32,
	flow:   [4]f32,
}

#assert(size_of(Grid_Point) == 20)

// ViewSimulation's initial data: a sinc(d * 0.1) * 40 splash centered at
// grid cell (32, 96).
build_initial_state :: proc() -> []Grid_Point {
	data := make([]Grid_Point, POINTS_X * POINTS_Y)
	for j in 0 ..< POINTS_Y {
		for i in 0 ..< POINTS_X {
			x := i - 32
			y := j - 96
			d2 := f32(x * x + y * y)

			height: f32 = 40.0
			if d2 != 0 {
				r := math.sqrt(d2) * 0.1 // fFrequency
				height = 40.0 * math.sin(r) / r
			}
			data[POINTS_X * j + i] = {height = height}
		}
	}
	return data
}

// --- plane geometry (GeometryGeneratorDX11::GenerateTexturedPlane) ----------

Plane_Vertex :: struct {
	position:  [3]f32,
	texcoords: [2]f32,
}

#assert(size_of(Plane_Vertex) == 20)

build_plane :: proc() -> (vertices: []Plane_Vertex, indices: []u32) {
	vertices = make([]Plane_Vertex, POINTS_X * POINTS_Y)
	for y in 0 ..< POINTS_Y {
		for x in 0 ..< POINTS_X {
			vertices[y * POINTS_X + x] = {
				position  = {f32(x), 0, f32(y)},
				texcoords = {f32(x), f32(y)},
			}
		}
	}

	indices = make([]u32, (POINTS_X - 1) * (POINTS_Y - 1) * 6)
	n := 0
	for j in 0 ..< POINTS_Y - 1 {
		for i in 0 ..< POINTS_X - 1 {
			v := u32(j * POINTS_X + i)
			indices[n + 0] = v
			indices[n + 1] = v + POINTS_X
			indices[n + 2] = v + 1
			indices[n + 3] = v + 1
			indices[n + 4] = v + POINTS_X
			indices[n + 5] = v + POINTS_X + 1
			n += 6
		}
	}
	return
}

// --- window messages → input state ------------------------------------------

App_State :: struct {
	input:           Camera_Input,
	save_screenshot: bool,
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

	case win32.WM_RBUTTONDOWN, win32.WM_RBUTTONUP:
		state.mouse_valid = false

	case win32.WM_SIZE:
		state.pending_resize = {u32(lparam & 0xffff), u32((lparam >> 16) & 0xffff)}
	}

	return win32.DefWindowProcW(hwnd, msg, wparam, lparam)
}

// --- scene / pipeline objects ------------------------------------------------

Scene :: struct {
	// Ping-ponged water state (SRV for reading, UAV for the compute pass).
	water_buffer: [2]^d3d11.IBuffer,
	water_srv:    [2]^d3d11.IShaderResourceView,
	water_uav:    [2]^d3d11.IUnorderedAccessView,

	// The displaced plane.
	vertex_buffer: ^d3d11.IBuffer,
	index_buffer:  ^d3d11.IBuffer,
	index_count:   u32,
	plane_layout:  ^d3d11.IInputLayout,

	// Shaders.
	sim_cs:   ^d3d11.IComputeShader,
	plane_vs: ^d3d11.IVertexShader,
	plane_ps: ^d3d11.IPixelShader,

	// States.
	rs_wireframe: ^d3d11.IRasterizerState,

	// Constant buffers.
	cb_time:       ^d3d11.IBuffer, // b0 in the compute shader
	cb_transforms: ^d3d11.IBuffer, // b0 in the vertex shader
	cb_dispatch:   ^d3d11.IBuffer, // b1 in the vertex shader (constant)
}

scene_destroy :: proc(s: ^Scene) {
	release :: proc(obj: ^$T) {
		if obj != nil {
			obj->Release()
		}
	}
	release(s.cb_dispatch)
	release(s.cb_transforms)
	release(s.cb_time)
	release(s.rs_wireframe)
	release(s.plane_ps)
	release(s.plane_vs)
	release(s.sim_cs)
	release(s.plane_layout)
	release(s.index_buffer)
	release(s.vertex_buffer)
	for i in 0 ..< 2 {
		release(s.water_uav[i])
		release(s.water_srv[i])
		release(s.water_buffer[i])
	}
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

	// Shaders.
	sim_cs_blob := shader.compile("WaterSimulation.hlsl", "CSMAIN", "cs_5_0") or_return
	defer sim_cs_blob->Release()
	plane_vs_blob := shader.compile("HeightmapVisualization.hlsl", "VSMAIN", "vs_5_0") or_return
	defer plane_vs_blob->Release()
	plane_ps_blob := shader.compile("HeightmapVisualization.hlsl", "PSMAIN", "ps_5_0") or_return
	defer plane_ps_blob->Release()

	if device->CreateComputeShader(sim_cs_blob->GetBufferPointer(), sim_cs_blob->GetBufferSize(), nil, &s.sim_cs) < 0 {return}
	if device->CreateVertexShader(plane_vs_blob->GetBufferPointer(), plane_vs_blob->GetBufferSize(), nil, &s.plane_vs) < 0 {return}
	if device->CreatePixelShader(plane_ps_blob->GetBufferPointer(), plane_ps_blob->GetBufferSize(), nil, &s.plane_ps) < 0 {return}

	// The two water state buffers, both starting from the same splash. Two
	// are needed because a cell's update reads its neighbors' *previous*
	// state; updating in place would let a thread see a neighbor another
	// group had already overwritten. So one buffer is bound read-only at t0
	// and the other read-write at u0, and the roles swap each frame.
	//
	// Both are seeded so that whichever buffer happens to be read first shows
	// the splash rather than zeros.
	initial := build_initial_state()
	defer delete(initial)

	water_desc := d3d11.BUFFER_DESC {
		ByteWidth           = u32(len(initial) * size_of(Grid_Point)),
		Usage               = .DEFAULT,
		BindFlags           = {.SHADER_RESOURCE, .UNORDERED_ACCESS},
		MiscFlags           = {.BUFFER_STRUCTURED},
		StructureByteStride = size_of(Grid_Point),
	}
	water_data := d3d11.SUBRESOURCE_DATA {
		pSysMem = raw_data(initial),
	}
	for i in 0 ..< 2 {
		if device->CreateBuffer(&water_desc, &water_data, &s.water_buffer[i]) < 0 {return}
		if device->CreateShaderResourceView((^d3d11.IResource)(s.water_buffer[i]), nil, &s.water_srv[i]) < 0 {return}
		if device->CreateUnorderedAccessView((^d3d11.IResource)(s.water_buffer[i]), nil, &s.water_uav[i]) < 0 {return}
	}

	// Plane geometry.
	vertices, indices := build_plane()
	defer delete(vertices)
	defer delete(indices)
	s.index_count = u32(len(indices))

	vb_desc := d3d11.BUFFER_DESC {
		ByteWidth = u32(len(vertices) * size_of(Plane_Vertex)),
		Usage     = .IMMUTABLE,
		BindFlags = {.VERTEX_BUFFER},
	}
	vb_data := d3d11.SUBRESOURCE_DATA {
		pSysMem = raw_data(vertices),
	}
	if device->CreateBuffer(&vb_desc, &vb_data, &s.vertex_buffer) < 0 {return}

	ib_desc := d3d11.BUFFER_DESC {
		ByteWidth = u32(len(indices) * size_of(u32)),
		Usage     = .IMMUTABLE,
		BindFlags = {.INDEX_BUFFER},
	}
	ib_data := d3d11.SUBRESOURCE_DATA {
		pSysMem = raw_data(indices),
	}
	if device->CreateBuffer(&ib_desc, &ib_data, &s.index_buffer) < 0 {return}

	plane_elements := [2]d3d11.INPUT_ELEMENT_DESC{
		{"POSITION", 0, .R32G32B32_FLOAT, 0, 0, .VERTEX_DATA, 0},
		{"TEXCOORDS", 0, .R32G32_FLOAT, 0, 12, .VERTEX_DATA, 0},
	}
	if device->CreateInputLayout(&plane_elements[0], 2, plane_vs_blob->GetBufferPointer(), plane_vs_blob->GetBufferSize(), &s.plane_layout) < 0 {return}

	// Wireframe rasterizer (App::Initialize's RasterizerStateConfigDX11).
	rs_desc := d3d11.RASTERIZER_DESC {
		FillMode        = .WIREFRAME,
		CullMode        = .BACK,
		DepthClipEnable = true,
	}
	if device->CreateRasterizerState(&rs_desc, &s.rs_wireframe) < 0 {return}

	s.cb_time = dynamic_cbuffer(device, size_of(Time_CB)) or_return
	s.cb_transforms = dynamic_cbuffer(device, size_of(Transforms_CB)) or_return

	// DispatchSize never changes: (groups x, groups z, points x, points y).
	dispatch := Dispatch_CB {
		dispatch_size = {DISPATCH_X, DISPATCH_Z, POINTS_X, POINTS_Y},
	}
	dispatch_desc := d3d11.BUFFER_DESC {
		ByteWidth = size_of(Dispatch_CB),
		Usage     = .IMMUTABLE,
		BindFlags = {.CONSTANT_BUFFER},
	}
	dispatch_data := d3d11.SUBRESOURCE_DATA {
		pSysMem = &dispatch,
	}
	if device->CreateBuffer(&dispatch_desc, &dispatch_data, &s.cb_dispatch) < 0 {return}

	return s, true
}

// --- depth buffer ------------------------------------------------------------

Depth_Target :: struct {
	tex: ^d3d11.ITexture2D,
	dsv: ^d3d11.IDepthStencilView,
}

depth_destroy :: proc(d: ^Depth_Target) {
	if d.dsv != nil {
		d.dsv->Release()
	}
	if d.tex != nil {
		d.tex->Release()
	}
	d^ = {}
}

depth_create :: proc(device: ^d3d11.IDevice, width, height: u32) -> (d: Depth_Target, ok: bool) {
	desc := d3d11.TEXTURE2D_DESC {
		Width      = width,
		Height     = height,
		MipLevels  = 1,
		ArraySize  = 1,
		Format     = .D32_FLOAT,
		SampleDesc = {Count = 1},
		Usage      = .DEFAULT,
		BindFlags  = {.DEPTH_STENCIL},
	}
	if device->CreateTexture2D(&desc, nil, &d.tex) < 0 {return}
	if device->CreateDepthStencilView((^d3d11.IResource)(d.tex), nil, &d.dsv) < 0 {
		depth_destroy(&d)
		return
	}
	return d, true
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
	window.set_caption(&win, "WaterSimulation")
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
	depth, depth_ok := depth_create(r.device, WIDTH, HEIGHT)
	if !scene_ok || !depth_ok {
		win32.MessageBoxW(
			nil,
			win32.L("Scene setup failed - see stderr for details (build without -subsystem:windows)."),
			win32.L("WaterSimulation setup failed"),
			win32.MB_ICONEXCLAMATION | win32.MB_SYSTEMMODAL,
		)
		return
	}
	defer scene_destroy(&scene)
	defer depth_destroy(&depth)

	// The default camera node (0, 10, -20) plus the app's body transform.
	cam := Fp_Camera {
		position = {-100, 40.5, -120},
		pitch    = 0.307,
		yaw      = 0.707,
	}
	proj := camera.perspective_fov_lh(f32(linalg.PI) / 4, f32(WIDTH) / f32(HEIGHT), NEAR_CLIP, FAR_CLIP)

	current := 0 // which water buffer holds the current state
	rotation_angle: f32 = 0.0
	runtime: f32 = 0.0
	frame_count := 0
	framerate := 0
	fps_frames := 0
	fps_time: f32 = 0.0

	ctx := r.ctx
	last_tick := time.tick_now()
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

		if state.pending_resize.x != 0 && state.pending_resize.y != 0 {
			renderer.resize(&r, state.pending_resize.x, state.pending_resize.y)
			depth_destroy(&depth)
			resize_ok: bool
			depth, resize_ok = depth_create(r.device, r.width, r.height)
			if !resize_ok {
				fmt.eprintln("failed to recreate the depth buffer after resize")
				return
			}
			proj = camera.perspective_fov_lh(f32(linalg.PI) / 4, f32(r.width) / f32(r.height), NEAR_CLIP, FAR_CLIP)
			state.pending_resize = {}
		}

		dt := f32(time.duration_seconds(time.tick_lap_time(&last_tick)))
		runtime += dt
		frame_count += 1

		// The engine timer's framerate updates once per second; it feeds
		// TimeFactors.y and the FPS readout (title bar here).
		fps_frames += 1
		fps_time += dt
		if fps_time >= 1.0 {
			framerate = fps_frames
			fps_frames = 0
			fps_time = 0.0
			title := fmt.tprintf("WaterSimulation - FPS: %d", framerate)
			win32.SetWindowTextW(win.hwnd, win32.utf8_to_wstring(title))
		}

		camera_update(&cam, &state.input, dt)
		view := camera_view_matrix(&cam)

		// The plane's node spins about Y at 0.2 rad/s; the body offset
		// centers the grid on the origin.
		rotation_angle += dt * 0.2
		world := linalg.matrix4_rotate_f32(rotation_angle, {0, 1, 0}) * linalg.matrix4_translate_f32({-8 * DISPATCH_X, 0, -8 * DISPATCH_Z})

		// --- 1. Simulation pass (ViewSimulation) ---------------------------
		// App::Update doubles the elapsed time in TimeFactors.x. The shader
		// then clamps it with min(TimeFactors.x, 0.05) for the acceleration
		// factor, so the *force* term is frame-rate limited but nothing else
		// is: the 0.9995 damping factor multiplies the flow once per
		// dispatch, not per second. One iteration per frame means the waves
		// die off in proportion to frame count, so uncapped at thousands of
		// FPS the surface flattens within a few seconds. That is preserved
		// C++ behavior, not a porting bug — the original is equally
		// frame-rate dependent, it just ran at a lower frame rate.
		time_cb := Time_CB {
			time_factors  = {dt * 2.0, f32(framerate), runtime, f32(frame_count)},
			dispatch_size = {DISPATCH_X, DISPATCH_Z, POINTS_X, POINTS_Y},
		}
		write_cbuffer(ctx, scene.cb_time, &time_cb)

		null_srv := [1]^d3d11.IShaderResourceView{nil}
		null_uav := [1]^d3d11.IUnorderedAccessView{nil}
		ctx->VSSetShaderResources(0, 1, &null_srv[0]) // release last frame's read before writing

		ctx->CSSetShader(scene.sim_cs, nil, 0)
		ctx->CSSetConstantBuffers(0, 1, &scene.cb_time)
		ctx->CSSetShaderResources(0, 1, &scene.water_srv[current])
		ctx->CSSetUnorderedAccessViews(0, 1, &scene.water_uav[1 - current], nil)
		// 16x16 groups, each 18x18 threads — 256x256 cells written by the
		// 16x16 interior threads of each group.
		ctx->Dispatch(DISPATCH_X, DISPATCH_Z, 1)

		// The buffer just written becomes the visualization pass's SRV, so
		// its UAV binding has to go first (a resource cannot be an SRV and a
		// UAV at once).
		ctx->CSSetShaderResources(0, 1, &null_srv[0])
		ctx->CSSetUnorderedAccessViews(0, 1, &null_uav[0], nil)
		current = 1 - current

		// --- 2. Visualization pass -----------------------------------------
		transforms := Transforms_CB {
			world_view_proj = proj * view * world,
		}
		write_cbuffer(ctx, scene.cb_transforms, &transforms)

		viewport := d3d11.VIEWPORT {
			Width    = f32(r.width),
			Height   = f32(r.height),
			MinDepth = 0.0,
			MaxDepth = 1.0,
		}
		ctx->RSSetViewports(1, &viewport)

		clear_color := [4]f32{0.6, 0.6, 0.9, 1.0}
		ctx->OMSetRenderTargets(1, &r.rtv, depth.dsv)
		ctx->ClearRenderTargetView(r.rtv, &clear_color)
		ctx->ClearDepthStencilView(depth.dsv, {.DEPTH}, 1.0, 0)

		stride: u32 = size_of(Plane_Vertex)
		offset: u32 = 0
		ctx->IASetInputLayout(scene.plane_layout)
		ctx->IASetVertexBuffers(0, 1, &scene.vertex_buffer, &stride, &offset)
		ctx->IASetIndexBuffer(scene.index_buffer, .R32_UINT, 0)
		ctx->IASetPrimitiveTopology(.TRIANGLELIST)
		ctx->VSSetShader(scene.plane_vs, nil, 0)
		vs_cbuffers := [2]^d3d11.IBuffer{scene.cb_transforms, scene.cb_dispatch}
		ctx->VSSetConstantBuffers(0, 2, &vs_cbuffers[0])
		// The plane's vertex buffer carries a flat y=0 grid; the VS indexes
		// this structured buffer by the vertex's texcoords and substitutes
		// the simulated height, so the geometry never round-trips through the
		// CPU and there is no heightmap texture at all. b1 (cb_dispatch)
		// supplies the row stride it needs to flatten (x, y) into an index.
		ctx->VSSetShaderResources(0, 1, &scene.water_srv[current])
		ctx->PSSetShader(scene.plane_ps, nil, 0)
		ctx->RSSetState(scene.rs_wireframe)
		ctx->OMSetDepthStencilState(nil, 0)
		ctx->OMSetBlendState(nil, nil, 0xffffffff)
		ctx->DrawIndexed(scene.index_count, 0, 0)

		renderer.present(&r)

		if state.save_screenshot {
			state.save_screenshot = false
			screenshot_number += 1
			renderer.save_backbuffer_png(&r, fmt.tprintf("WaterSimulation%d.png", screenshot_number))
		}

		free_all(context.temp_allocator)
	}
}
