// Odin port of the InterlockingTerrainTiles sample
// (Applications/InterlockingTerrainTiles/App.cpp) — chapter 9's adaptive
// terrain: a 32x32 grid of tiles drawn as 12-CONTROL-POINT patches (each
// tile's 4 corners plus 8 clamped neighbour points — the "interlocking"
// trick that lets adjacent tiles agree on edge tessellation), displaced by
// TerrainHeightMap.png in the domain shader, with distance-based LOD
// computed per patch in the hull shader.
//
// Keys, all key-up, matching the C++ (text overlay omitted):
//   - W toggles wireframe/cull-none (initial) vs solid/cull-FRONT.
//   - L toggles the hull shader: hsSimple (midpoint distance LOD) vs
//     hsComplex (neighbour-aware LOD via a texLODLookup texture the app
//     never provides — preserved C++ quirk: t1 is unbound in the original
//     too, so complex mode reads zeros).
//   - D cycles the domain shader's shading: solid colour -> N.L shading ->
//     LOD debug view (three compiles of dsMain with different defines).
//   - A toggles the auto-orbiting viewpoint (30 s/circuit, look-at swinging
//     ahead of the camera); when off, the view freezes.
//   - Esc quits; Space screenshots with the C++'s GetName prefix.
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
TERRAIN_X_LEN :: 32
TERRAIN_Z_LEN :: 32

Terrain_Vertex :: struct {
	position: [3]f32,
	texcoord: [2]f32,
}

// The shader's three cbuffers. Per-stage register assignment among used
// cbuffers (declaration order main, patch, sampleparams): VS uses main only
// (b0); the hull constant functions use patch + sampleparams (b0, b1); the
// DS uses all three (b0, b1, b2); GS/PS use none.
Main_CB :: struct #align (16) {
	world:           matrix[4, 4]f32,
	view_proj:       matrix[4, 4]f32,
	inv_tpose_world: matrix[4, 4]f32,
}

Patch_CB :: struct #align (16) {
	camera_position:  [4]f32,
	min_max_distance: [4]f32,
	min_max_lod:      [4]f32,
}

Sample_Params_CB :: struct #align (16) {
	height_map_dimensions: [4]f32,
}

Shading_Mode :: enum {
	Solid_Colour,
	Simple_Shading,
	Lod_Debug_View,
}

App_State :: struct {
	save_screenshot: bool,
	toggle_solid:    bool,
	toggle_hull:     bool,
	cycle_shading:   bool,
	toggle_auto:     bool,
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
		case win32.WPARAM('L'):
			state.toggle_hull = true
		case win32.WPARAM('D'):
			state.cycle_shading = true
		case win32.WPARAM('A'):
			state.toggle_auto = true
		}
	}

	return win32.DefWindowProcW(hwnd, msg, wparam, lparam)
}

Scene :: struct {
	vertex_buffer:  ^d3d11.IBuffer,
	index_buffer:   ^d3d11.IBuffer,
	index_count:    u32,
	input_layout:   ^d3d11.IInputLayout,
	vertex_shader:  ^d3d11.IVertexShader,
	hs_simple:      ^d3d11.IHullShader,
	hs_complex:     ^d3d11.IHullShader,
	domain_shaders: [Shading_Mode]^d3d11.IDomainShader,
	geometry_shader: ^d3d11.IGeometryShader,
	pixel_shader:   ^d3d11.IPixelShader,
	rs_wireframe:   ^d3d11.IRasterizerState,
	rs_solid:       ^d3d11.IRasterizerState,
	sampler:        ^d3d11.ISamplerState,
	height_texture: ^d3d11.ITexture2D,
	height_srv:     ^d3d11.IShaderResourceView,
	height_dims:    [2]f32,
	cb_main:        ^d3d11.IBuffer,
	cb_patch:       ^d3d11.IBuffer,
	cb_sample:      ^d3d11.IBuffer,
}

scene_destroy :: proc(s: ^Scene) {
	release :: proc(obj: ^$T) {
		if obj != nil {obj->Release()}
	}
	release(s.cb_sample)
	release(s.cb_patch)
	release(s.cb_main)
	release(s.height_srv)
	release(s.height_texture)
	release(s.sampler)
	release(s.rs_solid)
	release(s.rs_wireframe)
	release(s.pixel_shader)
	release(s.geometry_shader)
	for ds in s.domain_shaders {
		release(ds)
	}
	release(s.hs_complex)
	release(s.hs_simple)
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

	vs_blob := shader.compile("InterlockingTerrainTiles.hlsl", "vsMain", "vs_5_0") or_return
	defer vs_blob->Release()
	hs_simple_blob := shader.compile("InterlockingTerrainTiles.hlsl", "hsSimple", "hs_5_0") or_return
	defer hs_simple_blob->Release()
	hs_complex_blob := shader.compile("InterlockingTerrainTiles.hlsl", "hsComplex", "hs_5_0") or_return
	defer hs_complex_blob->Release()
	gs_blob := shader.compile("InterlockingTerrainTiles.hlsl", "gsMain", "gs_5_0") or_return
	defer gs_blob->Release()
	ps_blob := shader.compile("InterlockingTerrainTiles.hlsl", "psMain", "ps_5_0") or_return
	defer ps_blob->Release()

	if device->CreateVertexShader(vs_blob->GetBufferPointer(), vs_blob->GetBufferSize(), nil, &s.vertex_shader) < 0 {return}
	if device->CreateHullShader(hs_simple_blob->GetBufferPointer(), hs_simple_blob->GetBufferSize(), nil, &s.hs_simple) < 0 {return}
	if device->CreateHullShader(hs_complex_blob->GetBufferPointer(), hs_complex_blob->GetBufferSize(), nil, &s.hs_complex) < 0 {return}
	if device->CreateGeometryShader(gs_blob->GetBufferPointer(), gs_blob->GetBufferSize(), nil, &s.geometry_shader) < 0 {return}
	if device->CreatePixelShader(ps_blob->GetBufferPointer(), ps_blob->GetBufferSize(), nil, &s.pixel_shader) < 0 {return}

	// Three domain-shader variants of dsMain, selected by preprocessor
	// define — the 'D' key cycles them.
	ds_defines := [Shading_Mode]cstring {
		.Solid_Colour   = "SHADING_SOLID",
		.Simple_Shading = "SHADING_SIMPLE",
		.Lod_Debug_View = "SHADING_DEBUG_LOD",
	}
	for define, mode in ds_defines {
		defines := [1]cstring{define}
		blob := shader.compile_defines("InterlockingTerrainTiles.hlsl", "dsMain", "ds_5_0", defines[:]) or_return
		defer blob->Release()
		if device->CreateDomainShader(blob->GetBufferPointer(), blob->GetBufferSize(), nil, &s.domain_shaders[mode]) < 0 {return}
	}

	// The terrain grid: (33 x 33) control points over [-0.5, 0.5]^2 with
	// texcoords in [0, 1], and per tile the 12-point interlocking patch —
	// 4 corners then the 8 edge-clamped neighbours.
	vertices: [dynamic]Terrain_Vertex
	defer delete(vertices)
	resize(&vertices, (TERRAIN_X_LEN + 1) * (TERRAIN_Z_LEN + 1))
	for x in 0 ..< TERRAIN_X_LEN + 1 {
		for z in 0 ..< TERRAIN_Z_LEN + 1 {
			fx := f32(x) / f32(TERRAIN_X_LEN) - 0.5
			fz := f32(z) / f32(TERRAIN_Z_LEN) - 0.5
			vertices[x + z * (TERRAIN_X_LEN + 1)] = {
				position = {fx, 0, fz},
				texcoord = {fx + 0.5, fz + 0.5},
			}
		}
	}

	indices: [dynamic]u32
	defer delete(indices)
	idx :: proc(z, x: int) -> u32 {
		return u32(clamp(z, 0, TERRAIN_Z_LEN) + clamp(x, 0, TERRAIN_X_LEN) * (TERRAIN_X_LEN + 1))
	}
	for x in 0 ..< TERRAIN_X_LEN {
		for z in 0 ..< TERRAIN_Z_LEN {
			append(&indices, idx(z + 0, x + 0))
			append(&indices, idx(z + 1, x + 0))
			append(&indices, idx(z + 0, x + 1))
			append(&indices, idx(z + 1, x + 1))
			append(&indices, idx(z + 0, x + 2))
			append(&indices, idx(z + 1, x + 2))
			append(&indices, idx(z + 2, x + 0))
			append(&indices, idx(z + 2, x + 1))
			append(&indices, idx(z + 0, x - 1))
			append(&indices, idx(z + 1, x - 1))
			append(&indices, idx(z - 1, x + 0))
			append(&indices, idx(z - 1, x + 1))
		}
	}
	s.index_count = u32(len(indices))

	vb_desc := d3d11.BUFFER_DESC {
		ByteWidth = u32(len(vertices) * size_of(Terrain_Vertex)),
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

	elements := [2]d3d11.INPUT_ELEMENT_DESC{
		{"CONTROL_POINT_POSITION", 0, .R32G32B32_FLOAT, 0, 0, .VERTEX_DATA, 0},
		{"CONTROL_POINT_TEXCOORD", 0, .R32G32_FLOAT, 0, 12, .VERTEX_DATA, 0},
	}
	if device->CreateInputLayout(&elements[0], 2, vs_blob->GetBufferPointer(), vs_blob->GetBufferSize(), &s.input_layout) < 0 {return}

	// Wireframe/cull-none (initial) and solid/cull-FRONT, per CreateShaders.
	rs_desc := d3d11.RASTERIZER_DESC {
		FillMode        = .WIREFRAME,
		CullMode        = .NONE,
		DepthClipEnable = true,
	}
	if device->CreateRasterizerState(&rs_desc, &s.rs_wireframe) < 0 {return}
	rs_desc.FillMode = .SOLID
	rs_desc.CullMode = .FRONT
	if device->CreateRasterizerState(&rs_desc, &s.rs_solid) < 0 {return}

	// The height map + a linear/clamp sampler (CreateTerrainTextures).
	s.height_texture, s.height_srv = renderer.load_texture_png(r, "TerrainHeightMap.png") or_return
	tex_desc: d3d11.TEXTURE2D_DESC
	s.height_texture->GetDesc(&tex_desc)
	s.height_dims = {f32(tex_desc.Width), f32(tex_desc.Height)}

	sampler_desc := d3d11.SAMPLER_DESC {
		Filter         = .MIN_MAG_MIP_LINEAR,
		AddressU       = .CLAMP,
		AddressV       = .CLAMP,
		AddressW       = .CLAMP,
		MaxAnisotropy  = 1,
		ComparisonFunc = .NEVER,
		MaxLOD         = d3d11.FLOAT32_MAX,
	}
	if device->CreateSamplerState(&sampler_desc, &s.sampler) < 0 {return}

	s.cb_main = dynamic_cbuffer(device, size_of(Main_CB)) or_return
	s.cb_patch = dynamic_cbuffer(device, size_of(Patch_CB)) or_return
	s.cb_sample = dynamic_cbuffer(device, size_of(Sample_Params_CB)) or_return

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
	window.set_caption(&win, "Direct3D 11 Interlocking Terrain Tiles Demo")
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
			win32.L("InterlockingTerrainTiles setup failed"),
			win32.MB_ICONEXCLAMATION | win32.MB_SYSTEMMODAL,
		)
		return
	}
	defer scene_destroy(&scene)

	solid_render := false
	simple_complexity := true
	shading := Shading_Mode.Solid_Colour // "best for wireframe"
	auto_view := true

	// The world transform: XZ scale 15 (the domain shader owns Y).
	world := linalg.matrix4_scale_f32({15, 1, 15})
	inv_tpose_world := linalg.transpose(linalg.inverse(world))
	view_proj: matrix[4, 4]f32
	camera_position: [3]f32

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
			simple_complexity = !simple_complexity
		}
		if state.cycle_shading {
			state.cycle_shading = false
			switch shading {
			case .Solid_Colour:
				shading = .Simple_Shading
			case .Simple_Shading:
				shading = .Lod_Debug_View
			case .Lod_Debug_View:
				shading = .Solid_Colour
			}
		}
		if state.toggle_auto {
			state.toggle_auto = false
			auto_view = !auto_view
		}

		// UpdateViewState: an orbiting viewpoint with the look-at point
		// swinging ~30 degrees ahead; frozen when auto mode is off.
		if auto_view {
			t := f32(time.duration_seconds(time.tick_since(start)))
			distance := t / 30.0
			from_angle := math.mod(distance * 2.0 * math.PI, 2.0 * math.PI)
			to_angle := math.mod((distance + 0.08) * 2.0 * math.PI, 2.0 * math.PI)
			look_from := [3]f32{math.sin(from_angle) * 10.0, 4.0, math.cos(from_angle) * 10.0}
			look_at := [3]f32{math.sin(to_angle) * 3.0, 0.3, math.cos(to_angle) * 3.0}

			view := camera.look_at_lh(look_from, look_at, {0, 1, 0})
			proj := camera.perspective_fov_lh(math.PI / 3.0, f32(WIDTH) / f32(HEIGHT), 1.0, 25.0)
			view_proj = proj * view
			camera_position = look_from
		}

		main_cb := Main_CB {
			world           = world,
			view_proj       = view_proj,
			inv_tpose_world = inv_tpose_world,
		}
		write_cbuffer(ctx, scene.cb_main, &main_cb)
		patch_cb := Patch_CB {
			camera_position  = {camera_position.x, camera_position.y, camera_position.z, 0},
			min_max_distance = {4.0, 18.0, 0, 0},
			min_max_lod      = {1.0, 5.0, 0, 0},
		}
		write_cbuffer(ctx, scene.cb_patch, &patch_cb)
		sample_cb := Sample_Params_CB {
			height_map_dimensions = {scene.height_dims.x, scene.height_dims.y, TERRAIN_X_LEN, TERRAIN_Z_LEN},
		}
		write_cbuffer(ctx, scene.cb_sample, &sample_cb)

		clear_color := [4]f32{1, 1, 1, 1}
		ctx->ClearRenderTargetView(r.rtv, &clear_color)
		ctx->ClearDepthStencilView(r.dsv, {.DEPTH}, 1.0, 0)

		ctx->IASetInputLayout(scene.input_layout)
		stride: u32 = size_of(Terrain_Vertex)
		offset: u32 = 0
		ctx->IASetVertexBuffers(0, 1, &scene.vertex_buffer, &stride, &offset)
		ctx->IASetIndexBuffer(scene.index_buffer, .R32_UINT, 0)
		ctx->IASetPrimitiveTopology(._12_CONTROL_POINT_PATCHLIST)

		hs_cbuffers := [2]^d3d11.IBuffer{scene.cb_patch, scene.cb_sample}
		ds_cbuffers := [3]^d3d11.IBuffer{scene.cb_main, scene.cb_patch, scene.cb_sample}
		ctx->VSSetShader(scene.vertex_shader, nil, 0)
		ctx->VSSetConstantBuffers(0, 1, &scene.cb_main)
		ctx->HSSetShader(scene.hs_simple if simple_complexity else scene.hs_complex, nil, 0)
		ctx->HSSetConstantBuffers(0, 2, &hs_cbuffers[0])
		// The hull LOD helpers sample the height map; texLODLookup (t1)
		// stays unbound, as in the C++.
		ctx->HSSetShaderResources(0, 1, &scene.height_srv)
		ctx->HSSetSamplers(0, 1, &scene.sampler)
		ctx->DSSetShader(scene.domain_shaders[shading], nil, 0)
		ctx->DSSetConstantBuffers(0, 3, &ds_cbuffers[0])
		ctx->DSSetShaderResources(0, 1, &scene.height_srv)
		ctx->DSSetSamplers(0, 1, &scene.sampler)
		ctx->GSSetShader(scene.geometry_shader, nil, 0)
		ctx->PSSetShader(scene.pixel_shader, nil, 0)

		ctx->RSSetState(scene.rs_solid if solid_render else scene.rs_wireframe)

		ctx->DrawIndexed(scene.index_count, 0, 0)

		renderer.present(&r)

		if state.save_screenshot {
			state.save_screenshot = false
			screenshot_number += 1
			renderer.save_backbuffer_png(&r, fmt.tprintf("Direct3D 11 Interlocking Terrain Tiles Demo%d.png", screenshot_number))
		}
	}
}
