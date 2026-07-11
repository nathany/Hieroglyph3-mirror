//! Rust port of the TessellationParams sample
//! (Applications/TessellationParams) — the chapter-4 interactive tessellation
//! parameter explorer. A single quad or triangle patch is drawn wireframe on
//! white while you vary every tessellator input live:
//!
//! - **G** toggles quad/triangle domain.
//! - **P** cycles partitioning: pow2 → integer → fractional_odd →
//!   fractional_even (one hull shader compiled per mode from the same source
//!   via preprocessor defines, exactly as the C++ does).
//! - **E** / **I** select edge/inside editing (pressing again cycles which
//!   edge/inside factor is selected — 3/1 for tri, 4/2 for quad).
//! - **Numpad +/-** adjust the selected weight by 0.1, clamped to [1, 64].
//! - **Esc** quits, **Space** saves `TessellationParams<n>.png`.
//!
//! The C++ shows the current state as on-screen text; text rendering is out
//! of scope for these ports, so the state lives in the **window title bar**
//! instead — same information, no sprite fonts.
//!
//! `TessellationParameters.hlsl` is used unchanged: one `main` cbuffer
//! (world/view-proj/weights, register b0 in every stage that uses it), quad
//! path runs the weights through `Process2DQuadTessFactorsAvg`.

#![windows_subsystem = "windows"]

use glam::{Mat4, Vec3, Vec4};
use glyph::renderer::Renderer;
use glyph::shader::{compile_shader, compile_shader_defines};
use glyph::window::{AppMessageHandler, RenderWindow, WindowProc};
use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::Graphics::Direct3D::{
    D3D_FEATURE_LEVEL_11_0, D3D11_PRIMITIVE_TOPOLOGY_3_CONTROL_POINT_PATCHLIST,
    D3D11_PRIMITIVE_TOPOLOGY_4_CONTROL_POINT_PATCHLIST,
};
use windows::Win32::Graphics::Direct3D11::{
    D3D11_BIND_CONSTANT_BUFFER, D3D11_BIND_VERTEX_BUFFER, D3D11_BUFFER_DESC, D3D11_CLEAR_DEPTH,
    D3D11_CPU_ACCESS_WRITE, D3D11_CULL_BACK, D3D11_FILL_WIREFRAME, D3D11_INPUT_ELEMENT_DESC,
    D3D11_INPUT_PER_VERTEX_DATA, D3D11_MAP_WRITE_DISCARD, D3D11_MAPPED_SUBRESOURCE,
    D3D11_RASTERIZER_DESC, D3D11_SUBRESOURCE_DATA, D3D11_USAGE_DYNAMIC, D3D11_USAGE_IMMUTABLE,
    ID3D11Buffer, ID3D11DomainShader, ID3D11GeometryShader, ID3D11HullShader, ID3D11InputLayout,
    ID3D11PixelShader, ID3D11RasterizerState, ID3D11VertexShader,
};
use windows::Win32::Graphics::Dxgi::Common::{
    DXGI_FORMAT_R32G32B32_FLOAT, DXGI_FORMAT_R32G32B32A32_FLOAT,
};
use windows::Win32::UI::Input::KeyboardAndMouse::{VK_ADD, VK_SUBTRACT};
use windows::Win32::UI::WindowsAndMessaging::{
    DefWindowProcW, DispatchMessageW, MB_ICONEXCLAMATION, MB_SYSTEMMODAL, MSG, MessageBoxW,
    PM_REMOVE, PeekMessageW, SW_HIDE, SetWindowTextW, ShowWindow, TranslateMessage, WM_KEYUP,
    WM_QUIT,
};
use windows::core::{HSTRING, Result, s, w};

const WIDTH: u32 = 640;
const HEIGHT: u32 = 480;

/// The shader's single `main` cbuffer (float2 pads out to a 16-byte
/// register).
#[repr(C)]
struct MainCBuffer {
    world: Mat4,
    view_proj: Mat4,
    edge_weights: Vec4,
    inside_weights: [f32; 2],
    _pad: [f32; 2],
}

#[derive(Clone, Copy, PartialEq)]
enum Domain {
    Quad,
    Tri,
}

#[derive(Clone, Copy, PartialEq)]
enum Editing {
    Edge,
    Inside,
}

const PARTITION_NAMES: [&str; 4] = ["pow2", "integer", "fractional_odd", "fractional_even"];
const PARTITION_DEFINES: [&str; 4] = [
    "POW2_PARTITIONING",
    "INTEGER_PARTITIONING",
    "FRAC_ODD_PARTITIONING",
    "FRAC_EVEN_PARTITIONING",
];

/// App state driven by the keyboard, mirroring the C++ members.
struct State {
    domain: Domain,
    partitioning: usize,
    editing: Editing,
    edge_index: usize,
    inside_index: usize,
    edge_weights: [f32; 4],
    inside_weights: [f32; 2],
}

impl State {
    /// The C++ SetEdgeWeight/SetInsideWeight guards: silently rejects values
    /// outside [1, 64] and indices beyond the current domain's counts.
    fn adjust(&mut self, delta: f32) {
        match self.editing {
            Editing::Edge => {
                let max = if self.domain == Domain::Tri { 2 } else { 3 };
                if self.edge_index <= max {
                    let weight = self.edge_weights[self.edge_index] + delta;
                    if (1.0..=64.0).contains(&weight) {
                        self.edge_weights[self.edge_index] = weight;
                    }
                }
            }
            Editing::Inside => {
                let max = if self.domain == Domain::Tri { 0 } else { 1 };
                if self.inside_index <= max {
                    let weight = self.inside_weights[self.inside_index] + delta;
                    if (1.0..=64.0).contains(&weight) {
                        self.inside_weights[self.inside_index] = weight;
                    }
                }
            }
        }
    }

    /// The on-screen text of the C++, condensed for the title bar.
    fn title(&self) -> String {
        let editing = match self.editing {
            Editing::Edge => format!("editing edge {}", self.edge_index),
            Editing::Inside => format!("editing inside {}", self.inside_index),
        };
        match self.domain {
            Domain::Tri => format!(
                "TessellationParams — tri | {} | edges [{:.1}, {:.1}, {:.1}] inside [{:.1}] | {} (G/P/E/I/+/-)",
                PARTITION_NAMES[self.partitioning],
                self.edge_weights[0], self.edge_weights[1], self.edge_weights[2],
                self.inside_weights[0], editing
            ),
            Domain::Quad => format!(
                "TessellationParams — quad | {} | edges [{:.1}, {:.1}, {:.1}, {:.1}] inside [{:.1}, {:.1}] | {} (G/P/E/I/+/-)",
                PARTITION_NAMES[self.partitioning],
                self.edge_weights[0], self.edge_weights[1], self.edge_weights[2], self.edge_weights[3],
                self.inside_weights[0], self.inside_weights[1], editing
            ),
        }
    }
}

/// Extends the shared Esc/Space handling with this demo's keys.
#[derive(Default)]
struct Handler {
    base: AppMessageHandler,
    toggle_geometry: bool,
    next_partitioning: bool,
    press_e: bool,
    press_i: bool,
    adjust: f32,
}

impl WindowProc for Handler {
    fn window_proc(&mut self, hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
        if msg == WM_KEYUP {
            match wparam.0 as u8 {
                b'G' => self.toggle_geometry = true,
                b'P' => self.next_partitioning = true,
                b'E' => self.press_e = true,
                b'I' => self.press_i = true,
                _ if wparam.0 == VK_ADD.0 as usize => self.adjust += 0.1,
                _ if wparam.0 == VK_SUBTRACT.0 as usize => self.adjust -= 0.1,
                _ => return self.base.window_proc(hwnd, msg, wparam, lparam),
            }
            // SAFETY: Forwarding with Win32's own arguments is always valid.
            return unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) };
        }
        self.base.window_proc(hwnd, msg, wparam, lparam)
    }
}

/// A patch's control points: position + colour (the C++'s
/// CONTROL_POINT_POSITION / COLOUR vertex elements, colours all black).
#[repr(C)]
struct ControlPoint {
    position: [f32; 3],
    colour: [f32; 4],
}

struct Patch {
    vertex_buffer: ID3D11Buffer,
    vertex_count: u32,
    topology: windows::Win32::Graphics::Direct3D::D3D_PRIMITIVE_TOPOLOGY,
    hull_shaders: [ID3D11HullShader; 4],
    domain_shader: ID3D11DomainShader,
}

struct Scene {
    quad: Patch,
    tri: Patch,
    vertex_shader: ID3D11VertexShader,
    geometry_shader: ID3D11GeometryShader,
    pixel_shader: ID3D11PixelShader,
    input_layout: ID3D11InputLayout,
    wireframe: ID3D11RasterizerState,
    cb_main: ID3D11Buffer,
    view_proj: Mat4,
}

fn create_patch(
    renderer: &Renderer,
    points: &[ControlPoint],
    hs_entry: &str,
    ds_entry: &str,
    topology: windows::Win32::Graphics::Direct3D::D3D_PRIMITIVE_TOPOLOGY,
) -> Result<Patch> {
    // One hull shader per partitioning mode, selected by a preprocessor
    // define — the [partitioning(...)] attribute can't be set at runtime.
    let hull_bytecodes: Vec<Vec<u8>> = PARTITION_DEFINES
        .iter()
        .map(|define| {
            compile_shader_defines("TessellationParameters.hlsl", hs_entry, "hs_5_0", &[(define, "1")])
        })
        .collect::<Result<_>>()?;
    let ds_bytecode = compile_shader("TessellationParameters.hlsl", ds_entry, "ds_5_0")?;

    // SAFETY: Valid descriptors, live bytecode/data, valid out-params.
    unsafe {
        let mut hull_shaders = Vec::with_capacity(4);
        for bytecode in &hull_bytecodes {
            let mut hs: Option<ID3D11HullShader> = None;
            renderer.device.CreateHullShader(bytecode, None, Some(&mut hs))?;
            hull_shaders.push(hs.unwrap());
        }
        let mut domain_shader: Option<ID3D11DomainShader> = None;
        renderer.device.CreateDomainShader(&ds_bytecode, None, Some(&mut domain_shader))?;

        let vb_desc = D3D11_BUFFER_DESC {
            ByteWidth: std::mem::size_of_val(points) as u32,
            Usage: D3D11_USAGE_IMMUTABLE,
            BindFlags: D3D11_BIND_VERTEX_BUFFER.0 as u32,
            CPUAccessFlags: 0,
            MiscFlags: 0,
            StructureByteStride: 0,
        };
        let vb_data = D3D11_SUBRESOURCE_DATA {
            pSysMem: points.as_ptr() as *const _,
            SysMemPitch: 0,
            SysMemSlicePitch: 0,
        };
        let mut vertex_buffer: Option<ID3D11Buffer> = None;
        renderer.device.CreateBuffer(&vb_desc, Some(&vb_data), Some(&mut vertex_buffer))?;

        Ok(Patch {
            vertex_buffer: vertex_buffer.unwrap(),
            vertex_count: points.len() as u32,
            topology,
            hull_shaders: hull_shaders.try_into().map_err(|_| windows::core::Error::from_hresult(windows::core::HRESULT(-1))).unwrap(),
            domain_shader: domain_shader.unwrap(),
        })
    }
}

fn setup(renderer: &Renderer) -> Result<Scene> {
    let device = &renderer.device;

    let vs_bytecode = compile_shader("TessellationParameters.hlsl", "vsMain", "vs_5_0")?;
    let gs_bytecode = compile_shader("TessellationParameters.hlsl", "gsMain", "gs_5_0")?;
    let ps_bytecode = compile_shader("TessellationParameters.hlsl", "psMain", "ps_5_0")?;

    let black = [0.0f32, 0.0, 0.0, 1.0];
    let quad_points = [
        ControlPoint { position: [-1.0, 0.0, -1.0], colour: black },
        ControlPoint { position: [-1.0, 0.0, 1.0], colour: black },
        ControlPoint { position: [1.0, 0.0, -1.0], colour: black },
        ControlPoint { position: [1.0, 0.0, 1.0], colour: black },
    ];
    let tri_points = [
        ControlPoint { position: [-1.0, 0.0, -1.0], colour: black },
        ControlPoint { position: [-1.0, 0.0, 1.0], colour: black },
        ControlPoint { position: [1.0, 0.0, -1.0], colour: black },
    ];

    let quad = create_patch(
        renderer,
        &quad_points,
        "hsQuadMain",
        "dsQuadMain",
        D3D11_PRIMITIVE_TOPOLOGY_4_CONTROL_POINT_PATCHLIST,
    )?;
    let tri = create_patch(
        renderer,
        &tri_points,
        "hsTriangleMain",
        "dsTriangleMain",
        D3D11_PRIMITIVE_TOPOLOGY_3_CONTROL_POINT_PATCHLIST,
    )?;

    let elements = [
        D3D11_INPUT_ELEMENT_DESC {
            SemanticName: s!("CONTROL_POINT_POSITION"),
            SemanticIndex: 0,
            Format: DXGI_FORMAT_R32G32B32_FLOAT,
            InputSlot: 0,
            AlignedByteOffset: 0,
            InputSlotClass: D3D11_INPUT_PER_VERTEX_DATA,
            InstanceDataStepRate: 0,
        },
        D3D11_INPUT_ELEMENT_DESC {
            SemanticName: s!("COLOUR"),
            SemanticIndex: 0,
            Format: DXGI_FORMAT_R32G32B32A32_FLOAT,
            InputSlot: 0,
            AlignedByteOffset: 12,
            InputSlotClass: D3D11_INPUT_PER_VERTEX_DATA,
            InstanceDataStepRate: 0,
        },
    ];

    // SAFETY: Valid descriptors, live bytecode, valid out-params.
    unsafe {
        let mut vertex_shader: Option<ID3D11VertexShader> = None;
        device.CreateVertexShader(&vs_bytecode, None, Some(&mut vertex_shader))?;
        let mut geometry_shader: Option<ID3D11GeometryShader> = None;
        device.CreateGeometryShader(&gs_bytecode, None, Some(&mut geometry_shader))?;
        let mut pixel_shader: Option<ID3D11PixelShader> = None;
        device.CreatePixelShader(&ps_bytecode, None, Some(&mut pixel_shader))?;
        let mut input_layout: Option<ID3D11InputLayout> = None;
        device.CreateInputLayout(&elements, &vs_bytecode, Some(&mut input_layout))?;

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

        let cb_desc = D3D11_BUFFER_DESC {
            ByteWidth: size_of::<MainCBuffer>() as u32,
            Usage: D3D11_USAGE_DYNAMIC,
            BindFlags: D3D11_BIND_CONSTANT_BUFFER.0 as u32,
            CPUAccessFlags: D3D11_CPU_ACCESS_WRITE.0 as u32,
            MiscFlags: 0,
            StructureByteStride: 0,
        };
        let mut cb_main: Option<ID3D11Buffer> = None;
        device.CreateBuffer(&cb_desc, None, Some(&mut cb_main))?;

        // The camera from App::Initialize.
        let view = glam::camera::lh::view::look_at_mat4(
            Vec3::new(-2.0, 2.0, -2.0),
            Vec3::ZERO,
            Vec3::Y,
        );
        let proj = glam::camera::lh::proj::directx::perspective(
            std::f32::consts::FRAC_PI_4,
            640.0 / 480.0,
            0.1,
            50.0,
        );

        Ok(Scene {
            quad,
            tri,
            vertex_shader: vertex_shader.unwrap(),
            geometry_shader: geometry_shader.unwrap(),
            pixel_shader: pixel_shader.unwrap(),
            input_layout: input_layout.unwrap(),
            wireframe: wireframe.unwrap(),
            cb_main: cb_main.unwrap(),
            view_proj: proj * view,
        })
    }
}

fn main() {
    let mut handler = Handler::default();

    let mut window = RenderWindow::new();
    window.set_position(25, 25);
    window.set_size(WIDTH as i32, HEIGHT as i32);
    window.set_caption("TessellationParams");
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
                MessageBoxW(None, &text, w!("TessellationParams setup failed"), MB_ICONEXCLAMATION | MB_SYSTEMMODAL);
            }
            return;
        }
    };

    let mut state = State {
        domain: Domain::Quad,
        partitioning: 1, // the C++ starts with SetPartitioningMode(Integer)
        editing: Editing::Edge,
        edge_index: 0,
        inside_index: 0,
        edge_weights: [1.0; 4],
        inside_weights: [1.0; 2],
    };
    let mut title_dirty = true;

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

        // Apply key presses to the state (App::HandleEvent).
        if handler.toggle_geometry {
            handler.toggle_geometry = false;
            state.domain = if state.domain == Domain::Quad { Domain::Tri } else { Domain::Quad };
            title_dirty = true;
        }
        if handler.next_partitioning {
            handler.next_partitioning = false;
            // The C++ cycle: pow2 → integer → frac_odd → frac_even → pow2.
            state.partitioning = (state.partitioning + 1) % 4;
            title_dirty = true;
        }
        if handler.press_e {
            handler.press_e = false;
            if state.editing == Editing::Edge {
                let count = if state.domain == Domain::Tri { 3 } else { 4 };
                state.edge_index = (state.edge_index + 1) % count;
            } else {
                state.editing = Editing::Edge;
            }
            title_dirty = true;
        }
        if handler.press_i {
            handler.press_i = false;
            if state.editing == Editing::Inside {
                let count = if state.domain == Domain::Tri { 1 } else { 2 };
                state.inside_index = (state.inside_index + 1) % count;
            } else {
                state.editing = Editing::Inside;
            }
            title_dirty = true;
        }
        while handler.adjust.abs() >= 0.05 {
            let step = if handler.adjust > 0.0 { 0.1 } else { -0.1 };
            handler.adjust -= step;
            state.adjust(step);
            title_dirty = true;
        }

        if title_dirty {
            title_dirty = false;
            // SAFETY: Live window handle; HSTRING is NUL-terminated.
            unsafe {
                let _ = SetWindowTextW(window.handle(), &HSTRING::from(state.title()));
            }
        }

        let context = &renderer.context;
        let patch = match state.domain {
            Domain::Quad => &scene.quad,
            Domain::Tri => &scene.tri,
        };

        // SAFETY: All bound objects live in `scene`/`renderer` for the whole
        // loop; array parameters reference locals that outlive their calls;
        // the cbuffer write matches its creation size.
        unsafe {
            context.ClearRenderTargetView(&renderer.rtv, &[1.0, 1.0, 1.0, 1.0]);
            context.ClearDepthStencilView(&renderer.dsv, D3D11_CLEAR_DEPTH.0 as u32, 1.0, 0);

            let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
            if context.Map(&scene.cb_main, 0, D3D11_MAP_WRITE_DISCARD, 0, Some(&mut mapped)).is_ok() {
                *(mapped.pData as *mut MainCBuffer) = MainCBuffer {
                    world: Mat4::IDENTITY,
                    view_proj: scene.view_proj,
                    edge_weights: Vec4::from_array(state.edge_weights),
                    inside_weights: state.inside_weights,
                    _pad: [0.0; 2],
                };
                context.Unmap(&scene.cb_main, 0);
            }

            context.IASetInputLayout(&scene.input_layout);
            let vbs = [Some(patch.vertex_buffer.clone())];
            let strides = [size_of::<ControlPoint>() as u32];
            let offsets = [0u32];
            context.IASetVertexBuffers(0, 1, Some(vbs.as_ptr()), Some(strides.as_ptr()), Some(offsets.as_ptr()));
            context.IASetPrimitiveTopology(patch.topology);

            // The single `main` cbuffer is b0 in every stage that uses it.
            let cb = [Some(scene.cb_main.clone())];
            context.VSSetShader(&scene.vertex_shader, None);
            context.VSSetConstantBuffers(0, Some(&cb));
            context.HSSetShader(&patch.hull_shaders[state.partitioning], None);
            context.HSSetConstantBuffers(0, Some(&cb));
            context.DSSetShader(&patch.domain_shader, None);
            context.DSSetConstantBuffers(0, Some(&cb));
            context.GSSetShader(&scene.geometry_shader, None);
            context.GSSetConstantBuffers(0, Some(&cb));
            context.PSSetShader(&scene.pixel_shader, None);
            context.PSSetConstantBuffers(0, Some(&cb));

            context.RSSetState(&scene.wireframe);

            // Un-indexed patch draw, as PipelineManagerDX11::Draw issues for
            // geometry without... the engine always uses DrawIndexed; the
            // patches here have trivial 0..n indices, so plain Draw is
            // equivalent.
            context.Draw(patch.vertex_count, 0);
        }

        renderer.present();

        if handler.base.save_screenshot {
            handler.base.save_screenshot = false;
            screenshot_number += 1;
            renderer.save_backbuffer_png(&format!("TessellationParams{screenshot_number}.png"));
        }
    }
}
