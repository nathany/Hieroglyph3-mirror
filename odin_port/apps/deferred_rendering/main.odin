// Odin port of the DeferredRendering sample (Applications/DeferredRendering/)
// — the chapter-11 classic deferred renderer, with every optimization toggle
// from the book, no text overlay (the settings live in the title bar).
//
// The frame, mirroring ViewDeferredRenderer + ViewGBuffer + ViewLights:
//
//   1. G-Buffer pass (GBuffer.hlsl): Sample_Scene.ms3d fills 4 (or 3) MRTs.
//      Unoptimized ('K' off): world-space normal, diffuse albedo, specular
//      albedo+power, world-space position — all R32G32B32A32_FLOAT.
//      Optimized ('K' on): spheremap-encoded view-space normal (R16G16_SNORM),
//      diffuse albedo (R10G10B10A2), specular albedo + power/255 (R8G8B8A8) —
//      position is reconstructed from the depth buffer instead of stored.
//      Stencil marks geometry pixels with 1.
//   2. Light pass (Lights.hlsl): for each point light in the N-cycled grid,
//      additively accumulate diffuse+specular*albedo into the final target,
//      stencil-tested against the G-Buffer mask. 'O' picks the optimization:
//      fullscreen quad per light (None), quad + scissor rectangle fit to the
//      light sphere (ScissorRect), or a real sphere volume mesh with
//      LESS_EQUAL/back-face — or GREATER_EQUAL/front-face when the volume
//      pokes through the far plane (Volumes).
//   3. Display ('V'): the final target blitted to the backbuffer (through an
//      MSAA resolve if needed), or the individual G-Buffer attributes, or
//      all four in quadrants — replacing the C++'s SpriteRenderer with the
//      same alpha-blended, linear-filtered pixel-space blit.
//
//   'M' cycles antialiasing: None, SSAA (all targets at 2x resolution,
//   linearly downsampled by the display blit), MSAA (4x targets, per-sample
//   G-Buffer fetch loop driven by SV_Coverage in the light shader). The
//   G-Buffer views can't be displayed under MSAA (the C++ shows a text
//   message; here the screen just stays black).
//
// Preserved C++ quirks: the "CameraPos" shader parameter is filled from the
// scene root's position — always the origin, not the camera — so the
// unoptimized path's specular term is subtly wrong in the original too; and
// the quadrant layout of the G-Buffer display mode is hardcoded for
// 1280x720, so at 800x480 the right-hand tiles are mostly off-screen. The
// C++ also compiles spot/directional light shaders (and a cone volume) it
// never uses, and its Volumes mode has a quad fallback no grid light can
// trigger; both are omitted.
package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:time"
import win32 "core:sys/windows"
import d3d11 "vendor:directx/d3d11"
import d3dc "vendor:directx/d3d_compiler"
import dxgi "vendor:directx/dxgi"
import "glyph:camera"
import "glyph:ms3d"
import "glyph:renderer"
import "glyph:shader"
import "glyph:window"

WIDTH :: 800
HEIGHT :: 480
NEAR_CLIP :: 1.0
FAR_CLIP :: 15.0

// --- settings (AppSettings.h) ------------------------------------------------

Light_Opt :: enum { // 'O'
	None,
	Scissor_Rect,
	Volumes,
}

Display_Mode :: enum { // 'V'
	Final,
	G_Buffer,
	Normals,
	Diffuse_Albedo,
	Specular_Albedo,
	Position,
}

Light_Mode :: enum { // 'N'
	Lights3x3x3,
	Lights5x5x5,
	Lights7x7x7,
}

Gbuf_Opt :: enum { // 'K'
	Disabled,
	Enabled,
}

AA_Mode :: enum { // 'M'
	None,
	SSAA,
	MSAA,
}

Settings :: struct {
	light_opt:    Light_Opt,
	display_mode: Display_Mode,
	light_mode:   Light_Mode,
	gbuf_opt:     Gbuf_Opt,
	aa_mode:      AA_Mode,
}

light_opt_names := [Light_Opt]string {
	.None         = "No Optimizations",
	.Scissor_Rect = "Scissor Rectangle",
	.Volumes      = "Light Volumes",
}
display_mode_names := [Display_Mode]string {
	.Final           = "Final",
	.G_Buffer        = "G-Buffer",
	.Normals         = "Normals",
	.Diffuse_Albedo  = "Diffuse Albedo",
	.Specular_Albedo = "Specular Albedo",
	.Position        = "Position/Depth",
}
light_mode_names := [Light_Mode]string {
	.Lights3x3x3 = "3x3x3",
	.Lights5x5x5 = "5x5x5",
	.Lights7x7x7 = "7x7x7",
}
gbuf_opt_names := [Gbuf_Opt]string {
	.Disabled = "Disabled",
	.Enabled  = "Enabled",
}
aa_mode_names := [AA_Mode]string {
	.None = "None",
	.SSAA = "Supersampling",
	.MSAA = "Multisampling",
}

// --- cbuffer mirrors ---------------------------------------------------------

// GBuffer.hlsl / Lights.hlsl `Transforms` (b0 in the G-Buffer VS and the
// light-volume VS).
Transforms_CB :: struct #align (16) {
	world:           matrix[4, 4]f32,
	world_view:      matrix[4, 4]f32,
	world_view_proj: matrix[4, 4]f32,
}

// Lights.hlsl `LightParams` (b0 in the light PS). Every float3 is followed
// by a pad word because HLSL packs each cbuffer member into its own
// 16-byte register boundary here — LightPos, LightColor and LightDirection
// are each declared as a bare float3 in the shader.
Light_Params_CB :: struct #align (16) {
	light_pos:       [3]f32,
	_pad0:           f32,
	light_color:     [3]f32,
	_pad1:           f32,
	light_direction: [3]f32,
	_pad2:           f32,
	spot_angles:     [2]f32,
	_pad3:           [2]f32,
	light_range:     [4]f32,
}

#assert(size_of(Light_Params_CB) == 80)

// Lights.hlsl `CameraParams` (b0 in the light-quad VS, b1 in the light PS).
// The matrices start at byte offset 16, which Odin's 32-byte-aligned matrix
// type can't express — so they're stored as raw float arrays (same memory).
// Shaders compile with PACK_MATRIX_ROW_MAJOR (see glyph:shader), so an Odin
// column-vector matrix arrives transposed, which is what the book's
// `mul(v, M)` shaders want. That also means Lights.hlsl's
// `ProjMatrix[3][2] / (z - ProjMatrix[2][2])` reads Odin's proj[2,3] and
// proj[2,2] — the LH 0..1 depth terms it needs to linearize the z-buffer.
Camera_Params_CB :: struct #align (16) {
	camera_pos: [3]f32,
	_pad0:      f32,
	proj:       [16]f32,
	inv_proj:   [16]f32,
}

#assert(size_of(Camera_Params_CB) == 144)

// The display blit's destination rectangle in clip space.
Blit_CB :: struct #align (16) {
	dst_rect: [4]f32, // x0, y0(top), x1, y1(bottom) in NDC
}

// --- vertex formats ----------------------------------------------------------

// Matches GBuffer.hlsl's VSInput: POSITION/TEXCOORDS0/NORMAL/TANGENT at
// offsets 0/12/20/32, as the input layout in `setup` declares. The .w of
// the tangent carries the bitangent handedness sign.
Scene_Vertex :: struct {
	position:  [3]f32,
	texcoords: [2]f32,
	normal:    [3]f32,
	tangent:   [4]f32,
}

Quad_Vertex :: struct {
	position:  [4]f32,
	texcoords: [2]f32,
}

Light :: struct {
	position: [3]f32,
	color:    [3]f32,
	range:    f32,
}

// --- Lengyel tangent frame (GeometryDX11::ComputeTangentFrame) --------------

compute_tangent_frame :: proc(vertices: []Scene_Vertex, indices: []u32) {
	tangents := make([][3]f32, len(vertices))
	bitangents := make([][3]f32, len(vertices))
	defer delete(tangents)
	defer delete(bitangents)

	for i := 0; i < len(indices); i += 3 {
		i1 := indices[i + 0]
		i2 := indices[i + 1]
		i3 := indices[i + 2]

		e1 := vertices[i2].position - vertices[i1].position
		e2 := vertices[i3].position - vertices[i1].position
		w1 := vertices[i1].texcoords
		w2 := vertices[i2].texcoords
		w3 := vertices[i3].texcoords

		s1 := w2.x - w1.x
		s2 := w3.x - w1.x
		t1 := w2.y - w1.y
		t2 := w3.y - w1.y

		r := 1.0 / (s1 * t2 - s2 * t1)
		s_dir := (e1 * t2 - e2 * t1) * r
		t_dir := (e2 * s1 - e1 * s2) * r

		tangents[i1] += s_dir
		tangents[i2] += s_dir
		tangents[i3] += s_dir
		bitangents[i1] += t_dir
		bitangents[i2] += t_dir
		bitangents[i3] += t_dir
	}

	for &v, i in vertices {
		n := v.normal
		t := tangents[i]
		tangent := linalg.normalize(t - n * linalg.dot(n, t))
		sign: f32 = -1.0 if linalg.dot(linalg.cross(n, t), bitangents[i]) < 0 else 1.0
		v.tangent = {tangent.x, tangent.y, tangent.z, sign}
	}
}

// --- window messages → input state ------------------------------------------

App_State :: struct {
	input:           Camera_Input,
	save_screenshot: bool,
	setting_keys:    [5]bool, // pending V/N/K/O/M presses
	pending_resize:  [2]u32,
	last_mouse:      [2]i32,
	mouse_valid:     bool,
}

SETTING_KEYS := [5]u8{'V', 'N', 'K', 'O', 'M'}

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
		// The settings keys are handled on keydown in App::HandleEvent.
		handled := false
		for key, i in SETTING_KEYS {
			if wparam == win32.WPARAM(key) {
				state.setting_keys[i] = true
				handled = true
			}
		}
		if !handled {
			set_camera_key(state, wparam, true)
		}

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

// --- render targets (ViewDeferredRenderer's per-AA-mode textures) -----------

Color_Target :: struct {
	tex: ^d3d11.ITexture2D,
	rtv: ^d3d11.IRenderTargetView,
	srv: ^d3d11.IShaderResourceView,
}

color_target_create :: proc(device: ^d3d11.IDevice, width, height: u32, format: dxgi.FORMAT, samples: u32) -> (t: Color_Target, ok: bool) {
	desc := d3d11.TEXTURE2D_DESC {
		Width      = width,
		Height     = height,
		MipLevels  = 1,
		ArraySize  = 1,
		Format     = format,
		SampleDesc = {Count = samples, Quality = 0},
		Usage      = .DEFAULT,
		BindFlags  = {.SHADER_RESOURCE, .RENDER_TARGET},
	}
	if device->CreateTexture2D(&desc, nil, &t.tex) < 0 {return}
	if device->CreateRenderTargetView((^d3d11.IResource)(t.tex), nil, &t.rtv) < 0 {return}
	if device->CreateShaderResourceView((^d3d11.IResource)(t.tex), nil, &t.srv) < 0 {return}
	return t, true
}

color_target_destroy :: proc(t: ^Color_Target) {
	if t.srv != nil {t.srv->Release()}
	if t.rtv != nil {t.rtv->Release()}
	if t.tex != nil {t.tex->Release()}
	t^ = {}
}

AA_Targets :: struct {
	gbuf_unopt:   [4]Color_Target, // R32G32B32A32_FLOAT x4
	gbuf_opt:     [3]Color_Target, // R16G16_SNORM, R10G10B10A2, R8G8B8A8
	final:        Color_Target, // R10G10B10A2
	depth_tex:    ^d3d11.ITexture2D, // R24G8_TYPELESS
	depth_dsv:    ^d3d11.IDepthStencilView,
	depth_dsv_ro: ^d3d11.IDepthStencilView,
	depth_srv:    ^d3d11.IShaderResourceView,
	width:        u32, // 2x the window for SSAA
	height:       u32,
}

Targets :: struct {
	aa:      [AA_Mode]AA_Targets,
	resolve: Color_Target, // window-sized, single-sample
}

targets_destroy :: proc(t: ^Targets) {
	for &aa in t.aa {
		for &ct in aa.gbuf_unopt {color_target_destroy(&ct)}
		for &ct in aa.gbuf_opt {color_target_destroy(&ct)}
		color_target_destroy(&aa.final)
		if aa.depth_srv != nil {aa.depth_srv->Release()}
		if aa.depth_dsv_ro != nil {aa.depth_dsv_ro->Release()}
		if aa.depth_dsv != nil {aa.depth_dsv->Release()}
		if aa.depth_tex != nil {aa.depth_tex->Release()}
		aa = {}
	}
	color_target_destroy(&t.resolve)
	t^ = {}
}

targets_create :: proc(device: ^d3d11.IDevice, width, height: u32) -> (t: Targets, ok: bool) {
	defer if !ok {targets_destroy(&t)}

	for mode in AA_Mode {
		aa := &t.aa[mode]
		aa.width = width * 2 if mode == .SSAA else width
		aa.height = height * 2 if mode == .SSAA else height
		samples: u32 = 4 if mode == .MSAA else 1

		for i in 0 ..< 4 {
			aa.gbuf_unopt[i] = color_target_create(device, aa.width, aa.height, .R32G32B32A32_FLOAT, samples) or_return
		}
		aa.gbuf_opt[0] = color_target_create(device, aa.width, aa.height, .R16G16_SNORM, samples) or_return
		aa.gbuf_opt[1] = color_target_create(device, aa.width, aa.height, .R10G10B10A2_UNORM, samples) or_return
		aa.gbuf_opt[2] = color_target_create(device, aa.width, aa.height, .R8G8B8A8_UNORM, samples) or_return
		aa.final = color_target_create(device, aa.width, aa.height, .R10G10B10A2_UNORM, samples) or_return

		// Typeless depth: written through a D24_UNORM_S8_UINT DSV, read back
		// through an R24_UNORM_X8_TYPELESS SRV. A concrete depth format
		// couldn't do both.
		depth_desc := d3d11.TEXTURE2D_DESC {
			Width      = aa.width,
			Height     = aa.height,
			MipLevels  = 1,
			ArraySize  = 1,
			Format     = .R24G8_TYPELESS,
			SampleDesc = {Count = samples, Quality = 0},
			Usage      = .DEFAULT,
			BindFlags  = {.DEPTH_STENCIL, .SHADER_RESOURCE},
		}
		if device->CreateTexture2D(&depth_desc, nil, &aa.depth_tex) < 0 {return}

		dsv_desc := d3d11.DEPTH_STENCIL_VIEW_DESC {
			Format        = .D24_UNORM_S8_UINT,
			ViewDimension = .TEXTURE2DMS if mode == .MSAA else .TEXTURE2D,
		}
		if device->CreateDepthStencilView((^d3d11.IResource)(aa.depth_tex), &dsv_desc, &aa.depth_dsv) < 0 {return}
		// The light pass needs depth bound as a DSV (for stencil/depth tests
		// against the light volume) and as an SRV (for position
		// reconstruction) at the same time. D3D11 only allows that if the
		// DSV is read-only, hence this second view over the same texture —
		// ViewDeferredRenderer's m_ReadOnlyDepthTarget.
		dsv_desc.Flags = {.DEPTH, .STENCIL} // read-only depth + stencil
		if device->CreateDepthStencilView((^d3d11.IResource)(aa.depth_tex), &dsv_desc, &aa.depth_dsv_ro) < 0 {return}

		srv_desc := d3d11.SHADER_RESOURCE_VIEW_DESC {
			Format        = .R24_UNORM_X8_TYPELESS,
			ViewDimension = .TEXTURE2DMS if mode == .MSAA else .TEXTURE2D,
		}
		// TEXTURE2DMS has no mip fields — the union must stay zeroed there.
		if mode != .MSAA {
			srv_desc.Texture2D = {MostDetailedMip = 0, MipLevels = 1}
		}
		if device->CreateShaderResourceView((^d3d11.IResource)(aa.depth_tex), &srv_desc, &aa.depth_srv) < 0 {return}
	}

	// Single-sample destination for the MSAA path's ResolveSubresource; must
	// match the final target's format.
	t.resolve = color_target_create(device, width, height, .R10G10B10A2_UNORM, 1) or_return
	return t, true
}

// --- light volume sphere (GeometryGeneratorDX11::GenerateSphere(8, 7, 1)) ---

generate_sphere :: proc(u_res, v_res: int) -> (vertices: [dynamic][3]f32, indices: [dynamic]u32) {
	radius :: 1.0
	rings := v_res - 2

	append(&vertices, [3]f32{0, radius, 0})
	for v in 1 ..= rings {
		for u in 0 ..< u_res {
			u_angle := f32(u) / f32(u_res) * 3.14159 * 2
			v_angle := f32(v) / f32(v_res - 1) * 3.14159
			append(&vertices, [3]f32{
				math.sin(v_angle) * math.cos(u_angle) * radius,
				math.cos(v_angle) * radius,
				-math.sin(v_angle) * math.sin(u_angle) * radius,
			})
		}
	}
	append(&vertices, [3]f32{0, -radius, 0})

	// Top cap.
	for u in 0 ..< u_res {
		next_u := (u + 1) % u_res
		append(&indices, 0, u32(u + 1), u32(next_u + 1))
	}
	// Middle rings.
	for v in 1 ..< v_res - 2 {
		top := 1 + (v - 1) * u_res
		bottom := top + u_res
		for u in 0 ..< u_res {
			next_u := (u + 1) % u_res
			append(&indices, u32(top + u), u32(bottom + u), u32(bottom + next_u))
			append(&indices, u32(bottom + next_u), u32(top + next_u), u32(top + u))
		}
	}
	// Bottom cap.
	top := 1 + (rings - 1) * u_res
	bottom := len(vertices) - 1
	for u in 0 ..< u_res {
		next_u := (u + 1) % u_res
		append(&indices, u32(top + u), u32(bottom), u32(top + next_u))
	}

	return
}

// --- scene / pipeline objects ------------------------------------------------

// Stand-in for the engine's SpriteRenderer: an alpha-blended, linearly
// sampled quad at a pixel-space rectangle.
BLIT_HLSL :: `
cbuffer BlitParams { float4 DstRect; }
Texture2D BlitTexture : register( t0 );
SamplerState BlitSampler : register( s0 );
struct VSOut { float4 pos : SV_Position; float2 tex : TEXCOORD; };
VSOut VSMain( uint id : SV_VertexID )
{
	VSOut o;
	float2 t = float2( id & 1, id >> 1 );
	o.pos = float4( lerp( DstRect.x, DstRect.z, t.x ), lerp( DstRect.y, DstRect.w, t.y ), 0, 1 );
	o.tex = t;
	return o;
}
float4 PSMain( VSOut i ) : SV_Target0
{
	return BlitTexture.Sample( BlitSampler, i.tex );
}
`

Light_Effect :: struct {
	vs: ^d3d11.IVertexShader,
	ps: ^d3d11.IPixelShader,
}

Scene :: struct {
	// Scene geometry.
	vertex_buffer:   ^d3d11.IBuffer,
	index_buffer:    ^d3d11.IBuffer,
	index_count:     u32,
	scene_layout:    ^d3d11.IInputLayout,

	// Fullscreen quad + light volume sphere.
	quad_vb:         ^d3d11.IBuffer,
	quad_ib:         ^d3d11.IBuffer,
	quad_layout:     ^d3d11.IInputLayout,
	sphere_vb:       ^d3d11.IBuffer,
	sphere_ib:       ^d3d11.IBuffer,
	sphere_indices:  u32,
	sphere_layout:   ^d3d11.IInputLayout,

	// Shaders.
	gbuffer_vs:      [Gbuf_Opt]^d3d11.IVertexShader,
	gbuffer_ps:      [Gbuf_Opt]^d3d11.IPixelShader,
	// Point-light shaders, indexed by [G-Buffer opt][volume path][MSAA].
	// The C++ keys the middle axis on all three LightOptModes, but only
	// Volumes changes a #define — None and ScissorRect compile identically,
	// so this collapses to 2.
	light_effects:   [Gbuf_Opt][2][2]Light_Effect,
	blit_vs:         ^d3d11.IVertexShader,
	blit_ps:         ^d3d11.IPixelShader,

	// States.
	ds_gbuffer:      ^d3d11.IDepthStencilState, // depth LESS write, stencil REPLACE
	ds_disabled:     ^d3d11.IDepthStencilState, // depth off, stencil EQUAL
	ds_less_equal:   ^d3d11.IDepthStencilState,
	ds_greater:      ^d3d11.IDepthStencilState, // GREATER_EQUAL
	bs_additive:     ^d3d11.IBlendState,
	bs_alpha:        ^d3d11.IBlendState, // the sprite blit's src-alpha blend
	rs_back_cull:    ^d3d11.IRasterizerState, // multisample, cull back
	rs_front_cull:   ^d3d11.IRasterizerState,
	rs_scissor:      ^d3d11.IRasterizerState,

	// Textures + samplers.
	diffuse_tex:     ^d3d11.ITexture2D,
	diffuse_srv:     ^d3d11.IShaderResourceView,
	normal_tex:      ^d3d11.ITexture2D,
	normal_srv:      ^d3d11.IShaderResourceView,
	sampler_aniso:   ^d3d11.ISamplerState,
	sampler_linear:  ^d3d11.ISamplerState,

	// Constant buffers.
	cb_transforms:   ^d3d11.IBuffer,
	cb_light_params: ^d3d11.IBuffer,
	cb_camera:       ^d3d11.IBuffer,
	cb_blit:         ^d3d11.IBuffer,
}

scene_destroy :: proc(s: ^Scene) {
	release :: proc(obj: ^$T) {
		if obj != nil {
			obj->Release()
		}
	}
	release(s.cb_blit)
	release(s.cb_camera)
	release(s.cb_light_params)
	release(s.cb_transforms)
	release(s.sampler_linear)
	release(s.sampler_aniso)
	release(s.normal_srv)
	release(s.normal_tex)
	release(s.diffuse_srv)
	release(s.diffuse_tex)
	release(s.rs_scissor)
	release(s.rs_front_cull)
	release(s.rs_back_cull)
	release(s.bs_alpha)
	release(s.bs_additive)
	release(s.ds_greater)
	release(s.ds_less_equal)
	release(s.ds_disabled)
	release(s.ds_gbuffer)
	release(s.blit_ps)
	release(s.blit_vs)
	for &per_opt in s.light_effects {
		for &per_vol in per_opt {
			for &e in per_vol {
				release(e.ps)
				release(e.vs)
			}
		}
	}
	for vs in s.gbuffer_vs {release(vs)}
	for ps in s.gbuffer_ps {release(ps)}
	release(s.sphere_layout)
	release(s.sphere_ib)
	release(s.sphere_vb)
	release(s.quad_layout)
	release(s.quad_ib)
	release(s.quad_vb)
	release(s.scene_layout)
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

setup :: proc(r: ^renderer.Renderer) -> (s: Scene, ok: bool) {
	device := r.device

	// G-Buffer shader pairs (K toggles between them).
	gbuffer_entries := [Gbuf_Opt][2]string {
		.Disabled = {"VSMain", "PSMain"},
		.Enabled  = {"VSMainOptimized", "PSMainOptimized"},
	}
	first_vs_blob: ^d3dc.ID3DBlob // kept for input-layout creation
	for entries, opt in gbuffer_entries {
		vs_blob := shader.compile("GBuffer.hlsl", entries[0], "vs_5_0") or_return
		ps_blob := shader.compile("GBuffer.hlsl", entries[1], "ps_5_0") or_return
		defer ps_blob->Release()
		if device->CreateVertexShader(vs_blob->GetBufferPointer(), vs_blob->GetBufferSize(), nil, &s.gbuffer_vs[opt]) < 0 {return}
		if device->CreatePixelShader(ps_blob->GetBufferPointer(), ps_blob->GetBufferSize(), nil, &s.gbuffer_ps[opt]) < 0 {return}
		if opt == .Disabled {
			first_vs_blob = vs_blob // released below, after layout creation
		} else {
			vs_blob->Release()
		}
	}
	defer first_vs_blob->Release()

	// Point-light shader permutations: [gbuffer opt][volumes][msaa], with
	// only the enabled flags defined (an undefined identifier is 0 in #if).
	quad_vs_blob, volume_vs_blob: ^d3dc.ID3DBlob
	for opt in Gbuf_Opt {
		for volumes in 0 ..< 2 {
			for msaa in 0 ..< 2 {
				defines: [dynamic]cstring
				defer delete(defines)
				// SPOTLIGHT/DIRECTIONALLIGHT are omitted rather than defined
				// to "0" — the C++ compiles those two light types too, but
				// this port only ever draws point lights.
				append(&defines, "POINTLIGHT")
				if opt == .Enabled {append(&defines, "GBUFFEROPTIMIZATIONS")}
				if volumes == 1 {append(&defines, "LIGHTVOLUMES")}
				if msaa == 1 {append(&defines, "MSAA")}

				vs_blob := shader.compile_defines("Lights.hlsl", "VSMain", "vs_5_0", defines[:]) or_return
				ps_blob := shader.compile_defines("Lights.hlsl", "PSMain", "ps_5_0", defines[:]) or_return
				defer ps_blob->Release()

				effect := &s.light_effects[opt][volumes][msaa]
				if device->CreateVertexShader(vs_blob->GetBufferPointer(), vs_blob->GetBufferSize(), nil, &effect.vs) < 0 {
					vs_blob->Release()
					return
				}
				if device->CreatePixelShader(ps_blob->GetBufferPointer(), ps_blob->GetBufferSize(), nil, &effect.ps) < 0 {
					vs_blob->Release()
					return
				}

				// Keep one blob of each VS flavor for input layouts.
				if opt == .Disabled && msaa == 0 {
					if volumes == 0 {
						quad_vs_blob = vs_blob
						continue
					} else {
						volume_vs_blob = vs_blob
						continue
					}
				}
				vs_blob->Release()
			}
		}
	}
	defer quad_vs_blob->Release()
	defer volume_vs_blob->Release()

	blit_vs_blob := shader.compile_source(BLIT_HLSL, "blit", "VSMain", "vs_5_0", nil) or_return
	defer blit_vs_blob->Release()
	blit_ps_blob := shader.compile_source(BLIT_HLSL, "blit", "PSMain", "ps_5_0", nil) or_return
	defer blit_ps_blob->Release()
	if device->CreateVertexShader(blit_vs_blob->GetBufferPointer(), blit_vs_blob->GetBufferSize(), nil, &s.blit_vs) < 0 {return}
	if device->CreatePixelShader(blit_ps_blob->GetBufferPointer(), blit_ps_blob->GetBufferSize(), nil, &s.blit_ps) < 0 {return}

	// Sample_Scene.ms3d with computed tangents.
	mesh := ms3d.load("Sample_Scene.ms3d") or_return
	defer ms3d.destroy(&mesh)

	vertices := make([]Scene_Vertex, len(mesh.vertices))
	defer delete(vertices)
	for v, i in mesh.vertices {
		vertices[i] = {
			position  = v.position,
			texcoords = v.texcoords,
			normal    = v.normal,
		}
	}
	compute_tangent_frame(vertices, mesh.indices[:])
	s.index_count = u32(len(mesh.indices))

	s.vertex_buffer = immutable_buffer(device, raw_data(vertices), u32(len(vertices) * size_of(Scene_Vertex)), {.VERTEX_BUFFER}) or_return
	s.index_buffer = immutable_buffer(device, raw_data(mesh.indices), u32(len(mesh.indices) * size_of(u32)), {.INDEX_BUFFER}) or_return

	scene_elements := [4]d3d11.INPUT_ELEMENT_DESC{
		{"POSITION", 0, .R32G32B32_FLOAT, 0, 0, .VERTEX_DATA, 0},
		{"TEXCOORDS", 0, .R32G32_FLOAT, 0, 12, .VERTEX_DATA, 0},
		{"NORMAL", 0, .R32G32B32_FLOAT, 0, 20, .VERTEX_DATA, 0},
		{"TANGENT", 0, .R32G32B32A32_FLOAT, 0, 32, .VERTEX_DATA, 0},
	}
	if device->CreateInputLayout(&scene_elements[0], 4, first_vs_blob->GetBufferPointer(), first_vs_blob->GetBufferSize(), &s.scene_layout) < 0 {return}

	// Fullscreen quad (GenerateFullScreenQuad).
	quad_vertices := [4]Quad_Vertex{
		{{-1, 1, 0, 1}, {0, 0}},
		{{-1, -1, 0, 1}, {0, 1}},
		{{1, 1, 0, 1}, {1, 0}},
		{{1, -1, 0, 1}, {1, 1}},
	}
	quad_indices := [6]u32{0, 2, 1, 1, 2, 3}
	s.quad_vb = immutable_buffer(device, &quad_vertices[0], size_of(quad_vertices), {.VERTEX_BUFFER}) or_return
	s.quad_ib = immutable_buffer(device, &quad_indices[0], size_of(quad_indices), {.INDEX_BUFFER}) or_return

	quad_elements := [2]d3d11.INPUT_ELEMENT_DESC{
		{"POSITION", 0, .R32G32B32A32_FLOAT, 0, 0, .VERTEX_DATA, 0},
		{"TEXCOORDS", 0, .R32G32_FLOAT, 0, 16, .VERTEX_DATA, 0},
	}
	if device->CreateInputLayout(&quad_elements[0], 2, quad_vs_blob->GetBufferPointer(), quad_vs_blob->GetBufferSize(), &s.quad_layout) < 0 {return}

	// Light volume sphere (GenerateSphere(8, 7, 1)).
	sphere_verts, sphere_idx := generate_sphere(8, 7)
	defer delete(sphere_verts)
	defer delete(sphere_idx)
	s.sphere_indices = u32(len(sphere_idx))
	s.sphere_vb = immutable_buffer(device, raw_data(sphere_verts), u32(len(sphere_verts) * 12), {.VERTEX_BUFFER}) or_return
	s.sphere_ib = immutable_buffer(device, raw_data(sphere_idx), u32(len(sphere_idx) * size_of(u32)), {.INDEX_BUFFER}) or_return

	sphere_elements := [1]d3d11.INPUT_ELEMENT_DESC{
		{"POSITION", 0, .R32G32B32_FLOAT, 0, 0, .VERTEX_DATA, 0},
	}
	if device->CreateInputLayout(&sphere_elements[0], 1, volume_vs_blob->GetBufferPointer(), volume_vs_blob->GetBufferSize(), &s.sphere_layout) < 0 {return}

	// Depth-stencil states. The G-Buffer pass REPLACEs stencil with the ref
	// value (1, passed to OMSetDepthStencilState) on every pixel it shades,
	// so the light pass can stencil-EQUAL-test against 1 and skip the sky.
	ds_desc := d3d11.DEPTH_STENCIL_DESC {
		DepthEnable = true,
		DepthWriteMask = .ALL,
		DepthFunc = .LESS,
		StencilEnable = true,
		StencilReadMask = d3d11.DEFAULT_STENCIL_READ_MASK,
		StencilWriteMask = d3d11.DEFAULT_STENCIL_WRITE_MASK,
		FrontFace = {StencilFailOp = .KEEP, StencilDepthFailOp = .KEEP, StencilPassOp = .REPLACE, StencilFunc = .ALWAYS},
	}
	ds_desc.BackFace = ds_desc.FrontFace
	if device->CreateDepthStencilState(&ds_desc, &s.ds_gbuffer) < 0 {return}

	// The light states: stencil EQUAL, no writes; depth off / <= / >=.
	// StencilWriteMask 0 and DepthWriteMask ZERO are required — the light
	// pass runs against the read-only DSV, which forbids any writes.
	ds_desc.DepthEnable = false
	ds_desc.DepthWriteMask = .ZERO
	ds_desc.StencilWriteMask = 0
	ds_desc.FrontFace = {StencilFailOp = .KEEP, StencilDepthFailOp = .KEEP, StencilPassOp = .KEEP, StencilFunc = .EQUAL}
	ds_desc.BackFace = ds_desc.FrontFace
	if device->CreateDepthStencilState(&ds_desc, &s.ds_disabled) < 0 {return}
	ds_desc.DepthEnable = true
	ds_desc.DepthFunc = .LESS_EQUAL
	if device->CreateDepthStencilState(&ds_desc, &s.ds_less_equal) < 0 {return}
	ds_desc.DepthFunc = .GREATER_EQUAL
	if device->CreateDepthStencilState(&ds_desc, &s.ds_greater) < 0 {return}

	// Additive blend for the lights; src-alpha blend for the sprite blit.
	blend_desc: d3d11.BLEND_DESC
	for &rt in blend_desc.RenderTarget {
		rt = {
			BlendEnable           = true,
			SrcBlend              = .ONE,
			DestBlend             = .ONE,
			BlendOp               = .ADD,
			SrcBlendAlpha         = .ONE,
			DestBlendAlpha        = .ONE,
			BlendOpAlpha          = .ADD,
			RenderTargetWriteMask = u8(d3d11.COLOR_WRITE_ENABLE_ALL),
		}
	}
	if device->CreateBlendState(&blend_desc, &s.bs_additive) < 0 {return}
	for &rt in blend_desc.RenderTarget {
		rt.SrcBlend = .SRC_ALPHA
		rt.DestBlend = .INV_SRC_ALPHA
	}
	if device->CreateBlendState(&blend_desc, &s.bs_alpha) < 0 {return}

	// Rasterizer states (all multisample-enabled like the C++).
	rs_desc := d3d11.RASTERIZER_DESC {
		FillMode          = .SOLID,
		CullMode          = .BACK,
		DepthClipEnable   = true,
		MultisampleEnable = true,
	}
	if device->CreateRasterizerState(&rs_desc, &s.rs_back_cull) < 0 {return}
	rs_desc.CullMode = .FRONT
	if device->CreateRasterizerState(&rs_desc, &s.rs_front_cull) < 0 {return}
	// ScissorEnable is baked into the rasterizer state, so the scissor path
	// needs its own object even though it culls like rs_back_cull.
	rs_desc.CullMode = .BACK
	rs_desc.ScissorEnable = true
	if device->CreateRasterizerState(&rs_desc, &s.rs_scissor) < 0 {return}

	// Textures + samplers.
	s.diffuse_tex, s.diffuse_srv = renderer.load_texture_png(r, "Hex.png") or_return
	s.normal_tex, s.normal_srv = renderer.load_texture_png(r, "Hex_Normal.png") or_return

	sampler_desc := d3d11.SAMPLER_DESC {
		Filter         = .ANISOTROPIC,
		AddressU       = .WRAP,
		AddressV       = .WRAP,
		AddressW       = .WRAP,
		MaxAnisotropy  = 16,
		ComparisonFunc = .ALWAYS,
		MaxLOD         = d3d11.FLOAT32_MAX,
	}
	if device->CreateSamplerState(&sampler_desc, &s.sampler_aniso) < 0 {return}
	sampler_desc.Filter = .MIN_MAG_MIP_LINEAR
	sampler_desc.AddressU = .CLAMP
	sampler_desc.AddressV = .CLAMP
	sampler_desc.AddressW = .CLAMP
	sampler_desc.MaxAnisotropy = 1
	if device->CreateSamplerState(&sampler_desc, &s.sampler_linear) < 0 {return}

	s.cb_transforms = dynamic_cbuffer(device, size_of(Transforms_CB)) or_return
	s.cb_light_params = dynamic_cbuffer(device, size_of(Light_Params_CB)) or_return
	s.cb_camera = dynamic_cbuffer(device, size_of(Camera_Params_CB)) or_return
	s.cb_blit = dynamic_cbuffer(device, size_of(Blit_CB)) or_return

	return s, true
}

// SetupViews' light grid — same as LightPrepass.
build_lights :: proc(lights: ^[dynamic]Light, mode: Light_Mode) {
	clear(lights)

	// 3, 5 or 7 lights per axis — 27, 125 or 343 draws in the light pass,
	// which is the whole point of the optimization toggles.
	cube_size := 3 + int(mode) * 2
	cube_min := -(cube_size / 2)
	cube_max := cube_size / 2

	min_extents := [3]f32{-4, 1, -4}
	max_extents := [3]f32{4, 11, 4}
	min_color := [3]f32{1, 0, 0}
	max_color := [3]f32{0, 1, 1}

	for x in cube_min ..= cube_max {
		for y in cube_min ..= cube_max {
			for z in cube_min ..= cube_max {
				lerp := [3]f32{
					f32(x - cube_min) / f32(cube_size - 1),
					f32(y - cube_min) / f32(cube_size - 1),
					f32(z - cube_min) / f32(cube_size - 1),
				}
				append(lights, Light{
					position = linalg.lerp(min_extents, max_extents, lerp),
					color    = linalg.lerp(min_color, max_color, lerp) * 1.5,
					range    = 2,
				})
			}
		}
	}
}

// ViewLights::CalcScissorRect — fit a screen-space scissor rectangle to the
// light's bounding sphere. Only the diagonal terms proj[0,0]/proj[1,1] are
// read, so the row-vs-column-vector question never arises; like the C++,
// this assumes a projection symmetric in X and Y.
calc_scissor_rect :: proc(view, proj: matrix[4, 4]f32, light_pos: [3]f32, light_range: f32, vp_width, vp_height: f32) -> d3d11.RECT {
	center := view * [4]f32{light_pos.x, light_pos.y, light_pos.z, 1}
	radius := light_range

	top := center + {0, radius, 0, 0}
	bottom := center - {0, radius, 0, 0}
	left := center - {radius, 0, 0, 0}
	right := center + {radius, 0, 0, 0}

	left.z = left.z - radius if left.x < 0 else left.z + radius
	right.z = right.z + radius if right.x < 0 else right.z - radius
	top.z = top.z + radius if top.y < 0 else top.z - radius
	bottom.z = bottom.z - radius if bottom.y < 0 else bottom.z + radius

	left.z = clamp(left.z, NEAR_CLIP, FAR_CLIP)
	right.z = clamp(right.z, NEAR_CLIP, FAR_CLIP)
	top.z = clamp(top.z, NEAR_CLIP, FAR_CLIP)
	bottom.z = clamp(bottom.z, NEAR_CLIP, FAR_CLIP)

	rect_left := clamp(left.x * proj[0, 0] / left.z, -1, 1)
	rect_right := clamp(right.x * proj[0, 0] / right.z, -1, 1)
	rect_top := clamp(top.y * proj[1, 1] / top.z, -1, 1)
	rect_bottom := clamp(bottom.y * proj[1, 1] / bottom.z, -1, 1)

	// Viewport transform (with the Y flip).
	return {
		left   = i32((rect_left * 0.5 + 0.5) * vp_width),
		right  = i32((rect_right * 0.5 + 0.5) * vp_width),
		top    = i32((1 - (rect_top * 0.5 + 0.5)) * vp_height),
		bottom = i32((1 - (rect_bottom * 0.5 + 0.5)) * vp_height),
	}
}

update_title :: proc(hwnd: win32.HWND, s: ^Settings) {
	title := fmt.tprintf(
		"DeferredRendering - V:%s  N:%s  K:%s  O:%s  M:%s",
		display_mode_names[s.display_mode],
		light_mode_names[s.light_mode],
		gbuf_opt_names[s.gbuf_opt],
		light_opt_names[s.light_opt],
		aa_mode_names[s.aa_mode],
	)
	win32.SetWindowTextW(hwnd, win32.utf8_to_wstring(title))
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
	window.set_caption(&win, "DeferredRendering")
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
	targets, targets_ok := targets_create(r.device, WIDTH, HEIGHT)
	if !scene_ok || !targets_ok {
		win32.MessageBoxW(
			nil,
			win32.L("Scene setup failed - see stderr for details (build without -subsystem:windows)."),
			win32.L("DeferredRendering setup failed"),
			win32.MB_ICONEXCLAMATION | win32.MB_SYSTEMMODAL,
		)
		return
	}
	defer scene_destroy(&scene)
	defer targets_destroy(&targets)

	cam := Fp_Camera {
		position = {4, 4.5, -4},
		pitch    = 0.407,
		yaw      = -0.707,
	}
	proj := camera.perspective_fov_lh(f32(linalg.PI) / 2, f32(WIDTH) / f32(HEIGHT), NEAR_CLIP, FAR_CLIP)

	// AppSettings.cpp startup values: optimizations on, volume lights.
	settings := Settings {
		gbuf_opt  = .Enabled,
		light_opt = .Volumes,
	}
	lights: [dynamic]Light
	defer delete(lights)
	update_title(win.hwnd, &settings)

	rotation_angle: f32 = 0.0
	ctx := r.ctx
	last_tick := time.tick_now()
	screenshot_number := 100_000

	// Draws `srv` alpha-blended at the pixel rectangle (x, y, w, h), the
	// sprite-renderer stand-in. Callers bind the render target + viewport.
	blit :: proc(ctx: ^d3d11.IDeviceContext, s: ^Scene, srv: ^d3d11.IShaderResourceView, x, y, w, h, vp_w, vp_h: f32) {
		srv := srv
		cb := Blit_CB {
			dst_rect = {
				x / vp_w * 2 - 1,
				1 - y / vp_h * 2,
				(x + w) / vp_w * 2 - 1,
				1 - (y + h) / vp_h * 2,
			},
		}
		write_cbuffer(ctx, s.cb_blit, &cb)

		// No vertex buffer: the four corners come from SV_VertexID, so the
		// input layout is deliberately nil.
		ctx->IASetInputLayout(nil)
		ctx->IASetPrimitiveTopology(.TRIANGLESTRIP)
		ctx->VSSetShader(s.blit_vs, nil, 0)
		ctx->VSSetConstantBuffers(0, 1, &s.cb_blit)
		ctx->GSSetShader(nil, nil, 0)
		ctx->PSSetShader(s.blit_ps, nil, 0)
		ctx->PSSetShaderResources(0, 1, &srv)
		ctx->PSSetSamplers(0, 1, &s.sampler_linear)
		ctx->OMSetDepthStencilState(nil, 0)
		ctx->OMSetBlendState(s.bs_alpha, nil, 0xffffffff)
		ctx->RSSetState(nil)
		ctx->Draw(4, 0)
	}

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
			targets_destroy(&targets)
			resize_ok: bool
			targets, resize_ok = targets_create(r.device, r.width, r.height)
			if !resize_ok {
				fmt.eprintln("failed to recreate render targets after resize")
				return
			}
			proj = camera.perspective_fov_lh(f32(linalg.PI) / 2, f32(r.width) / f32(r.height), NEAR_CLIP, FAR_CLIP)
			state.pending_resize = {}
		}

		settings_changed := false
		for &pending, i in state.setting_keys {
			if !pending {
				continue
			}
			pending = false
			settings_changed = true
			switch SETTING_KEYS[i] {
			case 'V':
				settings.display_mode = Display_Mode((int(settings.display_mode) + 1) % len(Display_Mode))
			case 'N':
				settings.light_mode = Light_Mode((int(settings.light_mode) + 1) % len(Light_Mode))
			case 'K':
				settings.gbuf_opt = Gbuf_Opt((int(settings.gbuf_opt) + 1) % len(Gbuf_Opt))
			case 'O':
				settings.light_opt = Light_Opt((int(settings.light_opt) + 1) % len(Light_Opt))
			case 'M':
				settings.aa_mode = AA_Mode((int(settings.aa_mode) + 1) % len(AA_Mode))
			}
		}
		if settings_changed {
			update_title(win.hwnd, &settings)
		}

		dt := f32(time.duration_seconds(time.tick_lap_time(&last_tick)))

		camera_update(&cam, &state.input, dt)
		view := camera_view_matrix(&cam)

		rotation_angle += dt * 0.2
		world := linalg.matrix4_rotate_f32(rotation_angle, {0, 1, 0})

		build_lights(&lights, settings.light_mode)

		aa := &targets.aa[settings.aa_mode]
		// GBuffer.hlsl's PSOutput declares SV_Target0..3; PSOutputOptimized
		// stops at SV_Target2 because position comes from the depth buffer.
		gbuf_count := 4 if settings.gbuf_opt == .Disabled else 3
		msaa := settings.aa_mode == .MSAA

		rt_viewport := d3d11.VIEWPORT {
			Width    = f32(aa.width),
			Height   = f32(aa.height),
			MinDepth = 0.0,
			MaxDepth = 1.0,
		}
		clear_color := [4]f32{0, 0, 0, 0}
		null_srvs := [4]^d3d11.IShaderResourceView{}

		// --- 1. G-Buffer pass (ViewGBuffer) --------------------------------
		rtvs: [4]^d3d11.IRenderTargetView
		for i in 0 ..< gbuf_count {
			rtvs[i] = aa.gbuf_unopt[i].rtv if settings.gbuf_opt == .Disabled else aa.gbuf_opt[i].rtv
		}
		// The writable DSV here, not depth_dsv_ro — this pass writes depth
		// and the stencil mask.
		ctx->OMSetRenderTargets(u32(gbuf_count), &rtvs[0], aa.depth_dsv)
		ctx->RSSetViewports(1, &rt_viewport)
		for i in 0 ..< gbuf_count {
			ctx->ClearRenderTargetView(rtvs[i], &clear_color)
		}
		ctx->ClearDepthStencilView(aa.depth_dsv, {.DEPTH, .STENCIL}, 1.0, 0)

		// Column-vector composition; uploaded without transposes because the
		// row-major compile flag hands the shaders the transpose they want
		// (see glyph:shader). world_view is what VSMainOptimized uses to put
		// the tangent frame in view space.
		transforms := Transforms_CB {
			world           = world,
			world_view      = view * world,
			world_view_proj = proj * view * world,
		}
		write_cbuffer(ctx, scene.cb_transforms, &transforms)

		stride: u32 = size_of(Scene_Vertex)
		offset: u32 = 0
		ctx->IASetInputLayout(scene.scene_layout)
		ctx->IASetVertexBuffers(0, 1, &scene.vertex_buffer, &stride, &offset)
		ctx->IASetIndexBuffer(scene.index_buffer, .R32_UINT, 0)
		ctx->IASetPrimitiveTopology(.TRIANGLELIST)
		ctx->VSSetShader(scene.gbuffer_vs[settings.gbuf_opt], nil, 0)
		ctx->VSSetConstantBuffers(0, 1, &scene.cb_transforms)
		ctx->GSSetShader(nil, nil, 0)
		ctx->PSSetShader(scene.gbuffer_ps[settings.gbuf_opt], nil, 0)
		scene_srvs := [2]^d3d11.IShaderResourceView{scene.diffuse_srv, scene.normal_srv}
		ctx->PSSetShaderResources(0, 2, &scene_srvs[0])
		ctx->PSSetSamplers(0, 1, &scene.sampler_aniso)
		// Stencil ref 1: the value REPLACEd into every shaded pixel.
		ctx->OMSetDepthStencilState(scene.ds_gbuffer, 1)
		ctx->OMSetBlendState(nil, nil, 0xffffffff)
		ctx->RSSetState(scene.rs_back_cull)
		ctx->DrawIndexed(scene.index_count, 0, 0)

		// --- 2. Light pass (ViewLights) ------------------------------------
		// Unbind the G-Buffer pass's PS textures first: they are about to be
		// bound the other way round (the G-Buffer RTVs become SRVs below),
		// and D3D11 would silently null one of the two bindings.
		ctx->PSSetShaderResources(0, 4, &null_srvs[0])
		// Clear with no DSV attached, then re-attach the read-only one: a
		// read-only DSV can't be cleared, and depth/stencil must survive the
		// pass anyway. Mirrors ViewLights::ExecuteTask's two ApplyRenderTargets.
		ctx->OMSetRenderTargets(1, &aa.final.rtv, nil)
		ctx->ClearRenderTargetView(aa.final.rtv, &clear_color)
		ctx->OMSetRenderTargets(1, &aa.final.rtv, aa.depth_dsv_ro)

		// G-Buffer SRVs t0..t3; with optimizations the depth SRV rides in t3.
		// Lights.hlsl deliberately declares both PositionTexture and
		// DepthTexture at register t3 — only one is referenced per
		// permutation, so the aliasing is safe and the slot is reused.
		light_srvs: [4]^d3d11.IShaderResourceView
		if settings.gbuf_opt == .Disabled {
			for i in 0 ..< 4 {
				light_srvs[i] = aa.gbuf_unopt[i].srv
			}
		} else {
			for i in 0 ..< 3 {
				light_srvs[i] = aa.gbuf_opt[i].srv
			}
			light_srvs[3] = aa.depth_srv
		}
		ctx->PSSetShaderResources(0, 4, &light_srvs[0])

		camera_cb := Camera_Params_CB {
			camera_pos = {0, 0, 0}, // the C++ passes the scene root's position — the origin
			proj       = transmute([16]f32)proj,
			inv_proj   = transmute([16]f32)linalg.inverse(proj),
		}
		write_cbuffer(ctx, scene.cb_camera, &camera_cb)

		effect := scene.light_effects[settings.gbuf_opt][1 if settings.light_opt == .Volumes else 0][1 if msaa else 0]
		ctx->VSSetShader(effect.vs, nil, 0)
		ctx->PSSetShader(effect.ps, nil, 0)
		// b0/b1 in declaration order: LightParams then CameraParams.
		light_ps_cbs := [2]^d3d11.IBuffer{scene.cb_light_params, scene.cb_camera}
		ctx->PSSetConstantBuffers(0, 2, &light_ps_cbs[0])
		ctx->OMSetBlendState(scene.bs_additive, nil, 0xffffffff)

		for light in lights {
			// LightParams: position/direction move to view space when the
			// G-Buffer optimizations reconstruct view-space position.
			light_cb := Light_Params_CB {
				light_pos       = light.position,
				light_color     = light.color,
				light_direction = linalg.normalize([3]f32{-1, -1, 1}), // LightParams default
				// cos(SpotInnerAngle/2), cos(SpotOuterAngle/2) with both
				// angles at their LightParams default of 0 — preserved from
				// the C++, and unread by the POINTLIGHT permutation.
				spot_angles     = {math.cos_f32(0), math.cos_f32(0)},
				light_range     = {light.range, 1, 1, 1},
			}
			if settings.gbuf_opt == .Enabled {
				pos4 := view * [4]f32{light.position.x, light.position.y, light.position.z, 1}
				dir4 := view * [4]f32{light_cb.light_direction.x, light_cb.light_direction.y, light_cb.light_direction.z, 0}
				light_cb.light_pos = pos4.xyz
				light_cb.light_direction = dir4.xyz
			}
			write_cbuffer(ctx, scene.cb_light_params, &light_cb)

			switch settings.light_opt {
			case .None:
				// The quad VS passes clip-space positions straight through
				// and only touches InvProjMatrix, so CameraParams is the
				// single cbuffer it keeps — landing at b0. (The volume VS
				// below keeps Transforms instead, also at b0.)
				ctx->RSSetState(scene.rs_back_cull)
				ctx->OMSetDepthStencilState(scene.ds_disabled, 1)
				quad_stride: u32 = size_of(Quad_Vertex)
				ctx->IASetInputLayout(scene.quad_layout)
				ctx->IASetVertexBuffers(0, 1, &scene.quad_vb, &quad_stride, &offset)
				ctx->IASetIndexBuffer(scene.quad_ib, .R32_UINT, 0)
				ctx->VSSetConstantBuffers(0, 1, &scene.cb_camera)
				ctx->DrawIndexed(6, 0, 0)

			case .Scissor_Rect:
				// Scissor is in target pixels, so the SSAA/MSAA target size
				// is the right viewport extent here, not the window size.
				rect := calc_scissor_rect(view, proj, light.position, light.range, f32(aa.width), f32(aa.height))
				ctx->RSSetScissorRects(1, &rect)
				ctx->RSSetState(scene.rs_scissor)
				ctx->OMSetDepthStencilState(scene.ds_disabled, 1)
				quad_stride: u32 = size_of(Quad_Vertex)
				ctx->IASetInputLayout(scene.quad_layout)
				ctx->IASetVertexBuffers(0, 1, &scene.quad_vb, &quad_stride, &offset)
				ctx->IASetIndexBuffer(scene.quad_ib, .R32_UINT, 0)
				ctx->VSSetConstantBuffers(0, 1, &scene.cb_camera)
				ctx->DrawIndexed(6, 0, 0)

			case .Volumes:
				// The C++'s quad fallback (volume crossing both clip planes)
				// can't happen with this light grid, so only spheres draw.
				light_pos_vs := view * [4]f32{light.position.x, light.position.y, light.position.z, 1}
				intersects_far := light_pos_vs.z + light.range >= FAR_CLIP

				// 1.1x slack so the unit sphere comfortably contains the
				// light's attenuation radius (m_WorldMatrix.Scale in the C++).
				volume_world := linalg.matrix4_translate_f32(light.position) * linalg.matrix4_scale_f32(light.range * 1.1)
				volume_transforms := Transforms_CB {
					world           = volume_world,
					world_view      = view * volume_world,
					world_view_proj = proj * view * volume_world,
				}
				write_cbuffer(ctx, scene.cb_transforms, &volume_transforms)

				// Normal case: draw the sphere's *back* faces (cull front)
				// and keep fragments whose depth is GREATER_EQUAL, i.e.
				// scene geometry that lies in front of the volume's far
				// side — so each lit pixel is shaded exactly once even when
				// the camera is inside the volume. If the volume pokes
				// through the far plane its back faces get clipped away, so
				// fall back to front faces with LESS_EQUAL.
				if intersects_far {
					ctx->RSSetState(scene.rs_back_cull)
					ctx->OMSetDepthStencilState(scene.ds_less_equal, 1)
				} else {
					ctx->RSSetState(scene.rs_front_cull)
					ctx->OMSetDepthStencilState(scene.ds_greater, 1)
				}

				sphere_stride: u32 = 12
				ctx->IASetInputLayout(scene.sphere_layout)
				ctx->IASetVertexBuffers(0, 1, &scene.sphere_vb, &sphere_stride, &offset)
				ctx->IASetIndexBuffer(scene.sphere_ib, .R32_UINT, 0)
				ctx->VSSetConstantBuffers(0, 1, &scene.cb_transforms)
				ctx->DrawIndexed(scene.sphere_indices, 0, 0)
			}
		}

		// --- 3. Display (ViewDeferredRenderer::ExecuteTask) ----------------
		// Unbind the G-Buffer SRVs before the final target (also an SRV
		// below) and the backbuffer take over the pipeline.
		ctx->PSSetShaderResources(0, 4, &null_srvs[0])
		ctx->OMSetRenderTargets(1, &r.rtv, nil)
		// Back to window pixels — the passes above ran at aa.width/height.
		backbuffer_viewport := d3d11.VIEWPORT {
			Width    = f32(r.width),
			Height   = f32(r.height),
			MinDepth = 0.0,
			MaxDepth = 1.0,
		}
		ctx->RSSetViewports(1, &backbuffer_viewport)
		ctx->ClearRenderTargetView(r.rtv, &clear_color)

		// SSAA's targets are 2x, so a 0.5 destination scale lands them back
		// at window size — and the blit's linear sampler is what actually
		// performs the 2x2 downsample. This is the C++'s SpriteRenderer
		// ScaleMatrix( scaleFactor ).
		scale: f32 = 0.5 if settings.aa_mode == .SSAA else 1.0
		vp_w := f32(r.width)
		vp_h := f32(r.height)
		tex_w := f32(aa.width)
		tex_h := f32(aa.height)

		switch {
		case settings.display_mode == .Final:
			srv := aa.final.srv
			// A multisampled SRV can't be Sampled, only Loaded — so the MSAA
			// path resolves into the single-sample target first, and blits
			// that 1:1 (its samples, not its resolution, carried the AA).
			if msaa {
				ctx->ResolveSubresource(
					(^d3d11.IResource)(targets.resolve.tex), 0,
					(^d3d11.IResource)(aa.final.tex), 0,
					.R10G10B10A2_UNORM,
				)
				srv = targets.resolve.srv
				blit(ctx, &scene, srv, 0, 0, vp_w, vp_h, vp_w, vp_h)
			} else {
				blit(ctx, &scene, srv, 0, 0, tex_w * scale, tex_h * scale, vp_w, vp_h)
			}

		case msaa:
		// The C++ prints "Unable to view G-Buffers while MSAA is enabled";
		// without text rendering the screen just stays black.

		case settings.display_mode == .G_Buffer:
			// Quadrants at the C++'s hardcoded 1280x720 offsets — at this
			// app's 800x480 the 640/360 origins put the right and bottom
			// tiles largely off-screen. Preserved rather than fixed.
			tile :: proc(gbuf_opt: Gbuf_Opt, aa: ^AA_Targets, i: int) -> ^d3d11.IShaderResourceView {
				return aa.gbuf_unopt[i].srv if gbuf_opt == .Disabled else aa.gbuf_opt[i].srv
			}
			blit(ctx, &scene, tile(settings.gbuf_opt, aa, 0), 0, 0, tex_w * 0.5 * scale, tex_h * 0.5 * scale, vp_w, vp_h)
			blit(ctx, &scene, tile(settings.gbuf_opt, aa, 1), 640, 0, tex_w * 0.5 * scale, tex_h * 0.5 * scale, vp_w, vp_h)
			blit(ctx, &scene, tile(settings.gbuf_opt, aa, 2), 0, 360, tex_w * 0.5 * scale, tex_h * 0.5 * scale, vp_w, vp_h)
			last := aa.depth_srv if settings.gbuf_opt == .Enabled else aa.gbuf_unopt[3].srv
			blit(ctx, &scene, last, 640, 360, tex_w * 0.5 * scale, tex_h * 0.5 * scale, vp_w, vp_h)

		case:
			// A single G-Buffer attribute fullscreen. Normals/Diffuse/
			// Specular/Position are consecutive, so subtracting .Normals
			// gives the target index — the C++'s
			// `gBuffer[ DisplayMode::Value - DisplayMode::Normals ]`.
			index := int(settings.display_mode) - int(Display_Mode.Normals)
			srv: ^d3d11.IShaderResourceView
			if settings.gbuf_opt == .Enabled && settings.display_mode == .Position {
				srv = aa.depth_srv
			} else if settings.gbuf_opt == .Enabled {
				srv = aa.gbuf_opt[index].srv
			} else {
				srv = aa.gbuf_unopt[index].srv
			}
			blit(ctx, &scene, srv, 0, 0, tex_w * scale, tex_h * scale, vp_w, vp_h)
		}

		// Leave nothing bound as an SRV: next frame starts by binding these
		// same textures as render targets.
		ctx->PSSetShaderResources(0, 4, &null_srvs[0])
		ctx->OMSetBlendState(nil, nil, 0xffffffff)

		renderer.present(&r)

		if state.save_screenshot {
			state.save_screenshot = false
			screenshot_number += 1
			renderer.save_backbuffer_png(&r, fmt.tprintf("DeferredRendering%d.png", screenshot_number))
		}

		free_all(context.temp_allocator)
	}
}
