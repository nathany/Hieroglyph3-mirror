// Odin port of the SkinAndBones sample (Applications/SkinAndBones/App.cpp) —
// the chapter-8 vertex skinning demo. Three actors (text overlay omitted):
//
//   - A DISPLACED skinned cone at (20,0,20): the procedurally generated,
//     6-bone weighted cone drawn as a 3_CONTROL_POINT_PATCHLIST through
//     MeshSkinnedTessellatedTextured.hlsl — skinning in the VS, fixed
//     factor-5 tessellation in the HS, and height-map displacement in the DS
//     (HeightTexture = EyeOfHorus.png).
//   - A plain SKINNED cone at (0,0,20): the same geometry as a TRIANGLELIST
//     through MeshSkinnedTextured.hlsl (skinning + texturing only).
//   - A STATIC box at (-20,10,15): box.ms3d with MeshStaticTextured.hlsl and
//     Tiles.png — rigid geometry for contrast.
//
// Every bone displays its coordinate axes (the engine attaches an axis
// gizmo entity to each bone node), so the skeleton is visible through the
// mesh swing. All three actors slowly spin (the default RotationController:
// 0.25 rad/s about +Y). The bone swing animation eases (QuadraticInOut)
// through keyframes over 6 seconds and then STOPS — press 'A' to replay,
// exactly like the C++. Esc quits; Space saves SkinAndBones<n>.png.
//
// The skinning matrices carry the actors' full node transforms (the C++
// captures bind pose before the app positions the nodes, and the skinned
// shaders transform positions by SkinMatrices then ViewProjMatrix — the
// cbuffer's WorldMatrix is unused for positions). LightColor is loaded by
// the C++ app but never read by any of these shaders; only LightPositionWS
// matters (VS-stage lighting vectors).
package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:time"
import win32 "core:sys/windows"
import d3d11 "vendor:directx/d3d11"
import "glyph:camera"
import "glyph:ms3d"
import "glyph:renderer"
import "glyph:shader"
import "glyph:window"

WIDTH :: 800
HEIGHT :: 600
NUM_BONES :: 6

// MeshSkinned*.hlsl's SkinningTransforms cbuffer. Both skinned shaders blend
// a vertex through SkinMatrices[bone.xyzw] weighted by weights.xyzw and take
// that result as the WORLD-space position — `world` below is written to match
// the C++ layout but no shader ever reads it. The two shaders differ only in
// where the ViewProjMatrix multiply happens: the plain VS does it inline, the
// tessellated VS leaves the position in world space so the HS/DS can subdivide
// and displace it, and the DS applies ViewProjMatrix last.
Skinning_Transforms :: struct #align (16) {
	world:                matrix[4, 4]f32,
	view_proj:            matrix[4, 4]f32,
	skin_matrices:        [NUM_BONES]matrix[4, 4]f32,
	skin_normal_matrices: [NUM_BONES]matrix[4, 4]f32,
}

// LightParameters: float3 + float4 pack into two 16-byte registers.
Light_Parameters :: struct #align (16) {
	light_position_ws: [3]f32,
	_pad:              f32,
	light_color:       [4]f32,
}

// MeshStaticTextured.hlsl's StaticMeshTransforms cbuffer.
Static_Transforms :: struct #align (16) {
	world:           matrix[4, 4]f32,
	world_view_proj: matrix[4, 4]f32,
}

// VertexColor.hlsl's Transforms cbuffer (the axis gizmos).
Axis_Transforms :: struct #align (16) {
	world_view_proj: matrix[4, 4]f32,
}

App_State :: struct {
	save_screenshot: bool,
	replay:          bool,
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
		case win32.WPARAM('A'):
			// 'A' Key - restart animations.
			state.replay = true
			return 0
		}
	}

	return win32.DefWindowProcW(hwnd, msg, wparam, lparam)
}

Scene :: struct {
	// Cone geometry, shared by the displaced and skinned actors.
	cone_vb:         ^d3d11.IBuffer,
	cone_ib:         ^d3d11.IBuffer,
	cone_index_count: u32,
	skinned_layout:  ^d3d11.IInputLayout,
	// Displaced (tessellated) material.
	vs_tess:         ^d3d11.IVertexShader,
	hs_tess:         ^d3d11.IHullShader,
	ds_tess:         ^d3d11.IDomainShader,
	ps_tess:         ^d3d11.IPixelShader,
	// Plain skinned material.
	vs_skinned:      ^d3d11.IVertexShader,
	ps_skinned:      ^d3d11.IPixelShader,
	// Static mesh.
	box_vb:          ^d3d11.IBuffer,
	box_ib:          ^d3d11.IBuffer,
	box_index_count: u32,
	static_layout:   ^d3d11.IInputLayout,
	vs_static:       ^d3d11.IVertexShader,
	ps_static:       ^d3d11.IPixelShader,
	// Bone axis gizmos.
	axis_vb:         ^d3d11.IBuffer,
	axis_ib:         ^d3d11.IBuffer,
	axis_layout:     ^d3d11.IInputLayout,
	vs_axis:         ^d3d11.IVertexShader,
	ps_axis:         ^d3d11.IPixelShader,
	// States, samplers, textures.
	cull_none:       ^d3d11.IRasterizerState,
	aniso_sampler:   ^d3d11.ISamplerState,
	linear_sampler:  ^d3d11.ISamplerState,
	color_texture:   ^d3d11.ITexture2D,
	color_srv:       ^d3d11.IShaderResourceView,
	height_texture:  ^d3d11.ITexture2D,
	height_srv:      ^d3d11.IShaderResourceView,
	tiles_texture:   ^d3d11.ITexture2D,
	tiles_srv:       ^d3d11.IShaderResourceView,
	// Constant buffers.
	cb_skinning:     ^d3d11.IBuffer,
	cb_light:        ^d3d11.IBuffer,
	cb_static:       ^d3d11.IBuffer,
	cb_axis:         ^d3d11.IBuffer,
}

scene_destroy :: proc(s: ^Scene) {
	release :: proc(obj: ^$T) {
		if obj != nil {obj->Release()}
	}
	release(s.cb_axis)
	release(s.cb_static)
	release(s.cb_light)
	release(s.cb_skinning)
	release(s.tiles_srv)
	release(s.tiles_texture)
	release(s.height_srv)
	release(s.height_texture)
	release(s.color_srv)
	release(s.color_texture)
	release(s.linear_sampler)
	release(s.aniso_sampler)
	release(s.cull_none)
	release(s.ps_axis)
	release(s.vs_axis)
	release(s.axis_layout)
	release(s.axis_ib)
	release(s.axis_vb)
	release(s.ps_static)
	release(s.vs_static)
	release(s.static_layout)
	release(s.box_ib)
	release(s.box_vb)
	release(s.ps_skinned)
	release(s.vs_skinned)
	release(s.ps_tess)
	release(s.ds_tess)
	release(s.hs_tess)
	release(s.vs_tess)
	release(s.skinned_layout)
	release(s.cone_ib)
	release(s.cone_vb)
	s^ = {}
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

	// Shaders. The tessellated set is SM 5.0 (HS/DS); the rest 4.0-class.
	vs_tess := shader.compile("MeshSkinnedTessellatedTextured.hlsl", "VSMAIN", "vs_5_0") or_return
	defer vs_tess->Release()
	hs_tess := shader.compile("MeshSkinnedTessellatedTextured.hlsl", "HSMAIN", "hs_5_0") or_return
	defer hs_tess->Release()
	ds_tess := shader.compile("MeshSkinnedTessellatedTextured.hlsl", "DSMAIN", "ds_5_0") or_return
	defer ds_tess->Release()
	ps_tess := shader.compile("MeshSkinnedTessellatedTextured.hlsl", "PSMAIN", "ps_5_0") or_return
	defer ps_tess->Release()
	vs_skinned := shader.compile("MeshSkinnedTextured.hlsl", "VSMAIN", "vs_4_0") or_return
	defer vs_skinned->Release()
	ps_skinned := shader.compile("MeshSkinnedTextured.hlsl", "PSMAIN", "ps_4_0") or_return
	defer ps_skinned->Release()
	vs_static := shader.compile("MeshStaticTextured.hlsl", "VSMAIN", "vs_4_0") or_return
	defer vs_static->Release()
	ps_static := shader.compile("MeshStaticTextured.hlsl", "PSMAIN", "ps_4_0") or_return
	defer ps_static->Release()
	vs_axis := shader.compile("VertexColor.hlsl", "VSMAIN", "vs_4_0") or_return
	defer vs_axis->Release()
	ps_axis := shader.compile("VertexColor.hlsl", "PSMAIN", "ps_4_0") or_return
	defer ps_axis->Release()

	if device->CreateVertexShader(vs_tess->GetBufferPointer(), vs_tess->GetBufferSize(), nil, &s.vs_tess) < 0 {return}
	if device->CreateHullShader(hs_tess->GetBufferPointer(), hs_tess->GetBufferSize(), nil, &s.hs_tess) < 0 {return}
	if device->CreateDomainShader(ds_tess->GetBufferPointer(), ds_tess->GetBufferSize(), nil, &s.ds_tess) < 0 {return}
	if device->CreatePixelShader(ps_tess->GetBufferPointer(), ps_tess->GetBufferSize(), nil, &s.ps_tess) < 0 {return}
	if device->CreateVertexShader(vs_skinned->GetBufferPointer(), vs_skinned->GetBufferSize(), nil, &s.vs_skinned) < 0 {return}
	if device->CreatePixelShader(ps_skinned->GetBufferPointer(), ps_skinned->GetBufferSize(), nil, &s.ps_skinned) < 0 {return}
	if device->CreateVertexShader(vs_static->GetBufferPointer(), vs_static->GetBufferSize(), nil, &s.vs_static) < 0 {return}
	if device->CreatePixelShader(ps_static->GetBufferPointer(), ps_static->GetBufferSize(), nil, &s.ps_static) < 0 {return}
	if device->CreateVertexShader(vs_axis->GetBufferPointer(), vs_axis->GetBufferSize(), nil, &s.vs_axis) < 0 {return}
	if device->CreatePixelShader(ps_axis->GetBufferPointer(), ps_axis->GetBufferSize(), nil, &s.ps_axis) < 0 {return}

	// The cone (shared by both skinned actors).
	cone_vertices, cone_indices := generate_skinned_cone(16, 20, 2.0, 40.0, NUM_BONES)
	defer delete(cone_vertices)
	defer delete(cone_indices)
	s.cone_index_count = u32(len(cone_indices))
	s.cone_vb = immutable_buffer(device, raw_data(cone_vertices), u32(len(cone_vertices) * size_of(Skinned_Vertex)), {.VERTEX_BUFFER}) or_return
	s.cone_ib = immutable_buffer(device, raw_data(cone_indices), u32(len(cone_indices) * size_of(u32)), {.INDEX_BUFFER}) or_return

	skinned_elements := [5]d3d11.INPUT_ELEMENT_DESC{
		{"POSITION", 0, .R32G32B32_FLOAT, 0, 0, .VERTEX_DATA, 0},
		{"BONEIDS", 0, .R32G32B32A32_SINT, 0, 12, .VERTEX_DATA, 0},
		{"BONEWEIGHTS", 0, .R32G32B32A32_FLOAT, 0, 28, .VERTEX_DATA, 0},
		{"TEXCOORDS", 0, .R32G32_FLOAT, 0, 44, .VERTEX_DATA, 0},
		{"NORMAL", 0, .R32G32B32_FLOAT, 0, 52, .VERTEX_DATA, 0},
	}
	if device->CreateInputLayout(&skinned_elements[0], 5, vs_tess->GetBufferPointer(), vs_tess->GetBufferSize(), &s.skinned_layout) < 0 {return}

	// The static box.
	box := ms3d.load("box.ms3d") or_return
	defer ms3d.destroy(&box)
	s.box_index_count = u32(len(box.indices))
	s.box_vb = immutable_buffer(device, raw_data(box.vertices), u32(len(box.vertices) * size_of(ms3d.Vertex)), {.VERTEX_BUFFER}) or_return
	s.box_ib = immutable_buffer(device, raw_data(box.indices), u32(len(box.indices) * size_of(u32)), {.INDEX_BUFFER}) or_return

	static_elements := [3]d3d11.INPUT_ELEMENT_DESC{
		{"POSITION", 0, .R32G32B32_FLOAT, 0, 0, .VERTEX_DATA, 0},
		{"TEXCOORDS", 0, .R32G32_FLOAT, 0, 12, .VERTEX_DATA, 0},
		{"NORMAL", 0, .R32G32B32_FLOAT, 0, 20, .VERTEX_DATA, 0},
	}
	if device->CreateInputLayout(&static_elements[0], 3, vs_static->GetBufferPointer(), vs_static->GetBufferSize(), &s.static_layout) < 0 {return}

	// The bone axis gizmos.
	s.axis_vb = immutable_buffer(device, &axis_vertices[0], size_of(axis_vertices), {.VERTEX_BUFFER}) or_return
	s.axis_ib = immutable_buffer(device, &axis_indices[0], size_of(axis_indices), {.INDEX_BUFFER}) or_return

	axis_elements := [2]d3d11.INPUT_ELEMENT_DESC{
		{"POSITION", 0, .R32G32B32_FLOAT, 0, 0, .VERTEX_DATA, 0},
		{"COLOR", 0, .R32G32B32A32_FLOAT, 0, 12, .VERTEX_DATA, 0},
	}
	if device->CreateInputLayout(&axis_elements[0], 2, vs_axis->GetBufferPointer(), vs_axis->GetBufferSize(), &s.axis_layout) < 0 {return}

	// All three mesh materials use CullMode NONE (the material generators).
	rs_desc := d3d11.RASTERIZER_DESC {
		FillMode        = .SOLID,
		CullMode        = .NONE,
		DepthClipEnable = true,
	}
	if device->CreateRasterizerState(&rs_desc, &s.cull_none) < 0 {return}

	// The cone generator's anisotropic wrap sampler; the static material's
	// default linear wrap.
	sampler_desc := d3d11.SAMPLER_DESC {
		Filter         = .ANISOTROPIC,
		AddressU       = .WRAP,
		AddressV       = .WRAP,
		AddressW       = .WRAP,
		MaxAnisotropy  = 1,
		ComparisonFunc = .NEVER,
		MaxLOD         = d3d11.FLOAT32_MAX,
	}
	if device->CreateSamplerState(&sampler_desc, &s.aniso_sampler) < 0 {return}
	sampler_desc.Filter = .MIN_MAG_MIP_LINEAR
	if device->CreateSamplerState(&sampler_desc, &s.linear_sampler) < 0 {return}

	// Textures, per the cone generator and the App.
	s.color_texture, s.color_srv = renderer.load_texture_png(r, "EyeOfHorus_128_Blurred.png") or_return
	s.height_texture, s.height_srv = renderer.load_texture_png(r, "EyeOfHorus.png") or_return
	s.tiles_texture, s.tiles_srv = renderer.load_texture_png(r, "Tiles.png") or_return

	s.cb_skinning = dynamic_cbuffer(device, size_of(Skinning_Transforms)) or_return
	s.cb_light = dynamic_cbuffer(device, size_of(Light_Parameters)) or_return
	s.cb_static = dynamic_cbuffer(device, size_of(Static_Transforms)) or_return
	s.cb_axis = dynamic_cbuffer(device, size_of(Axis_Transforms)) or_return

	return s, true
}

// Draw the axis gizmos for one bone chain.
draw_bone_axes :: proc(ctx: ^d3d11.IDeviceContext, s: ^Scene, bones: []Bone, view_proj: matrix[4, 4]f32) {
	ctx->IASetInputLayout(s.axis_layout)
	stride: u32 = size_of(Axis_Vertex)
	offset: u32 = 0
	ctx->IASetVertexBuffers(0, 1, &s.axis_vb, &stride, &offset)
	ctx->IASetIndexBuffer(s.axis_ib, .R32_UINT, 0)
	ctx->IASetPrimitiveTopology(.TRIANGLELIST)
	ctx->VSSetShader(s.vs_axis, nil, 0)
	ctx->PSSetShader(s.ps_axis, nil, 0)
	ctx->VSSetConstantBuffers(0, 1, &s.cb_axis)
	ctx->RSSetState(nil) // engine default state (cull back)

	for &b in bones {
		transforms := Axis_Transforms {
			world_view_proj = view_proj * b.world,
		}
		write_cbuffer(ctx, s.cb_axis, &transforms)
		ctx->DrawIndexed(u32(len(axis_indices)), 0, 0)
	}
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
	window.set_caption(&win, "SkinAndBones")
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
			win32.L("SkinAndBones setup failed"),
			win32.MB_ICONEXCLAMATION | win32.MB_SYSTEMMODAL,
		)
		return
	}
	defer scene_destroy(&scene)

	// Two independent bone chains (one per skinned actor), bind pose
	// captured before the actors move — as the C++'s call order does.
	displaced_bones := make_bones(NUM_BONES, 40.0)
	defer bones_destroy(&displaced_bones)
	skinned_bones := make_bones(NUM_BONES, 40.0)
	defer bones_destroy(&skinned_bones)
	bones_set_bind_pose(displaced_bones[:])
	bones_set_bind_pose(skinned_bones[:])
	bones_play_all(displaced_bones[:])
	bones_play_all(skinned_bones[:])

	// RenderApplication camera: pitch 0.7 at (0,50,-20); proj pi/4,
	// 0.1..1000. The camera is static in this sample.
	cam_rotation := linalg.matrix4_rotate_f32(f32(0.7), [3]f32{1, 0, 0})
	view := linalg.transpose(cam_rotation) * linalg.matrix4_translate_f32([3]f32{0, -50, 20})
	proj := camera.perspective_fov_lh(math.PI / 4, f32(WIDTH) / f32(HEIGHT), 0.1, 1000.0)
	view_proj := proj * view

	ctx := r.ctx
	start := time.tick_now()
	last_frame := start
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
		runtime_s := f32(time.duration_seconds(time.tick_diff(start, now)))

		if state.replay {
			state.replay = false
			bones_play_all(displaced_bones[:])
			bones_play_all(skinned_bones[:])
		}

		// The default RotationControllers: 0.25 rad/s about +Y on each actor.
		spin := runtime_s * 0.25
		displaced_node := linalg.matrix4_translate_f32([3]f32{20, 0, 20}) * linalg.matrix4_rotate_f32(spin, [3]f32{0, 1, 0})
		skinned_node := linalg.matrix4_translate_f32([3]f32{0, 0, 20}) * linalg.matrix4_rotate_f32(spin, [3]f32{0, 1, 0})
		static_world := linalg.matrix4_translate_f32([3]f32{-20, 10, 15}) * linalg.matrix4_rotate_f32(spin, [3]f32{0, 1, 0})

		// Each actor drives its own chain because the node matrix is the root
		// of the bone hierarchy, not a separate world transform applied
		// afterwards — two actors at different positions cannot share bones.
		bones_update(displaced_bones[:], displaced_node, dt)
		bones_update(skinned_bones[:], skinned_node, dt)

		clear_color := [4]f32{0.1, 0.1, 0.3, 0.0}
		ctx->ClearRenderTargetView(r.rtv, &clear_color)
		ctx->ClearDepthStencilView(r.dsv, {.DEPTH}, 1.0, 0)

		// Frame constants: the light (only LightPositionWS is actually read
		// by the shaders).
		light := Light_Parameters {
			light_position_ws = {-1000, 200, 0},
			light_color       = {0.2, 0.7, 0.2, 0.7},
		}
		write_cbuffer(ctx, scene.cb_light, &light)

		fill_skinning :: proc(bones: []Bone, world: matrix[4, 4]f32, view_proj: matrix[4, 4]f32) -> Skinning_Transforms {
			t := Skinning_Transforms {
				world     = world,
				view_proj = view_proj,
			}
			for &b, i in bones {
				t.skin_matrices[i] = bone_skin_matrix(&b)
				t.skin_normal_matrices[i] = bone_skin_normal_matrix(&b)
			}
			return t
		}

		// --- Displaced (tessellated) cone --------------------------------
		skinning := fill_skinning(displaced_bones[:], displaced_node, view_proj)
		write_cbuffer(ctx, scene.cb_skinning, &skinning)

		ctx->IASetInputLayout(scene.skinned_layout)
		stride: u32 = size_of(Skinned_Vertex)
		offset: u32 = 0
		ctx->IASetVertexBuffers(0, 1, &scene.cone_vb, &stride, &offset)
		ctx->IASetIndexBuffer(scene.cone_ib, .R32_UINT, 0)
		// Same triangle index buffer as the plain cone below, reinterpreted:
		// with a hull shader bound, each group of 3 indices is a patch's
		// control points rather than a triangle. The HS declares
		// domain("tri")/outputcontrolpoints(3) to match, so the subdivided
		// domain lines up exactly with the original triangles.
		ctx->IASetPrimitiveTopology(._3_CONTROL_POINT_PATCHLIST)

		vs_cbuffers := [2]^d3d11.IBuffer{scene.cb_skinning, scene.cb_light}
		ctx->VSSetShader(scene.vs_tess, nil, 0)
		ctx->VSSetConstantBuffers(0, 2, &vs_cbuffers[0])
		ctx->HSSetShader(scene.hs_tess, nil, 0)
		ctx->DSSetShader(scene.ds_tess, nil, 0)
		// The DS's only used cbuffer (SkinningTransforms.ViewProjMatrix)
		// lands in its b0; HeightTexture is declared register(t1).
		ctx->DSSetConstantBuffers(0, 1, &scene.cb_skinning)
		// t0 (ColorTexture) is unused by the DS, so slot 0 is padded with nil
		// purely to land the height map in t1. The DS pushes each generated
		// point along its interpolated normal by HeightTexture.r * 0.5, at a
		// MIP level chosen from the point's distance to a hard-coded world
		// reference position — preserved from the C++ shader.
		ds_srvs := [2]^d3d11.IShaderResourceView{nil, scene.height_srv}
		ctx->DSSetShaderResources(0, 2, &ds_srvs[0])
		ctx->DSSetSamplers(0, 1, &scene.aniso_sampler)
		ctx->PSSetShader(scene.ps_tess, nil, 0)
		ctx->PSSetShaderResources(0, 1, &scene.color_srv)
		ctx->PSSetSamplers(0, 1, &scene.aniso_sampler)
		ctx->RSSetState(scene.cull_none)

		ctx->DrawIndexed(scene.cone_index_count, 0, 0)

		// Unbind the tessellation stages before the untessellated draws — the
		// device would otherwise keep feeding patches to a stale HS/DS.
		ctx->HSSetShader(nil, nil, 0)
		ctx->DSSetShader(nil, nil, 0)

		// --- Plain skinned cone ------------------------------------------
		skinning = fill_skinning(skinned_bones[:], skinned_node, view_proj)
		write_cbuffer(ctx, scene.cb_skinning, &skinning)

		ctx->IASetPrimitiveTopology(.TRIANGLELIST)
		ctx->VSSetShader(scene.vs_skinned, nil, 0)
		ctx->VSSetConstantBuffers(0, 2, &vs_cbuffers[0])
		ctx->PSSetShader(scene.ps_skinned, nil, 0)
		ctx->PSSetShaderResources(0, 1, &scene.color_srv)
		ctx->PSSetSamplers(0, 1, &scene.aniso_sampler)

		ctx->DrawIndexed(scene.cone_index_count, 0, 0)

		// --- Static box ---------------------------------------------------
		static_transforms := Static_Transforms {
			world           = static_world,
			world_view_proj = view_proj * static_world,
		}
		write_cbuffer(ctx, scene.cb_static, &static_transforms)

		ctx->IASetInputLayout(scene.static_layout)
		stride = size_of(ms3d.Vertex)
		ctx->IASetVertexBuffers(0, 1, &scene.box_vb, &stride, &offset)
		ctx->IASetIndexBuffer(scene.box_ib, .R32_UINT, 0)
		static_cbuffers := [2]^d3d11.IBuffer{scene.cb_static, scene.cb_light}
		ctx->VSSetShader(scene.vs_static, nil, 0)
		ctx->VSSetConstantBuffers(0, 2, &static_cbuffers[0])
		ctx->PSSetShader(scene.ps_static, nil, 0)
		ctx->PSSetShaderResources(0, 1, &scene.tiles_srv)
		ctx->PSSetSamplers(0, 1, &scene.linear_sampler)

		ctx->DrawIndexed(scene.box_index_count, 0, 0)

		// --- Bone axis gizmos --------------------------------------------
		draw_bone_axes(ctx, &scene, displaced_bones[:], view_proj)
		draw_bone_axes(ctx, &scene, skinned_bones[:], view_proj)

		renderer.present(&r)

		if state.save_screenshot {
			state.save_screenshot = false
			screenshot_number += 1
			renderer.save_backbuffer_png(&r, fmt.tprintf("SkinAndBones%d.png", screenshot_number))
		}
	}
}
