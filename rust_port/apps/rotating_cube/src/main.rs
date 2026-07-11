//! Rust port of the RotatingCube sample (Applications/RotatingCube/App.cpp).
//!
//! The book's first real render: an indexed color cube spun by a world matrix
//! rebuilt every frame, drawn with VS → GS → PS from
//! `data/shaders/RotatingCube.hlsl` (copied unchanged from
//! Applications/Data/Shaders). The vertex shader is a passthrough; the
//! geometry shader "blows up" each face along its normal by 1/4 and applies
//! the `WorldViewProjMatrix` — so the cbuffer is a *geometry* shader input,
//! the one stage most samples don't use.
//!
//! Matrix conventions, spelled out once (see also `glyph::shader`):
//! - The shader does row-vector math (`mul(position, WorldViewProjMatrix)`),
//!   and the engine compiles with `D3DCOMPILE_PACK_MATRIX_ROW_MAJOR` — so does
//!   `glyph::shader::compile_shader`.
//! - glam composes column-vector style: `proj * view * world` here equals the
//!   C++'s row-vector `World * View * Proj` (each is the other's transpose),
//!   and the row-major packing flag makes HLSL read glam's memory as that
//!   transpose. Net result: natural glam math, unchanged shaders, zero
//!   transposes.
//! - C++ `RotationMatrixY(t) * RotationMatrixX(t)` (row-vector: Y first, then
//!   X) becomes `from_rotation_x(t) * from_rotation_y(t)` in column-vector
//!   glam.
//!
//! The window (and the `Space` screenshot prefix) is titled
//! "BasicApplication" because the C++ `App::GetName()` returns exactly that —
//! a copy-paste quirk in the original, preserved faithfully.

#![windows_subsystem = "windows"]

use std::f32::consts::FRAC_PI_2;
use std::time::Instant;

use glam::{Mat4, Vec3};
use glyph::renderer::Renderer;
use glyph::shader::compile_shader;
use glyph::window::{AppMessageHandler, RenderWindow};
use windows::Win32::Graphics::Direct3D::{
    D3D_FEATURE_LEVEL_10_0, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST,
};
use windows::Win32::Graphics::Direct3D11::{
    D3D11_BIND_CONSTANT_BUFFER, D3D11_BIND_INDEX_BUFFER, D3D11_BIND_VERTEX_BUFFER,
    D3D11_BLEND_DESC, D3D11_BLEND_ONE, D3D11_BLEND_OP_ADD, D3D11_BLEND_ZERO, D3D11_BUFFER_DESC,
    D3D11_CLEAR_DEPTH, D3D11_COLOR_WRITE_ENABLE_ALL, D3D11_COMPARISON_ALWAYS,
    D3D11_COMPARISON_LESS, D3D11_CPU_ACCESS_WRITE, D3D11_CULL_BACK, D3D11_DEPTH_STENCIL_DESC,
    D3D11_DEPTH_STENCILOP_DESC, D3D11_DEPTH_WRITE_MASK_ALL, D3D11_FILL_SOLID,
    D3D11_INPUT_ELEMENT_DESC, D3D11_INPUT_PER_VERTEX_DATA, D3D11_MAP_WRITE_DISCARD,
    D3D11_MAPPED_SUBRESOURCE, D3D11_RASTERIZER_DESC, D3D11_RENDER_TARGET_BLEND_DESC,
    D3D11_STENCIL_OP_KEEP, D3D11_SUBRESOURCE_DATA, D3D11_USAGE_DYNAMIC, D3D11_USAGE_IMMUTABLE,
    ID3D11BlendState, ID3D11Buffer, ID3D11DepthStencilState, ID3D11GeometryShader,
    ID3D11InputLayout, ID3D11PixelShader, ID3D11RasterizerState, ID3D11VertexShader,
};
use windows::Win32::Graphics::Dxgi::Common::{
    DXGI_FORMAT_R32G32B32_FLOAT, DXGI_FORMAT_R32G32B32A32_FLOAT, DXGI_FORMAT_R32_UINT,
};
use windows::Win32::UI::WindowsAndMessaging::{
    DispatchMessageW, MB_ICONEXCLAMATION, MB_SYSTEMMODAL, MSG, MessageBoxW, PM_REMOVE,
    PeekMessageW, SW_HIDE, ShowWindow, TranslateMessage, WM_QUIT,
};
use windows::core::{Result, s, w};

// Unlike BasicApplication's 640x320, this sample uses 640x480.
const WIDTH: u32 = 640;
const HEIGHT: u32 = 480;

/// Matches the C++ `Vertex { XMFLOAT3 Pos; XMFLOAT4 Color; }`: 28 bytes,
/// color at offset 12, as the input layout below declares. Plain float arrays
/// rather than glam types on purpose — glam's `Vec4` is 16-byte aligned,
/// which would pad this struct to 32 bytes and break the layout.
#[repr(C)]
struct Vertex {
    position: [f32; 3],
    color: [f32; 4],
}

/// Everything `App::ConfigureEngineComponents` + `App::Initialize` create
/// beyond the shared `Renderer`.
struct Scene {
    vertex_buffer: ID3D11Buffer,
    index_buffer: ID3D11Buffer,
    constant_buffer: ID3D11Buffer,
    input_layout: ID3D11InputLayout,
    vertex_shader: ID3D11VertexShader,
    geometry_shader: ID3D11GeometryShader,
    pixel_shader: ID3D11PixelShader,
    rasterizer_state: ID3D11RasterizerState,
    depth_stencil_state: ID3D11DepthStencilState,
    blend_state: ID3D11BlendState,
    view: Mat4,
    proj: Mat4,
}

fn setup(renderer: &Renderer) -> Result<Scene> {
    let device = &renderer.device;

    // Shaders — same file, entry points, and shader-model targets as the C++
    // (`LoadShader` calls with vs_4_0/gs_4_0/ps_4_0, matching the feature
    // level 10.0 device).
    let vs_bytecode = compile_shader("RotatingCube.hlsl", "VSMain", "vs_4_0")?;
    let gs_bytecode = compile_shader("RotatingCube.hlsl", "GSMain", "gs_4_0")?;
    let ps_bytecode = compile_shader("RotatingCube.hlsl", "PSMain", "ps_4_0")?;

    // SAFETY: All creation calls receive valid descriptors, initial data
    // pointing at live stack arrays, bytecode slices from the compiles above,
    // and valid out-params.
    unsafe {
        let mut vertex_shader: Option<ID3D11VertexShader> = None;
        device.CreateVertexShader(&vs_bytecode, None, Some(&mut vertex_shader))?;
        let mut geometry_shader: Option<ID3D11GeometryShader> = None;
        device.CreateGeometryShader(&gs_bytecode, None, Some(&mut geometry_shader))?;
        let mut pixel_shader: Option<ID3D11PixelShader> = None;
        device.CreatePixelShader(&ps_bytecode, None, Some(&mut pixel_shader))?;

        // "just use default states" — the C++ creates state objects from the
        // engine's default configs (which mirror the D3D11 defaults), with
        // back-face culling set explicitly on the rasterizer.
        let rasterizer_desc = D3D11_RASTERIZER_DESC {
            FillMode: D3D11_FILL_SOLID,
            CullMode: D3D11_CULL_BACK,
            FrontCounterClockwise: false.into(),
            DepthBias: 0,
            DepthBiasClamp: 0.0,
            SlopeScaledDepthBias: 0.0,
            DepthClipEnable: true.into(),
            ScissorEnable: false.into(),
            MultisampleEnable: false.into(),
            AntialiasedLineEnable: false.into(),
        };
        let mut rasterizer_state: Option<ID3D11RasterizerState> = None;
        device.CreateRasterizerState(&rasterizer_desc, Some(&mut rasterizer_state))?;

        let stencil_op = D3D11_DEPTH_STENCILOP_DESC {
            StencilFailOp: D3D11_STENCIL_OP_KEEP,
            StencilDepthFailOp: D3D11_STENCIL_OP_KEEP,
            StencilPassOp: D3D11_STENCIL_OP_KEEP,
            StencilFunc: D3D11_COMPARISON_ALWAYS,
        };
        let depth_stencil_desc = D3D11_DEPTH_STENCIL_DESC {
            DepthEnable: true.into(),
            DepthWriteMask: D3D11_DEPTH_WRITE_MASK_ALL,
            DepthFunc: D3D11_COMPARISON_LESS,
            StencilEnable: false.into(),
            StencilReadMask: 0xff,
            StencilWriteMask: 0xff,
            FrontFace: stencil_op,
            BackFace: stencil_op,
        };
        let mut depth_stencil_state: Option<ID3D11DepthStencilState> = None;
        device.CreateDepthStencilState(&depth_stencil_desc, Some(&mut depth_stencil_state))?;

        let blend_desc = D3D11_BLEND_DESC {
            AlphaToCoverageEnable: false.into(),
            IndependentBlendEnable: false.into(),
            RenderTarget: [D3D11_RENDER_TARGET_BLEND_DESC {
                BlendEnable: false.into(),
                SrcBlend: D3D11_BLEND_ONE,
                DestBlend: D3D11_BLEND_ZERO,
                BlendOp: D3D11_BLEND_OP_ADD,
                SrcBlendAlpha: D3D11_BLEND_ONE,
                DestBlendAlpha: D3D11_BLEND_ZERO,
                BlendOpAlpha: D3D11_BLEND_OP_ADD,
                RenderTargetWriteMask: D3D11_COLOR_WRITE_ENABLE_ALL.0 as u8,
            }; 8],
        };
        let mut blend_state: Option<ID3D11BlendState> = None;
        device.CreateBlendState(&blend_desc, Some(&mut blend_state))?;

        // Input layout — semantics and offsets exactly as the C++ declares
        // them ("SV_POSITION" as a vertex-input semantic name is unusual but
        // matches the shader's `float4 position : SV_Position`). Requires the
        // VS bytecode for signature validation.
        let layout_desc = [
            D3D11_INPUT_ELEMENT_DESC {
                SemanticName: s!("SV_POSITION"),
                SemanticIndex: 0,
                Format: DXGI_FORMAT_R32G32B32_FLOAT,
                InputSlot: 0,
                AlignedByteOffset: 0,
                InputSlotClass: D3D11_INPUT_PER_VERTEX_DATA,
                InstanceDataStepRate: 0,
            },
            D3D11_INPUT_ELEMENT_DESC {
                SemanticName: s!("COLOR"),
                SemanticIndex: 0,
                Format: DXGI_FORMAT_R32G32B32A32_FLOAT,
                InputSlot: 0,
                AlignedByteOffset: 12,
                InputSlotClass: D3D11_INPUT_PER_VERTEX_DATA,
                InstanceDataStepRate: 0,
            },
        ];
        let mut input_layout: Option<ID3D11InputLayout> = None;
        device.CreateInputLayout(&layout_desc, &vs_bytecode, Some(&mut input_layout))?;

        // Cube geometry — vertices and winding copied from App::Initialize.
        let vertices = [
            Vertex { position: [-1.0, 1.0, -1.0], color: [0.0, 0.0, 1.0, 1.0] },
            Vertex { position: [1.0, 1.0, -1.0], color: [0.0, 1.0, 0.0, 1.0] },
            Vertex { position: [1.0, 1.0, 1.0], color: [0.0, 1.0, 1.0, 1.0] },
            Vertex { position: [-1.0, 1.0, 1.0], color: [1.0, 0.0, 0.0, 1.0] },
            Vertex { position: [-1.0, -1.0, -1.0], color: [1.0, 0.0, 1.0, 1.0] },
            Vertex { position: [1.0, -1.0, -1.0], color: [1.0, 1.0, 0.0, 1.0] },
            Vertex { position: [1.0, -1.0, 1.0], color: [1.0, 1.0, 1.0, 1.0] },
            Vertex { position: [-1.0, -1.0, 1.0], color: [0.0, 0.0, 0.0, 1.0] },
        ];
        #[rustfmt::skip]
        let indices: [u32; 36] = [
            3, 1, 0,  2, 1, 3,
            0, 5, 4,  1, 5, 0,
            3, 4, 7,  0, 4, 3,
            1, 6, 5,  2, 6, 1,
            2, 7, 6,  3, 7, 2,
            6, 4, 5,  7, 4, 6,
        ];

        // Immutable vertex/index buffers, as BufferConfigDX11's non-dynamic
        // defaults produce.
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
        let mut vertex_buffer: Option<ID3D11Buffer> = None;
        device.CreateBuffer(&vb_desc, Some(&vb_data), Some(&mut vertex_buffer))?;

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
        let mut index_buffer: Option<ID3D11Buffer> = None;
        device.CreateBuffer(&ib_desc, Some(&ib_data), Some(&mut index_buffer))?;

        // Constant buffer for the shader's `Transforms` cbuffer (one matrix).
        // The engine's ParameterManager creates its cbuffers dynamic and maps
        // them; same here.
        let cb_desc = D3D11_BUFFER_DESC {
            ByteWidth: size_of::<Mat4>() as u32,
            Usage: D3D11_USAGE_DYNAMIC,
            BindFlags: D3D11_BIND_CONSTANT_BUFFER.0 as u32,
            CPUAccessFlags: D3D11_CPU_ACCESS_WRITE.0 as u32,
            MiscFlags: 0,
            StructureByteStride: 0,
        };
        let mut constant_buffer: Option<ID3D11Buffer> = None;
        device.CreateBuffer(&cb_desc, None, Some(&mut constant_buffer))?;

        // The "camera" from App::Initialize: XMMatrixLookAtLH /
        // XMMatrixPerspectiveFovLH with the same arguments. glam's `camera`
        // module has the matching left-handed, 0..1-depth constructors.
        let view = glam::camera::lh::view::look_at_mat4(
            Vec3::new(0.0, 1.0, -5.0),
            Vec3::new(0.0, 1.0, 0.0),
            Vec3::new(0.0, 1.0, 0.0),
        );
        let proj = glam::camera::lh::proj::directx::perspective(
            FRAC_PI_2,
            WIDTH as f32 / HEIGHT as f32,
            0.01,
            100.0,
        );

        Ok(Scene {
            vertex_buffer: vertex_buffer.unwrap(),
            index_buffer: index_buffer.unwrap(),
            constant_buffer: constant_buffer.unwrap(),
            input_layout: input_layout.unwrap(),
            vertex_shader: vertex_shader.unwrap(),
            geometry_shader: geometry_shader.unwrap(),
            pixel_shader: pixel_shader.unwrap(),
            rasterizer_state: rasterizer_state.unwrap(),
            depth_stencil_state: depth_stencil_state.unwrap(),
            blend_state: blend_state.unwrap(),
            view,
            proj,
        })
    }
}

fn main() {
    let mut handler = AppMessageHandler::default();

    let mut window = RenderWindow::new();
    window.set_position(25, 25);
    window.set_size(WIDTH as i32, HEIGHT as i32);
    // The C++ App::GetName() returns "BasicApplication" — a copy-paste quirk
    // in the original sample, preserved here.
    window.set_caption("BasicApplication");
    window.initialize(&mut handler);

    let renderer = match Renderer::new(window.handle(), WIDTH, HEIGHT, D3D_FEATURE_LEVEL_10_0) {
        Ok(r) => r,
        Err(_) => {
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

    let scene = match setup(&renderer) {
        Ok(s) => s,
        Err(e) => {
            // The C++ logs setup failures (e.g. shader compile errors) and
            // asserts; show the message instead, since there's no console.
            let text = windows::core::HSTRING::from(e.message());
            // SAFETY: MessageBoxW with valid string arguments.
            unsafe {
                MessageBoxW(
                    None,
                    &text,
                    w!("RotatingCube setup failed"),
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

        // App::Update — clear, animate the world matrix, draw, present.
        let t = start.elapsed().as_secs_f32();

        // C++ (row-vector): RotationMatrixY(t) * RotationMatrixX(t) — Y first,
        // then X. Column-vector equivalent: from_rotation_x * from_rotation_y.
        let world = Mat4::from_rotation_x(t) * Mat4::from_rotation_y(t);
        let world_view_proj = scene.proj * scene.view * world;

        let context = &renderer.context;

        // SAFETY: All bound objects live in `scene`/`renderer` for the whole
        // loop. The cbuffer map writes one Mat4 (64 bytes) into a 64-byte
        // WRITE_DISCARD mapping. Array/pointer parameters reference locals
        // that outlive the calls.
        unsafe {
            context.ClearRenderTargetView(&renderer.rtv, &[0.0, 0.0, 0.0, 0.0]);
            context.ClearDepthStencilView(&renderer.dsv, D3D11_CLEAR_DEPTH.0 as u32, 1.0, 0);

            // Upload WorldViewProjMatrix (see the module docs for why no
            // transpose happens here).
            let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
            if context
                .Map(&scene.constant_buffer, 0, D3D11_MAP_WRITE_DISCARD, 0, Some(&mut mapped))
                .is_ok()
            {
                *(mapped.pData as *mut Mat4) = world_view_proj;
                context.Unmap(&scene.constant_buffer, 0);
            }

            // PipelineManagerDX11::Draw, unrolled: IA, shader stages, states,
            // then the indexed draw.
            context.IASetInputLayout(&scene.input_layout);
            let vertex_buffers = [Some(scene.vertex_buffer.clone())];
            let strides = [size_of::<Vertex>() as u32];
            let offsets = [0u32];
            context.IASetVertexBuffers(
                0,
                1,
                Some(vertex_buffers.as_ptr()),
                Some(strides.as_ptr()),
                Some(offsets.as_ptr()),
            );
            context.IASetIndexBuffer(&scene.index_buffer, DXGI_FORMAT_R32_UINT, 0);
            context.IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);

            context.VSSetShader(&scene.vertex_shader, None);
            context.GSSetShader(&scene.geometry_shader, None);
            context.PSSetShader(&scene.pixel_shader, None);

            // Only the geometry shader declares the Transforms cbuffer, so
            // that's the only stage it needs binding to (the engine's
            // reflection-driven ParameterManager arrives at the same result).
            context.GSSetConstantBuffers(0, Some(&[Some(scene.constant_buffer.clone())]));

            context.RSSetState(&scene.rasterizer_state);
            // The C++ passes the depth-stencil state's *index* as the stencil
            // ref (m_uStencilRef = iDepthStencilState) — harmless since
            // stenciling is disabled; 0 here.
            context.OMSetDepthStencilState(&scene.depth_stencil_state, 0);
            context.OMSetBlendState(&scene.blend_state, None, 0xffffffff);

            context.DrawIndexed(36, 0, 0);
        }

        renderer.present();

        // Application::TakeScreenShot — Space; prefix is GetName(), i.e. the
        // "BasicApplication" quirk again.
        if handler.save_screenshot {
            handler.save_screenshot = false;
            screenshot_number += 1;
            renderer.save_backbuffer_png(&format!("BasicApplication{screenshot_number}.png"));
        }
    }
}
