# rust_port

Rust reference implementations of the Hieroglyph3 sample applications from
*Practical Rendering and Computation with Direct3D 11*, written against raw
D3D11 via the `windows` crate. Companion to [D3D11-Rust-Guide.md](../D3D11-Rust-Guide.md);
each app mirrors the behavior of its C++ original (in `../Applications/`),
verified side by side against the VS2022 builds in `../Applications/Bin`.

## Layout

```
rust_port/
├── Cargo.toml            # workspace; shared deps in [workspace.dependencies]
├── glyph/                # support library — grows only as samples need it
│   └── src/
│       ├── window.rs     #   Win32 window wrappers (≈ Win32RenderWindow, Win32Window)
│       ├── renderer.rs   #   device/swap chain/depth/textures/screenshot (≈ RendererDX11 subset)
│       ├── shader.rs     #   runtime HLSL compilation (≈ ShaderFactoryDX11)
│       └── paths.rs      #   data-file lookup (≈ FileSystem)
├── apps/                 # one binary crate per sample application
└── data/
    ├── shaders/          # copied unchanged from ../Applications/Data/Shaders
    └── textures/         # copied from ../Applications/Data/Textures
```

The `glyph` crate is deliberately **not** an engine port — it holds only the
support code the samples share, mirroring the behavior of the corresponding
engine classes (each module's docs name its C++ counterpart) without the
abstraction layers (`ResourceProxy`, `ParameterManager`, events, scene graph).

## Build & run

```
cargo run -p basic_window
```

## Applications

| App | C++ original | Book chapter | Status |
|---|---|---|---|
| `basic_window` | Applications/BasicWindow | 1 | ✅ matches C++ behavior |
| `basic_application` | Applications/BasicApplication | 1 | ✅ matches C++ behavior |
| `rotating_cube` | Applications/RotatingCube | 3 | ✅ matches C++ behavior |
| `basic_compute_shader` | Applications/BasicComputeShader | 5 | ✅ pixel-identical to C++ |

### basic_window

Pure Win32, no Direct3D. Two windows: the main 320×240 window at (200, 100)
(empty title), and a "Some Text" window that animates its width 170→310 right
after startup. Closing the main window quits; closing "Some Text" doesn't (its
messages go straight to `DefWindowProc` — a quirk preserved from the C++
sample). The app then spins in a `PeekMessage` loop, which is where later
samples put their per-frame update/render.

### basic_application

First Direct3D 11 sample: 640×320 window at (25, 25), cleared each frame to a
time-varying blue (`sin(t²) * 0.25 + 0.5` — the pulsing speeds up over time)
and presented uncapped (`SyncInterval = 0`, as the C++ framework does).
`Esc` quits; `Space` saves `BasicApplication<n>.png` (numbered from 100001)
to the working directory via a staging-texture readback + the `image` crate,
standing in for DirectXTK's `SaveWICTextureToFile`. Device creation mirrors
`RendererDX11::Initialize` — hardware adapters tried at exactly feature level
10.0, reference-driver fallback, debug layer in debug builds. Swap chain uses
the engine's defaults (`R8G8B8A8_UNORM_SRGB`, 2 buffers, `DISCARD`); depth is
`D32_FLOAT`. Resizing the window does not resize the swap chain — faithful to
the C++, where nothing consumes the resize event in this sample.

### rotating_cube

The book's first real render (640×480): an indexed color cube spun by a world
matrix rebuilt each frame, drawn VS → GS → PS with
[data/shaders/RotatingCube.hlsl](data/shaders/RotatingCube.hlsl) unchanged.
The geometry shader — not the vertex shader — applies `WorldViewProjMatrix`
and "blows up" each face along its normal, so the cbuffer binds to the GS
stage only. Matrix handling is the guide's recommended setup: shaders compiled
with `D3DCOMPILE_PACK_MATRIX_ROW_MAJOR` (as the engine's `ShaderFactoryDX11`
does), glam composing naturally (`proj * view * world`), zero transposes.
`camera::lh::proj::directx::perspective` / `camera::lh::view::look_at_mat4`
stand in for `XMMatrixPerspectiveFovLH` / `XMMatrixLookAtLH`. The window and
screenshot prefix say "BasicApplication" because the C++ `GetName()` does —
a copy-paste quirk in the original, preserved. Verified side-by-side against
`Applications/Bin/RotatingCube_Desktop.exe` screenshots.

### basic_compute_shader

The book's first compute pipeline (640×480, feature level 11.0 for `cs_5_0`).
Each frame: `InvertColorCS.hlsl` reads `Outcrop.png` (SRV t0) and writes the
inverted image to a `R16G16B16A16_FLOAT` texture (UAV u0) in 20×20 thread
groups dispatched 32×24; the CS bindings are then cleared (the C++'s
`ClearPipelineResources`) so a fullscreen quad can `Load` the result in the
pixel shader. Texture loading mirrors WICTextureLoader's sRGB handling: the
input texture gets an `_SRGB` format because `Outcrop.png` carries sRGB/gAMA
metadata — without this the output is uniformly wrong by a gamma curve.
Screenshots verified **pixel-identical** (max channel diff 0) against
`Applications/Bin/BasicComputeShader_Desktop.exe`, which is possible here
because the output is static.
