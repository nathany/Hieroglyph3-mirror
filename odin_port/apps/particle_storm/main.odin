// Odin port of the ParticleStorm sample (Applications/ParticleStorm/) — the
// chapter-12 GPU particle system with append/consume buffers, no text
// overlay (the FPS readout lives in the title bar instead).
//
// 512x512 = 262,144 particles (position/velocity/lifetime, 28 bytes) live in
// two structured buffers with APPEND-flagged UAVs, swapped every frame. Each
// frame:
//
//   1. Insert pass (ParticleSystemInsertCS.hlsl, throttled to one batch per
//      8*30/262144 s — effectively rate-limiting at high FPS): 8 threads
//      append 8 particles at the emitter (-50, 10, 0), directions from a
//      per-frame random reflection vector.
//   2. CopyStructureCount writes the current buffer's hidden append counter
//      into a 16-byte *constant* buffer (NumParticles, b1 of the update CS).
//   3. Update pass (ParticleSystemUpdateCS.hlsl, 512 groups of 512 threads):
//      each live particle is Consume()d from u1, accelerated toward the
//      "black hole" at (50, 0, 0), and Append()ed to u0 — unless it fell
//      inside the event horizon (r <= 5) or aged past 30 s, which is how
//      particles die.
//   4. CopyStructureCount writes the new buffer's counter into a
//      DrawInstancedIndirect arguments buffer {count, 1, 0, 0}.
//   5. Render (ParticleSystemRender.hlsl): DrawInstancedIndirect of a point
//      list with no input layout — the VS fetches positions from the state
//      buffer by SV_VertexID, the GS expands each into a camera-facing
//      quad (scale 0.5) colored red near the black hole and blue far away,
//      and the PS modulates Particle.png; additive blend, depth test
//      without write.
//
// The first frame primes both UAV hidden counters to zero via a 1-group
// update dispatch (the C++'s bOneTimeInit path).
//
// The C++ reuses RenderApplication's default camera (node at (0, 10, -20))
// and positions the body at (-100, 60.5, -100) — so the effective
// first-person camera start is (-100, 70.5, -120), rotation (0.307, 0.707).
// Right-drag look, W/S/A/D/Q/E move, Ctrl sprint, Esc quits, Space
// screenshots, resize supported.
package main

import "core:fmt"
import "core:math/linalg"
import "core:math/rand"
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

PARTICLE_COUNT :: 512 * 512
// Particles per insertion x max lifetime / buffer size.
THROTTLE :: 8.0 * 30.0 / f32(PARTICLE_COUNT)

// --- cbuffer mirrors ---------------------------------------------------------

// ParticleSystemUpdateCS `SimulationParameters` (b0); NumParticles (b1) is
// the GPU-written ParticleCount buffer.
Simulation_CB :: struct #align (16) {
	time_factors:      [4]f32,
	emitter_location:  [4]f32,
	consumer_location: [4]f32,
}

// ParticleSystemInsertCS `ParticleInsertParameters` (b0).
Insert_CB :: struct #align (16) {
	emitter_location: [4]f32,
	random_vector:    [4]f32,
}

// ParticleSystemRender `Transforms` (b0) and `ParticleRenderParameters` (b1),
// both in the geometry shader.
Transforms_CB :: struct #align (16) {
	world_view: matrix[4, 4]f32,
	proj:       matrix[4, 4]f32,
}

Render_Params_CB :: struct #align (16) {
	emitter_location:  [4]f32,
	consumer_location: [4]f32,
}

// The structured-buffer element (float3 position, float3 velocity, float
// lifetime).
Particle :: struct {
	position: [3]f32,
	velocity: [3]f32,
	time:     f32,
}

#assert(size_of(Particle) == 28)

EMITTER_LOCATION :: [4]f32{-50, 10, 0, 0}
CONSUMER_LOCATION :: [4]f32{50, 0, 0, 0}

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
	// The two particle state buffers; index 0 is "current" each frame.
	particle_buffer: [2]^d3d11.IBuffer,
	particle_srv:    [2]^d3d11.IShaderResourceView,
	particle_uav:    [2]^d3d11.IUnorderedAccessView, // APPEND-flagged

	// GPU-written particle counts.
	cb_count:  ^d3d11.IBuffer, // constant buffer, CopyStructureCount target
	args_buf:  ^d3d11.IBuffer, // DrawInstancedIndirect {count, 1, 0, 0}

	// Shaders.
	update_cs: ^d3d11.IComputeShader,
	insert_cs: ^d3d11.IComputeShader,
	render_vs: ^d3d11.IVertexShader,
	render_gs: ^d3d11.IGeometryShader,
	render_ps: ^d3d11.IPixelShader,

	// States.
	bs_additive: ^d3d11.IBlendState,
	ds_no_write: ^d3d11.IDepthStencilState,

	// Texture + sampler.
	particle_tex:   ^d3d11.ITexture2D,
	particle_texv:  ^d3d11.IShaderResourceView,
	sampler_linear: ^d3d11.ISamplerState,

	// Constant buffers.
	cb_simulation: ^d3d11.IBuffer,
	cb_insert:     ^d3d11.IBuffer,
	cb_transforms: ^d3d11.IBuffer,
	cb_render:     ^d3d11.IBuffer,
}

scene_destroy :: proc(s: ^Scene) {
	release :: proc(obj: ^$T) {
		if obj != nil {
			obj->Release()
		}
	}
	release(s.cb_render)
	release(s.cb_transforms)
	release(s.cb_insert)
	release(s.cb_simulation)
	release(s.sampler_linear)
	release(s.particle_texv)
	release(s.particle_tex)
	release(s.ds_no_write)
	release(s.bs_additive)
	release(s.render_ps)
	release(s.render_gs)
	release(s.render_vs)
	release(s.insert_cs)
	release(s.update_cs)
	release(s.args_buf)
	release(s.cb_count)
	for i in 0 ..< 2 {
		release(s.particle_uav[i])
		release(s.particle_srv[i])
		release(s.particle_buffer[i])
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
	update_cs_blob := shader.compile("ParticleSystemUpdateCS.hlsl", "CSMAIN", "cs_5_0") or_return
	defer update_cs_blob->Release()
	insert_cs_blob := shader.compile("ParticleSystemInsertCS.hlsl", "CSMAIN", "cs_5_0") or_return
	defer insert_cs_blob->Release()
	render_vs_blob := shader.compile("ParticleSystemRender.hlsl", "VSMAIN", "vs_5_0") or_return
	defer render_vs_blob->Release()
	render_gs_blob := shader.compile("ParticleSystemRender.hlsl", "GSMAIN", "gs_5_0") or_return
	defer render_gs_blob->Release()
	render_ps_blob := shader.compile("ParticleSystemRender.hlsl", "PSMAIN", "ps_5_0") or_return
	defer render_ps_blob->Release()

	if device->CreateComputeShader(update_cs_blob->GetBufferPointer(), update_cs_blob->GetBufferSize(), nil, &s.update_cs) < 0 {return}
	if device->CreateComputeShader(insert_cs_blob->GetBufferPointer(), insert_cs_blob->GetBufferSize(), nil, &s.insert_cs) < 0 {return}
	if device->CreateVertexShader(render_vs_blob->GetBufferPointer(), render_vs_blob->GetBufferSize(), nil, &s.render_vs) < 0 {return}
	if device->CreateGeometryShader(render_gs_blob->GetBufferPointer(), render_gs_blob->GetBufferSize(), nil, &s.render_gs) < 0 {return}
	if device->CreatePixelShader(render_ps_blob->GetBufferPointer(), render_ps_blob->GetBufferSize(), nil, &s.render_ps) < 0 {return}

	// The two particle state buffers with APPEND-flagged UAVs. The initial
	// data (all zeros) is never used — the append counters start at 0.
	initial := make([]Particle, PARTICLE_COUNT)
	defer delete(initial)
	for &p in initial {
		p.velocity = {0, 0, 1} // the C++'s placeholder direction
	}

	buf_desc := d3d11.BUFFER_DESC {
		ByteWidth           = PARTICLE_COUNT * size_of(Particle),
		Usage               = .DEFAULT,
		BindFlags           = {.SHADER_RESOURCE, .UNORDERED_ACCESS},
		MiscFlags           = {.BUFFER_STRUCTURED},
		StructureByteStride = size_of(Particle),
	}
	buf_data := d3d11.SUBRESOURCE_DATA {
		pSysMem = raw_data(initial),
	}
	uav_desc := d3d11.UNORDERED_ACCESS_VIEW_DESC {
		Format = .UNKNOWN,
		ViewDimension = .BUFFER,
		Buffer = {NumElements = PARTICLE_COUNT, Flags = {.APPEND}},
	}
	for i in 0 ..< 2 {
		if device->CreateBuffer(&buf_desc, &buf_data, &s.particle_buffer[i]) < 0 {return}
		if device->CreateShaderResourceView((^d3d11.IResource)(s.particle_buffer[i]), nil, &s.particle_srv[i]) < 0 {return}
		if device->CreateUnorderedAccessView((^d3d11.IResource)(s.particle_buffer[i]), &uav_desc, &s.particle_uav[i]) < 0 {return}
	}

	// The GPU-written particle-count constant buffer (uint4 NumParticles)
	// and the DrawInstancedIndirect arguments buffer {count, 1, 0, 0}; both
	// receive the append counter via CopyStructureCount.
	zeros := [4]u32{0, 0, 0, 0}
	count_desc := d3d11.BUFFER_DESC {
		ByteWidth = size_of(zeros),
		Usage     = .DEFAULT,
		BindFlags = {.CONSTANT_BUFFER},
	}
	count_data := d3d11.SUBRESOURCE_DATA {
		pSysMem = &zeros,
	}
	if device->CreateBuffer(&count_desc, &count_data, &s.cb_count) < 0 {return}

	args := [4]u32{0, 1, 0, 0}
	args_desc := d3d11.BUFFER_DESC {
		ByteWidth = size_of(args),
		Usage     = .DEFAULT,
		MiscFlags = {.DRAWINDIRECT_ARGS},
	}
	args_data := d3d11.SUBRESOURCE_DATA {
		pSysMem = &args,
	}
	if device->CreateBuffer(&args_desc, &args_data, &s.args_buf) < 0 {return}

	// Additive blend, depth test without write (ParticleSystemActor).
	blend_desc: d3d11.BLEND_DESC
	blend_desc.RenderTarget[0] = {
		BlendEnable           = true,
		SrcBlend              = .ONE,
		DestBlend             = .ONE,
		BlendOp               = .ADD,
		SrcBlendAlpha         = .ONE,
		DestBlendAlpha        = .ONE,
		BlendOpAlpha          = .ADD,
		RenderTargetWriteMask = u8(d3d11.COLOR_WRITE_ENABLE_ALL),
	}
	if device->CreateBlendState(&blend_desc, &s.bs_additive) < 0 {return}

	ds_desc := d3d11.DEPTH_STENCIL_DESC {
		DepthEnable    = true,
		DepthWriteMask = .ZERO,
		DepthFunc      = .LESS,
	}
	if device->CreateDepthStencilState(&ds_desc, &s.ds_no_write) < 0 {return}

	// Particle.png with the engine's default linear/wrap sampler.
	s.particle_tex, s.particle_texv = renderer.load_texture_png(r, "Particle.png") or_return

	sampler_desc := d3d11.SAMPLER_DESC {
		Filter         = .MIN_MAG_MIP_LINEAR,
		AddressU       = .WRAP,
		AddressV       = .WRAP,
		AddressW       = .WRAP,
		ComparisonFunc = .ALWAYS,
		MaxAnisotropy  = 1,
		MaxLOD         = d3d11.FLOAT32_MAX,
	}
	if device->CreateSamplerState(&sampler_desc, &s.sampler_linear) < 0 {return}

	s.cb_simulation = dynamic_cbuffer(device, size_of(Simulation_CB)) or_return
	s.cb_insert = dynamic_cbuffer(device, size_of(Insert_CB)) or_return
	s.cb_transforms = dynamic_cbuffer(device, size_of(Transforms_CB)) or_return
	s.cb_render = dynamic_cbuffer(device, size_of(Render_Params_CB)) or_return

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

// ViewSimulation::SetRenderParams — a normalized random vector, refreshed
// each time the parameters are set.
random_vector :: proc() -> [4]f32 {
	v := linalg.normalize([3]f32{
		rand.float32() * 2.0 - 1.0,
		rand.float32() * 2.0 - 1.0,
		rand.float32() * 2.0 - 1.0,
	})
	return {v.x, v.y, v.z, 0}
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
	window.set_caption(&win, "ParticleStorm")
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
			win32.L("ParticleStorm setup failed"),
			win32.MB_ICONEXCLAMATION | win32.MB_SYSTEMMODAL,
		)
		return
	}
	defer scene_destroy(&scene)
	defer depth_destroy(&depth)

	// The default camera node (0, 10, -20) plus the app's body transform.
	cam := Fp_Camera {
		position = {-100, 70.5, -120},
		pitch    = 0.307,
		yaw      = 0.707,
	}
	proj := camera.perspective_fov_lh(f32(linalg.PI) / 4, f32(WIDTH) / f32(HEIGHT), NEAR_CLIP, FAR_CLIP)

	// current/next particle buffer roles; the C++ swaps every frame in
	// ViewSimulation::Update, so "current" alternates.
	current := 0
	one_time_init := true
	insert_delta := f32(THROTTLE) // starts at the throttle so frame 1 inserts

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

		fps_frames += 1
		fps_time += dt
		if fps_time >= 1.0 {
			framerate = fps_frames
			fps_frames = 0
			fps_time = 0.0
			title := fmt.tprintf("ParticleStorm - FPS: %d", framerate)
			win32.SetWindowTextW(win.hwnd, win32.utf8_to_wstring(title))
		}

		camera_update(&cam, &state.input, dt)
		view := camera_view_matrix(&cam)

		// --- Simulation (ViewSimulation) -----------------------------------
		// ViewSimulation::Update swaps the buffers before the frame's tasks.
		current = 1 - current
		next := 1 - current
		insert_delta += dt

		sim_cb := Simulation_CB {
			time_factors      = {dt, f32(framerate), runtime, f32(frame_count)},
			emitter_location  = EMITTER_LOCATION,
			consumer_location = CONSUMER_LOCATION,
		}
		write_cbuffer(ctx, scene.cb_simulation, &sim_cb)

		// One-time init: prime both append counters to zero with an empty
		// 1-group update dispatch.
		if one_time_init {
			one_time_init = false
			init_counts := [2]u32{0, 0}
			init_uavs := [2]^d3d11.IUnorderedAccessView{scene.particle_uav[next], scene.particle_uav[current]}
			ctx->CSSetShader(scene.update_cs, nil, 0)
			cs_cbuffers := [2]^d3d11.IBuffer{scene.cb_simulation, scene.cb_count}
			ctx->CSSetConstantBuffers(0, 2, &cs_cbuffers[0])
			ctx->CSSetUnorderedAccessViews(0, 2, &init_uavs[0], &init_counts[0])
			ctx->Dispatch(1, 1, 1)
		}

		// Insert pass: one batch of 8 particles per throttle interval. The
		// insert CS's u0 (append) is the *current* state buffer.
		if insert_delta > THROTTLE {
			insert_delta = 0.0
			insert_cb := Insert_CB {
				emitter_location = EMITTER_LOCATION,
				random_vector    = random_vector(),
			}
			write_cbuffer(ctx, scene.cb_insert, &insert_cb)

			keep_count := u32(0xffffffff)
			ctx->CSSetShader(scene.insert_cs, nil, 0)
			ctx->CSSetConstantBuffers(0, 1, &scene.cb_insert)
			ctx->CSSetUnorderedAccessViews(0, 1, &scene.particle_uav[current], &keep_count)
			ctx->Dispatch(1, 1, 1)
		}

		// Latch the current particle count into the NumParticles cbuffer,
		// then run the update: consume from u1 (current), append to u0 (next).
		ctx->CopyStructureCount(scene.cb_count, 0, scene.particle_uav[current])

		keep_counts := [2]u32{0xffffffff, 0xffffffff}
		update_uavs := [2]^d3d11.IUnorderedAccessView{scene.particle_uav[next], scene.particle_uav[current]}
		ctx->CSSetShader(scene.update_cs, nil, 0)
		cs_cbuffers := [2]^d3d11.IBuffer{scene.cb_simulation, scene.cb_count}
		ctx->CSSetConstantBuffers(0, 2, &cs_cbuffers[0])
		ctx->CSSetUnorderedAccessViews(0, 2, &update_uavs[0], &keep_counts[0])
		ctx->Dispatch(PARTICLE_COUNT / 512, 1, 1)

		// Unbind the UAVs and latch the survivor count into the indirect
		// arguments buffer for rendering.
		null_uavs := [2]^d3d11.IUnorderedAccessView{nil, nil}
		ctx->CSSetUnorderedAccessViews(0, 2, &null_uavs[0], nil)
		ctx->CopyStructureCount(scene.args_buf, 0, scene.particle_uav[next])

		// DEBUG: read back both buffers' hidden counters once per second.
		when #config(DEBUG_COUNTS, false) {
			@(static) staging: ^d3d11.IBuffer
			if staging == nil {
				st_desc := d3d11.BUFFER_DESC {
					ByteWidth      = 16,
					Usage          = .STAGING,
					CPUAccessFlags = {.READ},
				}
				r.device->CreateBuffer(&st_desc, nil, &staging)
			}
			@(static) debug_time: f32
			debug_time += dt
			if debug_time >= 1.0 {
				debug_time = 0
				ctx->CopyStructureCount(staging, 0, scene.particle_uav[current])
				ctx->CopyStructureCount(staging, 4, scene.particle_uav[next])
				mapped_dbg: d3d11.MAPPED_SUBRESOURCE
				if ctx->Map((^d3d11.IResource)(staging), 0, .READ, {}, &mapped_dbg) >= 0 {
					counts := ([^]u32)(mapped_dbg.pData)
					fmt.printfln("current=%v next=%v", counts[0], counts[1])
					ctx->Unmap((^d3d11.IResource)(staging), 0)
				}
			}
		}

		// --- Render --------------------------------------------------------
		transforms := Transforms_CB {
			world_view = view, // the particle actor never moves
			proj       = proj,
		}
		write_cbuffer(ctx, scene.cb_transforms, &transforms)
		render_cb := Render_Params_CB {
			emitter_location  = EMITTER_LOCATION,
			consumer_location = CONSUMER_LOCATION,
		}
		write_cbuffer(ctx, scene.cb_render, &render_cb)

		viewport := d3d11.VIEWPORT {
			Width    = f32(r.width),
			Height   = f32(r.height),
			MinDepth = 0.0,
			MaxDepth = 1.0,
		}
		ctx->RSSetViewports(1, &viewport)

		clear_color := [4]f32{0, 0, 0, 0}
		ctx->OMSetRenderTargets(1, &r.rtv, depth.dsv)
		ctx->ClearRenderTargetView(r.rtv, &clear_color)
		ctx->ClearDepthStencilView(depth.dsv, {.DEPTH}, 1.0, 0)

		ctx->IASetInputLayout(nil)
		ctx->IASetPrimitiveTopology(.POINTLIST)
		ctx->VSSetShader(scene.render_vs, nil, 0)
		// SimulationState has no explicit register, but FXC still honors
		// ParticleTexture's register(t0) reservation in the VS even though
		// the VS never samples it — so the buffer lands on t1.
		ctx->VSSetShaderResources(1, 1, &scene.particle_srv[next])
		ctx->GSSetShader(scene.render_gs, nil, 0)
		gs_cbuffers := [2]^d3d11.IBuffer{scene.cb_transforms, scene.cb_render}
		ctx->GSSetConstantBuffers(0, 2, &gs_cbuffers[0])
		ctx->PSSetShader(scene.render_ps, nil, 0)
		ctx->PSSetShaderResources(0, 1, &scene.particle_texv)
		ctx->PSSetSamplers(0, 1, &scene.sampler_linear)
		blend_factor := [4]f32{0, 0, 0, 0}
		ctx->OMSetBlendState(scene.bs_additive, &blend_factor, 0xffffffff)
		ctx->OMSetDepthStencilState(scene.ds_no_write, 0)
		ctx->RSSetState(nil)
		ctx->DrawInstancedIndirect(scene.args_buf, 0)

		// Unbind so next frame's compute passes can take the buffer as UAV.
		null_srv := [2]^d3d11.IShaderResourceView{nil, nil}
		ctx->VSSetShaderResources(0, 2, &null_srv[0])
		ctx->GSSetShader(nil, nil, 0)
		ctx->OMSetBlendState(nil, nil, 0xffffffff)

		renderer.present(&r)

		if state.save_screenshot {
			state.save_screenshot = false
			screenshot_number += 1
			renderer.save_backbuffer_png(&r, fmt.tprintf("ParticleStorm%d.png", screenshot_number))
		}

		free_all(context.temp_allocator)
	}
}
