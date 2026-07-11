//! Rust port of the BasicApplication sample (Applications/BasicApplication/App.cpp).
//!
//! The first sample with Direct3D 11: a 640x320 window at (25, 25) titled
//! "BasicApplication" whose client area is cleared each frame to a
//! time-varying blue — `sin(t²) * 0.25 + 0.5`, so the pulsing speeds up over
//! time — and presented with no vsync (the C++ framework presents with
//! `SyncInterval = 0` and logs the max framerate on exit).
//!
//! Behavior inherited from the C++ `Application` framework:
//! - `Esc` (key up) quits.
//! - `Space` (key up) saves a PNG screenshot of the backbuffer to the working
//!   directory, named `BasicApplication100001.png`, `...100002.png`, ... (the
//!   C++ numbering starts at 100001; DirectXTK's `SaveWICTextureToFile` is
//!   replaced by a staging-texture readback + the `image` crate).
//! - Closing the window quits.
//! - Resizing does nothing to the swap chain (no one handles the resize event
//!   in this sample), so the 640x320 image is stretched — faithful to C++.
//!
//! Device creation mirrors `RendererDX11::Initialize`: try each hardware
//! adapter at exactly `D3D_FEATURE_LEVEL_10_0`, fall back to the reference
//! driver, and abort with a message box if both fail. The debug layer is
//! enabled in debug builds. The swap chain mirrors `SwapChainConfigDX11`'s
//! defaults (R8G8B8A8_UNORM_SRGB, 2 buffers, DISCARD blit model — the modern
//! choice would be FLIP_DISCARD, but matching the C++ comes first here), and
//! the depth buffer mirrors `Texture2dConfigDX11::SetDepthBuffer` (D32_FLOAT).

#![windows_subsystem = "windows"]

use std::time::Instant;

use glyph::window::{RenderWindow, WindowProc};
use windows::Win32::Foundation::{HMODULE, HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::Graphics::Direct3D::{
    D3D_DRIVER_TYPE_REFERENCE, D3D_DRIVER_TYPE_UNKNOWN, D3D_FEATURE_LEVEL_10_0,
};
use windows::Win32::Graphics::Direct3D11::{
    D3D11_BIND_DEPTH_STENCIL, D3D11_CLEAR_DEPTH, D3D11_CPU_ACCESS_READ, D3D11_CREATE_DEVICE_DEBUG,
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
    CreateDXGIFactory1, DXGI_SWAP_CHAIN_DESC, DXGI_SWAP_EFFECT_DISCARD, DXGI_USAGE_RENDER_TARGET_OUTPUT,
    IDXGIAdapter1, IDXGIFactory1, IDXGISwapChain,
};
use windows::Win32::UI::Input::KeyboardAndMouse::{VK_ESCAPE, VK_SPACE};
use windows::Win32::UI::WindowsAndMessaging::{
    DefWindowProcW, DispatchMessageW, MB_ICONEXCLAMATION, MB_SYSTEMMODAL, MSG, MessageBoxW,
    PM_REMOVE, PeekMessageW, PostQuitMessage, TranslateMessage, WM_DESTROY, WM_KEYUP, WM_QUIT,
    SW_HIDE, ShowWindow,
};
use windows::core::{Result, w};

const WIDTH: u32 = 640;
const HEIGHT: u32 = 320;

/// Message handler mirroring the parts of `Application::WindowProc` +
/// `Application::HandleEvent` this sample exercises: quit on window
/// destruction or `Esc`, request a screenshot on `Space`.
struct MessageHandler {
    save_screenshot: bool,
}

impl WindowProc for MessageHandler {
    fn window_proc(&mut self, hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
        match msg {
            WM_DESTROY => {
                // SAFETY: Trivially safe to call from the thread that owns the
                // window; only marked unsafe as an FFI function.
                unsafe { PostQuitMessage(0) };
                return LRESULT(0);
            }

            WM_KEYUP => {
                if wparam.0 == VK_ESCAPE.0 as usize {
                    // SAFETY: As above.
                    unsafe { PostQuitMessage(0) };
                    return LRESULT(0);
                } else if wparam.0 == VK_SPACE.0 as usize {
                    self.save_screenshot = true;
                    return LRESULT(0);
                }
            }

            _ => {}
        }

        // SAFETY: Forwarding a message to the default handler with the exact
        // arguments Win32 passed in is always valid.
        unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) }
    }
}

/// The D3D11 objects `RendererDX11` + `App::ConfigureEngineComponents` set up.
/// COM interfaces are smart pointers in the `windows` crate, so drop order
/// handles the releases.
struct Renderer {
    #[allow(dead_code)]
    device: ID3D11Device,
    context: ID3D11DeviceContext,
    swap_chain: IDXGISwapChain,
    backbuffer: ID3D11Texture2D,
    rtv: ID3D11RenderTargetView,
    dsv: ID3D11DepthStencilView,
}

/// Mirrors `RendererDX11::Initialize`: enumerate hardware adapters and create
/// a device at exactly `D3D_FEATURE_LEVEL_10_0` on the first one that
/// succeeds, falling back to the reference driver. Debug layer in debug builds.
fn create_device() -> Result<(ID3D11Device, ID3D11DeviceContext)> {
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

        // "Could not create hardware device, trying to create the reference
        // device..." (which is unavailable on most modern systems, matching
        // the C++'s failure path).
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

/// Mirrors `App::ConfigureEngineComponents` from the swap chain onward:
/// swap chain with `SwapChainConfigDX11` defaults, backbuffer RTV, D32_FLOAT
/// depth buffer + DSV, both bound, and a full-window viewport.
fn create_renderer(hwnd: HWND) -> Result<Renderer> {
    let (device, context) = create_device()?;

    let desc = DXGI_SWAP_CHAIN_DESC {
        BufferDesc: DXGI_MODE_DESC {
            Width: WIDTH,
            Height: HEIGHT,
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
    // `hwnd` is the live window the caller owns. The pipeline-binding calls at
    // the end reference views kept alive by the returned `Renderer`.
    unsafe {
        // The C++ creates the swap chain from its adapter-enumeration factory;
        // creating a fresh factory here is equivalent.
        let factory: IDXGIFactory1 = CreateDXGIFactory1()?;
        let mut swap_chain: Option<IDXGISwapChain> = None;
        factory
            .CreateSwapChain(&device, &desc, &mut swap_chain)
            .ok()?;
        let swap_chain = swap_chain.unwrap();

        let backbuffer: ID3D11Texture2D = swap_chain.GetBuffer(0)?;
        let mut rtv: Option<ID3D11RenderTargetView> = None;
        device.CreateRenderTargetView(&backbuffer, None, Some(&mut rtv))?;
        let rtv = rtv.unwrap();

        // Depth buffer per Texture2dConfigDX11::SetDepthBuffer.
        let depth_desc = D3D11_TEXTURE2D_DESC {
            Width: WIDTH,
            Height: HEIGHT,
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

        // Bind the render targets and viewport (ApplyRenderTargets + the
        // viewport setup in ConfigureEngineComponents).
        context.OMSetRenderTargets(Some(&[Some(rtv.clone())]), &dsv);
        let viewport = D3D11_VIEWPORT {
            TopLeftX: 0.0,
            TopLeftY: 0.0,
            Width: WIDTH as f32,
            Height: HEIGHT as f32,
            MinDepth: 0.0,
            MaxDepth: 1.0,
        };
        context.RSSetViewports(Some(&[viewport]));

        Ok(Renderer { device, context, swap_chain, backbuffer, rtv, dsv })
    }
}

/// Mirrors `PipelineManagerDX11::SaveTextureScreenShot`: copy the backbuffer
/// through a staging texture and write `BasicApplication<n>.png` to the
/// working directory (the C++ uses DirectXTK's `SaveWICTextureToFile`).
fn save_screenshot(renderer: &Renderer, number: u32) {
    let staging_desc = D3D11_TEXTURE2D_DESC {
        Width: WIDTH,
        Height: HEIGHT,
        MipLevels: 1,
        ArraySize: 1,
        Format: DXGI_FORMAT_R8G8B8A8_UNORM_SRGB,
        SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
        Usage: D3D11_USAGE_STAGING,
        BindFlags: 0,
        CPUAccessFlags: D3D11_CPU_ACCESS_READ.0 as u32,
        MiscFlags: 0,
    };

    // SAFETY: Valid descriptor and out-params; the staging texture matches the
    // backbuffer's size/format, as `CopyResource` requires. `Map` grants CPU
    // read access to `pData` for `RowPitch * HEIGHT` bytes until `Unmap`, and
    // the copy below stays within one row's width per row.
    let pixels = unsafe {
        let mut staging: Option<ID3D11Texture2D> = None;
        if renderer
            .device
            .CreateTexture2D(&staging_desc, None, Some(&mut staging))
            .is_err()
        {
            return;
        }
        let staging = staging.unwrap();

        renderer.context.CopyResource(&staging, &renderer.backbuffer);

        let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
        if renderer
            .context
            .Map(&staging, 0, D3D11_MAP_READ, 0, Some(&mut mapped))
            .is_err()
        {
            return;
        }

        // Compact rows: RowPitch may exceed WIDTH * 4.
        let mut pixels = Vec::with_capacity((WIDTH * HEIGHT * 4) as usize);
        for row in 0..HEIGHT {
            let src = (mapped.pData as *const u8).add((row * mapped.RowPitch) as usize);
            pixels.extend_from_slice(std::slice::from_raw_parts(src, (WIDTH * 4) as usize));
        }

        renderer.context.Unmap(&staging, 0);
        pixels
    };

    // Failures are ignored beyond skipping the file, as in the C++ (which just
    // logs them).
    let _ = image::save_buffer(
        format!("BasicApplication{number}.png"),
        &pixels,
        WIDTH,
        HEIGHT,
        image::ColorType::Rgba8,
    );
}

fn main() {
    let mut handler = MessageHandler { save_screenshot: false };

    let mut window = RenderWindow::new();
    window.set_position(25, 25);
    window.set_size(WIDTH as i32, HEIGHT as i32);
    window.set_caption("BasicApplication");
    window.initialize(&mut handler);

    let renderer = match create_renderer(window.handle()) {
        Ok(r) => r,
        Err(_) => {
            // Mirrors the C++ failure path: hide the window, tell the user,
            // and abort.
            // SAFETY: The window handle is live; MessageBoxW with constant
            // strings is safe.
            unsafe {
                let _ = ShowWindow(window.handle(), SW_HIDE);
                MessageBoxW(
                    None,
                    w!("Could not create a hardware or software Direct3D 11 device - the program will now abort!"),
                    w!("Hieroglyph 3 Rendering"),
                    MB_ICONEXCLAMATION | MB_SYSTEMMODAL,
                );
            }
            return;
        }
    };

    let start = Instant::now();
    let mut screenshot_number = 100_000u32;
    let mut msg = MSG::default();

    loop {
        // SAFETY: Standard message pump; `DispatchMessageW` re-enters
        // `handler.window_proc`, which is sound because `handler` lives until
        // `main` returns and is only touched here between pump iterations —
        // wndproc calls and these accesses are temporally disjoint on this
        // single thread.
        unsafe {
            while PeekMessageW(&mut msg, None, 0, 0, PM_REMOVE).as_bool() {
                if msg.message == WM_QUIT {
                    return;
                }

                let _ = TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        }

        // App::Update — clear the window to a time-varying color and present.
        let runtime = start.elapsed().as_secs_f32();
        let f_blue = (runtime * runtime).sin() * 0.25 + 0.5;

        // SAFETY: The views/swap chain are alive for the whole loop; the clear
        // color is a valid [f32; 4].
        unsafe {
            renderer
                .context
                .ClearRenderTargetView(&renderer.rtv, &[0.0, 0.0, f_blue, 0.0]);
            renderer
                .context
                .ClearDepthStencilView(&renderer.dsv, D3D11_CLEAR_DEPTH.0 as u32, 1.0, 0);
            let _ = renderer.swap_chain.Present(0, windows::Win32::Graphics::Dxgi::DXGI_PRESENT(0));
        }

        // Application::TakeScreenShot — triggered by Space (see MessageHandler).
        if handler.save_screenshot {
            handler.save_screenshot = false;
            screenshot_number += 1;
            save_screenshot(&renderer, screenshot_number);
        }
    }
}
