//! Rust port of the ImageProcessor sample (Applications/ImageProcessor) —
//! the chapter-10 compute-shader image filters. Text overlay omitted (out of
//! scope for these ports); everything else matches the C++:
//!
//! - Five images (`Outcrop`, `fruit`, `Hex`, `EyeOfHorus`, `Tiles`), cycled
//!   with **I**. Switching images resizes the intermediate/output textures.
//! - Five filter algorithms, cycled with **N**: brute-force Gaussian,
//!   separable Gaussian, cached (groupshared) separable Gaussian,
//!   brute-force bilateral, separable bilateral — the chapter's
//!   "correct compute → fast compute" progression, shaders used unchanged.
//!   Separable variants run an X pass into an intermediate texture and a Y
//!   pass into the output (SRV/UAV unbinds between passes).
//! - Two samplers for the fullscreen viewer, cycled with **Space** (!) —
//!   linear wrap vs. linear border-black. This app repurposes Space, so
//!   there is no screenshot key, exactly like the C++.
//! - Left-drag pans, right-drag and the mouse wheel zoom — implemented in
//!   `ImageViewerVS.hlsl` from the `WindowSize`/`ImageSize`/`ViewingParams`
//!   constants this app maintains.
//! - Rendering is **event-driven**, mirroring the C++'s overridden
//!   `MessageLoop`: a blocking `GetMessage` pump, re-rendering only when the
//!   window is invalidated (input, resize, `WM_PAINT`). CPU idles otherwise.

#![windows_subsystem = "windows"]

use glam::Vec4;
use glyph::renderer::Renderer;
use glyph::shader::compile_shader;
use glyph::window::{RenderWindow, WindowProc};
use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::Graphics::Direct3D::D3D_FEATURE_LEVEL_11_0;
use windows::Win32::Graphics::Direct3D::D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST;
use windows::Win32::Graphics::Direct3D11::{
    D3D11_BIND_CONSTANT_BUFFER, D3D11_BIND_INDEX_BUFFER, D3D11_BIND_SHADER_RESOURCE,
    D3D11_BIND_UNORDERED_ACCESS, D3D11_BIND_VERTEX_BUFFER, D3D11_BUFFER_DESC, D3D11_CLEAR_DEPTH,
    D3D11_COMPARISON_NEVER, D3D11_CPU_ACCESS_WRITE, D3D11_FILTER_MIN_MAG_MIP_LINEAR,
    D3D11_FLOAT32_MAX, D3D11_INPUT_ELEMENT_DESC, D3D11_INPUT_PER_VERTEX_DATA,
    D3D11_MAP_WRITE_DISCARD, D3D11_MAPPED_SUBRESOURCE, D3D11_SAMPLER_DESC,
    D3D11_SUBRESOURCE_DATA, D3D11_TEXTURE2D_DESC, D3D11_TEXTURE_ADDRESS_BORDER,
    D3D11_TEXTURE_ADDRESS_WRAP, D3D11_USAGE_DEFAULT, D3D11_USAGE_DYNAMIC, D3D11_USAGE_IMMUTABLE,
    ID3D11Buffer, ID3D11ComputeShader, ID3D11InputLayout, ID3D11PixelShader, ID3D11SamplerState,
    ID3D11ShaderResourceView, ID3D11Texture2D, ID3D11UnorderedAccessView, ID3D11VertexShader,
};
use windows::Win32::Graphics::Dxgi::Common::{
    DXGI_FORMAT_R16G16B16A16_FLOAT, DXGI_FORMAT_R32G32_FLOAT, DXGI_FORMAT_R32G32B32A32_FLOAT,
    DXGI_FORMAT_R32_UINT, DXGI_SAMPLE_DESC,
};
use windows::Win32::Graphics::Gdi::{BeginPaint, EndPaint, InvalidateRect, PAINTSTRUCT};
use windows::Win32::UI::Input::KeyboardAndMouse::{VK_ESCAPE, VK_SPACE};
use windows::Win32::UI::WindowsAndMessaging::{
    DefWindowProcW, DispatchMessageW, GetMessageW, MB_ICONEXCLAMATION, MB_SYSTEMMODAL, MSG,
    MessageBoxW, PostQuitMessage, TranslateMessage, WM_DESTROY, WM_KEYUP, WM_MOUSEMOVE,
    WM_MOUSEWHEEL, WM_PAINT, WM_SIZE, SW_HIDE, ShowWindow,
};
use windows::core::{HSTRING, Result, s, w};

const WIDTH: u32 = 1024;
const HEIGHT: u32 = 640;

/// The viewer VS's `ImageViewingData` cbuffer.
#[repr(C)]
struct ImageViewingData {
    window_size: Vec4,
    image_size: Vec4,
    viewing_params: Vec4,
}

/// Mouse pan/zoom state, mirroring the C++'s `m_UIData` + the pieces of
/// `App::HandleMouseMove` / `HandleMouseWheel`.
#[derive(Default)]
struct MessageHandler {
    render_requested: bool,
    next_image: bool,
    next_algorithm: bool,
    next_sampler: bool,
    pending_resize: Option<(u32, u32)>,
    viewing_params: [f32; 4],
    l_down: bool,
    r_down: bool,
    last: (i32, i32),
}

impl WindowProc for MessageHandler {
    fn window_proc(&mut self, hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
        match msg {
            WM_DESTROY => {
                // SAFETY: Trivially safe on the window's owning thread.
                unsafe { PostQuitMessage(0) };
                return LRESULT(0);
            }

            // The C++ renders inside WM_PAINT; here the paint is validated
            // and the main loop renders right after dispatch.
            WM_PAINT => {
                // SAFETY: Begin/EndPaint pair on the window being painted.
                unsafe {
                    let mut ps = PAINTSTRUCT::default();
                    let hdc = BeginPaint(hwnd, &mut ps);
                    let _ = EndPaint(hwnd, &ps);
                    let _ = hdc;
                }
                self.render_requested = true;
                return LRESULT(0);
            }

            WM_KEYUP => {
                let invalidate = match wparam.0 as u8 {
                    b'N' => {
                        self.next_algorithm = true;
                        true
                    }
                    b'I' => {
                        self.next_image = true;
                        true
                    }
                    _ if wparam.0 == VK_SPACE.0 as usize => {
                        self.next_sampler = true;
                        true
                    }
                    _ if wparam.0 == VK_ESCAPE.0 as usize => {
                        // SAFETY: As above.
                        unsafe { PostQuitMessage(0) };
                        return LRESULT(0);
                    }
                    _ => false,
                };
                if invalidate {
                    // SAFETY: Live window handle.
                    unsafe {
                        let _ = InvalidateRect(Some(hwnd), None, false);
                    }
                }
            }

            WM_MOUSEMOVE => {
                let x = (lparam.0 & 0xffff) as i16 as i32;
                let y = ((lparam.0 >> 16) & 0xffff) as i16 as i32;
                let l_button = wparam.0 & 0x01 != 0; // MK_LBUTTON
                let r_button = wparam.0 & 0x02 != 0; // MK_RBUTTON

                if l_button {
                    // Panning; deltas are last - current, divided by zoom.
                    if self.l_down {
                        let dx = (self.last.0 - x) as f32;
                        let dy = (self.last.1 - y) as f32;
                        self.viewing_params[0] += dx / self.viewing_params[2];
                        self.viewing_params[1] += dy / self.viewing_params[3];
                    }
                    self.l_down = true;
                    self.r_down = false;
                    self.last = (x, y);
                } else {
                    self.l_down = false;
                    if r_button {
                        // Zooming on vertical drag.
                        if self.r_down {
                            let dy = (self.last.1 - y) as f32;
                            self.viewing_params[2] += dy * 0.001;
                            self.viewing_params[3] += dy * 0.001;
                        }
                        self.r_down = true;
                        self.last = (x, y);
                    } else {
                        self.r_down = false;
                    }
                }

                // SAFETY: Live window handle.
                unsafe {
                    let _ = InvalidateRect(Some(hwnd), None, false);
                }
            }

            WM_MOUSEWHEEL => {
                let delta = ((wparam.0 >> 16) & 0xffff) as u16 as i16 as f32;
                self.viewing_params[2] += delta * 0.0001;
                self.viewing_params[3] += delta * 0.0001;
                // SAFETY: Live window handle.
                unsafe {
                    let _ = InvalidateRect(Some(hwnd), None, false);
                }
            }

            WM_SIZE => {
                let width = (lparam.0 & 0xffff) as u32;
                let height = ((lparam.0 >> 16) & 0xffff) as u32;
                self.pending_resize = Some((width, height));
            }

            _ => {}
        }

        // SAFETY: Forwarding to the default handler with Win32's own
        // arguments is always valid.
        unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) }
    }
}

/// A filterable image: the loaded texture's SRV plus its dimensions.
struct SourceImage {
    _texture: ID3D11Texture2D,
    srv: ID3D11ShaderResourceView,
    width: u32,
    height: u32,
}

/// An R16G16B16A16_FLOAT UAV+SRV texture (`SetColorBuffer` + the app's bind
/// flags), used for the intermediate and output filter targets.
struct FilterTarget {
    _texture: ID3D11Texture2D,
    srv: ID3D11ShaderResourceView,
    uav: ID3D11UnorderedAccessView,
}

fn create_filter_target(renderer: &Renderer, width: u32, height: u32) -> Result<FilterTarget> {
    let desc = D3D11_TEXTURE2D_DESC {
        Width: width,
        Height: height,
        MipLevels: 1,
        ArraySize: 1,
        Format: DXGI_FORMAT_R16G16B16A16_FLOAT,
        SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
        Usage: D3D11_USAGE_DEFAULT,
        BindFlags: (D3D11_BIND_UNORDERED_ACCESS.0 | D3D11_BIND_SHADER_RESOURCE.0) as u32,
        CPUAccessFlags: 0,
        MiscFlags: 0,
    };
    // SAFETY: Valid descriptor and out-params.
    unsafe {
        let mut texture: Option<ID3D11Texture2D> = None;
        renderer.device.CreateTexture2D(&desc, None, Some(&mut texture))?;
        let texture = texture.unwrap();
        let mut srv: Option<ID3D11ShaderResourceView> = None;
        renderer.device.CreateShaderResourceView(&texture, None, Some(&mut srv))?;
        let mut uav: Option<ID3D11UnorderedAccessView> = None;
        renderer.device.CreateUnorderedAccessView(&texture, None, Some(&mut uav))?;
        Ok(FilterTarget { _texture: texture, srv: srv.unwrap(), uav: uav.unwrap() })
    }
}

struct Pipeline {
    // Compute shaders per algorithm; separable ones as (X, Y) pairs.
    cs_gaussian_brute: ID3D11ComputeShader,
    cs_gaussian_separable: (ID3D11ComputeShader, ID3D11ComputeShader),
    cs_gaussian_cached: (ID3D11ComputeShader, ID3D11ComputeShader),
    cs_bilateral_brute: ID3D11ComputeShader,
    cs_bilateral_separable: (ID3D11ComputeShader, ID3D11ComputeShader),
    // Fullscreen viewer.
    vertex_shader: ID3D11VertexShader,
    pixel_shader: ID3D11PixelShader,
    input_layout: ID3D11InputLayout,
    quad_vb: ID3D11Buffer,
    quad_ib: ID3D11Buffer,
    cb_viewing: ID3D11Buffer,
    samplers: [ID3D11SamplerState; 2],
}

fn create_compute(
    renderer: &Renderer,
    file: &str,
    entry: &str,
) -> Result<ID3D11ComputeShader> {
    let bytecode = compile_shader(file, entry, "cs_5_0")?;
    let mut cs: Option<ID3D11ComputeShader> = None;
    // SAFETY: Valid bytecode slice and out-param.
    unsafe {
        renderer.device.CreateComputeShader(&bytecode, None, Some(&mut cs))?;
    }
    Ok(cs.unwrap())
}

fn create_pipeline(renderer: &Renderer) -> Result<Pipeline> {
    let device = &renderer.device;

    let cs_gaussian_brute = create_compute(renderer, "GaussianBruteForceCS.hlsl", "CSMAIN")?;
    let cs_gaussian_separable = (
        create_compute(renderer, "GaussianSeparableCS.hlsl", "CSMAINX")?,
        create_compute(renderer, "GaussianSeparableCS.hlsl", "CSMAINY")?,
    );
    let cs_gaussian_cached = (
        create_compute(renderer, "GaussianCachedCS.hlsl", "CSMAINX")?,
        create_compute(renderer, "GaussianCachedCS.hlsl", "CSMAINY")?,
    );
    let cs_bilateral_brute = create_compute(renderer, "BilateralBruteForceCS.hlsl", "CSMAIN")?;
    let cs_bilateral_separable = (
        create_compute(renderer, "BilateralSeparableCS.hlsl", "CSMAINX")?,
        create_compute(renderer, "BilateralSeparableCS.hlsl", "CSMAINY")?,
    );

    let vs_bytecode = compile_shader("ImageViewerVS.hlsl", "VSMAIN", "vs_5_0")?;
    let ps_bytecode = compile_shader("ImageViewerPS.hlsl", "PSMAIN", "ps_5_0")?;

    // GenerateFullScreenQuad's vertices: clip-space float4 positions plus
    // texcoords — note the engine's "TEXCOORDS" semantic name, which the
    // viewer VS declares too.
    #[repr(C)]
    struct QuadVertex {
        position: [f32; 4],
        tex: [f32; 2],
    }
    let vertices = [
        QuadVertex { position: [-1.0, 1.0, 0.0, 1.0], tex: [0.0, 0.0] },
        QuadVertex { position: [-1.0, -1.0, 0.0, 1.0], tex: [0.0, 1.0] },
        QuadVertex { position: [1.0, 1.0, 0.0, 1.0], tex: [1.0, 0.0] },
        QuadVertex { position: [1.0, -1.0, 0.0, 1.0], tex: [1.0, 1.0] },
    ];
    let indices: [u32; 6] = [0, 2, 1, 1, 2, 3];

    let elements = [
        D3D11_INPUT_ELEMENT_DESC {
            SemanticName: s!("POSITION"),
            SemanticIndex: 0,
            Format: DXGI_FORMAT_R32G32B32A32_FLOAT,
            InputSlot: 0,
            AlignedByteOffset: 0,
            InputSlotClass: D3D11_INPUT_PER_VERTEX_DATA,
            InstanceDataStepRate: 0,
        },
        D3D11_INPUT_ELEMENT_DESC {
            SemanticName: s!("TEXCOORDS"),
            SemanticIndex: 0,
            Format: DXGI_FORMAT_R32G32_FLOAT,
            InputSlot: 0,
            AlignedByteOffset: 16,
            InputSlotClass: D3D11_INPUT_PER_VERTEX_DATA,
            InstanceDataStepRate: 0,
        },
    ];

    // SAFETY: Creation calls with valid descriptors, initial data pointing
    // at the stack arrays above, live bytecode, and valid out-params.
    unsafe {
        let mut vertex_shader: Option<ID3D11VertexShader> = None;
        device.CreateVertexShader(&vs_bytecode, None, Some(&mut vertex_shader))?;
        let mut pixel_shader: Option<ID3D11PixelShader> = None;
        device.CreatePixelShader(&ps_bytecode, None, Some(&mut pixel_shader))?;
        let mut input_layout: Option<ID3D11InputLayout> = None;
        device.CreateInputLayout(&elements, &vs_bytecode, Some(&mut input_layout))?;

        let vb_desc = D3D11_BUFFER_DESC {
            ByteWidth: size_of_val(&vertices) as u32,
            Usage: D3D11_USAGE_IMMUTABLE,
            BindFlags: D3D11_BIND_VERTEX_BUFFER.0 as u32,
            CPUAccessFlags: 0,
            MiscFlags: 0,
            StructureByteStride: 0,
        };
        let vb_data = D3D11_SUBRESOURCE_DATA {
            pSysMem: vertices.as_ptr() as *const _,
            SysMemPitch: 0,
            SysMemSlicePitch: 0,
        };
        let mut quad_vb: Option<ID3D11Buffer> = None;
        device.CreateBuffer(&vb_desc, Some(&vb_data), Some(&mut quad_vb))?;

        let ib_desc = D3D11_BUFFER_DESC {
            ByteWidth: size_of_val(&indices) as u32,
            Usage: D3D11_USAGE_IMMUTABLE,
            BindFlags: D3D11_BIND_INDEX_BUFFER.0 as u32,
            CPUAccessFlags: 0,
            MiscFlags: 0,
            StructureByteStride: 0,
        };
        let ib_data = D3D11_SUBRESOURCE_DATA {
            pSysMem: indices.as_ptr() as *const _,
            SysMemPitch: 0,
            SysMemSlicePitch: 0,
        };
        let mut quad_ib: Option<ID3D11Buffer> = None;
        device.CreateBuffer(&ib_desc, Some(&ib_data), Some(&mut quad_ib))?;

        let cb_desc = D3D11_BUFFER_DESC {
            ByteWidth: size_of::<ImageViewingData>() as u32,
            Usage: D3D11_USAGE_DYNAMIC,
            BindFlags: D3D11_BIND_CONSTANT_BUFFER.0 as u32,
            CPUAccessFlags: D3D11_CPU_ACCESS_WRITE.0 as u32,
            MiscFlags: 0,
            StructureByteStride: 0,
        };
        let mut cb_viewing: Option<ID3D11Buffer> = None;
        device.CreateBuffer(&cb_desc, None, Some(&mut cb_viewing))?;

        // Sampler 0: engine defaults (linear/wrap). Sampler 1: linear/border,
        // black border — cycled with Space.
        let mut sampler_desc = D3D11_SAMPLER_DESC {
            Filter: D3D11_FILTER_MIN_MAG_MIP_LINEAR,
            AddressU: D3D11_TEXTURE_ADDRESS_WRAP,
            AddressV: D3D11_TEXTURE_ADDRESS_WRAP,
            AddressW: D3D11_TEXTURE_ADDRESS_WRAP,
            MipLODBias: 0.0,
            MaxAnisotropy: 1,
            ComparisonFunc: D3D11_COMPARISON_NEVER,
            BorderColor: [0.0; 4],
            MinLOD: 0.0,
            MaxLOD: D3D11_FLOAT32_MAX,
        };
        let mut sampler0: Option<ID3D11SamplerState> = None;
        device.CreateSamplerState(&sampler_desc, Some(&mut sampler0))?;
        sampler_desc.AddressU = D3D11_TEXTURE_ADDRESS_BORDER;
        sampler_desc.AddressV = D3D11_TEXTURE_ADDRESS_BORDER;
        sampler_desc.AddressW = D3D11_TEXTURE_ADDRESS_BORDER;
        let mut sampler1: Option<ID3D11SamplerState> = None;
        device.CreateSamplerState(&sampler_desc, Some(&mut sampler1))?;

        Ok(Pipeline {
            cs_gaussian_brute,
            cs_gaussian_separable,
            cs_gaussian_cached,
            cs_bilateral_brute,
            cs_bilateral_separable,
            vertex_shader: vertex_shader.unwrap(),
            pixel_shader: pixel_shader.unwrap(),
            input_layout: input_layout.unwrap(),
            quad_vb: quad_vb.unwrap(),
            quad_ib: quad_ib.unwrap(),
            cb_viewing: cb_viewing.unwrap(),
            samplers: [sampler0.unwrap(), sampler1.unwrap()],
        })
    }
}

/// One compute pass: bind, dispatch, unbind (the C++'s Dispatch +
/// ClearPipelineResources sequence).
///
/// # Safety
/// Caller guarantees the context and resources outlive the call.
unsafe fn dispatch_filter(
    context: &windows::Win32::Graphics::Direct3D11::ID3D11DeviceContext,
    cs: &ID3D11ComputeShader,
    input: &ID3D11ShaderResourceView,
    output: &ID3D11UnorderedAccessView,
    x: u32,
    y: u32,
) {
    // SAFETY: See doc comment; the unbinds uphold the no-simultaneous-
    // SRV-and-UAV rule before the next pass reads what this one wrote.
    unsafe {
        context.CSSetShader(cs, None);
        context.CSSetShaderResources(0, Some(&[Some(input.clone())]));
        let uavs = [Some(output.clone())];
        context.CSSetUnorderedAccessViews(0, 1, Some(uavs.as_ptr()), None);
        context.Dispatch(x, y, 1);
        context.CSSetShaderResources(0, Some(&[None]));
        let no_uavs = [None::<ID3D11UnorderedAccessView>];
        context.CSSetUnorderedAccessViews(0, 1, Some(no_uavs.as_ptr()), None);
    }
}

fn main() {
    let mut handler = MessageHandler {
        viewing_params: [0.5, 0.5, 1.0, 1.0],
        ..Default::default()
    };

    let mut window = RenderWindow::new();
    window.set_size(WIDTH as i32, HEIGHT as i32);
    window.set_caption("ImageProcessor");
    window.initialize(&mut handler);

    let mut renderer = match Renderer::new(window.handle(), WIDTH, HEIGHT, D3D_FEATURE_LEVEL_11_0)
    {
        Ok(r) => r,
        Err(_) => {
            // SAFETY: Live window handle; constant strings.
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

    let setup = (|| -> Result<(Pipeline, Vec<SourceImage>)> {
        let pipeline = create_pipeline(&renderer)?;
        let images = ["Outcrop.png", "fruit.png", "Hex.png", "EyeOfHorus.png", "Tiles.png"]
            .iter()
            .map(|name| {
                let (texture, srv) = renderer.load_texture_png(name)?;
                // SAFETY: Live texture; out-param desc.
                let desc = unsafe {
                    let mut d = D3D11_TEXTURE2D_DESC::default();
                    texture.GetDesc(&mut d);
                    d
                };
                Ok(SourceImage {
                    _texture: texture,
                    srv,
                    width: desc.Width,
                    height: desc.Height,
                })
            })
            .collect::<Result<Vec<_>>>()?;
        Ok((pipeline, images))
    })();

    let (pipeline, images) = match setup {
        Ok(v) => v,
        Err(e) => {
            let text = HSTRING::from(e.message());
            // SAFETY: Valid string arguments.
            unsafe {
                MessageBoxW(None, &text, w!("ImageProcessor setup failed"), MB_ICONEXCLAMATION | MB_SYSTEMMODAL);
            }
            return;
        }
    };

    let mut image_index = 0usize;
    let mut algorithm = 0usize;
    let mut sampler_index = 0usize;

    let (mut intermediate, mut output) = {
        let img = &images[image_index];
        (
            create_filter_target(&renderer, img.width, img.height).expect("filter target"),
            create_filter_target(&renderer, img.width, img.height).expect("filter target"),
        )
    };

    // Trigger the first render (the C++ calls InvalidateRect at the end of
    // Initialize; window creation already queued a WM_PAINT here).
    let mut msg = MSG::default();

    // Blocking pump: GetMessage returns false on WM_QUIT.
    // SAFETY: Standard pump; `handler` outlives the loop and is only touched
    // between dispatches on this thread.
    loop {
        let got = unsafe { GetMessageW(&mut msg, None, 0, 0) };
        if !got.as_bool() {
            return;
        }
        unsafe {
            let _ = TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }

        // App state changes requested by the handler.
        if let Some((w, h)) = handler.pending_resize.take() {
            renderer.resize(w, h);
        }
        if handler.next_algorithm {
            handler.next_algorithm = false;
            algorithm = (algorithm + 1) % 5;
        }
        if handler.next_sampler {
            handler.next_sampler = false;
            sampler_index = (sampler_index + 1) % 2;
        }
        if handler.next_image {
            handler.next_image = false;
            image_index = (image_index + 1) % images.len();
            let img = &images[image_index];
            intermediate = create_filter_target(&renderer, img.width, img.height)
                .expect("filter target");
            output = create_filter_target(&renderer, img.width, img.height)
                .expect("filter target");
        }

        if !handler.render_requested {
            continue;
        }
        handler.render_requested = false;

        let img = &images[image_index];
        let (iw, ih) = (img.width as f32, img.height as f32);
        let context = &renderer.context;

        // SAFETY: All bound objects live in `pipeline`/targets/`renderer`
        // beyond this iteration; array params reference outliving locals;
        // the cbuffer write matches its creation size.
        unsafe {
            // Filter pass(es) — dispatch sizes exactly as App::Update.
            match algorithm {
                0 => dispatch_filter(
                    context,
                    &pipeline.cs_gaussian_brute,
                    &img.srv,
                    &output.uav,
                    (iw / 32.0).ceil() as u32,
                    (ih / 32.0).ceil() as u32,
                ),
                1 | 2 | 4 => {
                    let (cs_x, cs_y) = match algorithm {
                        1 => (&pipeline.cs_gaussian_separable.0, &pipeline.cs_gaussian_separable.1),
                        2 => (&pipeline.cs_gaussian_cached.0, &pipeline.cs_gaussian_cached.1),
                        _ => (&pipeline.cs_bilateral_separable.0, &pipeline.cs_bilateral_separable.1),
                    };
                    dispatch_filter(
                        context,
                        cs_x,
                        &img.srv,
                        &intermediate.uav,
                        (iw / 640.0).ceil() as u32,
                        img.height,
                    );
                    dispatch_filter(
                        context,
                        cs_y,
                        &intermediate.srv,
                        &output.uav,
                        img.width,
                        (ih / 480.0).ceil() as u32,
                    );
                }
                _ => dispatch_filter(
                    context,
                    &pipeline.cs_bilateral_brute,
                    &img.srv,
                    &output.uav,
                    (iw / 32.0).ceil() as u32,
                    (ih / 32.0).ceil() as u32,
                ),
            }

            // Viewer pass.
            context.ClearRenderTargetView(&renderer.rtv, &[0.2, 0.2, 0.2, 0.2]);
            context.ClearDepthStencilView(&renderer.dsv, D3D11_CLEAR_DEPTH.0 as u32, 1.0, 0);

            let viewing = ImageViewingData {
                window_size: Vec4::new(renderer.width as f32, renderer.height as f32, 0.0, 0.0),
                image_size: Vec4::new(iw, ih, 0.0, 0.0),
                viewing_params: Vec4::from_array(handler.viewing_params),
            };
            let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
            if context
                .Map(&pipeline.cb_viewing, 0, D3D11_MAP_WRITE_DISCARD, 0, Some(&mut mapped))
                .is_ok()
            {
                *(mapped.pData as *mut ImageViewingData) = viewing;
                context.Unmap(&pipeline.cb_viewing, 0);
            }

            context.IASetInputLayout(&pipeline.input_layout);
            let vbs = [Some(pipeline.quad_vb.clone())];
            let strides = [24u32];
            let offsets = [0u32];
            context.IASetVertexBuffers(0, 1, Some(vbs.as_ptr()), Some(strides.as_ptr()), Some(offsets.as_ptr()));
            context.IASetIndexBuffer(&pipeline.quad_ib, DXGI_FORMAT_R32_UINT, 0);
            context.IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
            context.VSSetShader(&pipeline.vertex_shader, None);
            context.VSSetConstantBuffers(0, Some(&[Some(pipeline.cb_viewing.clone())]));
            context.PSSetShader(&pipeline.pixel_shader, None);
            context.PSSetShaderResources(0, Some(&[Some(output.srv.clone())]));
            context.PSSetSamplers(0, Some(&[Some(pipeline.samplers[sampler_index].clone())]));

            context.DrawIndexed(6, 0, 0);

            // Release the output SRV so the next frame's compute pass can
            // write the UAV without a forced unbind.
            context.PSSetShaderResources(0, Some(&[None]));
        }

        renderer.present();
    }
}
