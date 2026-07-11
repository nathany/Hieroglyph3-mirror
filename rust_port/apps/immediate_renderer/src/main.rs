//! Rust port of the ImmediateRenderer sample
//! (Applications/ImmediateRenderer/App.cpp) — **core visual scope**: all the
//! rendered content and interaction except text (the 3D `TextActor` and the
//! FPS overlay need the engine's GDI sprite-font machinery) and the Lua
//! console. The missing `Capsule.obj` model is also omitted — the C++ loads
//! zero triangles for it and draws nothing.
//!
//! What renders, mirroring `App::Initialize`:
//! - An animated **paraboloid grid** (the chapter's immediate-rendering
//!   lesson): 20x20 vertices + indices rebuilt from scratch every frame into
//!   dynamic buffers, textured with `EyeOfHorus_128.png`, at (3,0,0),
//!   slowly spinning (-0.1 rad/s).
//! - A **shape collection** at (0,2.5,0), spinning at 0.4 rad/s, drawn in the
//!   alpha-blended pass: translucent red sphere, green cone, yellow disc,
//!   blue box, white arrow.
//! - The **STL mesh** `MeshedReconstruction.stl` at (5,5,0), spinning at
//!   -1 rad/s, vertex color (0,1,0,0).
//! - A green **Bézier curve** as a line list.
//! - The **skybox** (`TropicalSunnyDay.dds` cube map).
//! - A **point light** circling at radius 50, height 50 (-1 rad/s), driving
//!   the UE4-style PBR shading in the `vertex-color/textured
//!   .vertex-normal.point-light.perspective` shader pairs (used unchanged).
//!
//! Interaction, mirroring `RenderApplication` + `FirstPersonCamera`:
//! right-mouse-drag looks, W/S/A/D strafes, Q/E moves up/down, Ctrl speeds
//! up, keys 1/2/3 switch to the off-center projections from
//! `App::HandleEvent`, Esc quits, Space screenshots, and resizing the window
//! resizes the swap chain (and resets any 1/2/3 projection, as the C++'s
//! `SetAspectRatio` does).

#![windows_subsystem = "windows"]

mod camera;
mod mesh;
mod skybox;
mod stl;

use std::time::Instant;

use camera::{CameraInput, FirstPersonCamera};
use glam::{Mat4, Vec2, Vec3, Vec4};
use glyph::renderer::Renderer;
use glyph::shader::compile_shader;
use glyph::window::{RenderWindow, WindowProc};
use mesh::{BasicVertex, ImmediateMesh};
use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::Graphics::Direct3D::{
    D3D_FEATURE_LEVEL_11_0, D3D11_PRIMITIVE_TOPOLOGY_LINELIST,
    D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST,
};
use windows::Win32::Graphics::Direct3D11::{
    D3D11_BIND_CONSTANT_BUFFER, D3D11_BLEND_DESC, D3D11_BLEND_INV_SRC_ALPHA, D3D11_BLEND_ONE,
    D3D11_BLEND_OP_ADD, D3D11_BLEND_SRC_ALPHA, D3D11_BUFFER_DESC, D3D11_CLEAR_DEPTH,
    D3D11_COLOR_WRITE_ENABLE_ALL, D3D11_COMPARISON_LESS_EQUAL, D3D11_COMPARISON_NEVER,
    D3D11_CPU_ACCESS_WRITE, D3D11_DEPTH_STENCIL_DESC, D3D11_FILTER_MIN_MAG_MIP_LINEAR,
    D3D11_FLOAT32_MAX, D3D11_INPUT_ELEMENT_DESC, D3D11_INPUT_PER_VERTEX_DATA,
    D3D11_MAP_WRITE_DISCARD, D3D11_MAPPED_SUBRESOURCE, D3D11_RENDER_TARGET_BLEND_DESC,
    D3D11_SAMPLER_DESC, D3D11_TEXTURE_ADDRESS_WRAP, D3D11_USAGE_DYNAMIC, ID3D11BlendState,
    ID3D11Buffer, ID3D11DepthStencilState, ID3D11InputLayout, ID3D11PixelShader,
    ID3D11SamplerState, ID3D11ShaderResourceView, ID3D11VertexShader,
};
use windows::Win32::Graphics::Dxgi::Common::{
    DXGI_FORMAT_R32G32_FLOAT, DXGI_FORMAT_R32G32B32_FLOAT, DXGI_FORMAT_R32G32B32A32_FLOAT,
    DXGI_FORMAT_R32_UINT,
};
use windows::Win32::UI::Input::KeyboardAndMouse::{VK_CONTROL, VK_ESCAPE, VK_SPACE};
use windows::Win32::UI::WindowsAndMessaging::{
    DefWindowProcW, DispatchMessageW, MB_ICONEXCLAMATION, MB_SYSTEMMODAL, MSG, MessageBoxW,
    PM_REMOVE, PeekMessageW, PostQuitMessage, TranslateMessage, WM_DESTROY, WM_KEYDOWN, WM_KEYUP,
    WM_MOUSEMOVE, WM_QUIT, WM_RBUTTONDOWN, WM_RBUTTONUP, WM_SIZE, SW_HIDE, ShowWindow,
};
use windows::core::{HSTRING, Result, s, w};

const WIDTH: u32 = 800;
const HEIGHT: u32 = 600;

// --- cbuffer mirrors (16-byte packing; Mat4 is column-major memory that the
// row-major compile flag lets the row-vector shaders read directly) ----------

#[repr(C)]
struct WorldTransforms {
    world: Mat4,
    world_view_proj: Mat4,
}

#[repr(C)]
struct PointLightInfo {
    light_position: Vec4,
    ia: Vec4,
    id: Vec4,
    is_: Vec4,
}

#[repr(C)]
struct SceneInfo {
    view_position: Vec4,
}

#[repr(C)]
struct PbrMaterial {
    object_albedo: Vec4,
    object_material: Vec4,
}

#[repr(C)]
struct SkyboxData {
    view: Mat4,
    proj: Mat4,
    view_position: Vec4,
}

// --- window messages → input state ------------------------------------------

#[derive(Default)]
struct MessageHandler {
    input: CameraInput,
    save_screenshot: bool,
    projection_key: Option<u8>,
    pending_resize: Option<(u32, u32)>,
    last_mouse: Option<(i32, i32)>,
}

impl WindowProc for MessageHandler {
    fn window_proc(&mut self, hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
        match msg {
            WM_DESTROY => {
                // SAFETY: Trivially safe on the window's owning thread.
                unsafe { PostQuitMessage(0) };
                return LRESULT(0);
            }

            WM_KEYDOWN => {
                self.set_camera_key(wparam.0, true);
            }

            WM_KEYUP => {
                if wparam.0 == VK_ESCAPE.0 as usize {
                    // SAFETY: As above.
                    unsafe { PostQuitMessage(0) };
                    return LRESULT(0);
                } else if wparam.0 == VK_SPACE.0 as usize {
                    self.save_screenshot = true;
                } else if (b'1'..=b'3').contains(&(wparam.0 as u8)) {
                    self.projection_key = Some(wparam.0 as u8);
                } else {
                    self.set_camera_key(wparam.0, false);
                }
            }

            // FirstPersonCamera: rotate only while the right button drags.
            WM_MOUSEMOVE => {
                let x = (lparam.0 & 0xffff) as i16 as i32;
                let y = ((lparam.0 >> 16) & 0xffff) as i16 as i32;
                let rbutton_down = wparam.0 & 0x02 != 0; // MK_RBUTTON
                if rbutton_down {
                    if let Some((lx, ly)) = self.last_mouse {
                        self.input.mouse_dx += (x - lx) as f32;
                        self.input.mouse_dy += (y - ly) as f32;
                    }
                }
                self.last_mouse = Some((x, y));
            }

            WM_RBUTTONDOWN | WM_RBUTTONUP => {
                self.last_mouse = None;
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

impl MessageHandler {
    fn set_camera_key(&mut self, key: usize, down: bool) {
        match key as u8 {
            b'W' => self.input.forward = down,
            b'S' => self.input.back = down,
            b'A' => self.input.left = down,
            b'D' => self.input.right = down,
            b'Q' => self.input.up = down,
            b'E' => self.input.down = down,
            _ if key == VK_CONTROL.0 as usize => self.input.speed_up = down,
            _ => {}
        }
    }
}

// --- scene -------------------------------------------------------------------

enum MaterialKind {
    VertexColor,
    Textured(ID3D11ShaderResourceView),
}

struct SceneObject {
    mesh: ImmediateMesh,
    position: Vec3,
    spin_rate: f32, // radians/second about +Y (a RotationController)
    material: MaterialKind,
    /// The PBRMaterialParameters cbuffer: (object_albedo, object_material).
    material_params: PbrMaterial,
}

impl SceneObject {
    fn world_matrix(&self, time: f32) -> Mat4 {
        Mat4::from_translation(self.position) * Mat4::from_rotation_y(self.spin_rate * time)
    }
}

struct Pipeline {
    layout_vertex_color: ID3D11InputLayout,
    layout_textured: ID3D11InputLayout,
    layout_skybox: ID3D11InputLayout,
    vs_vertex_color: ID3D11VertexShader,
    ps_vertex_color: ID3D11PixelShader,
    vs_textured: ID3D11VertexShader,
    ps_textured: ID3D11PixelShader,
    vs_skybox: ID3D11VertexShader,
    ps_skybox: ID3D11PixelShader,
    sampler: ID3D11SamplerState,
    alpha_blend: ID3D11BlendState,
    skybox_depth: ID3D11DepthStencilState,
    cb_world: ID3D11Buffer,
    cb_light: ID3D11Buffer,
    cb_scene: ID3D11Buffer,
    cb_material: ID3D11Buffer,
    cb_skybox: ID3D11Buffer,
    skybox_vb: ID3D11Buffer,
    skybox_ib: ID3D11Buffer,
    _skybox_texture: windows::Win32::Graphics::Direct3D11::ID3D11Texture2D,
    skybox_srv: ID3D11ShaderResourceView,
}

fn create_pipeline(renderer: &Renderer) -> Result<Pipeline> {
    let device = &renderer.device;

    // The material-template shader pairs, used unchanged (see
    // MaterialTemplate.cpp / MaterialGeneratorDX11.cpp for the C++ loads).
    let vs_vc = compile_shader("vertex-color.vertex-normal.point-light.perspective.vs.hlsl", "VSMAIN", "vs_4_0")?;
    let ps_vc = compile_shader("vertex-color.vertex-normal.point-light.perspective.ps.hlsl", "PSMAIN", "ps_4_0")?;
    let vs_tex = compile_shader("textured.vertex-normal.point-light.perspective.vs.hlsl", "VSMAIN", "vs_4_0")?;
    let ps_tex = compile_shader("textured.vertex-normal.point-light.perspective.ps.hlsl", "PSMAIN", "ps_4_0")?;
    let vs_sky = compile_shader("Skybox.hlsl", "VSMAIN", "vs_4_0")?;
    let ps_sky = compile_shader("Skybox.hlsl", "PSMAIN", "ps_4_0")?;

    // BasicVertexDX11's element list (appended offsets over the 48-byte
    // vertex); the skybox layout is just POSITION over a 12-byte vertex.
    let basic_elements = [
        element(s!("POSITION"), DXGI_FORMAT_R32G32B32_FLOAT, 0),
        element(s!("NORMAL"), DXGI_FORMAT_R32G32B32_FLOAT, 12),
        element(s!("COLOR"), DXGI_FORMAT_R32G32B32A32_FLOAT, 24),
        element(s!("TEXCOORD"), DXGI_FORMAT_R32G32_FLOAT, 40),
    ];
    let skybox_elements = [
        element(s!("POSITION"), DXGI_FORMAT_R32G32B32_FLOAT, 0),
        element(s!("TEXCOORD"), DXGI_FORMAT_R32G32_FLOAT, 12),
    ];

    // SAFETY: Creation calls with valid descriptors, live bytecode slices,
    // initial data referencing stack arrays, and valid out-params.
    unsafe {
        let mut vs_vertex_color: Option<ID3D11VertexShader> = None;
        device.CreateVertexShader(&vs_vc, None, Some(&mut vs_vertex_color))?;
        let mut ps_vertex_color: Option<ID3D11PixelShader> = None;
        device.CreatePixelShader(&ps_vc, None, Some(&mut ps_vertex_color))?;
        let mut vs_textured: Option<ID3D11VertexShader> = None;
        device.CreateVertexShader(&vs_tex, None, Some(&mut vs_textured))?;
        let mut ps_textured: Option<ID3D11PixelShader> = None;
        device.CreatePixelShader(&ps_tex, None, Some(&mut ps_textured))?;
        let mut vs_skybox: Option<ID3D11VertexShader> = None;
        device.CreateVertexShader(&vs_sky, None, Some(&mut vs_skybox))?;
        let mut ps_skybox: Option<ID3D11PixelShader> = None;
        device.CreatePixelShader(&ps_sky, None, Some(&mut ps_skybox))?;

        let mut layout_vertex_color: Option<ID3D11InputLayout> = None;
        device.CreateInputLayout(&basic_elements, &vs_vc, Some(&mut layout_vertex_color))?;
        let mut layout_textured: Option<ID3D11InputLayout> = None;
        device.CreateInputLayout(&basic_elements, &vs_tex, Some(&mut layout_textured))?;
        let mut layout_skybox: Option<ID3D11InputLayout> = None;
        device.CreateInputLayout(&skybox_elements, &vs_sky, Some(&mut layout_skybox))?;

        // Linear/wrap sampler for "LinearSampler" (the engine's
        // SamplerStateConfigDX11 defaults).
        let sampler_desc = D3D11_SAMPLER_DESC {
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
        let mut sampler: Option<ID3D11SamplerState> = None;
        device.CreateSamplerState(&sampler_desc, Some(&mut sampler))?;

        // MaterialTemplate's alpha blend state: SRC_ALPHA / INV_SRC_ALPHA,
        // alpha channel ONE/ONE.
        let blend_desc = D3D11_BLEND_DESC {
            AlphaToCoverageEnable: false.into(),
            IndependentBlendEnable: false.into(),
            RenderTarget: [D3D11_RENDER_TARGET_BLEND_DESC {
                BlendEnable: true.into(),
                SrcBlend: D3D11_BLEND_SRC_ALPHA,
                DestBlend: D3D11_BLEND_INV_SRC_ALPHA,
                BlendOp: D3D11_BLEND_OP_ADD,
                SrcBlendAlpha: D3D11_BLEND_ONE,
                DestBlendAlpha: D3D11_BLEND_ONE,
                BlendOpAlpha: D3D11_BLEND_OP_ADD,
                RenderTargetWriteMask: D3D11_COLOR_WRITE_ENABLE_ALL.0 as u8,
            }; 8],
        };
        let mut alpha_blend: Option<ID3D11BlendState> = None;
        device.CreateBlendState(&blend_desc, Some(&mut alpha_blend))?;

        // SkyboxActor's depth state: default except LESS_EQUAL, so the
        // far-plane skybox passes where depth is still 1.0.
        let depth_desc = D3D11_DEPTH_STENCIL_DESC {
            DepthEnable: true.into(),
            DepthWriteMask: windows::Win32::Graphics::Direct3D11::D3D11_DEPTH_WRITE_MASK_ALL,
            DepthFunc: D3D11_COMPARISON_LESS_EQUAL,
            ..Default::default()
        };
        let mut skybox_depth: Option<ID3D11DepthStencilState> = None;
        device.CreateDepthStencilState(&depth_desc, Some(&mut skybox_depth))?;

        // Skybox geometry (scale 10, per the App's SkyboxActor).
        let scale = 10.0f32;
        let verts: Vec<skybox::SkyboxVertex> = skybox::CORNERS
            .iter()
            .map(|(p, t)| skybox::SkyboxVertex {
                position: [p[0] * scale, p[1] * scale, p[2] * scale],
                texcoords: *t,
            })
            .collect();
        let skybox_vb = immutable_buffer(
            device,
            verts.as_ptr() as *const _,
            (verts.len() * size_of::<skybox::SkyboxVertex>()) as u32,
            windows::Win32::Graphics::Direct3D11::D3D11_BIND_VERTEX_BUFFER.0 as u32,
        )?;
        let skybox_ib = immutable_buffer(device, skybox::INDICES.as_ptr() as *const _, (skybox::INDICES.len() * 4) as u32, windows::Win32::Graphics::Direct3D11::D3D11_BIND_INDEX_BUFFER.0 as u32)?;

        let (skybox_texture, skybox_srv) = skybox::load_cubemap_dds(device, "TropicalSunnyDay.dds")?;

        Ok(Pipeline {
            layout_vertex_color: layout_vertex_color.unwrap(),
            layout_textured: layout_textured.unwrap(),
            layout_skybox: layout_skybox.unwrap(),
            vs_vertex_color: vs_vertex_color.unwrap(),
            ps_vertex_color: ps_vertex_color.unwrap(),
            vs_textured: vs_textured.unwrap(),
            ps_textured: ps_textured.unwrap(),
            vs_skybox: vs_skybox.unwrap(),
            ps_skybox: ps_skybox.unwrap(),
            sampler: sampler.unwrap(),
            alpha_blend: alpha_blend.unwrap(),
            skybox_depth: skybox_depth.unwrap(),
            cb_world: dynamic_cbuffer(device, size_of::<WorldTransforms>() as u32)?,
            cb_light: dynamic_cbuffer(device, size_of::<PointLightInfo>() as u32)?,
            cb_scene: dynamic_cbuffer(device, size_of::<SceneInfo>() as u32)?,
            cb_material: dynamic_cbuffer(device, size_of::<PbrMaterial>() as u32)?,
            cb_skybox: dynamic_cbuffer(device, size_of::<SkyboxData>() as u32)?,
            skybox_vb,
            skybox_ib,
            _skybox_texture: skybox_texture,
            skybox_srv,
        })
    }
}

fn element(
    name: windows::core::PCSTR,
    format: windows::Win32::Graphics::Dxgi::Common::DXGI_FORMAT,
    offset: u32,
) -> D3D11_INPUT_ELEMENT_DESC {
    D3D11_INPUT_ELEMENT_DESC {
        SemanticName: name,
        SemanticIndex: 0,
        Format: format,
        InputSlot: 0,
        AlignedByteOffset: offset,
        InputSlotClass: D3D11_INPUT_PER_VERTEX_DATA,
        InstanceDataStepRate: 0,
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

fn immutable_buffer(
    device: &windows::Win32::Graphics::Direct3D11::ID3D11Device,
    data: *const core::ffi::c_void,
    byte_width: u32,
    bind_flags: u32,
) -> Result<ID3D11Buffer> {
    let desc = D3D11_BUFFER_DESC {
        ByteWidth: byte_width,
        Usage: windows::Win32::Graphics::Direct3D11::D3D11_USAGE_IMMUTABLE,
        BindFlags: bind_flags,
        CPUAccessFlags: 0,
        MiscFlags: 0,
        StructureByteStride: 0,
    };
    let init = windows::Win32::Graphics::Direct3D11::D3D11_SUBRESOURCE_DATA {
        pSysMem: data,
        SysMemPitch: 0,
        SysMemSlicePitch: 0,
    };
    let mut buffer: Option<ID3D11Buffer> = None;
    // SAFETY: The caller's data pointer covers byte_width bytes for the
    // duration of the call.
    unsafe {
        device.CreateBuffer(&desc, Some(&init), Some(&mut buffer))?;
    }
    Ok(buffer.unwrap())
}

/// Write one struct into a WRITE_DISCARD-mapped dynamic cbuffer.
fn write_cbuffer<T>(context: &windows::Win32::Graphics::Direct3D11::ID3D11DeviceContext, buffer: &ID3D11Buffer, value: &T) {
    // SAFETY: `buffer` was created with `size_of::<T>()` bytes by
    // `dynamic_cbuffer`, and the mapping grants write access to that many.
    unsafe {
        let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
        if context.Map(buffer, 0, D3D11_MAP_WRITE_DISCARD, 0, Some(&mut mapped)).is_ok() {
            std::ptr::copy_nonoverlapping(value as *const T, mapped.pData as *mut T, 1);
            context.Unmap(buffer, 0);
        }
    }
}

// --- scene construction (App::Initialize) ------------------------------------

fn build_scene(renderer: &Renderer) -> Result<(SceneObject, SceneObject, SceneObject, SceneObject)> {
    // Indexed paraboloid grid actor: textured, rebuilt per frame in the loop.
    // (The SRV holds its own reference to the texture, so the texture wrapper
    // can drop freely.)
    let (_tex, tex_srv) = renderer.load_texture_png("EyeOfHorus_128.png")?;
    let grid = SceneObject {
        mesh: ImmediateMesh::new(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST),
        position: Vec3::new(3.0, 0.0, 0.0),
        spin_rate: -0.1,
        material: MaterialKind::Textured(tex_srv),
        material_params: PbrMaterial {
            object_albedo: Vec4::ONE,
            object_material: Vec4::new(0.3, 0.0, 0.0, 0.0), // GeometryActor default
        },
    };

    // Shape collection (transparent material → alpha pass).
    let mut shapes_mesh = ImmediateMesh::new(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    shapes_mesh.color = Vec4::new(1.0, 0.0, 0.0, 0.5);
    shapes_mesh.draw_sphere(Vec3::new(2.5, 2.0, 0.0), 1.5, 16, 24);
    shapes_mesh.color = Vec4::new(0.0, 1.0, 0.0, 1.0);
    shapes_mesh.draw_cylinder(Vec3::new(-1.5, -1.0, 0.0), Vec3::new(-1.5, 3.0, 0.0), 1.5, 0.0, 8, 24);
    shapes_mesh.color = Vec4::new(1.0, 1.0, 0.0, 1.0);
    shapes_mesh.draw_disc(Vec3::new(0.0, -3.0, 0.0), Vec3::new(1.0, 1.0, 1.0), 2.0, 12);
    shapes_mesh.color = Vec4::new(0.0, 0.0, 1.0, 1.0);
    shapes_mesh.draw_box(Vec3::new(0.0, 3.0, 0.0), Vec3::ONE);
    shapes_mesh.color = Vec4::ONE;
    shapes_mesh.draw_arrow(Vec3::ZERO, Vec3::new(5.0, 0.0, 0.0), 0.5, 1.0, 1.0);
    let shapes = SceneObject {
        mesh: shapes_mesh,
        position: Vec3::new(0.0, 2.5, 0.0),
        spin_rate: 0.4,
        material: MaterialKind::VertexColor,
        material_params: PbrMaterial {
            object_albedo: Vec4::ONE, // SetDiffuse(1,1,1,1)
            object_material: Vec4::new(0.3, 0.0, 0.0, 0.0),
        },
    };

    // STL mesh actor: triangle soup with per-face normals, color (0,1,0,0).
    let mut stl_mesh = ImmediateMesh::new(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    stl_mesh.color = Vec4::new(0.0, 1.0, 0.0, 0.0);
    if let Some(path) = glyph::paths::find_data_file("Models", "MeshedReconstruction.stl") {
        let mut i = 0u32;
        for face in stl::load(&path) {
            stl_mesh.add_vertex_normal(face.v0, face.normal);
            stl_mesh.add_vertex_normal(face.v1, face.normal);
            stl_mesh.add_vertex_normal(face.v2, face.normal);
            stl_mesh.add_index(i);
            stl_mesh.add_index(i + 1);
            stl_mesh.add_index(i + 2);
            i += 3;
        }
    }
    let stl_object = SceneObject {
        mesh: stl_mesh,
        position: Vec3::new(5.0, 5.0, 0.0),
        spin_rate: -1.0,
        material: MaterialKind::VertexColor,
        material_params: PbrMaterial {
            object_albedo: Vec4::ZERO,
            // GenerateImmediateGeometrySolidMaterial: roughness 1.0.
            object_material: Vec4::new(1.0, 0.0, 0.0, 0.0),
        },
    };

    // Bézier curve actor: green line list at the origin, no controller.
    let mut curve_mesh = ImmediateMesh::new(D3D11_PRIMITIVE_TOPOLOGY_LINELIST);
    curve_mesh.color = Vec4::new(0.0, 1.0, 0.0, 1.0);
    curve_mesh.draw_bezier_curve(
        [
            Vec3::new(0.0, 0.0, 0.0),
            Vec3::new(5.0, 5.0, 0.0),
            Vec3::new(5.0, 10.0, 0.0),
            Vec3::new(0.0, 10.0, 0.0),
        ],
        0.0,
        1.0,
        200,
    );
    let curve = SceneObject {
        mesh: curve_mesh,
        position: Vec3::ZERO,
        spin_rate: 0.0,
        material: MaterialKind::VertexColor,
        material_params: PbrMaterial {
            object_albedo: Vec4::ONE,
            object_material: Vec4::new(0.3, 0.0, 0.0, 0.0),
        },
    };

    Ok((grid, shapes, stl_object, curve))
}

/// Rebuild the animated paraboloid grid, mirroring the immediate-rendering
/// block in `App::Update` verbatim.
fn rebuild_grid(mesh: &mut ImmediateMesh, runtime: f32) {
    const GRIDSIZE: i32 = 20;
    const FGRIDSIZE: f32 = GRIDSIZE as f32;
    const FSIZESCALE: f32 = 5.0 / FGRIDSIZE;

    let scaling = 0.25 * (runtime * 0.75).sin();

    mesh.reset();
    mesh.color = Vec4::ONE;

    for z in 0..GRIDSIZE {
        for x in 0..GRIDSIZE {
            let fx = x as f32;
            let fz = z as f32;

            let vx = fx - (GRIDSIZE / 2) as f32;
            let vz = fz - (GRIDSIZE / 2) as f32;
            let vy = (5.0 - 0.2 * (vx * vx + vz * vz)) * scaling;

            let uv = Vec2::new(fx / (FGRIDSIZE - 1.0), 1.0 - fz / (FGRIDSIZE - 1.0));
            mesh.add_vertex_tex(Vec3::new(vx, vy, vz) * FSIZESCALE, uv);
        }
    }

    let g = GRIDSIZE as u32;
    for z in 0..g - 1 {
        for x in 0..g - 1 {
            mesh.add_index(z * g + x);
            mesh.add_index(z * g + x + g);
            mesh.add_index(z * g + x + 1);

            mesh.add_index(z * g + x + 1);
            mesh.add_index(z * g + x + g);
            mesh.add_index(z * g + x + g + 1);
        }
    }
}

// --- main ---------------------------------------------------------------------

fn main() {
    let mut handler = MessageHandler::default();

    let mut window = RenderWindow::new();
    window.set_size(WIDTH as i32, HEIGHT as i32);
    window.set_caption("ImmediateRenderer");
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

    let (pipeline, mut grid, mut shapes, mut stl_object, mut curve) =
        match create_pipeline(&renderer).and_then(|p| {
            let (g, s, m, c) = build_scene(&renderer)?;
            Ok((p, g, s, m, c))
        }) {
            Ok(v) => v,
            Err(e) => {
                let text = HSTRING::from(e.message());
                // SAFETY: Valid string arguments.
                unsafe {
                    MessageBoxW(None, &text, w!("ImmediateRenderer setup failed"), MB_ICONEXCLAMATION | MB_SYSTEMMODAL);
                }
                return;
            }
        };

    // App::Initialize camera pose; RenderApplication projection params.
    let mut camera = FirstPersonCamera::new(Vec3::new(-3.0, 12.0, -15.0), 0.5, 0.3);
    let mut proj = glam::camera::lh::proj::directx::perspective(
        std::f32::consts::FRAC_PI_4,
        WIDTH as f32 / HEIGHT as f32,
        0.1,
        1000.0,
    );

    let start = Instant::now();
    let mut last_frame = start;
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
        let runtime = now.duration_since(start).as_secs_f32();

        // RenderApplication::HandleWindowResize (also resets the projection
        // via SetAspectRatio, dropping any 1/2/3 offset mode — as in C++).
        if let Some((w, h)) = handler.pending_resize.take() {
            renderer.resize(w, h);
            proj = glam::camera::lh::proj::directx::perspective(
                std::f32::consts::FRAC_PI_4,
                renderer.width as f32 / renderer.height as f32,
                0.1,
                1000.0,
            );
        }

        // App::HandleEvent keys 1/2/3: off-center projections.
        if let Some(key) = handler.projection_key.take() {
            let f = glam::camera::lh::proj::directx::frustum;
            proj = match key {
                b'1' => f(-0.4, 0.4, -0.3, 0.3, 0.5, 100.0),
                b'2' => f(0.0, 0.8, -0.3, 0.3, 0.5, 100.0),
                _ => f(-0.8, 0.0, -0.3, 0.3, 0.5, 100.0),
            };
        }

        camera.update(&mut handler.input, dt);
        let view = camera.view_matrix();

        // Controllers: the point light circles at radius 50, height 50.
        let light_angle = -runtime;
        let light_position =
            Mat4::from_rotation_y(light_angle).transform_point3(Vec3::new(50.0, 0.0, 0.0))
                + Vec3::new(0.0, 50.0, 0.0);

        rebuild_grid(&mut grid.mesh, runtime);

        for object in [&mut grid, &mut shapes, &mut stl_object, &mut curve] {
            object.mesh.commit(&renderer.device, &renderer.context);
        }

        let context = renderer.context.clone();

        // SAFETY: Every bound object lives in `pipeline`/`renderer`/the scene
        // objects for the whole loop; slice/pointer parameters reference
        // locals that outlive their calls; cbuffer writes match the buffer
        // sizes they were created with.
        unsafe {
            // ViewPerspective: clear to the App's color, depth to 1.
            context.ClearRenderTargetView(&renderer.rtv, &[0.2, 0.2, 0.4, 0.0]);
            context.ClearDepthStencilView(&renderer.dsv, D3D11_CLEAR_DEPTH.0 as u32, 1.0, 0);

            // Frame-constant cbuffers: PointLightInfo (Light's defaults) and
            // SceneInfo (camera world position).
            write_cbuffer(&context, &pipeline.cb_light, &PointLightInfo {
                light_position: light_position.extend(1.0),
                ia: Vec4::new(0.25, 0.25, 0.25, 0.25),
                id: Vec4::new(0.5, 0.5, 0.5, 1.0),
                is_: Vec4::ONE,
            });
            write_cbuffer(&context, &pipeline.cb_scene, &SceneInfo {
                view_position: camera.position.extend(1.0),
            });

            context.PSSetConstantBuffers(0, Some(&[
                Some(pipeline.cb_light.clone()),
                Some(pipeline.cb_scene.clone()),
                Some(pipeline.cb_material.clone()),
            ]));
            context.VSSetConstantBuffers(0, Some(&[Some(pipeline.cb_world.clone())]));
            context.PSSetSamplers(0, Some(&[Some(pipeline.sampler.clone())]));

            // GEOMETRY pass, in scene-graph order: grid, STL mesh, curve —
            // then the skybox (added last, LESS_EQUAL depth).
            for object in [&grid, &stl_object, &curve] {
                draw_object(&context, &pipeline, object, &view, &proj, runtime);
            }

            // Skybox (SkyboxActor): its own shader pair and cbuffer.
            write_cbuffer(&context, &pipeline.cb_skybox, &SkyboxData {
                view,
                proj,
                view_position: camera.position.extend(1.0),
            });
            context.IASetInputLayout(&pipeline.layout_skybox);
            let vbs = [Some(pipeline.skybox_vb.clone())];
            let strides = [size_of::<skybox::SkyboxVertex>() as u32];
            let offsets = [0u32];
            context.IASetVertexBuffers(0, 1, Some(vbs.as_ptr()), Some(strides.as_ptr()), Some(offsets.as_ptr()));
            context.IASetIndexBuffer(&pipeline.skybox_ib, DXGI_FORMAT_R32_UINT, 0);
            context.IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
            context.VSSetShader(&pipeline.vs_skybox, None);
            context.PSSetShader(&pipeline.ps_skybox, None);
            context.VSSetConstantBuffers(0, Some(&[Some(pipeline.cb_skybox.clone())]));
            context.PSSetShaderResources(0, Some(&[Some(pipeline.skybox_srv.clone())]));
            context.OMSetDepthStencilState(&pipeline.skybox_depth, 0);
            context.DrawIndexed(skybox::INDICES.len() as u32, 0, 0);
            context.OMSetDepthStencilState(None, 0);
            context.VSSetConstantBuffers(0, Some(&[Some(pipeline.cb_world.clone())]));

            // ALPHA pass: the transparent shape collection.
            context.OMSetBlendState(&pipeline.alpha_blend, None, 0xffffffff);
            draw_object(&context, &pipeline, &shapes, &view, &proj, runtime);
            context.OMSetBlendState(None, None, 0xffffffff);
        }

        renderer.present();

        if handler.save_screenshot {
            handler.save_screenshot = false;
            screenshot_number += 1;
            renderer.save_backbuffer_png(&format!("ImmediateRenderer{screenshot_number}.png"));
        }
    }
}

/// Draw one scene object with the material-template pipeline.
///
/// # Safety
/// Caller guarantees the context/pipeline/object outlive the call (all live
/// in `main`'s scope).
unsafe fn draw_object(
    context: &windows::Win32::Graphics::Direct3D11::ID3D11DeviceContext,
    pipeline: &Pipeline,
    object: &SceneObject,
    view: &Mat4,
    proj: &Mat4,
    time: f32,
) {
    let Some((vb, ib)) = object.mesh.buffers() else {
        return;
    };

    let world = object.world_matrix(time);
    write_cbuffer(context, &pipeline.cb_world, &WorldTransforms {
        world,
        world_view_proj: *proj * *view * world,
    });
    write_cbuffer(context, &pipeline.cb_material, &object.material_params);

    // SAFETY: See doc comment; array parameters reference locals that
    // outlive the calls.
    unsafe {
        match &object.material {
            MaterialKind::VertexColor => {
                context.IASetInputLayout(&pipeline.layout_vertex_color);
                context.VSSetShader(&pipeline.vs_vertex_color, None);
                context.PSSetShader(&pipeline.ps_vertex_color, None);
            }
            MaterialKind::Textured(srv) => {
                context.IASetInputLayout(&pipeline.layout_textured);
                context.VSSetShader(&pipeline.vs_textured, None);
                context.PSSetShader(&pipeline.ps_textured, None);
                context.PSSetShaderResources(0, Some(&[Some(srv.clone())]));
            }
        }

        let vbs = [Some(vb.clone())];
        let strides = [size_of::<BasicVertex>() as u32];
        let offsets = [0u32];
        context.IASetVertexBuffers(0, 1, Some(vbs.as_ptr()), Some(strides.as_ptr()), Some(offsets.as_ptr()));
        context.IASetIndexBuffer(ib, DXGI_FORMAT_R32_UINT, 0);
        context.IASetPrimitiveTopology(object.mesh.topology);
        context.DrawIndexed(object.mesh.indices.len() as u32, 0, 0);
    }
}
