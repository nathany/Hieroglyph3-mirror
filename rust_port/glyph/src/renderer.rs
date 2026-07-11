//! Device, swap chain, and render-target setup shared by the sample apps,
//! mirroring the parts of `RendererDX11` (Source/RendererDX11.cpp) and the
//! identical `ConfigureEngineComponents` boilerplate each C++ sample repeats.

use windows::Win32::Foundation::{HMODULE, HWND};
use windows::Win32::Graphics::Direct3D::{
    D3D_DRIVER_TYPE_REFERENCE, D3D_DRIVER_TYPE_UNKNOWN, D3D_FEATURE_LEVEL_10_0,
};
use windows::Win32::Graphics::Direct3D11::{
    D3D11_BIND_DEPTH_STENCIL, D3D11_CPU_ACCESS_READ, D3D11_CREATE_DEVICE_DEBUG,
    D3D11_CREATE_DEVICE_FLAG, D3D11_MAP_READ, D3D11_MAPPED_SUBRESOURCE, D3D11_SDK_VERSION,
    D3D11_TEXTURE2D_DESC, D3D11_USAGE_DEFAULT, D3D11_USAGE_STAGING, D3D11_VIEWPORT,
    D3D11CreateDevice, ID3D11DepthStencilView, ID3D11Device, ID3D11DeviceContext,
    ID3D11RenderTargetView, ID3D11Texture2D,
};
use windows::Win32::Graphics::Dxgi::Common::{
    DXGI_FORMAT_D32_FLOAT, DXGI_FORMAT_R8G8B8A8_UNORM_SRGB, DXGI_MODE_DESC,
    DXGI_MODE_SCALING_UNSPECIFIED, DXGI_MODE_SCANLINE_ORDER_UNSPECIFIED, DXGI_RATIONAL,
    DXGI_SAMPLE_DESC,
};
use windows::Win32::Graphics::Dxgi::{
    CreateDXGIFactory1, DXGI_PRESENT, DXGI_SWAP_CHAIN_DESC, DXGI_SWAP_EFFECT_DISCARD,
    DXGI_USAGE_RENDER_TARGET_OUTPUT, IDXGIAdapter1, IDXGIFactory1, IDXGISwapChain,
};
use windows::core::Result;

/// Mirrors `RendererDX11::Initialize`: enumerate hardware adapters and create
/// a device at exactly `D3D_FEATURE_LEVEL_10_0` on the first one that
/// succeeds, falling back to the reference driver (which is unavailable on
/// most modern systems, matching the C++'s failure path). Debug layer in
/// debug builds.
pub fn create_device() -> Result<(ID3D11Device, ID3D11DeviceContext)> {
    let flags = if cfg!(debug_assertions) {
        D3D11_CREATE_DEVICE_DEBUG
    } else {
        D3D11_CREATE_DEVICE_FLAG(0)
    };
    let levels = [D3D_FEATURE_LEVEL_10_0];

    let mut device: Option<ID3D11Device> = None;
    let mut context: Option<ID3D11DeviceContext> = None;

    // SAFETY: `D3D11CreateDevice` is called with a valid adapter (or None for
    // the reference driver), a valid feature-level slice, and valid out-params.
    unsafe {
        let factory: IDXGIFactory1 = CreateDXGIFactory1()?;

        let mut i = 0;
        while let Ok(adapter) = factory.EnumAdapters1(i) {
            let adapter: IDXGIAdapter1 = adapter;
            if D3D11CreateDevice(
                &adapter,
                D3D_DRIVER_TYPE_UNKNOWN,
                HMODULE::default(),
                flags,
                Some(&levels),
                D3D11_SDK_VERSION,
                Some(&mut device),
                None,
                Some(&mut context),
            )
            .is_ok()
            {
                return Ok((device.unwrap(), context.unwrap()));
            }
            i += 1;
        }

        D3D11CreateDevice(
            None,
            D3D_DRIVER_TYPE_REFERENCE,
            HMODULE::default(),
            flags,
            Some(&levels),
            D3D11_SDK_VERSION,
            Some(&mut device),
            None,
            Some(&mut context),
        )?;
    }

    Ok((device.unwrap(), context.unwrap()))
}

/// The D3D11 objects every sample's `ConfigureEngineComponents` sets up:
/// device, swap chain (per `SwapChainConfigDX11` defaults: R8G8B8A8_UNORM_SRGB,
/// 2 buffers, DISCARD blit model — the modern choice would be FLIP_DISCARD,
/// but matching the C++ comes first here), backbuffer RTV, D32_FLOAT depth
/// buffer + DSV (per `Texture2dConfigDX11::SetDepthBuffer`), both bound, and
/// a full-window viewport.
///
/// COM interfaces are smart pointers in the `windows` crate, so drop order
/// handles the releases.
pub struct Renderer {
    pub device: ID3D11Device,
    pub context: ID3D11DeviceContext,
    pub swap_chain: IDXGISwapChain,
    pub backbuffer: ID3D11Texture2D,
    pub rtv: ID3D11RenderTargetView,
    pub dsv: ID3D11DepthStencilView,
    pub width: u32,
    pub height: u32,
}

impl Renderer {
    pub fn new(hwnd: HWND, width: u32, height: u32) -> Result<Self> {
        let (device, context) = create_device()?;

        let desc = DXGI_SWAP_CHAIN_DESC {
            BufferDesc: DXGI_MODE_DESC {
                Width: width,
                Height: height,
                RefreshRate: DXGI_RATIONAL { Numerator: 60, Denominator: 1 },
                Format: DXGI_FORMAT_R8G8B8A8_UNORM_SRGB,
                ScanlineOrdering: DXGI_MODE_SCANLINE_ORDER_UNSPECIFIED,
                Scaling: DXGI_MODE_SCALING_UNSPECIFIED,
            },
            SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
            BufferUsage: DXGI_USAGE_RENDER_TARGET_OUTPUT,
            BufferCount: 2,
            OutputWindow: hwnd,
            Windowed: true.into(),
            SwapEffect: DXGI_SWAP_EFFECT_DISCARD,
            Flags: 0,
        };

        // SAFETY: All creation calls receive valid descriptors and out-params;
        // `hwnd` is the live window the caller owns. The pipeline-binding
        // calls at the end reference views kept alive by the returned struct.
        unsafe {
            // The C++ creates the swap chain from its adapter-enumeration
            // factory; creating a fresh factory here is equivalent.
            let factory: IDXGIFactory1 = CreateDXGIFactory1()?;
            let mut swap_chain: Option<IDXGISwapChain> = None;
            factory.CreateSwapChain(&device, &desc, &mut swap_chain).ok()?;
            let swap_chain = swap_chain.unwrap();

            let backbuffer: ID3D11Texture2D = swap_chain.GetBuffer(0)?;
            let mut rtv: Option<ID3D11RenderTargetView> = None;
            device.CreateRenderTargetView(&backbuffer, None, Some(&mut rtv))?;
            let rtv = rtv.unwrap();

            let depth_desc = D3D11_TEXTURE2D_DESC {
                Width: width,
                Height: height,
                MipLevels: 1,
                ArraySize: 1,
                Format: DXGI_FORMAT_D32_FLOAT,
                SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
                Usage: D3D11_USAGE_DEFAULT,
                BindFlags: D3D11_BIND_DEPTH_STENCIL.0 as u32,
                CPUAccessFlags: 0,
                MiscFlags: 0,
            };
            let mut depth_texture: Option<ID3D11Texture2D> = None;
            device.CreateTexture2D(&depth_desc, None, Some(&mut depth_texture))?;
            let mut dsv: Option<ID3D11DepthStencilView> = None;
            device.CreateDepthStencilView(&depth_texture.unwrap(), None, Some(&mut dsv))?;
            let dsv = dsv.unwrap();

            context.OMSetRenderTargets(Some(&[Some(rtv.clone())]), &dsv);
            let viewport = D3D11_VIEWPORT {
                TopLeftX: 0.0,
                TopLeftY: 0.0,
                Width: width as f32,
                Height: height as f32,
                MinDepth: 0.0,
                MaxDepth: 1.0,
            };
            context.RSSetViewports(Some(&[viewport]));

            Ok(Renderer { device, context, swap_chain, backbuffer, rtv, dsv, width, height })
        }
    }

    /// Mirrors `RendererDX11::Present`'s defaults: no vsync, no flags.
    pub fn present(&self) {
        // SAFETY: The swap chain is alive for `self`'s lifetime; failures
        // (e.g. device removed) are ignored here as in the C++.
        unsafe {
            let _ = self.swap_chain.Present(0, DXGI_PRESENT(0));
        }
    }

    /// Mirrors `PipelineManagerDX11::SaveTextureScreenShot`: copy the
    /// backbuffer through a staging texture and write it as a PNG (the C++
    /// uses DirectXTK's `SaveWICTextureToFile`). Failures are ignored beyond
    /// skipping the file, as in the C++ (which just logs them).
    pub fn save_backbuffer_png(&self, path: &str) {
        let staging_desc = D3D11_TEXTURE2D_DESC {
            Width: self.width,
            Height: self.height,
            MipLevels: 1,
            ArraySize: 1,
            Format: DXGI_FORMAT_R8G8B8A8_UNORM_SRGB,
            SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
            Usage: D3D11_USAGE_STAGING,
            BindFlags: 0,
            CPUAccessFlags: D3D11_CPU_ACCESS_READ.0 as u32,
            MiscFlags: 0,
        };

        // SAFETY: Valid descriptor and out-params; the staging texture matches
        // the backbuffer's size/format, as `CopyResource` requires. `Map`
        // grants CPU read access to `pData` for `RowPitch * height` bytes
        // until `Unmap`, and the copy below stays within one row's width per
        // row.
        let pixels = unsafe {
            let mut staging: Option<ID3D11Texture2D> = None;
            if self.device.CreateTexture2D(&staging_desc, None, Some(&mut staging)).is_err() {
                return;
            }
            let staging = staging.unwrap();

            self.context.CopyResource(&staging, &self.backbuffer);

            let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
            if self.context.Map(&staging, 0, D3D11_MAP_READ, 0, Some(&mut mapped)).is_err() {
                return;
            }

            // Compact rows (RowPitch may exceed width * 4) and drop the alpha
            // channel — DirectXTK's PNG output is opaque RGB, and the samples
            // clear alpha to 0, which would otherwise produce a fully
            // transparent image.
            let mut pixels = Vec::with_capacity((self.width * self.height * 3) as usize);
            for row in 0..self.height {
                let src = (mapped.pData as *const u8).add((row * mapped.RowPitch) as usize);
                let row_slice = std::slice::from_raw_parts(src, (self.width * 4) as usize);
                for rgba in row_slice.chunks_exact(4) {
                    pixels.extend_from_slice(&rgba[..3]);
                }
            }

            self.context.Unmap(&staging, 0);
            pixels
        };

        let _ = image::save_buffer(path, &pixels, self.width, self.height, image::ColorType::Rgb8);
    }
}
