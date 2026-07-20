# Practical Rendering and Computation with Direct3D 11 — Odin Port Guide

A chapter-by-chapter companion for working through *Practical Rendering and Computation
with Direct3D 11* (Zink, Pettineo, Hoxley) by writing each sample fresh in **Odin**
against raw D3D11, instead of porting the Hieroglyph3 engine. The engine source in this
repo is your reference implementation — read it when the book's prose isn't enough, but
don't transliterate it.

**The plan:** Chapters 1–6 are the core path. Chapter 4 is read-and-skim (implement
tessellation once, in Luna's DX12 book). Chapters 10–12 are optional continuations if
you decide to stay with DX11 for a while. Chapters 7–9 and 13 are skipped (rationale at
the bottom).

---

## Sample ↔ chapter map (this repo)

Which C++ sample belongs to which chapter — the thing you'll look up most often:

| Chapter | Samples |
|---|---|
| 1 Overview | BasicWindow, BasicApplication |
| 3 Rendering Pipeline | RotatingCube, ImmediateRenderer |
| 4 Tessellation Pipeline | BasicTessellation, TessellationParams |
| 5 Computation Pipeline | BasicComputeShader |
| 8 Mesh Rendering | SkinAndBones |
| 9 Dynamic Tessellation | CurvedPointNormalTriangles, InterlockingTerrainTiles |
| 10 Image Processing | ImageProcessor |
| 11 Deferred Rendering | DeferredRendering, LightPrepass |
| 12 Simulations | WaterSimulationI, ParticleStorm |
| 13 MT Paraboloid Rendering | MirrorMirror |

Shaders for all samples: `Applications/Data/Shaders/` (plain HLSL, reusable
byte-for-byte). Textures/models: `Applications/Data/`.

---

## Toolchain

Everything you need ships with the Odin compiler — no package manager, no version
matrix to manage:

| Piece | Package | Notes |
|---|---|---|
| D3D11 bindings | `vendor:directx/d3d11` | COM interfaces callable with Odin's `->` operator |
| DXGI (factory, swap chain) | `vendor:directx/dxgi` | |
| Shader compilation | `vendor:directx/d3d_compiler` | FXC, Shader Model 5.0 — same as the book. `vendor:directx/dxc` exists but isn't needed until DX12/SM6. |
| Win32 API | `core:sys/windows` | Window creation, message pump, `L("...")` UTF-16 literals |
| Math | built-in `matrix[4,4]f32` + `core:math/linalg` | See the matrix section below — this is the one area needing real care. The book's row-vector builders it doesn't cover live in `glyph:d3d_math`. |
| Image loading (ch. 5+) | `core:image/png` | Pure-Odin PNG decoder, zero C deps — enough for every texture the book ships. Parse metadata too: sRGB lives in the file's chunks, not the format you pick (gotcha #13). **No DDS support** — see the next row for the one file that needs it. |
| Cube map loading (ch. 3) | *(none — hand-rolled)* | `TropicalSunnyDay.dds` is the only DDS in the samples, and nothing in `core`/`vendor` reads DDS (stb doesn't either). It's the easy case though — legacy uncompressed 32-bit BGRA, 512×512, no mip chain — so it's a 128-byte header plus six flat face blobs, ~28 lines of parsing in `apps/immediate_renderer/skybox.odin`. Converting to six PNGs with `texconv` is possible but not worth it: the cube-texture + SRV creation is the same either way, and you'd trade those 28 lines for six asset files that diverge from the C++ demo. |
| Image saving (screenshots) | `vendor:stb/image` | `core:image/png` is **decode-only** (verified on `dev-2026-07`), so `write_png` handles the `Space`-key screenshots. The prebuilt `stb_image_write.lib` ships in the toolchain's `vendor/stb/lib`, so this C dependency costs no build step. |
| Timing | `core:time` | `tick_now()`/`tick_diff()` replace the engine's QPC `Timer` class |
| File I/O | `core:os` | `read_entire_file` for shader source and model files — it takes an allocator (required, not defaulted) and returns `([]byte, Error)` |
| Callback context | `base:runtime` | `proc "system"` callbacks (the wndproc) start with no Odin context; set `context = runtime.default_context()` before calling anything that allocates. Note `base:`, not `core:`. |
| Tests | `core:testing` | `odin test <pkg>` with `@(test)` procs — worth wiring up for anything numeric, e.g. the matrix helpers |

**One gap worth knowing up front:** there is no drop-in replacement for the engine's
sprite-font renderer. Ten of the samples draw state as an on-screen overlay — mostly
just name and FPS, but three of them show keybind legends and live tessellation
values. The cheap answer is the window title bar: one `SetWindowTextW` call, no
pipeline, and it comfortably holds even TessellationParams' full state. Document
keybinds in a README rather than drawing them. If you do want real text later,
`vendor:stb` has two good options — see Appendix B.

**Rosetta stone:** the official Odin examples repo contains
[`directx/d3d11_minimal_sdl2/d3d11_in_odin.odin`](https://github.com/odin-lang/examples/blob/master/directx/d3d11_minimal_sdl2/d3d11_in_odin.odin)
— 515 lines, a complete textured spinning cube (device, swap chain, depth buffer,
states, constant buffer, texture, draw loop). That's roughly the endpoint of chapters
1–3 in one file. Keep it open in a tab; it demonstrates every idiom this guide
mentions. (It uses SDL2 for the window; you'll use raw Win32 — see chapter 1.)

**Windowing choice:** the official example uses `vendor:sdl2` and extracts the HWND.
For this book, use raw Win32 via `core:sys/windows` instead — chapter 1 is literally
about the Win32/DXGI plumbing, and it's ~80 lines. SDL2/SDL3 remain an escape hatch if window management ever becomes friction.

---

## Matrices: the one section to internalize before writing code

The book's C++ (`Matrix4f`) and its HLSL are both **row-vector**: vertices transform
as `v * M` / `mul(v, M)`, chains compose left-to-right (`World * View * Proj`), and
translation sits in the bottom row of every matrix the book prints. Odin can match
that exactly, so your code reads like the page in front of you.

Odin's matrix types (`matrix[4,4]f32`) default to **column-major storage**, and
`core:math/linalg`'s builders are **column-vector** (`v' = M * v`). Both are one
keyword away from the book's convention: `#row_major` flips the storage, and
`odin_port/glyph/d3d_math` supplies row-vector builders (~10 procs, linalg naming).
Combined with the compile flag the engine already uses, everything lines up:

```odin
import dm "glyph:d3d_math"

Constants :: struct #align (16) {
    world_view_proj: dm.Matrix4f32,   // = #row_major matrix[4,4]f32
}
world := dm.matrix4_rotate_f32(angle, {0, 1, 0}) * dm.matrix4_translate_f32(pos)
constants.world_view_proj = world * view * proj   // the book's order, uploaded as-is
```

Three pieces have to agree, and they do:

1. **Builders** come from `d3d_math`, so matrices are laid out as the book prints
   them — translation in the bottom row.
2. **Storage** is `#row_major`, matching the **packing** the shaders are compiled
   with. This is an FXC flag, not an Odin one: `D3DCOMPILE_PACK_MATRIX_ROW_MAJOR`,
   passed by `ShaderFactoryDX11` in the engine and by `glyph:shader` here. It decides
   whether HLSL reads a cbuffer's 16 floats as the matrix's rows or its columns —
   visible in the generated code, where `mul(v, M)` becomes a `mul`/`mad` chain over
   rows with the flag, and four `dp4`s against columns without it. The general rule:
   the shader sees your matrix *transposed* exactly when field storage differs from
   the packing mode. Match them, as here, and it sees precisely what you built —
   **no transposes anywhere**. Drop the flag and every matrix arrives transposed.
3. **Composition** runs left-to-right, `world * view * proj`, exactly as the C++ does.

Everything then reads like the book: composition order, the printed matrix layouts,
`pos * world` ↔ the shader's `mul(pos, WorldMatrix)`, and even literal indexing —
HLSL `ProjMatrix[3][2]` is Odin `proj[3, 2]`. Two safety properties come free:
`#row_major matrix[4,4]f32` is a **distinct type**, so reaching for a column-vector
linalg builder by mistake is a compile error rather than a silent shear; and there is
no SIMD penalty (measured on `dev-2026-07`: matrix×matrix codegen is
instruction-identical to the column-major default, and `v * M` auto-vectorizes well).

### Cheat sheet: book / C++ → Odin

| Book / C++ (`Matrix4f`, DirectXMath) | Odin |
|---|---|
| `World * View * Proj` | `world * view * proj` — same order |
| `v * M` | `v * m` — built-in, `[4]f32 * dm.Matrix4f32` |
| `RotationMatrixX/Y/Z(a)` | `dm.matrix4_rotate_f32(a, {1,0,0}` / `{0,1,0}` / `{0,0,1})` |
| `TranslationMatrix(x, y, z)` | `dm.matrix4_translate_f32({x, y, z})` |
| `XMMatrixScaling(x, y, z)` | `dm.matrix4_scale_f32({x, y, z})` |
| `PerspectiveFovLHMatrix(fov, aspect, n, f)` | `dm.perspective_fov_lh(fov, aspect, n, f)` |
| `LookAtLHMatrix(eye, at, up)` | `dm.look_at_lh(eye, at, up)` |
| `M.Inverse()` | `dm.inverse(m)` |
| `M.Transpose()` | `linalg.transpose(m)` — accepts `#row_major` |
| transform a point (`XMVector3TransformCoord`) | `([4]f32{p.x, p.y, p.z, 1} * m).xyz` |
| `Vector3f` Normalize / Cross / Dot | `linalg.normalize` / `cross` / `dot` — arrays, convention-free |
| cbuffer matrix field | `dm.Matrix4f32` — pairs with the FXC packing flag (point 2) |
| element access — translation x at `m[3][0]` | `m[3, 0]` — same position |
| HLSL `M[i][j]` | `m[i, j]` — same position |

**The camera-function trap.** Don't reach for `linalg.matrix4_perspective` /
`matrix4_look_at`: they are **OpenGL-convention** — perspective maps depth to −1..1
(D3D needs 0..1) and look_at is −Z-forward. Your cube will be depth-clipped into
oblivion. The LH 0..1-depth versions live in the repo already: `glyph:d3d_math`
ports `Matrix4f::PerspectiveFovLHMatrix` / `PerspectiveOffCenterLH` /
`LookAtLHMatrix` in row-vector form.

Vector operations (`normalize`, `cross`, `dot`, `lerp`, `length`) and `transpose`
carry no convention — use linalg's freely. Matrix *builders* do: always take them
from `d3d_math`, never `linalg`. The distinct `#row_major` type enforces this for
you, so it's a rule the compiler keeps rather than one you have to remember.

One alternative is worth knowing exists, if only to recognize it in other code:
keeping linalg's column-vector matrices throughout and editing every shader to
`mul(M, v)`. That's what the official Odin D3D11 example does. It gives up running
the book's shaders unmodified, which is the whole point here, so this guide doesn't
take that route.

---

## Cross-cutting gotchas (read before Chapter 1)

1. **COM via `->`.** Interface pointers call methods with the arrow operator:
   `device->CreateBuffer(&desc, &init, &buffer)`, `ctx->Release()`. Every
   `Create*`/`Get*` AddRefs what it returns — adopt `defer obj->Release()` for locals
   and release stored interfaces in reverse creation order in your shutdown proc.

2. **Debug layer from day one.** `D3D11.CREATE_DEVICE_FLAGS{.DEBUG}` when creating the
   device (in debug builds). Most "black screen, no error" problems become a one-line
   warning in the debugger output. This substitutes for the validation Hieroglyph3
   does manually.

3. **HRESULT handling.** No exceptions, no panic helper — check returns yourself:
   `hr := device->CreateBuffer(...)` then `assert(windows.SUCCEEDED(hr))` (or a tiny
   `check(hr)` proc that prints and aborts). The one to actually *handle* is
   `Present()` returning `DXGI_ERROR_DEVICE_REMOVED`/`DEVICE_RESET`.

4. **Flags are bit_sets, not OR'd ints.** The vendor bindings turn C flag soup into
   Odin bit_sets and enums: `BindFlags = {.VERTEX_BUFFER}`, `Usage = .DYNAMIC`,
   `CPUAccessFlags = {.WRITE}`, `Map(..., .WRITE_DISCARD, ...)`. Pleasantly, invalid
   combinations become type errors.

5. **Wide strings.** Win32 `W` APIs want UTF-16: `windows.L("MyWindowClass")` for
   literals, `windows.utf8_to_wstring(s)` for runtime strings. Shader source stays
   UTF-8 (embed it as an Odin raw string literal or `os.read_entire_file`).

6. **cbuffer packing.** HLSL packs in 16-byte registers: a `float3` then a `float`
   share one; two `float3`s don't. Mirror cbuffers as `struct #align (16)` with
   explicit `_pad: f32` fields where needed, and `ByteWidth` must be a multiple of 16.
   Getting this wrong silently shears your matrices. **Odin-specific trap:**
   `matrix[4,4]f32` has **32-byte** alignment, so a matrix that should sit at byte
   offset 16 (say, after a `float4`) gets silently pushed to 32 — every field after it
   is wrong. Declare such a field as `[16]f32` and assign `transmute([16]f32)m`, or
   order the struct so matrices land on 32-byte boundaries. `#assert(size_of(T) == N)`
   on every cbuffer struct catches this at compile time.

7. **Swap chain model.** The book era used `DXGI_SWAP_EFFECT_DISCARD` (blit model).
   Use `.FLIP_DISCARD` with `BufferCount = 2` — D3D11 still lets you treat
   `GetBuffer(0)` as *the* backbuffer every frame. One consequence: flip-model swap
   chains can't be multisampled; if you later want MSAA, render to an MSAA texture and
   `ResolveSubresource` into the backbuffer.

8. **Depth buffers need typeless formats** once you want to read depth in a shader:
   texture `R24G8_TYPELESS`, DSV `D24_UNORM_S8_UINT`, SRV `R24_UNORM_X8_TYPELESS`.
   For chapters 1–6 a plain `D24_UNORM_S8_UINT` texture is fine; the typeless dance
   matters in ch. 10–11. See `Source/ViewDepthNormal.cpp` for the engine's version.

9. **Input layouts need shader bytecode.** `CreateInputLayout` validates against the
   compiled VS input signature — keep the VS blob alive until after layout creation,
   and make semantic names match exactly. The layout must supply *every* element the
   signature declares, including ones the shader body never reads (the skybox VS
   declares TEXCOORD0 and uses only POSITION; omitting it fails with `E_INVALIDARG`).

10. **Read/write hazards.** A resource can't be bound as SRV while also bound as
    RTV/UAV; D3D silently unbinds and the debug layer warns. When ping-ponging
    (ch. 5, 10), explicitly set nil SRVs/UAVs between passes. Hieroglyph3's stage
    state objects exist largely to manage this — you'll manage it by hand.

11. **Nothing is bound by default.** Viewport, primitive topology, render targets —
    set them explicitly. A missing `RSSetViewports` is the classic silent black screen.

12. **Register assignment is per stage, and reservations count even when unused.**
    Without explicit `register()` annotations, FXC numbers each stage's cbuffers from
    b0 independently, in declaration order, skipping ones that stage doesn't use — so
    the same `Transforms` cbuffer can be b0 in the VS and b1 in the GS. Textures and
    buffers are worse: an explicit `register(t0)` **reserves** that slot even if the
    entry point never touches that resource, pushing an unannotated
    `StructuredBuffer` in the same file to t1. The symptom is a shader that reads
    zeros with no warning from anything. Hieroglyph3 never hits this because
    `ParameterManagerDX11` binds by reflection; binding by hand, check the assignments
    (`fxc /dumpbin`, or reflect via `D3DReflect`) rather than assuming.

13. **sRGB lives in the image file's metadata, not the format you pick.** WIC (and
    therefore DirectXTK's `WICTextureLoader`, which the engine uses) inspects a PNG's
    `sRGB`/`gAMA` chunks and selects an `_SRGB` texture format when they say so. The
    book's data files carry that metadata, so a `core:image/png` loader that always
    creates plain `UNORM` leaves every sampled pixel off by a gamma curve — an error
    that looks like "slightly wrong lighting", never like a bug. Read the chunks
    (`png.load(..., {.return_metadata})`) and pick the format accordingly.

14. **UAV counters are invisible from the CPU.** Append/consume and counter UAVs keep
    their count inside the *view*, and there is no getter. You can only write it via
    the initial-counts array passed to `CSSetUnorderedAccessViews` (a value resets it;
    `0xffffffff` means "leave alone") and read it via `CopyStructureCount`, which
    writes 4 bytes into a buffer — either a constant buffer for a shader to read, or a
    `MiscFlags = {.DRAWINDIRECT_ARGS}` buffer feeding `DrawInstancedIndirect` so the
    draw size never round-trips to the CPU. Structured buffers additionally need
    `MiscFlags = {.BUFFER_STRUCTURED}` *and* a matching `StructureByteStride`.

15. **What not to port.** `ResourceProxyDX11` (int-handle resource + auto-created
    views), `ParameterManagerDX11` (reflection-driven auto-binding), the `Evt*` event
    system, the scene graph, `ScriptManager` (Lua). Where a sample calls
    `m_pParamMgr->SetWorldMatrixParameter(...)`, you will `Map` a cbuffer and write a
    struct through the pointer. That's the whole translation.

---

## Chapter 1 — Overview of Direct3D 11

**Read:** all of it. It's the mental model: device vs. immediate context, DXGI's role,
feature levels, resources vs. views, COM basics.

**Odin deliverable:** a window that clears to a color and presents. Roughly 200–300
lines: `windows.RegisterClassW`/`CreateWindowExW` + message pump from
`core:sys/windows`, `d3d11.CreateDevice` (request `._11_0`, add the debug flag), query
up to `IDXGIFactory` from the device (`dxgi_device->GetAdapter` → `GetParent`) or
`CreateDXGIFactory1`, create the swap chain, backbuffer RTV, then per frame:
`ClearRenderTargetView`, `Present(1, 0)`.

**Reference:**
- `Applications/BasicWindow/main.cpp` — the whole app without engine scaffolding;
  closest in spirit to what you're writing.
- `Source/Win32Window.cpp` (300 lines) — window creation details.
- `Source/RendererDX11.cpp` → `Initialize()` — device creation, feature-level
  fallback; `CreateSwapChain` further down.
- The official Odin example's device/swap-chain section — same calls, Odin syntax.

**Gotchas:** #5 (wide strings everywhere here), #7. Handle `WM_SIZE` minimally for now
(ignore it) — proper resize means releasing the RTV, `ResizeBuffers`, recreating views;
add it when it annoys you.

---

## Chapter 2 — Direct3D 11 Resources

**Read:** all of it, carefully. This is the most load-bearing chapter in the book and
the knowledge transfers wholesale to DX12 (where you'll do the same reasoning plus
manual memory management).

Key ideas to extract: the buffer zoo (vertex/index/constant/structured/append-consume/
byte-address), texture dimensionalities and array/mip subresources, `Usage` +
`CPUAccessFlags` combinations (IMMUTABLE vs DEFAULT vs DYNAMIC vs STAGING), and the
four view types (SRV/RTV/DSV/UAV) as the *only* way the pipeline touches resources.

**Odin deliverable:** no new demo. Extend the ch. 1 app: create a depth-stencil
texture + DSV and clear it each frame; create a small DYNAMIC buffer and
`Map`/`Unmap` it; create a STAGING texture, `CopyResource` the backbuffer into it, and
read pixels back (that's also how screenshots work — write them out with
`core:image/png` or stb).

**Reference:** `Source/BufferConfigDX11.cpp` and `Source/Texture2dConfigDX11.cpp` —
each "config" class is just a `D3D11_*_DESC` with good defaults; steal the defaults as
small Odin helper procs that return filled desc structs (Odin's struct literals with
named fields make these barely necessary, but the *defaults* are the value).

**Gotchas:** #6, #8. Also: `Map` returns a `RowPitch` that is *not* necessarily
`width * bytesPerPixel` — respect it when copying texture data either direction.

---

## Chapter 3 — The Rendering Pipeline

**Read:** all of it. Stage-by-stage (IA → VS → tess → GS → SO → RS → PS → OM); skim
the tessellation stages on this pass (ch. 4 re-covers them) and note the GS exists.
Skip nothing about the fixed-function bits: rasterizer state, blend state,
depth-stencil state.

**Odin deliverable:** port **RotatingCube** — the book's real "first render". Vertex +
index buffer for a cube, input layout, VS/PS from `RotatingCube.hlsl` **unchanged**
(this is where the matrix setup pays off), a cbuffer struct with `#row_major` world/view/proj
fields, depth buffer on, per-frame rotation via `d3d_math.matrix4_rotate_f32`, camera
from `d3d_math`'s LH helpers. The C++ sample also runs a geometry shader; treat
that as an optional second pass once the cube spins (it demonstrates the stage; the
cube doesn't need it).

**Reference:**
- `Applications/RotatingCube/App.cpp` (455 lines) — notably it uses the engine at its
  *thinnest*: raw desc structs for states, explicit buffer creation. The closest
  existing thing to your Odin program. The `m_pParamMgr->SetWorldMatrixParameter`
  calls at the end become your `Map`/struct-write/`Unmap`.
- `Applications/Data/Shaders/RotatingCube.hlsl` — reused as-is.
- `Source/Matrix4f.cpp` → `PerspectiveFovLHMatrix`, `LookAtLHMatrix`,
  `RotationMatrixY` — your `camera.odin` source material.
- `Source/GeometryGeneratorDX11.cpp` — procedural box/sphere/grid vertex data if you'd
  rather generate than hand-write.
- The official Odin example — the same program modulo shader conventions; diff against
  it when stuck.

**The chapter's second sample, ImmediateRenderer**, is worth doing after the cube: it
adds a skybox, which is where cube maps and `TEXTURECUBE` SRVs enter. `App.cpp:222`
loads `TropicalSunnyDay.dds` through DirectXTK's `DDSTextureLoader`; the Odin side
hand-parses it in `apps/immediate_renderer/skybox.odin` (see the toolchain table's
cube-map row for why). The shader trick is worth the port on its own —
`Skybox.hlsl` pushes positions to the far plane via `.xyww` and samples the cube by
direction, with depth compare `LESS_EQUAL` so it fills exactly the pixels depth never
touched.

**Gotchas:** the whole matrix section, #6, #9, #11.

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
`._3_CONTROL_POINT_PATCHLIST`.

---

## Chapter 5 — The Computation Pipeline

**Read:** all of it. The DX11 compute model — `Dispatch`, `[numthreads]`, thread/group
system values, UAVs on buffers and textures, structured + append/consume buffers,
`groupshared` memory, sync barriers — transfers to DX12 nearly verbatim, and this
chapter assumes less than Luna's compute chapter does. If you stay on DX11, compute is
how you'll do anything simulation- or post-processing-shaped.

**Odin deliverable:** port **BasicComputeShader**: load `Outcrop.png` with
`core:image/png` (→ texture with initial data), run `InvertColorCS.hlsl` reading the
SRV and writing a second texture through a UAV, then draw the result with a fullscreen
textured pass (`TextureVS.hlsl` / `TexturePS.hlsl`). Dispatch
`ceil(width/Nx) × ceil(height/Ny)` groups to cover the image.

**Reference:** `Applications/BasicComputeShader/App.cpp` (336 lines);
`Applications/Data/Shaders/InvertColorCS.hlsl`; texture in
`Applications/Data/Textures/`. The engine loads it via DirectXTK's WICTextureLoader
(`Source/RendererDX11.cpp` → `LoadTexture`) — your `core:image/png` replacement is
~20 lines (mind `RowPitch` in the initial-data struct, and convert to RGBA8 if the
PNG is RGB). Create the output texture with
`BindFlags = {.UNORDERED_ACCESS, .SHADER_RESOURCE}`.

**Gotchas:** #10 is the big one — set nil UAVs before binding that texture as an SRV
for the fullscreen pass, and vice versa each frame. Also remember compute is
`CSSetShader` + `Dispatch` with *no* IA/RS/OM state involved — a separate mental
pipeline.

---

## Chapter 6 — High Level Shading Language

**Read:** yes; **nothing to port** — the chapter is about HLSL itself, and every line
of HLSL in this repo runs from Odin literally unmodified.
Worth absorbing properly: semantics and stage linkage rules, the cbuffer packing rules
(gotcha #6 formalized), flow-control attributes, and intrinsics.

**Toolchain note:** the book (and your port) compiles with FXC
(`d3d_compiler.Compile`, `vs_5_0`/`ps_5_0`/`cs_5_0`). Luna's DX12 book also uses FXC
(SM 5.x); DXC/SM6 comes later still. So this knowledge doesn't expire at the DX12
boundary.

---

## Decision point

After chapter 6 you've covered devices, resources, every pipeline stage, compute, and
HLSL — the complete D3D11 fundamentals. From here:

- **Jump to Luna DX12:** you'll re-meet everything with explicit memory management,
  PSOs, descriptor heaps, and fences (`vendor:directx/d3d12` + `dxc` are already in
  the toolchain). Skinning and tessellation-in-anger get properly covered there.
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

## Appendix A — Using the C++ demos alongside

The solution builds with VS2022 (projects retargeted to v143, DirectXTK 2019 via
NuGet); built demos land in `Applications/Bin`. Running the original next to your Odin
port is the fastest way to answer "is my output actually right?" — especially for
TessellationParams (ch. 4 intuition) and the image-processing filters (ch. 10).

---

## Appendix B — Text rendering, if you want it

The title bar covers this port's needs, so nothing here is implemented. But the
options are better than they first appear, and the C++ is a worse guide than you'd
expect.

**What the engine actually does.** `SpriteFontDX11::Initialize` uses **GDI+** (not
GDI) — `Gdiplus::Font`, `MeasureString`, `DrawString` — to rasterize `'!'`..`'~'`
once into a 1024-wide atlas, measuring each glyph's blank space to derive tight
character rects. After startup GDI+ is gone; the per-frame path is plain D3D11
instanced quads through `Sprite.hlsl`. So the dated part is the *atlas baker*, not
the renderer. Porting it as-is means ~1,020 lines (`SpriteFontDX11`,
`SpriteRendererDX11`, `SpriteVertexDX11`, `SpriteFontLoaderDX11`) — and Odin has no
GDI+ bindings, so ~290 of those lines would mean hand-writing COM bindings for a
2001-era API. Don't. Replace the baker instead.

**`vendor:stb/easy_font`** is the small option. It's a pure-Odin source port, no
`foreign import` and no `.lib` — it pulls in only `core:math` and `core:mem`.
`print(x, y, text, color, quads[:])` fills a buffer of 64-byte `Quad`s (four
`Vertex{v: [3]f32, c: [4]u8}` corners) in screen-space pixels. There are **no
texture coordinates**, because there's no atlas and no texture: you're drawing
colored quads. That erases the whole font-asset problem — nothing to ship, nothing
to bake. A `glyph:text` package around it is roughly 180 lines (inline HLSL mapping
pixels to NDC, dynamic vertex buffer, static index buffer, alpha blend, depth off),
following the same inline-shader pattern `BLIT_HLSL` already uses in
`deferred_rendering` and `light_prepass`. The font is chunky and wireframe-ish —
fine for a keybind legend, not for anything you want to look designed.

**`vendor:stb/truetype`** is the real option, ~300 lines. `PackBegin` /
`PackFontRange` / `PackEnd` bake a proper atlas from a `.ttf` and
`GetPackedQuad` hands back positioned, textured quads. Note it calls stb_rect_pack
*internally* — you don't drive `vendor:stb/rect_pack` yourself. Costs a link
dependency (`stb_truetype.lib`, prebuilt in the toolchain's `vendor/stb/lib`) and a
decision about where the font file comes from; the C++ asks for `Consolas` by name,
so the equivalent is loading `C:\Windows\Fonts\consola.ttf`.

**DirectWrite** is the modern answer to "what replaced GDI+", and the wrong tool
here: there are no DirectWrite or Direct2D bindings in Odin, and drawing DWrite text
onto a D3D11 target normally goes through Direct2D interop — a D2D device, a
DXGI-shared surface, `BeginDraw`/`EndDraw` around your own rendering. That's more
novel COM plumbing than the GDI+ path you were trying to escape.

**[Slug](https://terathon.com/blog/decade-slug.html)** renders glyph outlines
directly from Bézier data in the pixel shader — sharp at any magnification, no atlas,
no baked resolution. Lengyel has dedicated the patent to the public domain and the
HLSL is available, which makes it genuinely viable now. But outline extraction, curve
preprocessing, and band construction are still on you, and that's the bulk of the
work. A project in its own right, not a step in porting this book.
