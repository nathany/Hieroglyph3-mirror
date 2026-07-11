//! Rust port of the BasicTessellation sample
//! (Applications/BasicTessellation/App.cpp).
//!
//! The chapter-4 hardware-tessellation demo: the `hedra.ms3d` model is drawn
//! as a `3_CONTROL_POINT_PATCHLIST` through the full VS → HS → tessellator →
//! DS → PS pipeline of `BasicTessellation.hlsl` (used unchanged, all SM 5.0
//! entry points):
//!
//! - The VS transforms control points to world space.
//! - The HS passes control points through; its patch-constant function feeds
//!   the fixed-function tessellator the animated `EdgeFactors` —
//!   `sin(t) * 6 + 7`, sweeping the factors between 1 and 13 with
//!   `fractional_even` partitioning, so triangles continuously split and
//!   merge.
//! - The DS interpolates the barycentric points and applies view-projection.
//!
//! Rendered as a wireframe (rasterizer state FILL_WIREFRAME) so the
//! tessellation pattern is the whole show, while the model slowly spins
//! (0.05 pi rad/s). The pixel shader outputs the `FinalColor` parameter,
//! which the C++ never sets — the engine zero-initializes vector parameters,
//! so the wireframe is black (alpha 0) on the 0.6-gray clear, and this port
//! matches that faithfully rather than the shader's suggested white default.
//!
//! `Esc` quits; `Space` saves `BasicTessellation<n>.png`.

#![windows_subsystem = "windows"]

mod ms3d;

use std::time::Instant;

use glam::{Mat4, Vec3, Vec4};
use glyph::renderer::Renderer;
use glyph::shader::compile_shader;
use glyph::window::{AppMessageHandler, RenderWindow};
use windows::Win32::Graphics::Direct3D::{
    D3D_FEATURE_LEVEL_11_0, D3D11_PRIMITIVE_TOPOLOGY_3_CONTROL_POINT_PATCHLIST,
};
use windows::Win32::Graphics::Direct3D11::{
    D3D11_BIND_CONSTANT_BUFFER, D3D11_BIND_INDEX_BUFFER, D3D11_BIND_VERTEX_BUFFER,
    D3D11_BUFFER_DESC, D3D11_CLEAR_DEPTH, D3D11_CPU_ACCESS_WRITE, D3D11_CULL_BACK,
    D3D11_FILL_WIREFRAME, D3D11_INPUT_ELEMENT_DESC, D3D11_INPUT_PER_VERTEX_DATA,
    D3D11_MAP_WRITE_DISCARD, D3D11_MAPPED_SUBRESOURCE, D3D11_RASTERIZER_DESC,
    D3D11_SUBRESOURCE_DATA, D3D11_USAGE_DYNAMIC, D3D11_USAGE_IMMUTABLE, ID3D11Buffer,
    ID3D11DomainShader, ID3D11HullShader, ID3D11InputLayout, ID3D11PixelShader,
    ID3D11RasterizerState, ID3D11VertexShader,
};
use windows::Win32::Graphics::Dxgi::Common::{
    DXGI_FORMAT_R32G32_FLOAT, DXGI_FORMAT_R32G32B32_FLOAT, DXGI_FORMAT_R32_UINT,
};
use windows::Win32::UI::WindowsAndMessaging::{
    DispatchMessageW, MB_ICONEXCLAMATION, MB_SYSTEMMODAL, MSG, MessageBoxW, PM_REMOVE,
    PeekMessageW, SW_HIDE, ShowWindow, TranslateMessage, WM_QUIT,
};
use windows::core::{HSTRING, Result, s, w};

const WIDTH: u32 = 640;
const HEIGHT: u32 = 480;

#[repr(C)]
struct Transforms {
    world: Mat4,
    view_proj: Mat4,
}

#[repr(C)]
struct TessellationParameters {
    edge_factors: Vec4,
}

#[repr(C)]
struct RenderingParameters {
    final_color: Vec4,
}

struct Scene {
    vertex_buffer: ID3D11Buffer,
    index_buffer: ID3D11Buffer,
    index_count: u32,
    input_layout: ID3D11InputLayout,
    vertex_shader: ID3D11VertexShader,
    hull_shader: ID3D11HullShader,
    domain_shader: ID3D11DomainShader,
    pixel_shader: ID3D11PixelShader,
    wireframe: ID3D11RasterizerState,
    cb_transforms: ID3D11Buffer,
    cb_tess: ID3D11Buffer,
    cb_rendering: ID3D11Buffer,
    view_proj: Mat4,
}

fn setup(renderer: &Renderer) -> Result<Scene> {
    let device = &renderer.device;

    // All four stages from the one file, as the C++ LoadShader calls do.
    let vs_bytecode = compile_shader("BasicTessellation.hlsl", "VSMAIN", "vs_5_0")?;
    let hs_bytecode = compile_shader("BasicTessellation.hlsl", "HSMAIN", "hs_5_0")?;
    let ds_bytecode = compile_shader("BasicTessellation.hlsl", "DSMAIN", "ds_5_0")?;
    let ps_bytecode = compile_shader("BasicTessellation.hlsl", "PSMAIN", "ps_5_0")?;

    let mesh = ms3d::load("hedra.ms3d")?;

    // The MS3D loader's element order: POSITION, TEXCOORD, NORMAL (stride 32).
    // Only POSITION feeds the VS; the rest ride along in the layout.
    let elements = [
        D3D11_INPUT_ELEMENT_DESC {
            SemanticName: s!("POSITION"),
            SemanticIndex: 0,
            Format: DXGI_FORMAT_R32G32B32_FLOAT,
            InputSlot: 0,
            AlignedByteOffset: 0,
            InputSlotClass: D3D11_INPUT_PER_VERTEX_DATA,
            InstanceDataStepRate: 0,
        },
        D3D11_INPUT_ELEMENT_DESC {
            SemanticName: s!("TEXCOORD"),
            SemanticIndex: 0,
            Format: DXGI_FORMAT_R32G32_FLOAT,
            InputSlot: 0,
            AlignedByteOffset: 12,
            InputSlotClass: D3D11_INPUT_PER_VERTEX_DATA,
            InstanceDataStepRate: 0,
        },
        D3D11_INPUT_ELEMENT_DESC {
            SemanticName: s!("NORMAL"),
            SemanticIndex: 0,
            Format: DXGI_FORMAT_R32G32B32_FLOAT,
            InputSlot: 0,
            AlignedByteOffset: 20,
            InputSlotClass: D3D11_INPUT_PER_VERTEX_DATA,
            InstanceDataStepRate: 0,
        },
    ];

    // SAFETY: Creation calls with valid descriptors, initial data pointing at
    // the loaded mesh vectors (alive across the calls), bytecode slices from
    // the compiles above, and valid out-params.
    unsafe {
        let mut vertex_shader: Option<ID3D11VertexShader> = None;
        device.CreateVertexShader(&vs_bytecode, None, Some(&mut vertex_shader))?;
        let mut hull_shader: Option<ID3D11HullShader> = None;
        device.CreateHullShader(&hs_bytecode, None, Some(&mut hull_shader))?;
        let mut domain_shader: Option<ID3D11DomainShader> = None;
        device.CreateDomainShader(&ds_bytecode, None, Some(&mut domain_shader))?;
        let mut pixel_shader: Option<ID3D11PixelShader> = None;
        device.CreatePixelShader(&ps_bytecode, None, Some(&mut pixel_shader))?;

        let mut input_layout: Option<ID3D11InputLayout> = None;
        device.CreateInputLayout(&elements, &vs_bytecode, Some(&mut input_layout))?;

        // Wireframe rasterizer (RasterizerStateConfigDX11 defaults + FILL_WIREFRAME).
        let rs_desc = D3D11_RASTERIZER_DESC {
            FillMode: D3D11_FILL_WIREFRAME,
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
        let mut wireframe: Option<ID3D11RasterizerState> = None;
        device.CreateRasterizerState(&rs_desc, Some(&mut wireframe))?;

        let vb_desc = D3D11_BUFFER_DESC {
            ByteWidth: (mesh.vertices.len() * size_of::<ms3d::Ms3dVertex>()) as u32,
            Usage: D3D11_USAGE_IMMUTABLE,
            BindFlags: D3D11_BIND_VERTEX_BUFFER.0 as u32,
            CPUAccessFlags: 0,
            MiscFlags: 0,
            StructureByteStride: 0,
        };
        let vb_data = D3D11_SUBRESOURCE_DATA {
            pSysMem: mesh.vertices.as_ptr() as *const _,
            SysMemPitch: 0,
            SysMemSlicePitch: 0,
        };
        let mut vertex_buffer: Option<ID3D11Buffer> = None;
        device.CreateBuffer(&vb_desc, Some(&vb_data), Some(&mut vertex_buffer))?;

        let ib_desc = D3D11_BUFFER_DESC {
            ByteWidth: (mesh.indices.len() * size_of::<u32>()) as u32,
            Usage: D3D11_USAGE_IMMUTABLE,
            BindFlags: D3D11_BIND_INDEX_BUFFER.0 as u32,
            CPUAccessFlags: 0,
            MiscFlags: 0,
            StructureByteStride: 0,
        };
        let ib_data = D3D11_SUBRESOURCE_DATA {
            pSysMem: mesh.indices.as_ptr() as *const _,
            SysMemPitch: 0,
            SysMemSlicePitch: 0,
        };
        let mut index_buffer: Option<ID3D11Buffer> = None;
        device.CreateBuffer(&ib_desc, Some(&ib_data), Some(&mut index_buffer))?;

        // The camera from App::Initialize; ViewProj is constant.
        let view = glam::camera::lh::view::look_at_mat4(
            Vec3::new(5.0, 5.5, -5.0),
            Vec3::new(0.0, 0.75, 0.0),
            Vec3::new(0.0, 1.0, 0.0),
        );
        let proj = glam::camera::lh::proj::directx::perspective(
            std::f32::consts::FRAC_PI_2,
            640.0 / 480.0,
            0.1,
            25.0,
        );

        Ok(Scene {
            vertex_buffer: vertex_buffer.unwrap(),
            index_buffer: index_buffer.unwrap(),
            index_count: mesh.indices.len() as u32,
            input_layout: input_layout.unwrap(),
            vertex_shader: vertex_shader.unwrap(),
            hull_shader: hull_shader.unwrap(),
            domain_shader: domain_shader.unwrap(),
            pixel_shader: pixel_shader.unwrap(),
            wireframe: wireframe.unwrap(),
            cb_transforms: dynamic_cbuffer(device, size_of::<Transforms>() as u32)?,
            cb_tess: dynamic_cbuffer(device, size_of::<TessellationParameters>() as u32)?,
            cb_rendering: dynamic_cbuffer(device, size_of::<RenderingParameters>() as u32)?,
            view_proj: proj * view,
        })
    }
}

fn dynamic_cbuffer(
    device: &windows::Win32::Graphics::Direct3D11::ID3D11Device,
    byte_width: u32,
) -> Result<ID3D11Buffer> {
    let desc = D3D11_BUFFER_DESC {
        ByteWidth: byte_width,
        Usage: D3D11_USAGE_DYNAMIC,
        BindFlags: D3D11_BIND_CONSTANT_BUFFER.0 as u32,
        CPUAccessFlags: D3D11_CPU_ACCESS_WRITE.0 as u32,
        MiscFlags: 0,
        StructureByteStride: 0,
    };
    let mut buffer: Option<ID3D11Buffer> = None;
    // SAFETY: Valid descriptor and out-param.
    unsafe {
        device.CreateBuffer(&desc, None, Some(&mut buffer))?;
    }
    Ok(buffer.unwrap())
}

fn write_cbuffer<T>(
    context: &windows::Win32::Graphics::Direct3D11::ID3D11DeviceContext,
    buffer: &ID3D11Buffer,
    value: &T,
) {
    // SAFETY: `buffer` was created with `size_of::<T>()` bytes by
    // `dynamic_cbuffer`; WRITE_DISCARD grants write access to that many.
    unsafe {
        let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
        if context.Map(buffer, 0, D3D11_MAP_WRITE_DISCARD, 0, Some(&mut mapped)).is_ok() {
            std::ptr::copy_nonoverlapping(value as *const T, mapped.pData as *mut T, 1);
            context.Unmap(buffer, 0);
        }
    }
}

fn main() {
    let mut handler = AppMessageHandler::default();

    let mut window = RenderWindow::new();
    window.set_position(25, 25);
    window.set_size(WIDTH as i32, HEIGHT as i32);
    window.set_caption("BasicTessellation");
    window.initialize(&mut handler);

    let renderer = match Renderer::new(window.handle(), WIDTH, HEIGHT, D3D_FEATURE_LEVEL_11_0) {
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

    let scene = match setup(&renderer) {
        Ok(s) => s,
        Err(e) => {
            let text = HSTRING::from(e.message());
            // SAFETY: Valid string arguments.
            unsafe {
                MessageBoxW(None, &text, w!("BasicTessellation setup failed"), MB_ICONEXCLAMATION | MB_SYSTEMMODAL);
            }
            return;
        }
    };

    // The C++ accumulates these with per-frame elapsed time; fTessellation
    // starts at 3pi/2 so the factor starts at its minimum of 1.
    let mut f_rotation = 0.0f32;
    let mut f_tessellation = 3.0 * std::f32::consts::PI / 2.0;

    let mut last_frame = Instant::now();
    let mut screenshot_number = 100_000u32;
    let mut msg = MSG::default();

    loop {
        // SAFETY: Standard pump; `handler` outlives the loop and is only
        // accessed between pump iterations on this thread.
        unsafe {
            while PeekMessageW(&mut msg, None, 0, 0, PM_REMOVE).as_bool() {
                if msg.message == WM_QUIT {
                    return;
                }
                let _ = TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        }

        let now = Instant::now();
        let dt = now.duration_since(last_frame).as_secs_f32();
        last_frame = now;

        // App::Update's animation.
        f_rotation += dt * 3.14 * 0.05;
        f_tessellation += dt * 0.2 * 3.14;
        let factor = f_tessellation.sin() * 6.0 + 7.0;

        let context = &renderer.context;

        // SAFETY: All bound objects live in `scene`/`renderer` for the whole
        // loop; array parameters reference locals that outlive their calls;
        // cbuffer writes match the buffers' creation sizes.
        unsafe {
            context.ClearRenderTargetView(&renderer.rtv, &[0.6, 0.6, 0.6, 0.6]);
            context.ClearDepthStencilView(&renderer.dsv, D3D11_CLEAR_DEPTH.0 as u32, 1.0, 0);

            write_cbuffer(context, &scene.cb_transforms, &Transforms {
                world: Mat4::from_rotation_y(f_rotation),
                view_proj: scene.view_proj,
            });
            write_cbuffer(context, &scene.cb_tess, &TessellationParameters {
                edge_factors: Vec4::splat(factor),
            });
            write_cbuffer(context, &scene.cb_rendering, &RenderingParameters {
                // Never set by the C++ → engine zero-init (black, alpha 0).
                final_color: Vec4::ZERO,
            });

            context.IASetInputLayout(&scene.input_layout);
            let vbs = [Some(scene.vertex_buffer.clone())];
            let strides = [size_of::<ms3d::Ms3dVertex>() as u32];
            let offsets = [0u32];
            context.IASetVertexBuffers(0, 1, Some(vbs.as_ptr()), Some(strides.as_ptr()), Some(offsets.as_ptr()));
            context.IASetIndexBuffer(&scene.index_buffer, DXGI_FORMAT_R32_UINT, 0);
            context.IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_3_CONTROL_POINT_PATCHLIST);

            // The full tessellation pipeline. Register assignment is
            // per-stage: each stage's first (only) used cbuffer lands in b0
            // for that stage — Transforms for VS and DS, EdgeFactors for the
            // HS's patch-constant function, FinalColor for the PS.
            context.VSSetShader(&scene.vertex_shader, None);
            context.VSSetConstantBuffers(0, Some(&[Some(scene.cb_transforms.clone())]));
            context.HSSetShader(&scene.hull_shader, None);
            context.HSSetConstantBuffers(0, Some(&[Some(scene.cb_tess.clone())]));
            context.DSSetShader(&scene.domain_shader, None);
            context.DSSetConstantBuffers(0, Some(&[Some(scene.cb_transforms.clone())]));
            context.PSSetShader(&scene.pixel_shader, None);
            context.PSSetConstantBuffers(0, Some(&[Some(scene.cb_rendering.clone())]));

            context.RSSetState(&scene.wireframe);

            context.DrawIndexed(scene.index_count, 0, 0);
        }

        renderer.present();

        if handler.save_screenshot {
            handler.save_screenshot = false;
            screenshot_number += 1;
            renderer.save_backbuffer_png(&format!("BasicTessellation{screenshot_number}.png"));
        }
    }
}
