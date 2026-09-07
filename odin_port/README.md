# odin_port

Odin reference implementations of the Hieroglyph3 sample applications from
*Practical Rendering and Computation with Direct3D 11*, written against raw
D3D11 via `vendor:directx`. Companion to
[D3D11-Odin-Guide.md](../D3D11-Odin-Guide.md); each app follows its C++ original
(in `../Applications/`) with documented deviations and outstanding defects.
Read [KNOWN_ISSUES.md](../KNOWN_ISSUES.md) and [validation records](VALIDATION.md)
alongside the sample notes; “runs” does not imply every mode matches the reference.

## Layout

```
odin_port/
├── Justfile           # local build, run, check, test, and ASan recipes
├── glyph/             # support library, imported as the `glyph:` collection
│   ├── window/        #   Win32 window wrappers (≈ Win32RenderWindow, Win32Window)
│   ├── renderer/      #   device/swap chain/depth/screenshot (≈ RendererDX11 subset)
│   └── d3d_math/      #   row-vector matrix helpers (≈ Matrix4f / DirectXMath)
└── apps/              # one package per sample application
```

The `glyph` collection is deliberately **not** an engine port — it holds only
the support code the samples share, mirroring the behavior of the
corresponding engine classes (each file names its C++ counterpart) without
the abstraction layers. Shaders and textures load directly from the
repository's `../Applications/Data/` tree, unchanged and uncopied.

## Build & run

From Git Bash:

```
cd odin_port
just run basic_window
```

Run `just list` to list the sample names and `just --list` to see all recipes.
Useful local validation commands include `just check basic_window`,
`just verify`, and `just asan basic_window`. The run recipe
wraps `odin run apps/<name> -collection:glyph=glyph -subsystem:windows -debug`.
ASan builds keep the console subsystem so sanitizer diagnostics remain visible. Text
rendering is permanently out of scope for these ports.

Debug builds request the D3D debug layer, which requires Windows Graphics Tools.
Its messages go to native debugger output or `ID3D11InfoQueue`, not ordinary
stdout/stderr. An empty console log is not evidence that the layer found nothing.
For a retained executable to launch in a debugger or RenderDoc, build from here:

```sh
odin build apps/basic_application -collection:glyph=glyph -out:bin/basic_application.exe -subsystem:windows -debug
```

`odin run` removes its output executable after normal completion. In RenderDoc,
launch the retained executable with API validation enabled and inspect a captured
frame's messages and pipeline bindings. A successful capture and replay is separate
evidence from merely having RenderDoc installed. See [VALIDATION.md](VALIDATION.md)
for the tooling checks actually performed.

Data files (shaders, textures, models) load from the repo's
`../Applications/Data` tree — the path is baked in at compile time from the
source location, so lookup doesn't depend on the working directory.

The math helpers in `glyph:d3d_math` have a test suite:

```
just test
```

## Applications

### Controls

The C++ samples draw their controls on screen; text rendering is out of scope here
(see *Build & run* above), so they're documented instead. App-specific keys are in the
table's **Controls** column; these are the ones shared across demos:

| Key | Effect |
|---|---|
| `Escape` | Quit |
| `Space` | Save a screenshot (PNG, next to the executable) — *except in `image_processor`, which rebinds it* |

Five demos share a first-person camera (`fp_camera.odin`, an identical copy in each —
`immediate_renderer`, `light_prepass`, `deferred_rendering`, `water_simulation`,
`particle_storm`):

| Input | Effect |
|---|---|
| `W` / `S` | Move forward / back |
| `A` / `D` | Strafe left / right |
| `Q` / `E` | Move up / down |
| `Ctrl` (hold) | 3× move speed |
| Right-drag | Look around (pitch clamped to ±90°) |

Note `W`/`A` mean *movement* in those five, but *wireframe* and a shader toggle in
`curved_pn_triangles` and `interlocking_terrain_tiles`, which have no free camera.
Where a demo shows live state (tessellation factors, active modes), it goes in the
**window title bar**.

| App | C++ original | Book chapter | Controls | Status |
|---|---|---|---|---|
| `basic_window` | Applications/BasicWindow | 1 | — | ✅ matches C++ behavior |
| `basic_application` | Applications/BasicApplication | 1 | — | ✅ matches C++ behavior |
| `rotating_cube` | Applications/RotatingCube | 3 | — | ✅ matches C++ behavior |
| `basic_compute_shader` | Applications/BasicComputeShader | 5 | — | ✅ pixel-identical to C++ |
| `basic_tessellation` | Applications/BasicTessellation | 4 | — | ✅ matches C++ behavior |
| `immediate_renderer` | Applications/ImmediateRenderer | 3 | camera; `1`/`2`/`3` off-center projection (symmetric / right / left) | ✅ core visual scope |
| `image_processor` | Applications/ImageProcessor | 10 | `N` next filter · `I` next image · `Space` cycles sampler · left-drag pan · right-drag / wheel zoom | ✅ all 5 filters/images/samplers |
| `tessellation_params` | Applications/TessellationParams | 4 | `G` tri/quad domain · `P` partitioning mode · `E`/`I` select edge / inside factor · numpad `+`/`-` adjust it | ✅ state in the title bar |
| `skin_and_bones` | Applications/SkinAndBones | 8 | `WASDQE` move · Ctrl speed · right-drag look · `A` release replays | Animation, camera and resize verified |
| `curved_pn_triangles` | Applications/CurvedPointNormalTriangles | 9 | `W` wireframe · `A` adaptive silhouette · numpad `+`/`-` tessellation factor (1–10) | Base mode runs; inherited adaptive defect |
| `interlocking_terrain_tiles` | Applications/InterlockingTerrainTiles | 9 | `W` wireframe · `L` hull-shader complexity · `D` shading mode (solid / shaded / LOD debug) · `A` automated camera | Simple/complex LOD and shading verified |
| `light_prepass` | Applications/LightPrepass | 11 | camera; `N` cycles light mode | ✅ MSAA deferred lighting |
| `deferred_rendering` | Applications/DeferredRendering | 11 | camera; `V` display · `N` light mode · `K` G-buffer opt · `O` light opt · `M` anti-aliasing | ✅ V/N/K/O/M toggles |
| `water_simulation` | Applications/WaterSimulationI | 12 | camera | ✅ FL10/SM4 simulation and reference camera |
| `particle_storm` | Applications/ParticleStorm | 12 | camera | Simulation runs; startup camera differs |

Rendering samples request the sizes listed below, then use the actual created
client size for the swap chain, shared depth/viewport, and dependent window-sized
targets. BasicComputeShader's compute output stays 640×480; ImageProcessor's
filter targets stay image-sized. RotatingCube, CurvedPointNormalTriangles, and
Terrain also derive their projection aspect from the actual size, matching C++.
Other startup camera aspects retain the reference's requested or fixed values.

The shared depth/viewport choice intentionally improves seven standalone C++
samples: BasicApplication, RotatingCube, BasicComputeShader, BasicTessellation,
TessellationParams, CurvedPointNormalTriangles, and Terrain use actual swap-chain
dimensions but requested depth/viewport dimensions. The Odin
port keeps those resources consistent. ImageProcessor's viewer uniform also uses
the actual size immediately; its C++ version starts with the requested size.

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
the cbuffer binds to the GS stage only. Matrix handling: row-vector matrices
from `glyph:d3d_math` in `#row_major` fields, matching the
`D3DCOMPILE_PACK_MATRIX_ROW_MAJOR` packing the engine's `ShaderFactoryDX11`
uses — so the math reads like the C++ line-for-line
(`RotationMatrixY(t) * RotationMatrixX(t)`, then `World * View * Proj`) and
uploads with zero transposes; see the note in `glyph/shader/shader.odin`.
Camera via `glyph:d3d_math`'s hand-rolled LH 0..1-depth
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

The cone's collapsed apex ring keeps zero CPU normals, matching C++ (KI-004 fixed).
Camera keys are **W/S** forward/back, **A/D** strafe, **Q/E** up/down, **Ctrl**
for triple speed, and right-drag to look. Releasing **A** both stops strafing and
replays the animation; this avoids C++ consuming that release and latching left
movement. Resize recreates the backbuffer/depth views and projection, and failure
exits cleanly (KI-003 fixed). The camera follows the other Odin samples' accumulated
mouse deltas and total-pitch clamp. The cone uses C++'s anisotropy 16 (KI-011 fixed).

### curved_pn_triangles

Chapter 9's curved point-normal triangles: the flat 4-triangle `CPNTest.ply`
(a tiny ASCII PLY loader lives in `ply.odin`) is inflated into cubic Bézier
patches by `CurvedPointNormalTriangles.hlsl` (13 control points per patch),
while the camera orbits (30 s/circuit). **W** toggles wireframe/solid, **±**
adjusts the tessellation factor (1–10), **A** swaps in the silhouette-
adaptive hull shader — preserved C++ quirk: that shader expects 6-point
adjacency patches the app never loads, so adaptive mode can render malformed or
incomplete patches in either version. The pipeline-statistics overlay is omitted (text).

### interlocking_terrain_tiles

Chapter 9's adaptive terrain: a 32×32 grid of tiles drawn as
**12-control-point patches** — each tile's 4 corners plus 8 edge-clamped
neighbour points, the "interlocking" trick that keeps adjacent tiles'
edge tessellation crack-free — displaced by `TerrainHeightMap.png` in the
domain shader with distance-based LOD from the hull shader. **W** toggles
wireframe/cull-none vs solid/cull-front, **L** swaps simple vs complex hull
LOD, **D** cycles solid/N·L/LOD-debug domain shaders (three
`compile_defines` variants), **A** freezes the auto-orbiting viewpoint.

As in C++, a one-time compute prepass summarizes the supplied 512×512 height map
into a 32×32 plane/deviation lookup. Each 16×16 thread group covers one tile.
The UAV is unbound before the hull shader reads the lookup at t1; other height-map
sizes are rejected explicitly. Domain-shader cbuffers are bound per
compiled shading variant: `main` at b0, then `sampleparams` for N·L shading or
`patch` for LOD debug at b1 (KI-019 fixed). The requested 1024×768 size now
matches C++ (KI-013 fixed).

### light_prepass

Chapter 11's light prepass (deferred lighting) renderer, everything at 4x
MSAA: (1) `Sample_Scene.ms3d` fills a G-Buffer (`GBufferLP.hlsl`) with
spheremap-encoded normal-mapped normals, specular power, and an edge flag
from `SV_Coverage`, writing stencil 1 where geometry landed; (2) a
fullscreen mask pass (`MaskLP.hlsl`) bumps edge pixels' stencil to 2;
(3) every point light is one vertex — a geometry shader fits a screen quad
to the light volume at its far depth, and GREATER_EQUAL testing against
the **read-only depth view** keeps only pixels where the volume meets
geometry; lighting accumulates additively (`LightsLP.hlsl`), per-pixel at
stencil 1 and per-sample (`SV_SampleIndex`) at stencil 2; (4) the scene
re-renders (`FinalPassLP.hlsl`), combining covered light samples with the
`Hex.png` albedo; (5) MSAA resolve + blit (an inline fullscreen-triangle
shader standing in for the engine's SpriteRenderer). The tangent frame the
normal mapping needs is computed on load (`GeometryDX11::ComputeTangentFrame`'s
Lengyel method). **N** cycles 3x3x3/5x5x5/7x7x7 point-light grids
(red-to-cyan color lerp — shown in the title bar), first-person camera as
usual, live resize recreates all five render targets. The C++ compiles
spot/directional light shaders it never draws; those are omitted.

The mask pass intentionally has no color target. Its shader still declares a
color output, so the debug layer reports `DEVICE_DRAW_RENDERTARGETVIEW_NOT_SET`;
C++ uses the same depth/stencil-only pass. This particular warning is expected.

The working Odin camera is a useful departure: this C++ setup override omits
camera event registration, leaving its viewpoint fixed. Movement speed remains
the reference camera's 10 units/second, or 30 with Ctrl.

### deferred_rendering

Chapter 11's classic deferred renderer, with the book's full optimization
matrix in the title bar. The G-Buffer pass fills 4 fat MRTs
(**K** off: world-space normal / diffuse / specular / position, all
RGBA32F) or 3 slim ones (**K** on: spheremap-encoded view-space normal
R16G16_SNORM, R10G10B10A2 diffuse, R8G8B8A8 specular — position
reconstructed from depth). Each point light then accumulates additively
into the final target, stencil-masked to geometry; **O** picks fullscreen
quad, scissor-rectangle, or sphere light volumes (LESS_EQUAL/back-face,
flipping to GREATER_EQUAL/front-face when the volume crosses the far
plane). **V** cycles what's displayed (final image, the G-Buffer attributes
singly, or all four in quadrants — hardcoded for 1280x720 in the C++, so
partly off-screen at 800x480, preserved). **N** cycles the light grid,
**M** the AA mode: none, 2x supersampling (all targets at 1600x960), or 4x
MSAA with an SV_Coverage per-sample loop (G-Buffer views are unavailable
under MSAA — the C++ shows a text message, here the screen stays black).
Startup state matches AppSettings.cpp: optimizations + light volumes on.
Preserved quirk: the shader's `CameraPos` is filled from the scene root's
position (the origin), not the camera, so the unoptimized path's specular
is subtly wrong in the original too. The engine's SpriteRenderer display
blit is replaced by an inline alpha-blended pixel-rect blit shader.

As in LightPrepass, C++ omits camera event registration in its setup override.
Odin deliberately provides working camera input; preserve that usability improvement.

### water_simulation

Chapter 12's compute-shader water simulation. A 256×256 grid of water
columns (height + four neighbor outflows) ping-pongs between two structured
buffers: each frame `WaterSimulation.hlsl` runs as 16×16 groups of 18×18
threads (16×16 plus a one-texel perimeter staged through group shared
memory), integrating the pipe-model flows and heights, then the buffers swap
roles. `HeightmapVisualization.hlsl` draws a 256×256-vertex plane in
wireframe, with the VS fetching each vertex's height straight from the water
state buffer (t0) and coloring alternate thread-group tiles green/blue. The
initial state is a sinc-shaped splash (amplitude 40) centered at grid
(32, 96) that ripples outward and reflects off the edges; the plane spins at
0.2 rad/s. FPS lives in the title bar. Faithful frame-rate dependence: the
time step is elapsed-time driven (doubled by the app, clamped to 0.05) but
the damping factor 0.9995 applies **per iteration**, so at uncapped
thousands of FPS the waves flatten within a couple of seconds — the C++
behaves the same way, just at its own frame rate. The camera starts at
(-100, 30.5, -100), matching C++: its spatial controller replaces the default
node translation rather than adding it (KI-006 fixed).
The port requests FL10 and SM4 like C++. It checks optional downlevel compute
and structured-buffer support and exits with a clear error if unavailable.
The C++'s unused "FinalColor" parameter is omitted.

### particle_storm

Chapter 12's GPU particle system. 512×512 = 262,144 particles ping-pong
between two structured buffers with APPEND-flagged UAVs. Per frame:
`ParticleSystemInsertCS.hlsl` appends batches of 8 particles at the emitter
(-50, 10, 0) with randomly reflected directions (throttled to one batch per
~0.9 ms — the C++'s particles-per-insert × lifetime / buffer-size rate);
`CopyStructureCount` latches the append counter into a 16-byte **constant**
buffer; `ParticleSystemUpdateCS.hlsl` (512×512 threads) `Consume()`s every
live particle, accelerates it toward the "black hole" at (50, 0, 0), and
`Append()`s it to the other buffer unless it crossed the event horizon
(r ≤ 5) or aged past 30 s; a second `CopyStructureCount` fills a
`DrawInstancedIndirect` arguments buffer. Rendering needs no vertex data at
all: the VS fetches positions by `SV_VertexID` from the state buffer, a GS
expands each point into a camera-facing quad colored red near the black
hole → blue far away, and the PS modulates `Particle.png`, additively
blended with depth-test-no-write. Port gotcha worth remembering: the render
VS's `SimulationState` buffer has no explicit register, but FXC still
honors the (unused-in-VS) `ParticleTexture : register(t0)` reservation, so
the buffer lands on **t1**. The C++'s `bDebugActive` counter-readback path
is mirrored behind `-define:DEBUG_COUNTS=true`: its staging buffer is checked
at startup and released on exit (KI-017 fixed). FPS in the title bar;
the camera starts at C++'s final translation (-100, 60.5, -100), without adding
the default node offset (KI-006 fixed).
The priming pass explicitly unbinds both UAV slots before insertion reuses one,
preserving the append counters without a startup binding hazard (KI-020 fixed).

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
keys 1/2/3 off-center projections (`glyph:d3d_math`'s
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

If an image switch cannot create either filter target, the port reports the
failure and exits cleanly. This improves the C++ helper's unchecked replacement
path without changing the filtering lesson.
