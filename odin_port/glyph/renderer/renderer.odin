// Device, swap chain, and render-target setup shared by the sample apps,
// mirroring the parts of RendererDX11 (Source/RendererDX11.cpp) and the
// identical ConfigureEngineComponents boilerplate each C++ sample repeats.
//
// COM lifetimes are manual: every Create*/Get* AddRefs what it returns, so
// locals are released with `defer x->Release()` and stored interfaces in
// reverse creation order in destroy.
package renderer

import "core:fmt"
import "core:os"
import win32 "core:sys/windows"
import d3d11 "vendor:directx/d3d11"
import dxgi "vendor:directx/dxgi"

// The D3D11 objects every sample's ConfigureEngineComponents sets up:
// device, swap chain (per SwapChainConfigDX11 defaults: R8G8B8A8_UNORM_SRGB,
// 2 buffers, DISCARD blit model — matching the C++ comes before modern
// flip-model here), backbuffer RTV, D32_FLOAT depth buffer + DSV (per
// Texture2dConfigDX11::SetDepthBuffer), both bound, and a full-window
// viewport.
Renderer :: struct {
	device:     ^d3d11.IDevice,
	ctx:        ^d3d11.IDeviceContext,
	swap_chain: ^dxgi.ISwapChain,
	backbuffer: ^d3d11.ITexture2D,
	rtv:        ^d3d11.IRenderTargetView,
	dsv:        ^d3d11.IDepthStencilView,
	width:      u32,
	height:     u32,
}

// Mirrors RendererDX11::Initialize: enumerate hardware adapters and create a
// device at exactly the requested feature level (the samples pass ._10_0 or
// ._11_0, matching their C++ counterparts) on the first adapter that
// succeeds, falling back to the reference driver (which is unavailable on
// most modern systems, matching the C++'s failure path). Debug layer in
// debug builds (-debug).
create_device :: proc(
	feature_level: d3d11.FEATURE_LEVEL,
) -> (
	device: ^d3d11.IDevice,
	ctx: ^d3d11.IDeviceContext,
	ok: bool,
) {
	flags: d3d11.CREATE_DEVICE_FLAGS
	when ODIN_DEBUG {
		flags = {.DEBUG}
	}
	levels := [1]d3d11.FEATURE_LEVEL{feature_level}

	factory: ^dxgi.IFactory1
	if dxgi.CreateDXGIFactory1(dxgi.IFactory1_UUID, (^rawptr)(&factory)) < 0 {
		return
	}
	defer factory->Release()

	for i: u32 = 0; ; i += 1 {
		adapter: ^dxgi.IAdapter1
		if factory->EnumAdapters1(i, &adapter) < 0 {
			break
		}
		defer adapter->Release()

		hr := d3d11.CreateDevice(
			(^dxgi.IAdapter)(adapter),
			.UNKNOWN,
			nil,
			flags,
			&levels[0],
			1,
			d3d11.SDK_VERSION,
			&device,
			nil,
			&ctx,
		)
		if hr >= 0 {
			return device, ctx, true
		}
	}

	// "Could not create hardware device, trying to create the reference
	// device..."
	hr := d3d11.CreateDevice(nil, .REFERENCE, nil, flags, &levels[0], 1, d3d11.SDK_VERSION, &device, nil, &ctx)
	ok = hr >= 0
	return
}

create :: proc(
	hwnd: win32.HWND,
	width, height: u32,
	feature_level: d3d11.FEATURE_LEVEL,
) -> (
	r: Renderer,
	ok: bool,
) {
	r.width = width
	r.height = height

	r.device, r.ctx = create_device(feature_level) or_return

	desc := dxgi.SWAP_CHAIN_DESC {
		BufferDesc = {
			Width = width,
			Height = height,
			RefreshRate = {Numerator = 60, Denominator = 1},
			Format = .R8G8B8A8_UNORM_SRGB,
		},
		SampleDesc = {Count = 1, Quality = 0},
		BufferUsage = {.RENDER_TARGET_OUTPUT},
		BufferCount = 2,
		OutputWindow = hwnd,
		Windowed = true,
		SwapEffect = .DISCARD,
	}

	// The C++ creates the swap chain from its adapter-enumeration factory;
	// a fresh factory here is equivalent.
	factory: ^dxgi.IFactory1
	if dxgi.CreateDXGIFactory1(dxgi.IFactory1_UUID, (^rawptr)(&factory)) < 0 {
		return
	}
	defer factory->Release()

	if factory->CreateSwapChain((^dxgi.IUnknown)(r.device), &desc, &r.swap_chain) < 0 {
		return
	}

	if r.swap_chain->GetBuffer(0, d3d11.ITexture2D_UUID, (^rawptr)(&r.backbuffer)) < 0 {
		return
	}
	if r.device->CreateRenderTargetView((^d3d11.IResource)(r.backbuffer), nil, &r.rtv) < 0 {
		return
	}

	// Depth buffer per Texture2dConfigDX11::SetDepthBuffer.
	depth_desc := d3d11.TEXTURE2D_DESC {
		Width      = width,
		Height     = height,
		MipLevels  = 1,
		ArraySize  = 1,
		Format     = .D32_FLOAT,
		SampleDesc = {Count = 1, Quality = 0},
		Usage      = .DEFAULT,
		BindFlags  = {.DEPTH_STENCIL},
	}
	depth_texture: ^d3d11.ITexture2D
	if r.device->CreateTexture2D(&depth_desc, nil, &depth_texture) < 0 {
		return
	}
	defer depth_texture->Release()
	if r.device->CreateDepthStencilView((^d3d11.IResource)(depth_texture), nil, &r.dsv) < 0 {
		return
	}

	// Bind the render targets and the full-window viewport.
	r.ctx->OMSetRenderTargets(1, &r.rtv, r.dsv)
	viewport := d3d11.VIEWPORT {
		Width    = f32(width),
		Height   = f32(height),
		MinDepth = 0.0,
		MaxDepth = 1.0,
	}
	r.ctx->RSSetViewports(1, &viewport)

	return r, true
}

destroy :: proc(r: ^Renderer) {
	if r.dsv != nil {r.dsv->Release(); r.dsv = nil}
	if r.rtv != nil {r.rtv->Release(); r.rtv = nil}
	if r.backbuffer != nil {r.backbuffer->Release(); r.backbuffer = nil}
	if r.swap_chain != nil {r.swap_chain->Release(); r.swap_chain = nil}
	if r.ctx != nil {r.ctx->Release(); r.ctx = nil}
	if r.device != nil {r.device->Release(); r.device = nil}
}

// Mirrors RendererDX11::Present's defaults: no vsync, no flags.
present :: proc(r: ^Renderer) {
	r.swap_chain->Present(0, {})
}

// Mirrors PipelineManagerDX11::SaveTextureScreenShot: copy the backbuffer
// through a staging texture and write it out. The C++ writes PNG via
// DirectXTK; Odin's core has no PNG *encoder* and the vendored
// stb_image_write ships without a prebuilt lib, so this writes an
// uncompressed 32-bit BMP instead — same pixels, different container. Alpha
// is forced opaque, matching DirectXTK's output. Failures are ignored beyond
// skipping the file, as in the C++ (which just logs them).
save_backbuffer_bmp :: proc(r: ^Renderer, path: string) {
	staging_desc := d3d11.TEXTURE2D_DESC {
		Width          = r.width,
		Height         = r.height,
		MipLevels      = 1,
		ArraySize      = 1,
		Format         = .R8G8B8A8_UNORM_SRGB,
		SampleDesc     = {Count = 1, Quality = 0},
		Usage          = .STAGING,
		CPUAccessFlags = {.READ},
	}
	staging: ^d3d11.ITexture2D
	if r.device->CreateTexture2D(&staging_desc, nil, &staging) < 0 {
		return
	}
	defer staging->Release()

	r.ctx->CopyResource((^d3d11.IResource)(staging), (^d3d11.IResource)(r.backbuffer))

	mapped: d3d11.MAPPED_SUBRESOURCE
	if r.ctx->Map((^d3d11.IResource)(staging), 0, .READ, {}, &mapped) < 0 {
		return
	}
	defer r.ctx->Unmap((^d3d11.IResource)(staging), 0)

	// 32-bit BMP: 14-byte file header + 40-byte BITMAPINFOHEADER, negative
	// height for top-down rows, pixels as BGRX.
	w := int(r.width)
	h := int(r.height)
	pixel_bytes := w * h * 4
	data := make([]u8, 54 + pixel_bytes)
	defer delete(data)

	put_u16 :: proc(b: []u8, off: int, v: u16) {
		b[off] = u8(v)
		b[off + 1] = u8(v >> 8)
	}
	put_u32 :: proc(b: []u8, off: int, v: u32) {
		b[off] = u8(v)
		b[off + 1] = u8(v >> 8)
		b[off + 2] = u8(v >> 16)
		b[off + 3] = u8(v >> 24)
	}

	data[0] = 'B'
	data[1] = 'M'
	put_u32(data, 2, u32(54 + pixel_bytes)) // file size
	put_u32(data, 10, 54) // pixel data offset
	put_u32(data, 14, 40) // BITMAPINFOHEADER size
	put_u32(data, 18, u32(w))
	put_u32(data, 22, u32(-h)) // negative = top-down
	put_u16(data, 26, 1) // planes
	put_u16(data, 28, 32) // bits per pixel
	// compression BI_RGB = 0, remaining header fields stay zero.

	src := ([^]u8)(mapped.pData)
	for row in 0 ..< h {
		src_row := int(mapped.RowPitch) * row
		dst_row := 54 + w * 4 * row
		for x in 0 ..< w {
			s := src_row + x * 4
			d := dst_row + x * 4
			data[d + 0] = src[s + 2] // B
			data[d + 1] = src[s + 1] // G
			data[d + 2] = src[s + 0] // R
			data[d + 3] = 0xFF
		}
	}

	if err := os.write_entire_file(path, data); err != nil {
		fmt.eprintln("failed to write", path, err)
	}
}
