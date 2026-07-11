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
└── apps/                 # one binary crate per sample application
```

The `glyph` crate is deliberately **not** an engine port — it holds only the
support code the samples share, mirroring the behavior of the corresponding
engine classes (each module's docs name its C++ counterpart) without the
abstraction layers (`ResourceProxy`, `ParameterManager`, events, scene graph).

Shaders and textures are loaded directly from the repository's
`../Applications/Data/` tree — the same files the C++ demos use, unchanged
and uncopied. `glyph::paths::find_data_file` resolves them whether an app is
run via `cargo run` from `rust_port/` or as a bare executable.

## Build & run

```
cargo run -p basic_window
```

## Applications

Text rendering (sprite fonts / overlays) is permanently out of scope for
these ports — demos that show text render everything else.

### Ported

| App | C++ original | Book chapter | Status |
|---|---|---|---|
| `basic_window` | Applications/BasicWindow | 1 | ✅ matches C++ behavior |
| `basic_application` | Applications/BasicApplication | 1 | ✅ matches C++ behavior |
| `rotating_cube` | Applications/RotatingCube | 3 | ✅ matches C++ behavior |
| `basic_compute_shader` | Applications/BasicComputeShader | 5 | ✅ pixel-identical to C++ |
| `immediate_renderer` | Applications/ImmediateRenderer | 3 | ✅ core visual scope (no text/console) |

### Remaining book-chapter demos

Chapters 2, 6, and 7 have no dedicated samples (2 and 6 are read-only
chapters; 7's material is applied by chapter 13's MirrorMirror).

| C++ demo | Chapter | Plan |
|---|---|---|
| BasicTessellation | 4 | Optional — plan says read ch. 4, implement tessellation once in Luna's DX12 book |
| TessellationParams | 4 | Optional — better *run* (interactive parameter visualizer) than ported |
| SkinAndBones | 8 | Skip — Luna's DX12 book has a full skinning chapter |
| CurvedPointNormalTriangles | 9 | Skip — advanced tessellation |
| InterlockingTerrainTiles | 9 | Skip — advanced tessellation |
| ImageProcessor | 10 | **First optional continuation** — Gaussian/bilateral compute filters |
| DeferredRendering | 11 | Optional, biggest lift — G-buffer + light passes |
| LightPrepass | 11 | Optional — lighter deferred variant |
| WaterSimulationI | 12 | **Second optional continuation** — compute heightfield fluid |
| ParticleStorm | 12 | Optional — append/consume buffers + DrawInstancedIndirect |
| MirrorMirror | 13 | Skip — deferred-context multithreading (dead end; DX12 does it right) |

### Engine demos (no book chapter)

Blog/engine showcases; port only if a technique becomes interesting:
AmbientOcclusionI (SSAO), BasicScenes (scene graph), BasicRenderViews
(render-view system), ViewFromTheWindow, VolumeRendering (3D textures),
PhysicalRenderingSandbox (PBR playground).

### Excluded

BasicScripting + Glyphlets/GlyphletViewerWPF (Lua scripting / glyphlet
hosting), KinectPlayground + Kinect2Playground (Kinect hardware),
OculusRiftSample (Rift hardware), MFCwithD3D11 (MFC host).

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
[RotatingCube.hlsl](../Applications/Data/Shaders/RotatingCube.hlsl) unchanged.
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

### immediate_renderer

The chapter-3 "immediate rendering" sample at **core visual scope**: all the
rendered content and interaction of the C++ demo except text (the 3D
`TextActor` and FPS overlay need the engine's sprite-font machinery) and the
Lua console. The centerpiece lesson is the animated paraboloid grid — 20×20
vertices + indices rebuilt from scratch every frame into DYNAMIC buffers
(`src/mesh.rs` is the dynamic-buffer machinery plus `GeometryActor`'s shape
builders: sphere/cone/disc/box/arrow/Bézier, ported math-for-math). Also:
alpha-blended shape collection, `MeshedReconstruction.stl` (binary STL loader),
skybox from a hand-parsed uncompressed DDS cube map, and a circling point
light driving the engine's UE4-style PBR shaders
(`vertex-color/textured.vertex-normal.point-light.perspective.*.hlsl`, used
unchanged). First-person camera (right-drag look, W/A/S/D/Q/E, Ctrl sprint),
keys 1/2/3 off-center projections, live swap-chain resize (`Renderer::resize`),
Esc/Space as usual. The missing `Capsule.obj` is omitted — the C++ loads zero
triangles for it. Note: this sample's C++ uses the engine's newer
MaterialTemplate/PBR path, *not* the older Blinn-Phong
`ImmediateGeometrySolid.hlsl` its comments suggest.
