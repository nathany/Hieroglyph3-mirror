// Device, swap chain, and render-target setup shared by the sample apps,
// mirroring the parts of RendererDX11 (Source/RendererDX11.cpp) and the
// identical ConfigureEngineComponents boilerplate each C++ sample repeats.
//
// COM lifetimes are manual: every Create*/Get* AddRefs what it returns, so
// locals are released with `defer x->Release()` and stored interfaces in
// reverse creation order in destroy.
package renderer

import "core:fmt"
import "core:image"
import "core:image/png"
import win32 "core:sys/windows"
import d3d11 "vendor:directx/d3d11"
import dxgi "vendor:directx/dxgi"
import stbi "vendor:stb/image"
import "glyph:paths"

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

// Mirrors RendererDX11::ResizeSwapChain + the render-view resize logic in
// RenderApplication::HandleWindowResize: release the backbuffer views,
// resize the swap chain buffers, and recreate the RTV, depth buffer, DSV,
// and viewport at the new size. All references to the old backbuffer must be
// released before ResizeBuffers.
resize :: proc(r: ^Renderer, width, height: u32) {
	width := max(width, 1)
	height := max(height, 1)

	r.ctx->OMSetRenderTargets(0, nil, nil)
	r.rtv->Release()
	r.rtv = nil
	r.dsv->Release()
	r.dsv = nil
	r.backbuffer->Release()
	r.backbuffer = nil

	if r.swap_chain->ResizeBuffers(2, width, height, .R8G8B8A8_UNORM_SRGB, {}) < 0 {
		fmt.eprintln("ResizeBuffers failed")
		return
	}

	if r.swap_chain->GetBuffer(0, d3d11.ITexture2D_UUID, (^rawptr)(&r.backbuffer)) < 0 {return}
	if r.device->CreateRenderTargetView((^d3d11.IResource)(r.backbuffer), nil, &r.rtv) < 0 {return}

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
	if r.device->CreateTexture2D(&depth_desc, nil, &depth_texture) < 0 {return}
	defer depth_texture->Release()
	if r.device->CreateDepthStencilView((^d3d11.IResource)(depth_texture), nil, &r.dsv) < 0 {return}

	r.ctx->OMSetRenderTargets(1, &r.rtv, r.dsv)
	viewport := d3d11.VIEWPORT {
		Width    = f32(width),
		Height   = f32(height),
		MinDepth = 0.0,
		MaxDepth = 1.0,
	}
	r.ctx->RSSetViewports(1, &viewport)

	r.width = width
	r.height = height
}

// Does the decoded PNG declare sRGB gamma — an sRGB chunk, or a gAMA chunk
// with the sRGB value 45455 (1/2.2 in PNG's 100k fixed-point encoding)? This
// is the signal WIC/DirectXTK use to pick an _SRGB texture format — and it
// matters: it decides whether shader Load/Sample returns raw or linearized
// values, and the book's data files carry the metadata (found the hard way
// in the Rust port, where plain UNORM left every filtered pixel off by a
// gamma curve). The chunks come from core:image/png's `.return_metadata`.
@(private)
png_declares_srgb :: proc(img: ^image.Image) -> bool {
	info, has_info := img.metadata.(^image.PNG_Info)
	if !has_info {
		return false
	}
	for c in info.chunks {
		#partial switch c.header.type {
		case .sRGB:
			return true
		case .gAMA:
			if g, g_ok := png.gamma(c); g_ok && int(g * 100_000 + 0.5) == 45455 {
				return true
			}
		}
	}
	return false
}

// Mirrors RendererDX11::LoadTexture (which uses DirectXTK's
// WICTextureLoader): load Applications/Data/Textures/<filename> into an
// immutable RGBA8 texture — with the _SRGB format when the PNG declares sRGB
// gamma, like WICTextureLoader's default flags — and create a default shader
// resource view for it. Decoding is pure-Odin core:image/png.
load_texture_png :: proc(
	r: ^Renderer,
	filename: string,
) -> (
	texture: ^d3d11.ITexture2D,
	srv: ^d3d11.IShaderResourceView,
	ok: bool,
) {
	path, found := paths.find_data_file("Textures", filename)
	if !found {
		fmt.eprintln("texture not found:", filename)
		return
	}

	img, img_err := png.load_from_file(path, {.alpha_add_if_missing, .return_metadata})
	if img_err != nil {
		fmt.eprintln("failed to load", path, img_err)
		return
	}
	defer png.destroy(img)

	if img.depth != 8 || img.channels != 4 {
		fmt.eprintln("unsupported PNG layout:", path, img.channels, "channels,", img.depth, "bit")
		return
	}

	format: dxgi.FORMAT = .R8G8B8A8_UNORM_SRGB if png_declares_srgb(img) else .R8G8B8A8_UNORM

	desc := d3d11.TEXTURE2D_DESC {
		Width      = u32(img.width),
		Height     = u32(img.height),
		MipLevels  = 1,
		ArraySize  = 1,
		Format     = format,
		SampleDesc = {Count = 1, Quality = 0},
		Usage      = .IMMUTABLE,
		BindFlags  = {.SHADER_RESOURCE},
	}
	init := d3d11.SUBRESOURCE_DATA {
		pSysMem     = raw_data(img.pixels.buf),
		SysMemPitch = u32(img.width * 4),
	}
	if r.device->CreateTexture2D(&desc, &init, &texture) < 0 {
		return
	}
	if r.device->CreateShaderResourceView((^d3d11.IResource)(texture), nil, &srv) < 0 {
		texture->Release()
		texture = nil
		return
	}

	return texture, srv, true
}

// Mirrors PipelineManagerDX11::SaveTextureScreenShot: copy the backbuffer
// through a staging texture and write it as a PNG via the vendored
// stb_image_write (its prebuilt lib ships with the Odin toolchain). Alpha is
// dropped — the pixels repack to 3-channel RGB, matching DirectXTK's opaque
// PNG output (the samples clear alpha to 0, which would otherwise make the
// image fully transparent). Failures are ignored beyond skipping the file,
// as in the C++ (which just logs them).
save_backbuffer_png :: proc(r: ^Renderer, path: string) {
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

	// Compact rows (RowPitch may exceed width*4) and drop alpha: RGBA -> RGB.
	w := int(r.width)
	h := int(r.height)
	rgb := make([]u8, w * h * 3)
	defer delete(rgb)

	src := ([^]u8)(mapped.pData)
	for row in 0 ..< h {
		src_row := int(mapped.RowPitch) * row
		dst_row := w * 3 * row
		for x in 0 ..< w {
			s := src_row + x * 4
			d := dst_row + x * 3
			rgb[d + 0] = src[s + 0]
			rgb[d + 1] = src[s + 1]
			rgb[d + 2] = src[s + 2]
		}
	}

	if stbi.write_png(fmt.ctprintf("%s", path), i32(w), i32(h), 3, raw_data(rgb), i32(w * 3)) == 0 {
		fmt.eprintln("failed to write", path)
	}
}
