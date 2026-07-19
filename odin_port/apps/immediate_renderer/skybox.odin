// Skybox, mirroring SkyboxActor (Source/SkyboxActor.cpp): a scaled cube of 8
// corner vertices rendered with Skybox.hlsl (which pushes positions to the
// far plane via .xyww and samples a cube map by direction), depth compare
// LESS_EQUAL so it fills exactly the untouched depth = 1.0 pixels.
//
// The cube map is TropicalSunnyDay.dds — a legacy uncompressed 32-bit BGRA
// cube map, hand-parsed here (the C++ goes through DirectXTK's
// DDSTextureLoader; the format is simple enough that a dependency isn't
// warranted: 128-byte header, then 6 faces of width*height*4 bytes in
// +X, -X, +Y, -Y, +Z, -Z order). core:image has no DDS support, so this
// stays hand-rolled even under the "prefer core:image" policy.
package main

import "core:fmt"
import "core:os"
import d3d11 "vendor:directx/d3d11"
import "glyph:paths"
import "glyph:renderer"

// The skybox vertex mirrors the engine's TexturedVertex (position +
// texcoords, 20 bytes): the shader only *uses* the position, but its input
// signature declares TEXCOORD0, so the layout must supply it — otherwise
// CreateInputLayout fails with E_INVALIDARG.
Skybox_Vertex :: struct {
	position:  [3]f32,
	texcoords: [2]f32,
}

// The cube's 8 corners and 36 indices, exactly as SkyboxActor builds them.
skybox_corners := [8]Skybox_Vertex{
	{{-1, 1, 1}, {0, 0}},   // top left front
	{{1, 1, 1}, {1, 0}},    // top right front
	{{-1, -1, 1}, {0, 1}},  // bottom left front
	{{1, -1, 1}, {1, 1}},   // bottom right front
	{{-1, 1, -1}, {0, 0}},  // top left back
	{{1, 1, -1}, {1, 0}},   // top right back
	{{-1, -1, -1}, {0, 1}}, // bottom left back
	{{1, -1, -1}, {1, 1}},  // bottom right back
}

skybox_indices := [36]u32{
	0, 1, 2, 1, 3, 2, // front
	1, 5, 3, 5, 7, 3, // right
	5, 4, 6, 5, 6, 7, // back
	0, 2, 4, 2, 6, 4, // left
	4, 5, 0, 5, 1, 0, // top
	2, 3, 6, 3, 7, 6, // bottom
}

// Load a legacy uncompressed BGRA cube-map DDS and create the cube SRV.
load_cubemap_dds :: proc(
	r: ^renderer.Renderer,
	filename: string,
) -> (
	texture: ^d3d11.ITexture2D,
	srv: ^d3d11.IShaderResourceView,
	ok: bool,
) {
	path, found := paths.find_data_file("Textures", filename)
	if !found {
		fmt.eprintln("cubemap not found:", filename)
		return
	}
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		fmt.eprintln("failed to read", path, read_err)
		return
	}
	defer delete(data)

	// DDS layout: "DDS " magic, then a 124-byte header.
	if len(data) < 128 || string(data[0:4]) != "DDS " {
		fmt.eprintln(filename, "is not a DDS file")
		return
	}
	u32_at :: proc(data: []u8, o: int) -> u32 {
		return u32(data[o]) | u32(data[o + 1]) << 8 | u32(data[o + 2]) << 16 | u32(data[o + 3]) << 24
	}
	height := u32_at(data, 12)
	width := u32_at(data, 16)
	pf_flags := u32_at(data, 80)
	bit_count := u32_at(data, 88)
	// dwCaps2 sits at offset 112: magic(4) + header where ddspf spans
	// 76..107 and dwCaps/dwCaps2 follow at 108/112.
	caps2 := u32_at(data, 112)

	// Only the exact shape this sample's asset has: uncompressed 32-bit
	// RGB+A (pf flags 0x41), full cube map (caps2 bit 0x200), no mip chain.
	if pf_flags & 0x40 == 0 || bit_count != 32 || caps2 & 0x200 == 0 {
		fmt.eprintln(filename, "is an unsupported DDS variant (only uncompressed 32-bit cube maps handled)")
		return
	}

	face_size := int(width * height * 4)
	if len(data) < 128 + 6 * face_size {
		fmt.eprintln(filename, "has truncated cube map data")
		return
	}

	desc := d3d11.TEXTURE2D_DESC {
		Width      = width,
		Height     = height,
		MipLevels  = 1,
		ArraySize  = 6,
		Format     = .B8G8R8A8_UNORM,
		SampleDesc = {Count = 1, Quality = 0},
		Usage      = .IMMUTABLE,
		BindFlags  = {.SHADER_RESOURCE},
		MiscFlags  = {.TEXTURECUBE},
	}

	init: [6]d3d11.SUBRESOURCE_DATA
	for face in 0 ..< 6 {
		init[face] = {
			pSysMem     = &data[128 + face * face_size],
			SysMemPitch = width * 4,
		}
	}

	if r.device->CreateTexture2D(&desc, &init[0], &texture) < 0 {
		fmt.eprintln("cube texture creation failed")
		return
	}

	srv_desc: d3d11.SHADER_RESOURCE_VIEW_DESC
	srv_desc.Format = .B8G8R8A8_UNORM
	srv_desc.ViewDimension = .TEXTURECUBE
	srv_desc.TextureCube = {MostDetailedMip = 0, MipLevels = 1}
	if r.device->CreateShaderResourceView((^d3d11.IResource)(texture), &srv_desc, &srv) < 0 {
		texture->Release()
		texture = nil
		fmt.eprintln("cube SRV creation failed")
		return
	}

	return texture, srv, true
}
