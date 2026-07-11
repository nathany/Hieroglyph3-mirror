# Practical Rendering and Computation with Direct3D 11 — Rust Port Guide

A chapter-by-chapter companion for working through *Practical Rendering and Computation
with Direct3D 11* (Zink, Pettineo, Hoxley) by writing each sample fresh in **Rust**
against raw D3D11, instead of porting the Hieroglyph3 engine. The engine source in this
repo is your reference implementation — read it when the book's prose isn't enough, but
don't transliterate it.

**The plan:** Chapters 1–6 are the core path. Chapter 4 is read-and-skim (implement
tessellation once, in Luna's DX12 book). Chapters 10–12 are optional continuations if
you decide to stay with DX11 for a while. Chapters 7–9 and 13 are skipped (rationale at
the bottom).

---

## Toolchain

| Piece | Crate | Notes |
|---|---|---|
| D3D11 + DXGI + Win32 + d3dcompiler | [`windows`](https://crates.io/crates/windows) | Microsoft's official bindings. COM interfaces are smart pointers — Drop releases, Clone AddRefs. Docs at [microsoft.github.io/windows-docs-rs](https://microsoft.github.io/windows-docs-rs/) (docs.rs can't build it). |
| Math | [`glam`](https://crates.io/crates/glam) | Has proper DirectX-convention (LH, 0..1 depth) projection/view constructors built in. Enable its `bytemuck` feature. |
| Byte casting | [`bytemuck`](https://crates.io/crates/bytemuck) | `#[repr(C)]` + `Pod` for vertex/cbuffer structs → safe `&[u8]` views. |
| Image loading (ch. 5+) | [`image`](https://crates.io/crates/image) | Pure Rust; replaces the engine's DirectXTK/WIC loading. |
| Shader compilation | `D3DCompile` in `windows::Win32::Graphics::Direct3D::Fxc` | FXC, Shader Model 5.0 — same as the book. No DXC until DX12/SM6. |

Starter `Cargo.toml`:

```toml
[dependencies]
glam = { version = "0.33", features = ["bytemuck"] }
bytemuck = { version = "1", features = ["derive"] }
image = "0.25"

[dependencies.windows]
version = "0.62"
features = [
    "Win32_Foundation",
    "Win32_UI_WindowsAndMessaging",
    "Win32_System_LibraryLoader",     # GetModuleHandleW
    "Win32_Graphics_Gdi",             # window class brushes, ValidateRect
    "Win32_Graphics_Direct3D",        # D3D_DRIVER_TYPE, feature levels, ID3DBlob
    "Win32_Graphics_Direct3D11",
    "Win32_Graphics_Direct3D_Fxc",    # D3DCompile + D3DCOMPILE_* flags
    "Win32_Graphics_Dxgi",
    "Win32_Graphics_Dxgi_Common",     # DXGI_FORMAT lives here
]
```

**The feature-flag treadmill:** every `windows` item exists only if its namespace
feature is enabled. When a type or function "doesn't exist", it's almost always a
missing feature, not a wrong path — each item's page in the docs lists its required
features. Expect to add two or three more over the course of the book; it's a
30-second fix each time.

**Windowing choice:** raw Win32 through the `windows` crate — chapter 1 is literally
about that plumbing, and `RegisterClassExW`/`CreateWindowExW`/message pump is ~100
lines of Rust. `winit` is the escape hatch if window management ever becomes friction
(it hands you an `HWND` for the swap chain), but it hides exactly what ch. 1 teaches.

---

## Math cheat sheet (glam ↔ the book)

glam's conventions:

- **Column-major storage** — `Mat4` is four `Vec4` columns (`x_axis`..`w_axis`).
- **Column-vector math** — `v' = M * v`, so world-view-projection composes as
  `let wvp = proj * view * world;` (rightmost applies first).
- Handedness/depth are **per-constructor**, and glam ships the D3D ones — unlike most
  GL-first math crates, nothing needs hand-rolling.

### The constructors you want (and the ones to avoid)

Since glam 0.33.1 the canonical camera constructors live in `glam::camera`, organized
as `{lh, rh}::{proj::{directx, opengl, vulkan}, view}`. The book is left-handed
DirectX, so everything you need is in `lh` + `directx`:

| Book / engine concept | glam (0.33.1+) | Notes |
|---|---|---|
| `Matrix4f::PerspectiveFovLHMatrix` | `camera::lh::proj::directx::perspective(vertical_fov, aspect_ratio, near, far)` | LH, depth 0..1 — exactly D3D |
| `Matrix4f::LookAtLHMatrix` | `camera::lh::view::look_at_mat4(eye, center, up)` | `look_to_mat4` for eye+direction |
| `Matrix4f::OrthographicLHMatrix` | `camera::lh::proj::directx::orthographic(l, r, b, t, near, far)` | |
| — (nice extra) | `camera::lh::proj::directx::perspective_infinite_reverse(...)` | reverse-Z, when you get curious |
| `Matrix4f::RotationMatrixY( a )` | `Mat4::from_rotation_y(a)` | also `_x`, `_z`, `from_axis_angle`, `from_quat` |
| translation | `Mat4::from_translation(vec3)` | |
| scale·rotate·translate | `Mat4::from_scale_rotation_translation(s, q, t)` | quaternion `Quat::from_rotation_y(a)` etc. |
| transpose | `m.transpose()` | |
| raw floats | `m.to_cols_array()` / `bytemuck::bytes_of(&m)` | column-major order |

On glam **older than 0.33.1**, the same matrices are `Mat4::perspective_lh`,
`Mat4::look_at_lh`, `Mat4::orthographic_lh` (deprecated since 0.33.1 but identical
math). Do **not** use anything suffixed `_gl`/`opengl` (−1..1 depth) or the `rh`
modules — wrong conventions for this book; a wrong pick looks like a depth-clipped
void or an inside-out scene.

### Getting glam matrices into the book's shaders

The book's HLSL is row-vector style — `mul(v, M)` (see
`Applications/Data/Shaders/RotatingCube.hlsl`) — while glam is column-vector, and HLSL
cbuffers default to column-major packing. Three coherent fixes; **pick exactly one**:

1. **Compile flag (recommended):** pass `D3DCOMPILE_PACK_MATRIX_ROW_MAJOR` to every
   `D3DCompile` call. HLSL then reads cbuffer matrices row-major; glam's column-major
   memory is therefore seen as the transpose, which is precisely what `mul(v, M)`
   row-vector math needs. Book shaders unchanged, zero per-frame transposes, matrices
   composed the natural `proj * view * world` way. One rule: *every* shader in the
   project gets the flag.
2. **Transpose on upload:** default packing, write `wvp.transpose()` into the cbuffer.
   Same result, small per-matrix cost, and it's the habit DirectXMath users (and
   Luna's DX12 book code) follow — worth knowing even if you choose option 1.
3. **Edit the shaders** to column-vector style `mul(M, v)`: no flag, no transpose, but
   every book shader needs its `mul` arguments flipped.

### cbuffer mirror structs

```rust
#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
struct Constants {
    world_view_proj: Mat4,   // 64 bytes, fine
    light_dir: Vec4,         // use Vec4 (or Vec3 + explicit f32 pad) in cbuffers
}
```

HLSL packs in 16-byte registers: a `float3` then a `float` share one; two `float3`s
don't. glam's `Vec3` is 12 unpadded bytes — in cbuffer mirrors, prefer `Vec4` or add
explicit `_pad: f32` fields so Rust layout matches HLSL packing. Total `ByteWidth`
must be a multiple of 16 (`size_of::<Constants>()` — round up if needed). Getting
this wrong silently shears your matrices.

---

## Cross-cutting gotchas (read before Chapter 1)

1. **COM lifetimes are automatic.** `windows` wraps every interface in a smart
   pointer: `Drop` = Release, `Clone` = AddRef, `.cast::<T>()?` = QueryInterface. No
   manual `Release()` anywhere — store interfaces in your app struct and let scope
   handle it. Corollary: an interface clone squirreled away somewhere keeps the device
   alive; if the debug layer reports live objects at exit, hunt for a lingering clone.

2. **Everything is `unsafe`.** Every D3D call sits in an `unsafe` block. The idiomatic
   move is a thin layer of small safe wrapper functions (create_device, create_buffer,
   compile_shader...) — which is, not coincidentally, exactly what Hieroglyph3's
   config/helper classes are in C++. Build it as you go, not up front.

3. **HRESULT → `Result`.** Creation calls return `windows::core::Result<()>` with
   out-params typed `Option<*mut Option<T>>` — the "double Option" dance:

   ```rust
   let mut device: Option<ID3D11Device> = None;
   let mut context: Option<ID3D11DeviceContext> = None;
   unsafe {
       D3D11CreateDevice(None, D3D_DRIVER_TYPE_HARDWARE, HMODULE::default(),
           D3D11_CREATE_DEVICE_DEBUG, Some(&[D3D_FEATURE_LEVEL_11_0]),
           D3D11_SDK_VERSION, Some(&mut device), None, Some(&mut context))?;
   }
   let device = device.unwrap();
   ```

   `Present()` returns a raw `HRESULT` — check it with `.ok()?` and handle
   `DXGI_ERROR_DEVICE_REMOVED`/`DEVICE_RESET`.

4. **Debug layer from day one.** `D3D11_CREATE_DEVICE_DEBUG` in debug builds. Most
   "black screen, no error" problems become a one-line warning in the debugger output.
   This substitutes for the validation Hieroglyph3 does manually.

5. **Strings.** Win32 wants UTF-16: `w!("WindowClass")` for literals,
   `HSTRING::from(s)` for runtime strings. Shader entry points and vertex-shader
   semantic names are *ANSI*: `s!("vs_main")`, `s!("POSITION")`. Shader source is
   plain bytes (`include_str!` or `std::fs::read`).

6. **WndProc vs the borrow checker.** The window callback is a free
   `extern "system"` function — it can't capture your app state. Keep it minimal
   (`WM_DESTROY` → `PostQuitMessage`, default the rest) and drive rendering from the
   main loop with `PeekMessageW`, like `Applications/BasicWindow/main.cpp` does. Stash
   state via `SetWindowLongPtrW(GWLP_USERDATA)` only when you genuinely need messages
   to reach app data (resize, input in ch. 3+).

7. **Swap chain model.** The book era used `DXGI_SWAP_EFFECT_DISCARD` (blit model).
   Use `DXGI_SWAP_EFFECT_FLIP_DISCARD` with `BufferCount = 2` — D3D11 still lets you
   treat `GetBuffer(0)` as *the* backbuffer every frame. One consequence: flip-model
   swap chains can't be multisampled; if you later want MSAA, render to an MSAA
   texture and `ResolveSubresource` into the backbuffer.

8. **Depth buffers need typeless formats** once you want to read depth in a shader:
   texture `R24G8_TYPELESS`, DSV `D24_UNORM_S8_UINT`, SRV `R24_UNORM_X8_TYPELESS`.
   For chapters 1–6 a plain `D24_UNORM_S8_UINT` texture is fine; the typeless dance
   matters in ch. 10–11. See `Source/ViewDepthNormal.cpp` for the engine's version.

9. **Input layouts need shader bytecode.** `CreateInputLayout` validates against the
   compiled VS input signature — keep the VS blob alive until after layout creation,
   and make semantic names match exactly (gotcha #5's `s!()`).

10. **Read/write hazards.** A resource can't be bound as SRV while also bound as
    RTV/UAV; D3D silently unbinds and the debug layer warns. When ping-ponging
    (ch. 5, 10), explicitly bind `None` SRVs/UAVs between passes. Hieroglyph3's stage
    state objects exist largely to manage this — you'll manage it by hand.

11. **Nothing is bound by default.** Viewport, primitive topology, render targets —
    set them explicitly. A missing `RSSetViewports` is the classic silent black
    screen.

12. **What not to port.** `ResourceProxyDX11` (int-handle resource + auto-created
    views), `ParameterManagerDX11` (reflection-driven auto-binding), the `Evt*` event
    system, the scene graph, `ScriptManager` (Lua). Where a sample calls
    `m_pParamMgr->SetWorldMatrixParameter(...)`, you will `Map` a cbuffer and
    `bytemuck::bytes_of` a struct into it. That's the whole translation.

---

## Chapter 1 — Overview of Direct3D 11

**Read:** all of it. It's the mental model: device vs. immediate context, DXGI's role,
feature levels, resources vs. views, COM basics (which the `windows` crate then
largely automates for you — read the chapter anyway; DX12 gives the manual version
back).

**Rust deliverable:** a window that clears to a color and presents. Roughly 200–300
lines: window class + `CreateWindowExW` + `PeekMessageW` pump, `D3D11CreateDevice`
(request `D3D_FEATURE_LEVEL_11_0`, debug flag per gotcha #4), `CreateDXGIFactory1` (or
`.cast()` up from the device) → swap chain, backbuffer RTV, then per frame:
`ClearRenderTargetView`, `Present(1, ...)`.

**Reference:**
- `Applications/BasicWindow/main.cpp` — the whole app without engine scaffolding;
  closest in spirit to what you're writing (including the PeekMessage-style loop).
- `Source/Win32Window.cpp` (300 lines) — window creation details.
- `Source/RendererDX11.cpp` → `Initialize()` — device creation, feature-level
  fallback; `CreateSwapChain` further down.
- `Source/SwapChainConfigDX11.cpp` — default swap-chain settings (then apply #7).

**Gotchas:** #3, #5, #6. Handle `WM_SIZE` minimally for now (ignore it) — proper
resize means dropping the RTV, `ResizeBuffers`, recreating views; add it when it
annoys you.

---

## Chapter 2 — Direct3D 11 Resources

**Read:** all of it, carefully. This is the most load-bearing chapter in the book and
the knowledge transfers wholesale to DX12 (where you'll do the same reasoning plus
manual memory management).

Key ideas to extract: the buffer zoo (vertex/index/constant/structured/append-consume/
byte-address), texture dimensionalities and array/mip subresources, `Usage` +
`CPUAccessFlags` combinations (IMMUTABLE vs DEFAULT vs DYNAMIC vs STAGING), and the
four view types (SRV/RTV/DSV/UAV) as the *only* way the pipeline touches resources.

**Rust deliverable:** no new demo. Extend the ch. 1 app: create a depth-stencil
texture + DSV and clear it each frame; create a small DYNAMIC buffer and
`Map`/`Unmap` it; create a STAGING texture, `CopyResource` the backbuffer into it,
read pixels back, and save them with the `image` crate (that's a screenshot feature —
the engine does the same via DirectXTK ScreenGrab in `Source/PipelineManagerDX11.cpp`).

**Reference:** `Source/BufferConfigDX11.cpp` and `Source/Texture2dConfigDX11.cpp` —
each "config" class is just a `D3D11_*_DESC` with good defaults. In Rust, struct
update syntax does most of it: `D3D11_BUFFER_DESC { ByteWidth: n, Usage:
D3D11_USAGE_DYNAMIC, ..Default::default() }` — but steal the engine's *defaults*.

**Gotchas:** the cbuffer struct rules from the math section. Also: `Map` returns a
`RowPitch` that is *not* necessarily `width * bytes_per_pixel` — respect it when
copying texture data either direction.

---

## Chapter 3 — The Rendering Pipeline

**Read:** all of it. Stage-by-stage (IA → VS → tess → GS → SO → RS → PS → OM); skim
the tessellation stages on this pass (ch. 4 re-covers them) and note the GS exists.
Skip nothing about the fixed-function bits: rasterizer state, blend state,
depth-stencil state.

**Rust deliverable:** port **RotatingCube** — the book's real "first render". Vertex +
index buffer for a cube (`#[repr(C)]` vertex struct + bytemuck), input layout, VS/PS
from `RotatingCube.hlsl` **unchanged** (compile with `D3DCOMPILE_PACK_MATRIX_ROW_MAJOR`
per the math section), a cbuffer with world/view/proj, depth buffer on, per-frame
rotation via `Mat4::from_rotation_y`, camera from `camera::lh::view::look_at_mat4` +
`camera::lh::proj::directx::perspective`. The C++ sample also runs a geometry shader;
treat that as an optional second pass once the cube spins (it demonstrates the stage;
the cube doesn't need it).

**Reference:**
- `Applications/RotatingCube/App.cpp` (455 lines) — notably it uses the engine at its
  *thinnest*: raw desc structs for states, explicit buffer creation. The closest
  existing thing to your Rust program. The `m_pParamMgr->SetWorldMatrixParameter`
  calls at the end become your `Map`/`bytes_of`/`Unmap`.
- `Applications/Data/Shaders/RotatingCube.hlsl` — reused as-is.
- `Source/GeometryGeneratorDX11.cpp` — procedural box/sphere/grid vertex data if you'd
  rather generate than hand-write.

**Gotchas:** the math section (this is where a wrong convention pick bites), #9, #11.

**Milestone:** when the cube spins, you have personally implemented everything
Hieroglyph3's 14k-line DX11 layer abstracts. Chapters 4–6 add stages, not
infrastructure.

---

## Chapter 4 — The Tessellation Pipeline (read; implement later in DX12)

**Read:** yes, fully — this is the best conceptual treatment of hardware tessellation
you'll get in either book. Extract: hull shader = control-point phase + patch-constant
phase; the fixed tessellator's domains (tri/quad/isoline) and partitioning schemes;
domain shader as "vertex shader for generated points"; `SV_TessFactor` /
`SV_InsideTessFactor` / `SV_DomainLocation`.

**Why not implement here:** DX11 and DX12 tessellation are the *same hardware feature
with identical HLSL* — same attributes, same system values, same max factor of 64. The
only difference is plumbing: DX11 binds HS/DS on the context (`HSSetShader`/
`DSSetShader` + patch-list topology), DX12 bakes them into the PSO. Luna's DX12 book
(ch. 14) re-covers the basics with worked examples (quad patch, distance-based LOD,
Bézier surface), so implementing in both books is pure duplication. Read Zink for the
*why*, implement in Luna for the *how*.

**Instead of porting:** run the prebuilt **TessellationParams** demo from
`Applications/Bin` while reading — it interactively visualizes every
domain/partitioning/factor combination, which is worth more than a port.

**If you can't resist:** `Applications/BasicTessellation/App.cpp` is only 295 lines +
one shader (`Data/Shaders/BasicTessellation.hlsl`, tri domain). On top of your ch. 3
app it's an afternoon: two more shader stages, topology
`D3D11_PRIMITIVE_TOPOLOGY_3_CONTROL_POINT_PATCHLIST`.

---

## Chapter 5 — The Computation Pipeline

**Read:** all of it. The DX11 compute model — `Dispatch`, `[numthreads]`, thread/group
system values, UAVs on buffers and textures, structured + append/consume buffers,
`groupshared` memory, sync barriers — transfers to DX12 nearly verbatim, and this
chapter assumes less than Luna's compute chapter does. If you stay on DX11, compute is
how you'll do anything simulation- or post-processing-shaped.

**Rust deliverable:** port **BasicComputeShader**: load `Outcrop.png` with
`image::open(...)?.to_rgba8()` (→ texture with initial data; `SysMemPitch = width * 4`),
run `InvertColorCS.hlsl` reading the SRV and writing a second texture through a UAV,
then draw the result with a fullscreen textured pass (`TextureVS.hlsl` /
`TexturePS.hlsl`). Dispatch `width.div_ceil(nx) × height.div_ceil(ny)` groups to cover
the image.

**Reference:** `Applications/BasicComputeShader/App.cpp` (336 lines);
`Applications/Data/Shaders/InvertColorCS.hlsl`; texture in
`Applications/Data/Textures/`. The engine loads it via DirectXTK's WICTextureLoader
(`Source/RendererDX11.cpp` → `LoadTexture`) — your `image`-crate replacement is ~15
lines. Create the output texture with
`BindFlags: D3D11_BIND_UNORDERED_ACCESS | D3D11_BIND_SHADER_RESOURCE`.

**Gotchas:** #10 is the big one — bind `None` UAVs before using that texture as an SRV
for the fullscreen pass, and vice versa each frame. Also remember compute is
`CSSetShader` + `Dispatch` with *no* IA/RS/OM state involved — a separate mental
pipeline.

---

## Chapter 6 — High Level Shading Language

**Read:** yes; **nothing to port** — the chapter is about HLSL itself, and every line
of HLSL in this repo runs unmodified from Rust (with the compile-flag approach,
literally unmodified). Worth absorbing properly: semantics and stage linkage rules,
the cbuffer packing rules (math section, formalized), flow-control attributes, and
intrinsics.

**Toolchain note:** the book (and your port) compiles with FXC (`D3DCompile`,
`vs_5_0`/`ps_5_0`/`cs_5_0`). Luna's DX12 book also uses FXC (SM 5.x); DXC/SM6 comes
later still. So this knowledge doesn't expire at the DX12 boundary.

---

## Decision point

After chapter 6 you've covered devices, resources, every pipeline stage, compute, and
HLSL — the complete D3D11 fundamentals. From here:

- **Jump to Luna DX12:** you'll re-meet everything with explicit memory management,
  PSOs, descriptor heaps, and fences — the `windows` crate covers D3D12 with the same
  patterns (and there the automatic COM lifetimes stop covering for you: resource
  lifetime vs. GPU timeline becomes your problem, which is the point of DX12).
  Skinning and tessellation-in-anger get properly covered there.
- **Stay on DX11 a while:** do the optional chapters below, in order of
  effort-to-payoff.

---

## Optional continuations (if staying with DX11)

### Chapter 10 — Image Processing (best payoff, do first)
Gaussian and bilateral filters as compute shaders, including the brute-force →
separable → `groupshared`-cached optimization progression — the canonical intro to
writing *fast* compute, not just correct compute. Builds directly on your ch. 5 app;
mostly new HLSL (`Data/Shaders/Gaussian*.hlsl`, `Bilateral*.hlsl`) plus a ping-pong
texture pair. Reference: `Applications/ImageProcessor/App.cpp`.

### Chapter 12 — Simulations
**WaterSimulationI** (499 lines): compute-shader heightfield fluid over 16×16 tiles,
then rendered — state-in-buffers simulation. **ParticleStorm**: append/consume
structured buffers + `DrawInstancedIndirect`, i.e. GPU-driven particle count with zero
CPU readback — the most "modern GPU" technique in the book. Both are compute-first;
ch. 5 + 10 prepare you fully.

### Chapter 11 — Deferred Rendering (biggest lift)
G-buffer via multiple render targets, then screen-space light accumulation; the
LightPrepass sample shows the lighter-weight variant. Valuable because Luna's DX12 book
*doesn't* really cover deferred — but it's the largest sample (~2k lines) and wants
scene infrastructure (meshes, many lights) you haven't built. Consider it a standalone
project. Reference: `Applications/DeferredRendering/`, `Data/Shaders/GBuffer*.hlsl`.

---

## Skipped chapters — and why

- **Ch. 7, Multithreaded Rendering / Ch. 13, Multithreaded Paraboloid Rendering:**
  built on D3D11 deferred contexts, which the industry largely skipped; DX12's
  command-list model is different and better, and Luna teaches it natively.
- **Ch. 8, Mesh Rendering:** vertex skinning — Luna's DX12 book has a full skinned-mesh
  chapter; doing it twice adds little.
- **Ch. 9, Dynamic Tessellation:** advanced applications of ch. 4; same "implement
  tessellation once, in DX12" logic applies.
- **Not book content at all** (engine/blog demos — ignore): BasicScripting (Lua),
  BasicScenes, BasicRenderViews, KinectPlayground, Kinect2Playground,
  OculusRiftSample, MFCwithD3D11, GlyphletViewerWPF, Glyphlets, VolumeRendering,
  AmbientOcclusionI, PhysicalRenderingSandbox, ViewFromTheWindow.

---

## Appendix A — Sample ↔ chapter map (this repo)

| Chapter | Samples | Size |
|---|---|---|
| 1 Overview | BasicWindow, BasicApplication | 365 / 249 loc |
| 3 Rendering Pipeline | RotatingCube, ImmediateRenderer | 455 / 400 loc |
| 4 Tessellation Pipeline | BasicTessellation, TessellationParams | 295 loc / — |
| 5 Computation Pipeline | BasicComputeShader | 336 loc |
| 8 Mesh Rendering | SkinAndBones | — |
| 9 Dynamic Tessellation | CurvedPointNormalTriangles, InterlockingTerrainTiles | — |
| 10 Image Processing | ImageProcessor | — |
| 11 Deferred Rendering | DeferredRendering, LightPrepass | ~2k loc |
| 12 Simulations | WaterSimulationI, ParticleStorm | 499 loc / — |
| 13 MT Paraboloid Rendering | MirrorMirror | — |

Shaders for all samples: `Applications/Data/Shaders/` (plain HLSL — with the
compile-flag approach, reusable byte-for-byte). Textures/models: `Applications/Data/`.

## Appendix B — Using the C++ demos alongside

The solution builds with VS2022 (projects retargeted to v143, DirectXTK 2019 via
NuGet); built demos land in `Applications/Bin`. Running the original next to your Rust
port is the fastest way to answer "is my output actually right?" — especially for
TessellationParams (ch. 4 intuition) and the image-processing filters (ch. 10).
