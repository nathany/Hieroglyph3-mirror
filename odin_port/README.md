# odin_port

Odin reference implementations of the Hieroglyph3 sample applications from
*Practical Rendering and Computation with Direct3D 11*, written against raw
D3D11 via `vendor:directx`. Companion to
[D3D11-Odin-Guide.md](../D3D11-Odin-Guide.md); each app mirrors the behavior
of its C++ original (in `../Applications/`). The sibling `rust_port/` (on the
`rust` branch) is the same exercise in Rust — behavioral findings from those
ports (engine quirks, sRGB texture metadata, per-stage cbuffer registers)
carry over here.

## Layout

```
odin_port/
├── odrun.bat          # build + run one app: `.\odrun.bat basic_window`
├── glyph/             # support library, imported as the `glyph:` collection
│   ├── window/        #   Win32 window wrappers (≈ Win32RenderWindow, Win32Window)
│   └── renderer/      #   device/swap chain/depth/screenshot (≈ RendererDX11 subset)
└── apps/              # one package per sample application
```

The `glyph` collection is deliberately **not** an engine port — it holds only
the support code the samples share, mirroring the behavior of the
corresponding engine classes (each file names its C++ counterpart) without
the abstraction layers. Shaders and textures load directly from the
repository's `../Applications/Data/` tree, unchanged and uncopied.

## Build & run

```
.\odrun.bat basic_window
```

In PowerShell the leading `.\` is required — PowerShell doesn't search the
current directory, so a bare `odrun` (or `run`) can find a same-named script
elsewhere on PATH. In cmd, `odrun basic_window` works. `odrun.bat` wraps
`odin run apps\<name> -collection:glyph=glyph -subsystem:windows -debug`; drop
`-subsystem:windows` to get a console for debug prints. Text rendering is
permanently out of scope for these ports.

Data files (shaders, textures, models) load from the repo's
`../Applications/Data` tree — the path is baked in at compile time from the
source location, so lookup doesn't depend on the working directory.

## Applications

| App | C++ original | Book chapter | Status |
|---|---|---|---|
| `basic_window` | Applications/BasicWindow | 1 | ✅ matches C++ behavior |
| `basic_application` | Applications/BasicApplication | 1 | ✅ matches C++ behavior |
| `rotating_cube` | Applications/RotatingCube | 3 | ✅ matches C++ behavior |
| `basic_compute_shader` | Applications/BasicComputeShader | 5 | ✅ pixel-identical to C++ |
| `basic_tessellation` | Applications/BasicTessellation | 4 | ✅ matches C++ behavior |
| `immediate_renderer` | Applications/ImmediateRenderer | 3 | ✅ core visual scope (no text/console) |
| `image_processor` | Applications/ImageProcessor | 10 | ✅ all 5 filters/images/samplers (no text) |
| `tessellation_params` | Applications/TessellationParams | 4 | ✅ state in the title bar (no text) |
| `skin_and_bones` | Applications/SkinAndBones | 8 | ✅ skinning + displacement + gizmos (no text) |

### basic_window

Pure Win32, no Direct3D. Two windows: the main 320×240 window at (200, 100)
(empty title), and a "Some Text" window that animates its width 170→310 right
after startup. Closing the main window quits; closing "Some Text" doesn't
(its messages go straight to `DefWindowProc` — a quirk preserved from the C++
sample). The app then spins in a `PeekMessage` loop, which is where later
samples put their per-frame update/render.

### basic_application

First Direct3D 11 sample: 640×320 window at (25, 25), cleared each frame to
a time-varying blue (`sin(t²) * 0.25 + 0.5` — the pulsing speeds up over
time) and presented uncapped. `Esc` quits; `Space` saves a numbered PNG
screenshot of the backbuffer via the vendored `stb_image_write` (its prebuilt
lib ships with the Odin toolchain), with alpha dropped to opaque RGB like
DirectXTK's output. Device creation mirrors `RendererDX11::Initialize` — hardware
adapters tried at exactly feature level 10.0, reference-driver fallback,
debug layer under `-debug`. Swap chain uses the engine's defaults
(`R8G8B8A8_UNORM_SRGB`, 2 buffers, `DISCARD`); depth is `D32_FLOAT`.
Resizing does not resize the swap chain — faithful to the C++.

### rotating_cube

The book's first real render (640×480): an indexed color cube spun by a
world matrix rebuilt each frame, drawn VS → GS → PS with
`RotatingCube.hlsl` unchanged. The geometry shader — not the vertex shader —
applies `WorldViewProjMatrix` and "blows up" each face along its normal, so
the cbuffer binds to the GS stage only. Matrix handling: shaders compile with
`D3DCOMPILE_PACK_MATRIX_ROW_MAJOR` (as the engine's `ShaderFactoryDX11`
does), so plain `matrix[4,4]f32` fields compose naturally
(`proj * view * world`) with zero transposes — see the note in
`glyph/shader/shader.odin` for why `#row_major` must *not* be combined with
the compile flag. Camera via `glyph:camera`'s hand-rolled LH 0..1-depth
helpers (core:math/linalg's are GL-convention). The window and screenshot
prefix say "BasicApplication" because the C++ `GetName()` does — a
copy-paste quirk in the original, preserved.

### basic_compute_shader

The book's first compute pipeline (640×480, feature level 11.0 for
`cs_5_0`). Each frame: `InvertColorCS.hlsl` reads `Outcrop.png` (SRV t0) and
writes the inverted image to an `R16G16B16A16_FLOAT` texture (UAV u0) in
20×20 thread groups dispatched 32×24; the CS bindings are then cleared (the
C++'s `ClearPipelineResources`) so a fullscreen quad can `Load` the result in
the pixel shader. Textures decode with pure-Odin `core:image/png`, and the
loader mirrors WICTextureLoader's sRGB handling: `Outcrop.png` carries
sRGB/gAMA chunks, so the texture gets an `_SRGB` format — without this the
output is uniformly wrong by a gamma curve. Screenshots verified
**pixel-identical** (max channel diff 0) against the C++
`BasicComputeShader_Desktop.exe` reference, which is possible because the
output is static.

### basic_tessellation

The chapter-4 hardware tessellation demo: `hedra.ms3d` (a small MilkShape3D
loader in `ms3d.odin` mirrors `GeometryLoaderDX11::loadMS3DFile2`, including
its Z-negation and winding flip) drawn as a `3_CONTROL_POINT_PATCHLIST`
through VS → HS → tessellator → DS → PS from `BasicTessellation.hlsl`
unchanged. Edge factors animate `sin(t)*6+7` (1 to 13, `fractional_even`), so
the wireframe continuously splits and merges while the model spins. The
wireframe is black because the shader's `FinalColor` is never set by the app
and the engine zero-initializes parameters — matching the C++. Note on
cbuffer registers: each *stage* assigns its used cbuffers from b0
independently (`Transforms` is b0 in VS and DS; `EdgeFactors` is b0 in the
HS; `FinalColor` is b0 in the PS).

### tessellation_params

The chapter-4 interactive tessellation explorer: one quad or triangle patch,
wireframe on white, with every tessellator input adjustable live. **G**
toggles domain, **P** cycles partitioning (pow2/integer/fractional_odd/
fractional_even — one hull shader compiled per mode via preprocessor
defines, `glyph:shader`'s `compile_defines`), **E**/**I** pick which edge or
inside factor to edit, **numpad +/−** adjust it (clamped 1–64, quad factors
run through `Process2DQuadTessFactorsAvg` in the shader). The C++ shows all
state as on-screen text; here it lives in the **window title bar** instead.
Space screenshots with the C++'s full `GetName` prefix ("Direct3D 11
Tessellation Parameters Demo…").

### skin_and_bones

The chapter-8 vertex-skinning demo. A procedurally generated 6-bone weighted
cone (`cone.odin` ports `GenerateWeightedSkinnedCone`, the engine's
`AnimationStream` with QuadraticInOut easing, and the
`SkinnedBoneController` skin-matrix math) appears twice: once as a plain
skinned mesh (`MeshSkinnedTextured.hlsl`) and once tessellated + height-map
displaced (`MeshSkinnedTessellatedTextured.hlsl`, 3-control-point patches),
next to a rigid `box.ms3d` with `Tiles.png` for contrast. Every bone shows
its coordinate-axis gizmo (`VertexColor.hlsl`). The bone swing eases through
keyframes over 6 seconds and then stops — **A** replays it, exactly like the
C++. Notables: the skinned shaders transform positions by `SkinMatrices`
then `ViewProjMatrix` (the cbuffer's `WorldMatrix` is unused), so the
actors' node motion rides inside the skin matrices via the bind-pose-before-
positioning call order; and the app's `LightColor` parameter is never read
by any of these shaders.

### immediate_renderer

The chapter-3 "immediate rendering" sample at **core visual scope** (no 3D
text/FPS overlay/Lua console; the missing `Capsule.obj` draws nothing in the
C++ either). The centerpiece is the animated paraboloid grid — 20×20
vertices + indices rebuilt from scratch every frame into DYNAMIC buffers
(`mesh.odin` holds the dynamic-buffer machinery plus `GeometryActor`'s shape
builders: sphere/cone/disc/box/arrow/Bézier). Also: alpha-blended shape
collection, `MeshedReconstruction.stl` (binary STL loader), skybox from a
hand-parsed uncompressed DDS cube map (`core:image` has no DDS support), and
a circling point light driving the engine's UE4-style PBR shaders, used
unchanged. First-person camera (right-drag look, W/A/S/D/Q/E, Ctrl sprint),
keys 1/2/3 off-center projections (`glyph:camera`'s
`perspective_off_center_lh`), live swap-chain resize (`glyph:renderer`'s
`resize`), Esc/Space as usual.

### image_processor

The chapter-10 compute image filters (1024×640, no text overlay). Five
images cycled with **I**, five algorithms with **N** — brute-force Gaussian,
separable Gaussian, cached (groupshared) Gaussian, brute-force bilateral,
separable bilateral, all shaders unchanged; separable variants ping-pong
through an intermediate `R16G16B16A16_FLOAT` target with SRV/UAV unbinds
between passes. **Space** cycles the viewer's sampler (linear-wrap vs
linear-border-black) — this app repurposes Space, so no screenshot key, like
the C++. Left-drag pans, right-drag/wheel zooms. Rendering is event-driven
like the C++'s overridden message loop: blocking `GetMessage`, re-render
only on invalidation — the CPU idles between inputs.
