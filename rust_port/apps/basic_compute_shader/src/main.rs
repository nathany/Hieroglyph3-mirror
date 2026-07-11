//! Rust port of the BasicComputeShader sample
//! (Applications/BasicComputeShader/App.cpp).
//!
//! The book's first compute pipeline (chapter 5), and the first sample to
//! need a feature level 11.0 device (`cs_5_0`). Each frame:
//!
//! 1. **Compute pass** — `InvertColorCS.hlsl` reads `Outcrop.png` through an
//!    SRV (`InputMap`, t0) and writes the inverted color to a second texture
//!    through a UAV (`OutputMap`, u0). Thread groups are 20x20
//!    (`[numthreads]` in the shader), dispatched 32x24 to cover the 640x480
//!    image exactly.
//! 2. **Unbind** — the CS's SRV and UAV are cleared so the output texture can
//!    be read in step 3 (a resource can't be bound as UAV and SRV at once;
//!    the C++ does this via `ClearPipelineResources`).
//! 3. **Fullscreen pass** — a clip-space quad (`TextureVS.hlsl` passthrough)
//!    with `TexturePS.hlsl` `Load`ing the filtered texture per pixel
//!    (`ColorMap00`, t0). The PS SRV is unbound after the draw so next
//!    frame's compute pass can write the UAV again.
//!
//! Faithful details: the output texture is `R16G16B16A16_FLOAT` — the
//! engine's `SetColorBuffer` default, not RGBA8. The C++'s fullscreen quad
//! (`GeometryGeneratorDX11::GenerateFullScreenQuad`) also carries a TEXCOORDS
//! element that `TextureVS` never reads; the vertex buffer here keeps just
//! the clip-space positions. No state objects are created — the sample runs
//! on the context defaults, as the C++ effectively does. `Esc` quits;
//! `Space` saves `BasicComputeShader<n>.png`.

#![windows_subsystem = "windows"]

use glyph::renderer::Renderer;
use glyph::shader::compile_shader;
use glyph::window::{AppMessageHandler, RenderWindow};
use windows::Win32::Graphics::Direct3D::{
    D3D_FEATURE_LEVEL_11_0, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST,
};
use windows::Win32::Graphics::Direct3D11::{
    D3D11_BIND_INDEX_BUFFER, D3D11_BIND_SHADER_RESOURCE, D3D11_BIND_UNORDERED_ACCESS,
    D3D11_BIND_VERTEX_BUFFER, D3D11_BUFFER_DESC, D3D11_CLEAR_DEPTH, D3D11_INPUT_ELEMENT_DESC,
    D3D11_INPUT_PER_VERTEX_DATA, D3D11_SUBRESOURCE_DATA, D3D11_TEXTURE2D_DESC,
    D3D11_USAGE_DEFAULT, D3D11_USAGE_IMMUTABLE, ID3D11Buffer, ID3D11ComputeShader,
    ID3D11InputLayout, ID3D11PixelShader, ID3D11ShaderResourceView, ID3D11Texture2D,
    ID3D11UnorderedAccessView, ID3D11VertexShader,
};
use windows::Win32::Graphics::Dxgi::Common::{
    DXGI_FORMAT_R16G16B16A16_FLOAT, DXGI_FORMAT_R32G32B32A32_FLOAT, DXGI_FORMAT_R32_UINT,
    DXGI_SAMPLE_DESC,
};
use windows::Win32::UI::WindowsAndMessaging::{
    DispatchMessageW, MB_ICONEXCLAMATION, MB_SYSTEMMODAL, MSG, MessageBoxW, PM_REMOVE,
    PeekMessageW, SW_HIDE, ShowWindow, TranslateMessage, WM_QUIT,
};
use windows::core::{HSTRING, Result, s, w};

const WIDTH: u32 = 640;
const HEIGHT: u32 = 480;

/// Everything `App::Initialize` creates beyond the shared `Renderer`.
struct Scene {
    // Keeps the input texture alive alongside its SRV.
    _input_texture: ID3D11Texture2D,
    input_srv: ID3D11ShaderResourceView,
    output_uav: ID3D11UnorderedAccessView,
    output_srv: ID3D11ShaderResourceView,
    compute_shader: ID3D11ComputeShader,
    vertex_shader: ID3D11VertexShader,
    pixel_shader: ID3D11PixelShader,
    input_layout: ID3D11InputLayout,
    vertex_buffer: ID3D11Buffer,
    index_buffer: ID3D11Buffer,
}

fn setup(renderer: &Renderer) -> Result<Scene> {
    let device = &renderer.device;

    // The input image, loaded as in RendererDX11::LoadTexture.
    let (input_texture, input_srv) = renderer.load_texture_png("Outcrop.png")?;

    // Shaders — same entry points and SM 5.0 targets as the C++ LoadShader
    // calls.
    let cs_bytecode = compile_shader("InvertColorCS.hlsl", "CSMAIN", "cs_5_0")?;
    let vs_bytecode = compile_shader("TextureVS.hlsl", "VSMAIN", "vs_5_0")?;
    let ps_bytecode = compile_shader("TexturePS.hlsl", "PSMAIN", "ps_5_0")?;

    // SAFETY: All creation calls receive valid descriptors, initial data
    // pointing at live stack arrays, bytecode slices from the compiles above,
    // and valid out-params.
    unsafe {
        let mut compute_shader: Option<ID3D11ComputeShader> = None;
        device.CreateComputeShader(&cs_bytecode, None, Some(&mut compute_shader))?;
        let mut vertex_shader: Option<ID3D11VertexShader> = None;
        device.CreateVertexShader(&vs_bytecode, None, Some(&mut vertex_shader))?;
        let mut pixel_shader: Option<ID3D11PixelShader> = None;
        device.CreatePixelShader(&ps_bytecode, None, Some(&mut pixel_shader))?;

        // Output texture for the compute shader, per Texture2dConfigDX11::
        // SetColorBuffer (R16G16B16A16_FLOAT) with the bind flags the app
        // overrides to UAV | SRV.
        let output_desc = D3D11_TEXTURE2D_DESC {
            Width: WIDTH,
            Height: HEIGHT,
            MipLevels: 1,
            ArraySize: 1,
            Format: DXGI_FORMAT_R16G16B16A16_FLOAT,
            SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
            Usage: D3D11_USAGE_DEFAULT,
            BindFlags: (D3D11_BIND_UNORDERED_ACCESS.0 | D3D11_BIND_SHADER_RESOURCE.0) as u32,
            CPUAccessFlags: 0,
            MiscFlags: 0,
        };
        let mut output_texture: Option<ID3D11Texture2D> = None;
        device.CreateTexture2D(&output_desc, None, Some(&mut output_texture))?;
        let output_texture = output_texture.unwrap();

        let mut output_uav: Option<ID3D11UnorderedAccessView> = None;
        device.CreateUnorderedAccessView(&output_texture, None, Some(&mut output_uav))?;
        let mut output_srv: Option<ID3D11ShaderResourceView> = None;
        device.CreateShaderResourceView(&output_texture, None, Some(&mut output_srv))?;

        // Fullscreen quad from GenerateFullScreenQuad: clip-space corner
        // positions, two triangles wound (0,2,1), (1,2,3).
        let vertices: [[f32; 4]; 4] = [
            [-1.0, 1.0, 0.0, 1.0],  // upper left
            [-1.0, -1.0, 0.0, 1.0], // lower left
            [1.0, 1.0, 0.0, 1.0],   // upper right
            [1.0, -1.0, 0.0, 1.0],  // lower right
        ];
        let indices: [u32; 6] = [0, 2, 1, 1, 2, 3];

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

        let layout_desc = [D3D11_INPUT_ELEMENT_DESC {
            SemanticName: s!("POSITION"),
            SemanticIndex: 0,
            Format: DXGI_FORMAT_R32G32B32A32_FLOAT,
            InputSlot: 0,
            AlignedByteOffset: 0,
            InputSlotClass: D3D11_INPUT_PER_VERTEX_DATA,
            InstanceDataStepRate: 0,
        }];
        let mut input_layout: Option<ID3D11InputLayout> = None;
        device.CreateInputLayout(&layout_desc, &vs_bytecode, Some(&mut input_layout))?;

        Ok(Scene {
            _input_texture: input_texture,
            input_srv,
            output_uav: output_uav.unwrap(),
            output_srv: output_srv.unwrap(),
            compute_shader: compute_shader.unwrap(),
            vertex_shader: vertex_shader.unwrap(),
            pixel_shader: pixel_shader.unwrap(),
            input_layout: input_layout.unwrap(),
            vertex_buffer: vertex_buffer.unwrap(),
            index_buffer: index_buffer.unwrap(),
        })
    }
}

fn main() {
    let mut handler = AppMessageHandler::default();

    let mut window = RenderWindow::new();
    window.set_position(25, 25);
    window.set_size(WIDTH as i32, HEIGHT as i32);
    window.set_caption("BasicComputeShader");
    window.initialize(&mut handler);

    let renderer = match Renderer::new(window.handle(), WIDTH, HEIGHT, D3D_FEATURE_LEVEL_11_0) {
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
            let text = HSTRING::from(e.message());
            // SAFETY: MessageBoxW with valid string arguments.
            unsafe {
                MessageBoxW(
                    None,
                    &text,
                    w!("BasicComputeShader setup failed"),
                    MB_ICONEXCLAMATION | MB_SYSTEMMODAL,
                );
            }
            return;
        }
    };

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

        let context = &renderer.context;

        // SAFETY: All bound objects live in `scene`/`renderer` for the whole
        // loop; array parameters reference locals that outlive the calls. The
        // unbinds between passes uphold D3D11's rule that a resource is never
        // simultaneously bound for read (SRV) and write (UAV).
        unsafe {
            // Compute pass: PipelineManagerDX11::Dispatch(effect, 32, 24, 1).
            context.CSSetShader(&scene.compute_shader, None);
            context.CSSetShaderResources(0, Some(&[Some(scene.input_srv.clone())]));
            let uavs = [Some(scene.output_uav.clone())];
            context.CSSetUnorderedAccessViews(0, 1, Some(uavs.as_ptr()), None);
            context.Dispatch(32, 24, 1);

            // ClearPipelineResources: release the CS bindings so the output
            // texture can be bound as the pixel shader's SRV below.
            context.CSSetShaderResources(0, Some(&[None]));
            let no_uavs = [None::<ID3D11UnorderedAccessView>];
            context.CSSetUnorderedAccessViews(0, 1, Some(no_uavs.as_ptr()), None);

            // Fullscreen pass: clear, then draw the quad sampling the result.
            context.ClearRenderTargetView(&renderer.rtv, &[0.0, 0.0, 0.0, 0.0]);
            context.ClearDepthStencilView(&renderer.dsv, D3D11_CLEAR_DEPTH.0 as u32, 1.0, 0);

            context.IASetInputLayout(&scene.input_layout);
            let vertex_buffers = [Some(scene.vertex_buffer.clone())];
            let strides = [(4 * size_of::<f32>()) as u32];
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
            context.PSSetShader(&scene.pixel_shader, None);
            context.PSSetShaderResources(0, Some(&[Some(scene.output_srv.clone())]));

            context.DrawIndexed(6, 0, 0);

            // Unbind the PS SRV so next frame's compute pass can write the
            // UAV without D3D force-unbinding it (and warning).
            context.PSSetShaderResources(0, Some(&[None]));
        }

        renderer.present();

        // Application::TakeScreenShot — Space (GetName() is correct in this
        // sample, unlike RotatingCube's).
        if handler.save_screenshot {
            handler.save_screenshot = false;
            screenshot_number += 1;
            renderer.save_backbuffer_png(&format!("BasicComputeShader{screenshot_number}.png"));
        }
    }
}
