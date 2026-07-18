// Odin port of the LightPrepass sample (Applications/LightPrepass/) — the
// chapter-11 light prepass (deferred lighting) renderer with MSAA
// edge-detection, no text overlay (FPS + light-count text live in the title
// bar instead).
//
// The frame, mirroring ViewLightPrepassRenderer and its three sub-views
// (everything below at 4x MSAA):
//
//   1. G-Buffer pass (ViewGBuffer / GBufferLP.hlsl): render Sample_Scene.ms3d
//      into an R16G16B16A16_FLOAT target — spheremap-encoded view-space
//      normal-mapped normals in .xy, specular power 64 in .z, and an
//      "edge pixel" flag in .w from SV_Coverage (any pixel whose triangle
//      didn't cover all 4 samples). Depth+stencil write, stencil = 1 where
//      geometry rendered.
//   2. Mask pass (MaskLP.hlsl): fullscreen quad, stencil INCR on pixels
//      whose G-Buffer .w says "edge" (clip() elsewhere) — leaving stencil 1
//      on interior pixels and 2 on edge pixels.
//   3. Light pass (ViewLights / LightsLP.hlsl): every light is one point
//      vertex; the GS fits a screen-space quad to the light volume at the
//      sphere's far depth, and with GREATER_EQUAL depth testing against the
//      read-only depth buffer only pixels where the volume touches geometry
//      survive. Additive blend into an R16G16B16A16_FLOAT light buffer
//      (diffuse rgb + mono specular in .w). Each light draws twice: stencil
//      ref 1 with the per-pixel shader, then ref 2 with the per-sample
//      (SV_SampleIndex) shader for edge pixels.
//   4. Final pass (ViewFinalPass / FinalPassLP.hlsl): re-render the scene
//      geometry (depth LESS_EQUAL, no writes), fetching the covered light
//      samples per SV_Coverage, modulating by the Hex.png albedo, into an
//      R10G10B10A2_UNORM target.
//   5. Resolve the MSAA final target and blit it to the backbuffer (the
//      C++ uses its SpriteRenderer for this; here it's a fullscreen
//      triangle from an inline shader).
//
// The scene spins at 0.2 rad/s; the point-light grid lerps position over
// (-4,1,-4)..(4,11,4) and color red..cyan (x1.5), range 2. N cycles
// 3x3x3 / 5x5x5 / 7x7x7 lights (27 / 125 / 343). First-person camera as in
// the C++ (right-drag look, W/S/A/D/Q/E, Ctrl sprint), starting at
// (4, 4.5, -4) pitched down. Esc quits, Space screenshots, resize supported.
//
// The C++ also compiles spot- and directional-light shader variants, but
// SetupLights only ever adds point lights, so those effects never draw —
// they are omitted here.
package main

import "core:fmt"
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
HEIGHT :: 480
NEAR_CLIP :: 1.0
FAR_CLIP :: 15.0
MSAA_SAMPLES :: 4
MAX_LIGHTS :: 1000 // ViewLights::MaxNumLights

// --- cbuffer mirrors ---------------------------------------------------------

// GBufferLP/FinalPassLP `Transforms` (b0 in both vertex shaders).
Transforms_CB :: struct #align (16) {
	world:           matrix[4, 4]f32,
	world_view:      matrix[4, 4]f32,
	world_view_proj: matrix[4, 4]f32,
}

// LightsLP `CameraParams` (b0 in the light VS, GS, and PS).
Camera_CB :: struct #align (16) {
	view:        matrix[4, 4]f32,
	proj:        matrix[4, 4]f32,
	inv_proj:    matrix[4, 4]f32,
	clip_planes: [2]f32,
	_pad:        [2]f32,
}

// --- vertex formats ----------------------------------------------------------

// The ms3d layout with the TANGENT element ComputeTangentFrame appends.
Scene_Vertex :: struct {
	position:  [3]f32,
	texcoords: [2]f32,
	normal:    [3]f32,
	tangent:   [4]f32, // xyz tangent, w handedness
}

// LightParams — one per light, drawn as a point list. The engine writes the
// whole struct into the vertex buffer; the trailing light type is not part
// of the input layout.
Light_Vertex :: struct {
	position:    [3]f32,
	color:       [3]f32,
	direction:   [3]f32,
	range:       f32,
	spot_angles: [2]f32,
	type:        i32, // 0 = point; the only type the app ever adds
}

#assert(size_of(Light_Vertex) == 52)

// The mask pass's fullscreen quad (GeometryGeneratorDX11::GenerateFullScreenQuad).
Quad_Vertex :: struct {
	position:  [4]f32,
	texcoords: [2]f32,
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

		v1 := vertices[i1].position
		v2 := vertices[i2].position
		v3 := vertices[i3].position
		w1 := vertices[i1].texcoords
		w2 := vertices[i2].texcoords
		w3 := vertices[i3].texcoords

		e1 := v2 - v1
		e2 := v3 - v1
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

		// Gram-Schmidt orthogonalize, then handedness from the bitangent.
		tangent := linalg.normalize(t - n * linalg.dot(n, t))
		sign: f32 = -1.0 if linalg.dot(linalg.cross(n, t), bitangents[i]) < 0 else 1.0
		v.tangent = {tangent.x, tangent.y, tangent.z, sign}
	}
}

// --- window messages → input state ------------------------------------------

Light_Mode :: enum {
	Lights3x3x3,
	Lights5x5x5,
	Lights7x7x7,
}

light_mode_names := [Light_Mode]string {
	.Lights3x3x3 = "3x3x3",
	.Lights5x5x5 = "5x5x5",
	.Lights7x7x7 = "7x7x7",
}

App_State :: struct {
	input:           Camera_Input,
	save_screenshot: bool,
	cycle_lights:    bool,
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
		// LightMode::Key is handled on keydown in App::HandleEvent.
		if wparam == win32.WPARAM('N') {
			state.cycle_lights = true
		} else {
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

// --- render targets (ViewLightPrepassRenderer's five textures) --------------

Targets :: struct {
	gbuffer_tex:    ^d3d11.ITexture2D, // R16G16B16A16_FLOAT, 4x MSAA
	gbuffer_rtv:    ^d3d11.IRenderTargetView,
	gbuffer_srv:    ^d3d11.IShaderResourceView,
	light_tex:      ^d3d11.ITexture2D, // R16G16B16A16_FLOAT, 4x MSAA
	light_rtv:      ^d3d11.IRenderTargetView,
	light_srv:      ^d3d11.IShaderResourceView,
	final_tex:      ^d3d11.ITexture2D, // R10G10B10A2_UNORM, 4x MSAA
	final_rtv:      ^d3d11.IRenderTargetView,
	depth_tex:      ^d3d11.ITexture2D, // R24G8_TYPELESS, 4x MSAA
	depth_dsv:      ^d3d11.IDepthStencilView,
	depth_dsv_ro:   ^d3d11.IDepthStencilView, // read-only: SRV bound simultaneously
	depth_srv:      ^d3d11.IShaderResourceView,
	resolve_tex:    ^d3d11.ITexture2D, // R10G10B10A2_UNORM, single sample
	resolve_srv:    ^d3d11.IShaderResourceView,
}

targets_destroy :: proc(t: ^Targets) {
	release :: proc(obj: ^$T) {
		if obj != nil {
			obj->Release()
		}
	}
	release(t.resolve_srv)
	release(t.resolve_tex)
	release(t.depth_srv)
	release(t.depth_dsv_ro)
	release(t.depth_dsv)
	release(t.depth_tex)
	release(t.final_rtv)
	release(t.final_tex)
	release(t.light_srv)
	release(t.light_rtv)
	release(t.light_tex)
	release(t.gbuffer_srv)
	release(t.gbuffer_rtv)
	release(t.gbuffer_tex)
	t^ = {}
}

targets_create :: proc(device: ^d3d11.IDevice, width, height: u32) -> (t: Targets, ok: bool) {
	defer if !ok {targets_destroy(&t)}

	color_desc := d3d11.TEXTURE2D_DESC {
		Width      = width,
		Height     = height,
		MipLevels  = 1,
		ArraySize  = 1,
		Format     = .R16G16B16A16_FLOAT,
		SampleDesc = {Count = MSAA_SAMPLES, Quality = 0},
		Usage      = .DEFAULT,
		BindFlags  = {.SHADER_RESOURCE, .RENDER_TARGET},
	}
	if device->CreateTexture2D(&color_desc, nil, &t.gbuffer_tex) < 0 {return}
	if device->CreateRenderTargetView((^d3d11.IResource)(t.gbuffer_tex), nil, &t.gbuffer_rtv) < 0 {return}
	if device->CreateShaderResourceView((^d3d11.IResource)(t.gbuffer_tex), nil, &t.gbuffer_srv) < 0 {return}

	if device->CreateTexture2D(&color_desc, nil, &t.light_tex) < 0 {return}
	if device->CreateRenderTargetView((^d3d11.IResource)(t.light_tex), nil, &t.light_rtv) < 0 {return}
	if device->CreateShaderResourceView((^d3d11.IResource)(t.light_tex), nil, &t.light_srv) < 0 {return}

	color_desc.Format = .R10G10B10A2_UNORM
	if device->CreateTexture2D(&color_desc, nil, &t.final_tex) < 0 {return}
	if device->CreateRenderTargetView((^d3d11.IResource)(t.final_tex), nil, &t.final_rtv) < 0 {return}

	// Depth-stencil: typeless texture with a D24S8 DSV, an R24X8 SRV, and a
	// second, read-only DSV so depth can be tested while bound as an SRV.
	depth_desc := d3d11.TEXTURE2D_DESC {
		Width      = width,
		Height     = height,
		MipLevels  = 1,
		ArraySize  = 1,
		Format     = .R24G8_TYPELESS,
		SampleDesc = {Count = MSAA_SAMPLES, Quality = 0},
		Usage      = .DEFAULT,
		BindFlags  = {.DEPTH_STENCIL, .SHADER_RESOURCE},
	}
	if device->CreateTexture2D(&depth_desc, nil, &t.depth_tex) < 0 {return}

	dsv_desc := d3d11.DEPTH_STENCIL_VIEW_DESC {
		Format        = .D24_UNORM_S8_UINT,
		ViewDimension = .TEXTURE2DMS,
	}
	if device->CreateDepthStencilView((^d3d11.IResource)(t.depth_tex), &dsv_desc, &t.depth_dsv) < 0 {return}
	dsv_desc.Flags = {.DEPTH, .STENCIL} // D3D11_DSV_READ_ONLY_DEPTH | _STENCIL
	if device->CreateDepthStencilView((^d3d11.IResource)(t.depth_tex), &dsv_desc, &t.depth_dsv_ro) < 0 {return}

	depth_srv_desc := d3d11.SHADER_RESOURCE_VIEW_DESC {
		Format        = .R24_UNORM_X8_TYPELESS,
		ViewDimension = .TEXTURE2DMS,
	}
	if device->CreateShaderResourceView((^d3d11.IResource)(t.depth_tex), &depth_srv_desc, &t.depth_srv) < 0 {return}

	resolve_desc := d3d11.TEXTURE2D_DESC {
		Width      = width,
		Height     = height,
		MipLevels  = 1,
		ArraySize  = 1,
		Format     = .R10G10B10A2_UNORM,
		SampleDesc = {Count = 1, Quality = 0},
		Usage      = .DEFAULT,
		BindFlags  = {.SHADER_RESOURCE, .RENDER_TARGET},
	}
	if device->CreateTexture2D(&resolve_desc, nil, &t.resolve_tex) < 0 {return}
	if device->CreateShaderResourceView((^d3d11.IResource)(t.resolve_tex), nil, &t.resolve_srv) < 0 {return}

	return t, true
}

// --- scene / pipeline objects ------------------------------------------------

BLIT_HLSL :: `
Texture2D BlitTexture : register( t0 );
SamplerState BlitSampler : register( s0 );
struct VSOut { float4 pos : SV_Position; float2 tex : TEXCOORD; };
VSOut VSMain( uint id : SV_VertexID )
{
	VSOut o;
	float2 t = float2( ( id << 1 ) & 2, id & 2 );
	o.pos = float4( t * float2( 2, -2 ) + float2( -1, 1 ), 0, 1 );
	o.tex = t;
	return o;
}
float4 PSMain( VSOut i ) : SV_Target0
{
	return BlitTexture.Sample( BlitSampler, i.tex );
}
`

Scene :: struct {
	// Scene geometry (Sample_Scene.ms3d + tangents).
	vertex_buffer:      ^d3d11.IBuffer,
	index_buffer:       ^d3d11.IBuffer,
	index_count:        u32,
	scene_layout:       ^d3d11.IInputLayout,

	// Fullscreen quad for the mask pass.
	quad_vb:            ^d3d11.IBuffer,
	quad_ib:            ^d3d11.IBuffer,
	quad_layout:        ^d3d11.IInputLayout,

	// Dynamic point-list vertex buffer of lights.
	light_vb:           ^d3d11.IBuffer,

	// Shaders.
	gbuffer_vs:         ^d3d11.IVertexShader,
	gbuffer_ps:         ^d3d11.IPixelShader,
	mask_vs:            ^d3d11.IVertexShader,
	mask_ps:            ^d3d11.IPixelShader,
	light_vs:           ^d3d11.IVertexShader,
	light_gs:           ^d3d11.IGeometryShader,
	light_ps:           ^d3d11.IPixelShader, // PSMain (per-pixel)
	light_ps_sample:    ^d3d11.IPixelShader, // PSMainPerSample
	light_layout:       ^d3d11.IInputLayout,
	final_vs:           ^d3d11.IVertexShader,
	final_ps:           ^d3d11.IPixelShader,
	blit_vs:            ^d3d11.IVertexShader,
	blit_ps:            ^d3d11.IPixelShader,

	// States.
	ds_gbuffer:         ^d3d11.IDepthStencilState, // depth LESS write, stencil REPLACE ref 1
	ds_mask:            ^d3d11.IDepthStencilState, // depth off, stencil EQUAL/INCR ref 1
	ds_light:           ^d3d11.IDepthStencilState, // depth GREATER_EQUAL no-write, stencil EQUAL
	ds_final:           ^d3d11.IDepthStencilState, // depth LESS_EQUAL no-write, stencil off
	bs_additive:        ^d3d11.IBlendState,
	rs_msaa:            ^d3d11.IRasterizerState, // MultisampleEnable, cull back

	// Textures + samplers.
	diffuse_tex:        ^d3d11.ITexture2D,
	diffuse_srv:        ^d3d11.IShaderResourceView,
	normal_tex:         ^d3d11.ITexture2D,
	normal_srv:         ^d3d11.IShaderResourceView,
	sampler_aniso:      ^d3d11.ISamplerState,
	sampler_blit:       ^d3d11.ISamplerState,

	// Constant buffers.
	cb_transforms:      ^d3d11.IBuffer, // b0 for G-Buffer + final vertex shaders
	cb_camera:          ^d3d11.IBuffer, // b0 for light VS/GS/PS
}

scene_destroy :: proc(s: ^Scene) {
	release :: proc(obj: ^$T) {
		if obj != nil {
			obj->Release()
		}
	}
	release(s.cb_camera)
	release(s.cb_transforms)
	release(s.sampler_blit)
	release(s.sampler_aniso)
	release(s.normal_srv)
	release(s.normal_tex)
	release(s.diffuse_srv)
	release(s.diffuse_tex)
	release(s.rs_msaa)
	release(s.bs_additive)
	release(s.ds_final)
	release(s.ds_light)
	release(s.ds_mask)
	release(s.ds_gbuffer)
	release(s.blit_ps)
	release(s.blit_vs)
	release(s.final_ps)
	release(s.final_vs)
	release(s.light_layout)
	release(s.light_ps_sample)
	release(s.light_ps)
	release(s.light_gs)
	release(s.light_vs)
	release(s.mask_ps)
	release(s.mask_vs)
	release(s.gbuffer_ps)
	release(s.gbuffer_vs)
	release(s.light_vb)
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

setup :: proc(r: ^renderer.Renderer) -> (s: Scene, ok: bool) {
	device := r.device

	// Shaders — all vs_5_0/ps_5_0 as in the C++, only the point-light
	// variant of LightsLP (the only light type the app adds).
	gbuffer_vs_blob := shader.compile("GBufferLP.hlsl", "VSMain", "vs_5_0") or_return
	defer gbuffer_vs_blob->Release()
	gbuffer_ps_blob := shader.compile("GBufferLP.hlsl", "PSMain", "ps_5_0") or_return
	defer gbuffer_ps_blob->Release()
	mask_vs_blob := shader.compile("MaskLP.hlsl", "VSMain", "vs_5_0") or_return
	defer mask_vs_blob->Release()
	mask_ps_blob := shader.compile("MaskLP.hlsl", "PSMain", "ps_5_0") or_return
	defer mask_ps_blob->Release()

	point_defines := [1]cstring{"POINTLIGHT"}
	light_vs_blob := shader.compile_defines("LightsLP.hlsl", "VSMain", "vs_5_0", point_defines[:]) or_return
	defer light_vs_blob->Release()
	light_gs_blob := shader.compile_defines("LightsLP.hlsl", "GSMain", "gs_5_0", point_defines[:]) or_return
	defer light_gs_blob->Release()
	light_ps_blob := shader.compile_defines("LightsLP.hlsl", "PSMain", "ps_5_0", point_defines[:]) or_return
	defer light_ps_blob->Release()
	light_pss_blob := shader.compile_defines("LightsLP.hlsl", "PSMainPerSample", "ps_5_0", point_defines[:]) or_return
	defer light_pss_blob->Release()

	final_vs_blob := shader.compile("FinalPassLP.hlsl", "VSMain", "vs_5_0") or_return
	defer final_vs_blob->Release()
	final_ps_blob := shader.compile("FinalPassLP.hlsl", "PSMain", "ps_5_0") or_return
	defer final_ps_blob->Release()

	blit_vs_blob := shader.compile_source(BLIT_HLSL, "blit", "VSMain", "vs_5_0", nil) or_return
	defer blit_vs_blob->Release()
	blit_ps_blob := shader.compile_source(BLIT_HLSL, "blit", "PSMain", "ps_5_0", nil) or_return
	defer blit_ps_blob->Release()

	if device->CreateVertexShader(gbuffer_vs_blob->GetBufferPointer(), gbuffer_vs_blob->GetBufferSize(), nil, &s.gbuffer_vs) < 0 {return}
	if device->CreatePixelShader(gbuffer_ps_blob->GetBufferPointer(), gbuffer_ps_blob->GetBufferSize(), nil, &s.gbuffer_ps) < 0 {return}
	if device->CreateVertexShader(mask_vs_blob->GetBufferPointer(), mask_vs_blob->GetBufferSize(), nil, &s.mask_vs) < 0 {return}
	if device->CreatePixelShader(mask_ps_blob->GetBufferPointer(), mask_ps_blob->GetBufferSize(), nil, &s.mask_ps) < 0 {return}
	if device->CreateVertexShader(light_vs_blob->GetBufferPointer(), light_vs_blob->GetBufferSize(), nil, &s.light_vs) < 0 {return}
	if device->CreateGeometryShader(light_gs_blob->GetBufferPointer(), light_gs_blob->GetBufferSize(), nil, &s.light_gs) < 0 {return}
	if device->CreatePixelShader(light_ps_blob->GetBufferPointer(), light_ps_blob->GetBufferSize(), nil, &s.light_ps) < 0 {return}
	if device->CreatePixelShader(light_pss_blob->GetBufferPointer(), light_pss_blob->GetBufferSize(), nil, &s.light_ps_sample) < 0 {return}
	if device->CreateVertexShader(final_vs_blob->GetBufferPointer(), final_vs_blob->GetBufferSize(), nil, &s.final_vs) < 0 {return}
	if device->CreatePixelShader(final_ps_blob->GetBufferPointer(), final_ps_blob->GetBufferSize(), nil, &s.final_ps) < 0 {return}
	if device->CreateVertexShader(blit_vs_blob->GetBufferPointer(), blit_vs_blob->GetBufferSize(), nil, &s.blit_vs) < 0 {return}
	if device->CreatePixelShader(blit_ps_blob->GetBufferPointer(), blit_ps_blob->GetBufferSize(), nil, &s.blit_ps) < 0 {return}

	// Sample_Scene.ms3d, with the tangent element appended.
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

	vb_desc := d3d11.BUFFER_DESC {
		ByteWidth = u32(len(vertices) * size_of(Scene_Vertex)),
		Usage     = .IMMUTABLE,
		BindFlags = {.VERTEX_BUFFER},
	}
	vb_data := d3d11.SUBRESOURCE_DATA {
		pSysMem = raw_data(vertices),
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

	scene_elements := [4]d3d11.INPUT_ELEMENT_DESC{
		{"POSITION", 0, .R32G32B32_FLOAT, 0, 0, .VERTEX_DATA, 0},
		{"TEXCOORDS", 0, .R32G32_FLOAT, 0, 12, .VERTEX_DATA, 0},
		{"NORMAL", 0, .R32G32B32_FLOAT, 0, 20, .VERTEX_DATA, 0},
		{"TANGENT", 0, .R32G32B32A32_FLOAT, 0, 32, .VERTEX_DATA, 0},
	}
	// Built against the G-Buffer VS (which consumes every element); the
	// final-pass VS uses a subset of the same layout.
	if device->CreateInputLayout(&scene_elements[0], 4, gbuffer_vs_blob->GetBufferPointer(), gbuffer_vs_blob->GetBufferSize(), &s.scene_layout) < 0 {return}

	// Fullscreen quad for the mask pass.
	quad_vertices := [4]Quad_Vertex{
		{{-1, 1, 0, 1}, {0, 0}}, // upper left
		{{-1, -1, 0, 1}, {0, 1}}, // lower left
		{{1, 1, 0, 1}, {1, 0}}, // upper right
		{{1, -1, 0, 1}, {1, 1}}, // lower right
	}
	quad_indices := [6]u32{0, 2, 1, 1, 2, 3}
	quad_vb_desc := d3d11.BUFFER_DESC {
		ByteWidth = size_of(quad_vertices),
		Usage     = .IMMUTABLE,
		BindFlags = {.VERTEX_BUFFER},
	}
	quad_vb_data := d3d11.SUBRESOURCE_DATA {
		pSysMem = &quad_vertices[0],
	}
	if device->CreateBuffer(&quad_vb_desc, &quad_vb_data, &s.quad_vb) < 0 {return}
	quad_ib_desc := d3d11.BUFFER_DESC {
		ByteWidth = size_of(quad_indices),
		Usage     = .IMMUTABLE,
		BindFlags = {.INDEX_BUFFER},
	}
	quad_ib_data := d3d11.SUBRESOURCE_DATA {
		pSysMem = &quad_indices[0],
	}
	if device->CreateBuffer(&quad_ib_desc, &quad_ib_data, &s.quad_ib) < 0 {return}

	quad_elements := [2]d3d11.INPUT_ELEMENT_DESC{
		{"POSITION", 0, .R32G32B32A32_FLOAT, 0, 0, .VERTEX_DATA, 0},
		{"TEXCOORDS", 0, .R32G32_FLOAT, 0, 16, .VERTEX_DATA, 0},
	}
	if device->CreateInputLayout(&quad_elements[0], 2, mask_vs_blob->GetBufferPointer(), mask_vs_blob->GetBufferSize(), &s.quad_layout) < 0 {return}

	// Dynamic light vertex buffer (one LightParams per point).
	light_vb_desc := d3d11.BUFFER_DESC {
		ByteWidth      = MAX_LIGHTS * size_of(Light_Vertex),
		Usage          = .DYNAMIC,
		BindFlags      = {.VERTEX_BUFFER},
		CPUAccessFlags = {.WRITE},
	}
	if device->CreateBuffer(&light_vb_desc, nil, &s.light_vb) < 0 {return}

	light_elements := [5]d3d11.INPUT_ELEMENT_DESC{
		{"POSITION", 0, .R32G32B32_FLOAT, 0, 0, .VERTEX_DATA, 0},
		{"COLOR", 0, .R32G32B32_FLOAT, 0, 12, .VERTEX_DATA, 0},
		{"DIRECTION", 0, .R32G32B32_FLOAT, 0, 24, .VERTEX_DATA, 0},
		{"RANGE", 0, .R32_FLOAT, 0, 36, .VERTEX_DATA, 0},
		{"SPOTANGLES", 0, .R32G32_FLOAT, 0, 40, .VERTEX_DATA, 0},
	}
	if device->CreateInputLayout(&light_elements[0], 5, light_vs_blob->GetBufferPointer(), light_vs_blob->GetBufferSize(), &s.light_layout) < 0 {return}

	// Depth-stencil states.
	// G-Buffer: depth LESS + write, stencil ALWAYS/REPLACE (ref 1).
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

	// Mask: depth off, stencil EQUAL/INCR (ref 1 → edge pixels become 2).
	ds_desc.DepthEnable = false
	ds_desc.DepthWriteMask = .ZERO
	ds_desc.DepthFunc = .ALWAYS
	ds_desc.FrontFace = {StencilFailOp = .KEEP, StencilDepthFailOp = .KEEP, StencilPassOp = .INCR, StencilFunc = .EQUAL}
	ds_desc.BackFace = ds_desc.FrontFace
	if device->CreateDepthStencilState(&ds_desc, &s.ds_mask) < 0 {return}

	// Lights (point): depth GREATER_EQUAL no-write, stencil EQUAL read-only.
	ds_desc.DepthEnable = true
	ds_desc.DepthFunc = .GREATER_EQUAL
	ds_desc.StencilWriteMask = 0
	ds_desc.FrontFace = {StencilFailOp = .KEEP, StencilDepthFailOp = .KEEP, StencilPassOp = .KEEP, StencilFunc = .EQUAL}
	ds_desc.BackFace = ds_desc.FrontFace
	if device->CreateDepthStencilState(&ds_desc, &s.ds_light) < 0 {return}

	// Final pass: depth LESS_EQUAL no-write, stencil off.
	ds_desc.DepthFunc = .LESS_EQUAL
	ds_desc.StencilEnable = false
	if device->CreateDepthStencilState(&ds_desc, &s.ds_final) < 0 {return}

	// Additive blend for light accumulation.
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

	// One rasterizer state everywhere: multisample, cull back.
	rs_desc := d3d11.RASTERIZER_DESC {
		FillMode          = .SOLID,
		CullMode          = .BACK,
		DepthClipEnable   = true,
		MultisampleEnable = true,
	}
	if device->CreateRasterizerState(&rs_desc, &s.rs_msaa) < 0 {return}

	// Textures: like WICTextureLoader, Hex.png's sRGB metadata decides the
	// _SRGB format (the C++'s intended explicit sRGB override is commented
	// out — it relies on the same metadata path).
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
	if device->CreateSamplerState(&sampler_desc, &s.sampler_blit) < 0 {return}

	s.cb_transforms = dynamic_cbuffer(device, size_of(Transforms_CB)) or_return
	s.cb_camera = dynamic_cbuffer(device, size_of(Camera_CB)) or_return

	return s, true
}

// SetupLights: a cube grid of point lights, position lerped over
// (-4,1,-4)..(4,11,4) and color over red..cyan (x1.5), range 2.
build_lights :: proc(lights: ^[dynamic]Light_Vertex, mode: Light_Mode) {
	clear(lights)

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
				append(lights, Light_Vertex{
					position  = linalg.lerp(min_extents, max_extents, lerp),
					color     = linalg.lerp(min_color, max_color, lerp) * 1.5,
					direction = {-1, -1, 1}, // LightParams defaults, unused
					range     = 2,
					type      = 0, // Point
				})
			}
		}
	}
}

update_title :: proc(hwnd: win32.HWND, mode: Light_Mode) {
	title := fmt.tprintf("LightPrepass - Number of Lights(N): %s", light_mode_names[mode])
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
	window.set_caption(&win, "LightPrepass")
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
			win32.L("LightPrepass setup failed"),
			win32.MB_ICONEXCLAMATION | win32.MB_SYSTEMMODAL,
		)
		return
	}
	defer scene_destroy(&scene)
	defer targets_destroy(&targets)

	// FirstPersonCamera at rotation (0.407, -0.707, 0), position (4, 4.5, -4).
	cam := Fp_Camera {
		position = {4, 4.5, -4},
		pitch    = 0.407,
		yaw      = -0.707,
	}
	proj := camera.perspective_fov_lh(f32(linalg.PI) / 2, f32(WIDTH) / f32(HEIGHT), NEAR_CLIP, FAR_CLIP)

	light_mode := Light_Mode.Lights3x3x3
	lights: [dynamic]Light_Vertex
	defer delete(lights)
	update_title(win.hwnd, light_mode)

	rotation_angle: f32 = 0.0
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

		if state.cycle_lights {
			state.cycle_lights = false
			light_mode = Light_Mode((int(light_mode) + 1) % len(Light_Mode))
			update_title(win.hwnd, light_mode)
		}

		dt := f32(time.duration_seconds(time.tick_lap_time(&last_tick)))

		camera_update(&cam, &state.input, dt)
		view := camera_view_matrix(&cam)

		// The scene's root node spins about Y at 0.2 rad/s.
		rotation_angle += dt * 0.2
		world := linalg.matrix4_rotate_f32(rotation_angle, {0, 1, 0})

		transforms := Transforms_CB {
			world           = world,
			world_view      = view * world,
			world_view_proj = proj * view * world,
		}
		write_cbuffer(ctx, scene.cb_transforms, &transforms)

		camera_cb := Camera_CB {
			view        = view,
			proj        = proj,
			inv_proj    = linalg.inverse(proj),
			clip_planes = {NEAR_CLIP, FAR_CLIP},
		}
		write_cbuffer(ctx, scene.cb_camera, &camera_cb)

		// SetupLights runs every frame in the C++'s QueuePreTasks.
		build_lights(&lights, light_mode)
		mapped: d3d11.MAPPED_SUBRESOURCE
		if ctx->Map((^d3d11.IResource)(scene.light_vb), 0, .WRITE_DISCARD, {}, &mapped) >= 0 {
			copy(([^]Light_Vertex)(mapped.pData)[:len(lights)], lights[:])
			ctx->Unmap((^d3d11.IResource)(scene.light_vb), 0)
		}

		viewport := d3d11.VIEWPORT {
			Width    = f32(r.width),
			Height   = f32(r.height),
			MinDepth = 0.0,
			MaxDepth = 1.0,
		}
		ctx->RSSetViewports(1, &viewport)
		clear_color := [4]f32{0, 0, 0, 0}
		null_srvs := [2]^d3d11.IShaderResourceView{nil, nil}

		// --- 1. G-Buffer pass (ViewGBuffer) --------------------------------
		ctx->OMSetRenderTargets(1, &targets.gbuffer_rtv, targets.depth_dsv)
		ctx->ClearRenderTargetView(targets.gbuffer_rtv, &clear_color)
		ctx->ClearDepthStencilView(targets.depth_dsv, {.DEPTH, .STENCIL}, 1.0, 0)

		stride: u32 = size_of(Scene_Vertex)
		offset: u32 = 0
		ctx->IASetInputLayout(scene.scene_layout)
		ctx->IASetVertexBuffers(0, 1, &scene.vertex_buffer, &stride, &offset)
		ctx->IASetIndexBuffer(scene.index_buffer, .R32_UINT, 0)
		ctx->IASetPrimitiveTopology(.TRIANGLELIST)
		ctx->VSSetShader(scene.gbuffer_vs, nil, 0)
		ctx->VSSetConstantBuffers(0, 1, &scene.cb_transforms)
		ctx->GSSetShader(nil, nil, 0)
		ctx->PSSetShader(scene.gbuffer_ps, nil, 0)
		ctx->PSSetShaderResources(0, 1, &scene.normal_srv)
		ctx->PSSetSamplers(0, 1, &scene.sampler_aniso)
		ctx->OMSetDepthStencilState(scene.ds_gbuffer, 1)
		ctx->OMSetBlendState(nil, nil, 0xffffffff)
		ctx->RSSetState(scene.rs_msaa)
		ctx->DrawIndexed(scene.index_count, 0, 0)

		// --- 2. Stencil mask pass (MaskLP on a fullscreen quad) ------------
		// Depth-stencil only — no color target. Edge pixels (G-Buffer .w
		// nonzero in any sample) increment stencil 1 → 2.
		ctx->OMSetRenderTargets(0, nil, targets.depth_dsv)
		ctx->PSSetShaderResources(0, 1, &targets.gbuffer_srv)

		quad_stride: u32 = size_of(Quad_Vertex)
		ctx->IASetInputLayout(scene.quad_layout)
		ctx->IASetVertexBuffers(0, 1, &scene.quad_vb, &quad_stride, &offset)
		ctx->IASetIndexBuffer(scene.quad_ib, .R32_UINT, 0)
		ctx->VSSetShader(scene.mask_vs, nil, 0)
		ctx->PSSetShader(scene.mask_ps, nil, 0)
		ctx->OMSetDepthStencilState(scene.ds_mask, 1)
		ctx->DrawIndexed(6, 0, 0)

		// --- 3. Light pass (ViewLights) ------------------------------------
		// Additive accumulation; read-only depth so the depth SRV can be
		// bound at the same time. Per-pixel shader at stencil ref 1, then
		// the per-sample shader at ref 2 for the edge pixels.
		ctx->PSSetShaderResources(0, 2, &null_srvs[0])
		ctx->OMSetRenderTargets(1, &targets.light_rtv, nil)
		ctx->ClearRenderTargetView(targets.light_rtv, &clear_color)
		ctx->OMSetRenderTargets(1, &targets.light_rtv, targets.depth_dsv_ro)

		light_srvs := [2]^d3d11.IShaderResourceView{targets.gbuffer_srv, targets.depth_srv}
		ctx->PSSetShaderResources(0, 2, &light_srvs[0])

		light_stride: u32 = size_of(Light_Vertex)
		ctx->IASetInputLayout(scene.light_layout)
		ctx->IASetVertexBuffers(0, 1, &scene.light_vb, &light_stride, &offset)
		ctx->IASetPrimitiveTopology(.POINTLIST)
		ctx->VSSetShader(scene.light_vs, nil, 0)
		ctx->VSSetConstantBuffers(0, 1, &scene.cb_camera)
		ctx->GSSetShader(scene.light_gs, nil, 0)
		ctx->GSSetConstantBuffers(0, 1, &scene.cb_camera)
		ctx->PSSetConstantBuffers(0, 1, &scene.cb_camera)
		blend_factor := [4]f32{0, 0, 0, 0}
		ctx->OMSetBlendState(scene.bs_additive, &blend_factor, 0xffffffff)

		ctx->PSSetShader(scene.light_ps, nil, 0)
		ctx->OMSetDepthStencilState(scene.ds_light, 1)
		ctx->Draw(u32(len(lights)), 0)

		ctx->PSSetShader(scene.light_ps_sample, nil, 0)
		ctx->OMSetDepthStencilState(scene.ds_light, 2)
		ctx->Draw(u32(len(lights)), 0)

		ctx->GSSetShader(nil, nil, 0)
		ctx->OMSetBlendState(nil, nil, 0xffffffff)

		// --- 4. Final pass (ViewFinalPass) ---------------------------------
		ctx->PSSetShaderResources(0, 2, &null_srvs[0])
		ctx->OMSetRenderTargets(1, &targets.final_rtv, nil)
		ctx->ClearRenderTargetView(targets.final_rtv, &clear_color)
		ctx->OMSetRenderTargets(1, &targets.final_rtv, targets.depth_dsv_ro)

		final_srvs := [2]^d3d11.IShaderResourceView{scene.diffuse_srv, targets.light_srv}
		ctx->PSSetShaderResources(0, 2, &final_srvs[0])

		ctx->IASetInputLayout(scene.scene_layout)
		ctx->IASetVertexBuffers(0, 1, &scene.vertex_buffer, &stride, &offset)
		ctx->IASetIndexBuffer(scene.index_buffer, .R32_UINT, 0)
		ctx->IASetPrimitiveTopology(.TRIANGLELIST)
		ctx->VSSetShader(scene.final_vs, nil, 0)
		ctx->VSSetConstantBuffers(0, 1, &scene.cb_transforms)
		ctx->PSSetShader(scene.final_ps, nil, 0)
		ctx->PSSetSamplers(0, 1, &scene.sampler_aniso)
		ctx->OMSetDepthStencilState(scene.ds_final, 0)
		ctx->DrawIndexed(scene.index_count, 0, 0)

		// --- 5. Resolve + blit to the backbuffer ---------------------------
		ctx->PSSetShaderResources(0, 2, &null_srvs[0])
		ctx->OMSetRenderTargets(1, &r.rtv, nil)
		ctx->ClearRenderTargetView(r.rtv, &clear_color)
		ctx->ResolveSubresource(
			(^d3d11.IResource)(targets.resolve_tex), 0,
			(^d3d11.IResource)(targets.final_tex), 0,
			.R10G10B10A2_UNORM,
		)

		ctx->IASetInputLayout(nil)
		ctx->IASetPrimitiveTopology(.TRIANGLELIST)
		ctx->VSSetShader(scene.blit_vs, nil, 0)
		ctx->PSSetShader(scene.blit_ps, nil, 0)
		ctx->PSSetShaderResources(0, 1, &targets.resolve_srv)
		ctx->PSSetSamplers(0, 1, &scene.sampler_blit)
		ctx->OMSetDepthStencilState(nil, 0)
		ctx->RSSetState(nil)
		ctx->Draw(3, 0)
		ctx->PSSetShaderResources(0, 2, &null_srvs[0])

		renderer.present(&r)

		if state.save_screenshot {
			state.save_screenshot = false
			screenshot_number += 1
			renderer.save_backbuffer_png(&r, fmt.tprintf("LightPrepass%d.png", screenshot_number))
		}

		free_all(context.temp_allocator)
	}
}
