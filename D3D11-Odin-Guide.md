# Practical Rendering and Computation with Direct3D 11 — Odin Port Guide

A chapter-by-chapter companion for working through *Practical Rendering and Computation
with Direct3D 11* (Zink, Pettineo, Hoxley) by writing each sample fresh in **Odin**
against raw D3D11, instead of porting the Hieroglyph3 engine. The engine source in this
repo is your reference implementation — read it when the book's prose isn't enough, but
don't transliterate it.

**Suggested route:** Chapters 1–6 are the core path. If you plan to move on to
Luna's DX12 book, you can read chapter 4 here and implement tessellation there;
chapters 10–12 are useful continuations. If this is your primary rendering book,
implementing tessellation and skinning here is equally reasonable. The later
chapter notes explain the choices rather than prescribing a single curriculum.

**Reference implementations:** `odin_port/` contains reference ports of the samples
below, MirrorMirror excepted. The demos have been tested, but have documented
limitations: consult [KNOWN_ISSUES.md](KNOWN_ISSUES.md) alongside the per-app notes
and controls in [odin_port/README.md](odin_port/README.md). Where older comments or
status notes conflict with the audited issue record, use that record and the C++
implementation to understand the difference. The suggested route concerns what
you write yourself; the other ports remain available to study.

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
| 13 MT Paraboloid Rendering | MirrorMirror *(no reference port — see Further chapters)* |

Shaders for all samples: `Applications/Data/Shaders/` (plain HLSL, reusable
byte-for-byte). Textures/models: `Applications/Data/`.

---

## Toolchain

The Odin compiler includes the language packages and bindings used below. Running
these Windows samples also needs the relevant system DLLs, and debug builds need
the Direct3D debug layer. On current Windows, enable the **Graphics Tools**
optional feature for that layer; it does not ship as part of Odin. See
[Microsoft's software-layer documentation](https://learn.microsoft.com/en-us/windows/win32/direct3d11/overviews-direct3d-11-devices-layers).
The repository's recipes use Git Bash and `just`;
see [Build & run](odin_port/README.md#build--run). Package details below describe
the local toolchain; check your compiler version if an API differs.

| Piece | Package | Notes |
|---|---|---|
| D3D11 bindings | `vendor:directx/d3d11` | COM interfaces callable with Odin's `->` operator |
| DXGI (factory, swap chain) | `vendor:directx/dxgi` | |
| Shader compilation | `vendor:directx/d3d_compiler` | FXC, Shader Model 4 or 5 according to the sample's feature level. Keep the C++ entry points and profiles together. `vendor:directx/dxc` is available for later SM6 work. |
| Win32 API | `core:sys/windows` | Window creation, message pump, `L("...")` UTF-16 literals |
| Math | built-in `matrix[4,4]f32` + `core:math/linalg` | See the matrix section below — this is the one area needing real care. The book's row-vector builders it doesn't cover live in `glyph:d3d_math`. |
| Image loading (ch. 5+) | `core:image/png` | Pure-Odin PNG decoder for the PNG assets used here. Read metadata to match the reference loader's sRGB choice (gotcha #13). DDS needs a separate loader. |
| Cube map loading (ch. 3) | Sample-specific DDS reader | `TropicalSunnyDay.dds` is legacy uncompressed 32-bit BGRA, 512×512, with six faces and no mip chain. See `odin_port/apps/immediate_renderer/skybox.odin`. This is a reader for that asset's layout, not a general DDS decoder; validate dimensions and payload length before creating the cube texture. |
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
— a complete textured spinning cube (device, swap chain, depth buffer,
states, constant buffer, texture, draw loop). That's roughly the endpoint of chapters
1–3 in one file. Keep it open in a tab; it demonstrates every idiom this guide
mentions. (It uses SDL2 for the window; you'll use raw Win32 — see chapter 1.)

**Windowing choice:** the official example uses `vendor:sdl2` and extracts the HWND.
For this book, use raw Win32 via `core:sys/windows` instead — chapter 1 is literally
about the Win32/DXGI plumbing, and it's ~80 lines. SDL2/SDL3 remain an escape hatch if window management ever becomes friction.

---

## Matrices: the one section to internalize before writing code

Quick reference — matching conventions let you upload the matrices without a transpose:

|  | CPU (DirectXMath → your Odin) | GPU (HLSL in this book) |
|---|---|---|
| **Vector convention** | Row-vector mathematics: `v * M`, chains left-to-right (`World * View * Proj`), translation in the bottom row. `Matrix4f` computes this convention despite its surprising `M * v` operator spelling; Odin uses `glyph:d3d_math` builders and `v * m`. | Row-vector, written explicitly in these shaders as `mul(v, M)`. This is an expression in the shader, not a compiler setting. |
| **Matrix storage** | Row-major. `Matrix4f` stores rows contiguously; Odin's `#row_major matrix[4,4]f32` does the same (plain `matrix[4,4]f32` would be column-major). | Row-major, but *not* declared in the HLSL — no shader in the book uses the `row_major` keyword. HLSL's default is column-major; the engine flips it globally with the FXC flag `D3DCOMPILE_PACK_MATRIX_ROW_MAJOR` (`ShaderFactoryDX11.cpp`, and `glyph:shader` here). |

The two rows are independent knobs. **Vector convention** decides the math you write;
**storage** decides how those 16 floats are read back out of the cbuffer. Storage
only has to agree *across* the CPU/GPU boundary — mismatch it and every matrix
arrives transposed, regardless of the math.

The book's C++ (`Matrix4f`) and these shaders use **row-vector mathematics**.
Chains compose left-to-right (`World * View * Proj`), with translation in the
bottom row. One syntax trap matters when reading the source:
[`Matrix4f::operator*(Vector4f)`](Source/Matrix4f.cpp#L755) spells the operation
`M * v` but computes row-vector multiplication. Its Odin equivalent is `v * m`,
matching HLSL's `mul(v, M)`; copying the C++ operator order literally is wrong.

Odin's matrix types (`matrix[4,4]f32`) default to **column-major storage**, and
`core:math/linalg`'s builders are **column-vector** (`v' = M * v`).
`#row_major` changes storage; `odin_port/glyph/d3d_math` supplies builders for the
row-vector mathematical convention. These are separate choices.
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
HLSL `ProjMatrix[3][2]` is Odin `proj[3, 2]`. One useful type check is:
`#row_major matrix[4,4]f32` is a **distinct type**, so a column-major
linalg result cannot be assigned directly to that field. An explicit conversion
can still preserve the wrong mathematical convention. The helpers explain why
their `transmute` preserves bytes while an ordinary conversion preserves elements.

### Cheat sheet: book / C++ → Odin

| Book / C++ (`Matrix4f`, DirectXMath) | Odin |
|---|---|
| `World * View * Proj` | `world * view * proj` — same order |
| `Matrix4f M * Vector4f v` (row-vector math) | `v * m` — built-in, `[4]f32 * dm.Matrix4f32` |
| `RotationMatrixX/Y/Z(a)` | `dm.matrix4_rotate_f32(a, axis)` with axis `{1,0,0}`, `{0,1,0}`, or `{0,0,1}` |
| `TranslationMatrix(x, y, z)` | `dm.matrix4_translate_f32({x, y, z})` |
| `XMMatrixScaling(x, y, z)` | `dm.matrix4_scale_f32({x, y, z})` |
| `PerspectiveFovLHMatrix(fov, aspect, n, f)` | `dm.perspective_fov_lh(fov, aspect, n, f)` |
| `LookAtLHMatrix(eye, at, up)` | `dm.look_at_lh(eye, at, up)` |
| `M.Inverse()` | `dm.inverse(m)` |
| `M.Transpose()` | `linalg.transpose(m)` — accepts `#row_major` |
| affine point transform | `([4]f32{p.x, p.y, p.z, 1} * m).xyz` |
| projective point transform (`XMVector3TransformCoord`) | Compute `q := [4]f32{p.x, p.y, p.z, 1} * m`, then `q.xyz / q.w`; a finite result requires nonzero `q.w`. |
| `Vector3f` Normalize / Cross / Dot | `linalg.normalize0` / `linalg.cross` / `linalg.dot`; `normalize0` preserves the C++ helper's zero-input behavior. |
| cbuffer matrix field | `dm.Matrix4f32` — pairs with the FXC packing flag (point 2) |
| element access — translation x at `m[3][0]` | `m[3, 0]` — same position |
| HLSL `M[i][j]` | `m[i, j]` — same position |

**The camera-function trap.** Don't reach for `linalg.matrix4_perspective` /
`matrix4_look_at`: they are **OpenGL-convention** — perspective maps depth to −1..1
(D3D needs 0..1) and look_at is −Z-forward. Your cube will be depth-clipped into
oblivion. The LH 0..1-depth versions live in the repo already: `glyph:d3d_math`
ports `Matrix4f::PerspectiveFovLHMatrix` / `PerspectiveOffCenterLH` /
`LookAtLHMatrix` in row-vector form.

Vector operations do not encode row/column matrix conventions, but their edge
cases still matter. `Vector3f::Normalize` leaves zero unchanged; use
`linalg.normalize0` to match it, and ordinary `normalize` only for proven nonzero
inputs. Take matrix builders from `d3d_math` to preserve the book's convention.

One alternative is worth knowing exists, if only to recognize it in other code:
keeping linalg's column-vector matrices throughout and editing every shader to
`mul(M, v)`. That's what the official Odin D3D11 example does. It gives up running
the book's shaders unmodified, which is the whole point here, so this guide doesn't
take that route.

---

## Cross-cutting gotchas (read before Chapter 1)

1. **COM via `->`.** Interface pointers call methods with the arrow operator:
   `device->CreateBuffer(&desc, &init, &buffer)`, `ctx->Release()`. Successful
   creation and interface-query calls generally return an owned COM reference;
   calls such as `GetDesc` merely copy data. Check each API's ownership contract.
   Register `defer obj->Release()` immediately after acquiring a local interface,
   and release stored interfaces in your shutdown proc. A constructor must also
   release partial results when a later step fails.

2. **Debug layer from day one.** `D3D11.CREATE_DEVICE_FLAGS{.DEBUG}` when creating the
   device (in debug builds). Most "black screen, no error" problems become a one-line
   warning in the debugger output. This complements HRESULT checks and does not
   establish that a successful frame matches the reference.

3. **HRESULT handling.** Check creation, mapping, resize, and presentation results.
   For a small demo, reporting failure, cleaning up, and exiting is sufficient;
   recovery is an optional extension. Do not continue drawing after failed resize
   leaves missing views. `Present` can report device removal or reset, which also
   needs an explicit decision rather than silently continuing.

4. **Flags are bit_sets, not OR'd ints.** The vendor bindings turn C flag soup into
   Odin bit_sets and enums: `BindFlags = {.VERTEX_BUFFER}`, `Usage = .DYNAMIC`,
   `CPUAccessFlags = {.WRITE}`, `Map(..., .WRITE_DISCARD, ...)`. These types catch
   flags from the wrong family, but cannot enforce every D3D contract:
   `{.CONSTANT_BUFFER, .VERTEX_BUFFER}` is expressible but API-invalid. Keep the
   HRESULT and debug-layer checks.

5. **Wide strings.** Win32 `W` APIs want UTF-16: `windows.L("MyWindowClass")` for
   literals, `windows.utf8_to_wstring(s)` for runtime strings. Shader source stays
   UTF-8 (embed it as an Odin raw string literal or `os.read_entire_file`). Runtime
   string conversions and `fmt.tprintf` can use the temporary allocator. Scope or
   reset scratch allocations after their last use, including repeated title changes
   and screenshots; do not reset while a retained slice still points into them.

6. **cbuffer packing.** HLSL packs in 16-byte registers: a `float3` then a `float`
   share one; two `float3`s don't. Mirror cbuffers as `struct #align (16)` with
   explicit `_pad: f32` fields where needed, and `ByteWidth` must be a multiple of 16.
   A packing mismatch changes what the shader reads. Check
   `#assert(size_of(T) == N)` and critical `#assert(offset_of(T, field) == N)`
   values against HLSL packing. Total size alone can hide an incorrect field offset.
   Do not assume a fixed matrix alignment across compiler versions: on the tested
   Windows x64 `dev-2026-09-nightly:a2fb372`, both plain and `#row_major`
   `matrix[4,4]f32` have 4-byte alignment. A matrix after a `[4]f32` field starts
   at byte 16 on that compiler. If the native layout does not match your cbuffer,
   explicit padding or a `[16]f32` field assigned with `transmute([16]f32)m` can
   make the representation explicit; verify its offsets too.

7. **Swap chain model.** Use `.DISCARD` to match the reference port. For swap-chain
   creation, obtain the factory through the D3D device's DXGI adapter, or retain
   the factory used to select that adapter; a fresh unrelated factory is not
   interchangeable. An optional modernization is `.FLIP_DISCARD`: it needs a
   supported non-sRGB swap-chain format (use an sRGB RTV when appropriate), at
   least two buffers, and rebinding the backbuffer render target after `Present`.
   Flip swap chains cannot be multisampled; render MSAA to a separate texture and
   resolve it. See [Microsoft's flip-model guidance](https://devblogs.microsoft.com/directx/dxgi-flip-model/).
   With discard presentation, capture before `Present` for dependable screenshots;
   the current C++ and Odin samples capture afterward, an inherited limitation.

8. **Depth buffers need typeless formats** once you want to read depth in a shader:
   texture `R24G8_TYPELESS`, DSV `D24_UNORM_S8_UINT`, SRV `R24_UNORM_X8_TYPELESS`.
   For chapters 1–6 a plain `D24_UNORM_S8_UINT` texture is fine; the typeless dance
   matters in ch. 10–11. See `Source/ViewDepthNormal.cpp` for the engine's version.

9. **Input layouts need shader bytecode.** `CreateInputLayout` validates against the
   compiled VS input signature — keep the VS blob alive until after layout creation,
   and match the user-supplied semantics in that compiled signature. Do not infer
   the layout solely from which source fields appear to be used; inspect the
   compiled signature. System-generated inputs such as `SV_VertexID` do not need
   vertex-buffer elements.

10. **Read/write hazards.** Overlapping subresources cannot be bound for SRV reads
    and RTV/UAV writes simultaneously; D3D unbinds conflicting views and the debug
    layer warns. When ping-ponging
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

13. **Match the reference texture's color-space interpretation.** WIC (and
    therefore DirectXTK's `WICTextureLoader`, which the engine uses) inspects a PNG's
    `sRGB`/`gAMA` chunks and selects an `_SRGB` texture format when they say so. The
    supplied PNGs can carry that metadata, so always choosing plain `UNORM` can
    change shader reads. Read the chunks (`png.load(..., {.return_metadata})`) and
    choose the matching format. The view format determines whether the GPU applies
    sRGB conversion; metadata only informs the loader's choice.

    Mip generation is a separate choice. The repository's C++ `LoadTexture` passes
    a context but a null SRV output to DirectXTK, which disables its automatic mip
    generation. The single-mip Odin PNG loader matches that behavior. Generating
    mips would be an optional quality improvement; see `KI-007` in
    [KNOWN_ISSUES.md](KNOWN_ISSUES.md).

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

**Odin deliverable:** a window that clears to a color and presents. Use
`windows.RegisterClassW`/`CreateWindowExW` and a message pump from
`core:sys/windows`. Create a D3D device at `._10_0` to match BasicApplication,
query its DXGI interface, then follow `GetAdapter` → `GetParent` to its factory.
Create the swap chain and backbuffer RTV, then clear and present each frame.
The C++ uses sync interval 0; interval 1 is an optional choice to wait for vertical
sync. Later samples request higher feature levels where their shaders require them.

**Reference:**

- `Applications/BasicWindow/main.cpp` — the whole app without engine scaffolding;
  closest in spirit to what you're writing.
- `Source/Win32Window.cpp` — window creation details.
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
four view types (SRV/RTV/DSV/UAV). These describe resource access for shader reads
and render/depth/unordered outputs; vertex, index, and constant buffers bind
directly rather than through those views.

**Odin deliverable:** no new demo. Extend the ch. 1 app: create a depth-stencil
texture + DSV and clear it each frame; create a small DYNAMIC buffer and
`Map`/`Unmap` it; create a STAGING texture, `CopyResource` the backbuffer into it, and
read pixels back (that's also how screenshots work — write them out with
`vendor:stb/image.write_png`; `core:image/png` only decodes).

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
index buffer for a cube, input layout, and VS/GS/PS from `RotatingCube.hlsl`
**unchanged**. Its `Transforms` cbuffer contains one combined
`WorldViewProjMatrix`; upload `world * view * proj` in `#row_major` storage and
bind it to the geometry stage. Keep depth enabled and use the `d3d_math` builders.
The VS only forwards attributes; the GS offsets each face and transforms its
vertices. It is required for the unchanged shader to produce the reference cube.
A VS-only introductory exercise is possible if you explicitly move the transform
into a modified VS, then restore the original shader for comparison.

**Reference:**

- `Applications/RotatingCube/App.cpp` — notably it uses the engine at its
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
adds a skybox, which is where cube maps and `TEXTURECUBE` SRVs enter. Its `App.cpp`
loads `TropicalSunnyDay.dds` through DirectXTK's `DDSTextureLoader`; the Odin side
hand-parses it in `odin_port/apps/immediate_renderer/skybox.odin` (see the toolchain table's
cube-map row for why). The shader trick is worth the port on its own —
`Skybox.hlsl` pushes positions to the far plane via `.xyww` and samples the cube by
direction, with depth compare `LESS_EQUAL` so it fills exactly the pixels depth never
touched.

**Gotchas:** the whole matrix section, #6, #9, #11.

**Milestone:** when the cube spins, you have implemented the basic resource and
draw path that the engine wraps. Later samples extend both pipeline stages and
resource management, including compute outputs and multiple render targets.

---

## Chapter 4 — The Tessellation Pipeline

**Read:** yes, fully — this is the best conceptual treatment of hardware tessellation
you'll get in either book. Extract: hull shader = control-point phase + patch-constant
phase; the fixed tessellator's domains (tri/quad/isoline) and partitioning schemes;
domain shader as "vertex shader for generated points"; `SV_TessFactor` /
`SV_InsideTessFactor` / `SV_DomainLocation`.

**If you plan to move to DX12:** DX11 and DX12 tessellation are the *same hardware feature
with identical HLSL* — same attributes, same system values, same max factor of 64. The
only difference is plumbing: DX11 binds HS/DS on the context (`HSSetShader`/
`DSSetShader` + patch-list topology), DX12 bakes them into the PSO. Luna's DX12 book
(ch. 14) re-covers the basics with worked examples (quad patch, distance-based LOD,
Bézier surface). You can defer implementation to that book, or implement here to
understand the stages with the D3D11 plumbing you have already learned.

**Explore while reading:** run the built **TessellationParams** demo from
`Applications/Bin` while reading — it lets you explore triangle and quad domains,
partitioning modes, and tessellation factors. (The Odin
reference port works just as well: `cd odin_port && just run tessellation_params`, state in the
title bar.)

**Implementation exercise:** `Applications/BasicTessellation/App.cpp` and
`Applications/Data/Shaders/BasicTessellation.hlsl` introduce a triangle domain.
Extend your chapter 3 app with two shader stages and topology
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

**Reference:** `Applications/BasicComputeShader/App.cpp`;
`Applications/Data/Shaders/InvertColorCS.hlsl`; texture in
`Applications/Data/Textures/`. The engine loads it via DirectXTK's WICTextureLoader
(`Source/RendererDX11.cpp` → `LoadTexture`). In your `core:image/png` replacement,
set `SysMemPitch` in the initial-data struct and add alpha if the PNG is RGB.
Create the output texture with
`BindFlags = {.UNORDERED_ACCESS, .SHADER_RESOURCE}`.

**Gotchas:** #10 is the big one — set nil UAVs before binding that texture as an SRV
for the fullscreen pass, and vice versa each frame. Also remember compute is
`CSSetShader` + `Dispatch` with *no* IA/RS/OM state involved — a separate mental
pipeline.

---

## Chapter 6 — High Level Shading Language

**Read:** yes; **nothing to port** — the chapter is about HLSL itself, and every line
of sample HLSL reused by these ports can be compiled from Odin without translating
it into a different shading language.
Worth absorbing properly: semantics and stage linkage rules, the cbuffer packing rules
(gotcha #6 formalized), flow-control attributes, and intrinsics.

**Toolchain note:** the book (and your port) compiles with FXC
(`d3d_compiler.Compile`, with profiles such as `vs_4_0`, `ps_4_0`, or `cs_5_0`
according to the sample). Luna's DX12 book also uses FXC
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

**WaterSimulationI**: compute-shader heightfield fluid over 16×16 tiles,
then rendered — state-in-buffers simulation. **ParticleStorm**: append/consume
structured buffers + `DrawInstancedIndirect`, i.e. GPU-driven particle count with zero
CPU readback — the most "modern GPU" technique in the book. Both are compute-first;
ch. 5 + 10 prepare you fully.

### Chapter 11 — Deferred Rendering (biggest lift)

G-buffer via multiple render targets, then screen-space light accumulation; the
LightPrepass sample shows the lighter-weight variant. Valuable because Luna's DX12 book
*doesn't* really cover deferred — but it is a substantial sample and wants
scene infrastructure (meshes, many lights) you haven't built. Consider it a standalone
project. Reference: `Applications/DeferredRendering/`, `Data/Shaders/GBuffer*.hlsl`.

---

## Further chapters and an optional DX12 route

- **Ch. 7, Multithreaded Rendering / Ch. 13, Multithreaded Paraboloid Rendering:**
  built on D3D11 deferred contexts. Study these for D3D11 multithreading; if moving
  directly to DX12, its command-list model is a separate topic. This is
  the one gap in the reference ports: MirrorMirror (ch. 13) has none.
- **Ch. 8, Mesh Rendering:** vertex skinning — Luna's DX12 book has a full skinned-mesh
  chapter, so you can implement there or use this chapter to learn it now.
  *(Reference port: `skin_and_bones`.)*
- **Ch. 9, Dynamic Tessellation:** advanced applications of ch. 4; implement here
  to explore adaptive geometry, or defer until your DX12 work. *(Reference ports: `curved_pn_triangles`,
  `interlocking_terrain_tiles`.)*
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

The reference ports use the title bar instead of a text renderer. If you want
on-screen labels in your own version, treat them as an optional extension.

**What the engine actually does.** `SpriteFontDX11::Initialize` uses **GDI+** (not
GDI) — `Gdiplus::Font`, `MeasureString`, `DrawString` — to rasterize `'!'`..`'~'`
once into a 1024-wide atlas, measuring each glyph's blank space to derive tight
character rects. After startup GDI+ is gone; the per-frame path is plain D3D11
instanced quads through `Sprite.hlsl`. So the dated part is the *atlas baker*, not
the renderer. Study `SpriteFontDX11` and `SpriteRendererDX11` to understand that
separation. Replacing the atlas baker is enough; you need not recreate the engine's
entire font-loading infrastructure. GDI+ binding work would be a separate task.

**`vendor:stb/easy_font`** is the small option. It's a pure-Odin source port, no
`foreign import` and no `.lib` — it pulls in only `core:math` and `core:mem`.
`print(x, y, text, color, quads[:])` fills a buffer of 64-byte `Quad`s (four
`Vertex{v: [3]f32, c: [4]u8}` corners) in screen-space pixels. There are **no
texture coordinates**, because there's no atlas and no texture: you're drawing
colored quads. A small renderer needs HLSL mapping pixels to NDC, a dynamic vertex
buffer, indices, alpha blending, and depth disabled,
following the same inline-shader pattern `BLIT_HLSL` already uses in
`deferred_rendering` and `light_prepass`. The font is chunky and wireframe-ish —
fine for a keybind legend, not for anything you want to look designed.

**`vendor:stb/truetype`** is an atlas-based option. `PackBegin` /
`PackFontRange` / `PackEnd` bake a proper atlas from a `.ttf` and
`GetPackedQuad` hands back positioned, textured quads. Note it calls stb_rect_pack
*internally* — you don't drive `vendor:stb/rect_pack` yourself. Costs a link
dependency (`stb_truetype.lib`, prebuilt in the toolchain's `vendor/stb/lib`) and a
decision about where the font file comes from; the C++ asks for `Consolas` by name,
so the equivalent is loading `C:\Windows\Fonts\consola.ttf`.

**DirectWrite** is another route, but integrating its text services and any
Direct2D rendering adds a separate API and interop lesson. Check binding support
in your toolchain before choosing it.

**[Slug](https://terathon.com/blog/decade-slug.html)** renders glyph outlines
directly from Bézier data in the pixel shader — sharp at any magnification, no atlas,
no baked resolution. Outline extraction, curve preprocessing, and band construction
make this a substantial separate project. Consult its current documentation if
that technique, rather than a simple sample label, is what you want to study.
