# Known Issues

These issues were identified while reviewing the Odin port against `master` on
2026-08-11. The executable C++ applications and the engine helpers they call are
the behavioral reference. The items are ordered by priority; checkboxes are
intended to make later follow-up easy to track.

## P1 — Shared renderer uses an unrelated DXGI factory

- [ ] Fix swap-chain creation to use the factory associated with the D3D device.

Location: [`odin_port/glyph/renderer/renderer.odin`](odin_port/glyph/renderer/renderer.odin#L123)

`create_device` enumerates an adapter through one `IDXGIFactory1` and creates the
D3D device from that adapter. `renderer.create` then calls
`CreateDXGIFactory1` again and uses this second factory to create the swap chain.
Mixing DXGI objects from different factory instances is unsupported. A driver or
runtime that rejects the combination makes every Odin sample abort during
startup even though device creation succeeded.

The C++ implementation follows the supported ownership chain in
[`Source/RendererDX11.cpp`](Source/RendererDX11.cpp#L482): query the device for
its DXGI interface, obtain its adapter, then obtain that adapter's parent
factory and call `CreateSwapChain` on it. The Odin renderer should do the same
instead of creating a fresh factory. See Microsoft's
[DXGI best practices](https://learn.microsoft.com/en-us/windows/win32/direct3darticles/dxgi-best-practices).

## P2 — Complex interlocking-terrain LOD is nonfunctional

- [ ] Port the terrain lookup compute prepass and bind its result at hull-shader `t1`.

Location: [`odin_port/apps/interlocking_terrain_tiles/main.odin`](odin_port/apps/interlocking_terrain_tiles/main.odin#L489)

The port deliberately leaves `texLODLookup` unbound. When the user presses `L`
to select `hsComplex`, `ReadLookup` therefore returns zeros and every patch
receives the minimum tessellation factor. The advertised height-variance,
neighbour-aware LOD mode never runs.

The C++ sample calls `CreateComputeShaderResources` and `RunComputeShader` from
[`Applications/InterlockingTerrainTiles/App.cpp`](Applications/InterlockingTerrainTiles/App.cpp#L168).
Those helpers create a 32x32 `R32G32B32A32_FLOAT` UAV/SRV, dispatch
`InterlockingTerrainTilesComputeShader.hlsl` over the height map, and bind the
result as `texLODLookup` for the hull shader. Reproduce that resource creation,
dispatch, UAV unbind, and SRV binding in the Odin sample. The existing comment
that describes the missing lookup as an inherited C++ quirk is incorrect.

## P2 — SkinAndBones omits inherited camera and resize behavior

- [ ] Forward camera input and recreate size-dependent rendering state on `WM_SIZE`.

Locations:

- [`odin_port/apps/skin_and_bones/main.odin`](odin_port/apps/skin_and_bones/main.odin#L82)
- [`odin_port/apps/skin_and_bones/main.odin`](odin_port/apps/skin_and_bones/main.odin#L414)

The Odin callback handles only quit, screenshot, and animation-replay input,
then renders with a permanently fixed view and projection. First-person camera
input and live resize therefore have no effect; after a window resize, the
swap chain and 800x600 projection remain unchanged.

The C++ `App` derives from `RenderApplication` and delegates unhandled events to
it in [`Applications/SkinAndBones/App.cpp`](Applications/SkinAndBones/App.cpp#L224).
`RenderApplication` forwards camera events and handles `WINDOW_RESIZE` by
resizing the swap chain and render views and updating the camera aspect ratio
in [`Source/RenderApplication.cpp`](Source/RenderApplication.cpp#L183). Reuse
the first-person-camera and pending-resize approach already present in the Odin
particle and water samples, while preserving the sample's `A` replay behavior.

## P2 — SkinAndBones generates NaN normals at the cone apex

- [ ] Preserve the C++ zero-vector normalization behavior when generating cone normals.

Location: [`odin_port/apps/skin_and_bones/cone.odin`](odin_port/apps/skin_and_bones/cone.odin#L291)

The `v == 0` ring collapses to the cone apex, so `x`, `z`, and the computed
`y` component of its normal are all zero. Odin's `linalg.normalize` divides by
the vector length and produces NaNs for this deterministic zero input. Those
values are uploaded as vertex normals and can contaminate lighting and
tessellation calculations.

The corresponding C++ code also calls `Normalize`, but
[`Vector3f::Normalize`](Source/Vector3f.cpp#L42) explicitly substitutes a
nonzero divisor for zero magnitude and leaves the vector at zero. Use
`linalg.normalize0` or an explicit zero-length guard to preserve that behavior.

## P2 — WaterSimulation unnecessarily requires feature level 11

- [ ] Restore the original feature-level 10 and shader-model 4 path.

Locations:

- [`odin_port/apps/water_simulation/main.odin`](odin_port/apps/water_simulation/main.odin#L311)
- [`odin_port/apps/water_simulation/main.odin`](odin_port/apps/water_simulation/main.odin#L459)

The port compiles the compute, vertex, and pixel shaders as shader model 5.0
and requests feature level 11.0. It consequently refuses to start on feature
level 10 hardware even though the shaders use no feature requiring level 11.

The reference creates a feature-level 10.0 renderer in
[`Applications/WaterSimulationI/App.cpp`](Applications/WaterSimulationI/App.cpp#L48),
compiles the water compute shader as `cs_4_0` in
[`Applications/WaterSimulationI/ViewSimulation.cpp`](Applications/WaterSimulationI/ViewSimulation.cpp#L81),
and compiles the visualization shaders as `vs_4_0` and `ps_4_0`. Change the
Odin profiles to their 4.0 forms and pass `._10_0` to `renderer.create`.

## P2 — ParticleStorm and WaterSimulation start from the wrong cameras

- [ ] Use the final reference camera translations without adding the default node offset.

Locations:

- [`odin_port/apps/particle_storm/main.odin`](odin_port/apps/particle_storm/main.odin#L483)
- [`odin_port/apps/water_simulation/main.odin`](odin_port/apps/water_simulation/main.odin#L488)

The ports add RenderApplication's earlier default node position `(0, 10, -20)`
to the application-specified camera positions. ParticleStorm therefore starts
at `(-100, 70.5, -120)` instead of `(-100, 60.5, -100)`, and WaterSimulation
starts at `(-100, 40.5, -120)` instead of `(-100, 30.5, -100)`. This changes
the initial view and navigation origin on every run.

`SpatialController::Update` assigns its stored translation directly to the
node in [`Include/SpatialController.inl`](Include/SpatialController.inl#L32);
it does not add the prior node transform. The values passed to `Spatial()` by
[`Applications/ParticleStorm/App.cpp`](Applications/ParticleStorm/App.cpp#L74)
and [`Applications/WaterSimulationI/App.cpp`](Applications/WaterSimulationI/App.cpp#L114)
are therefore already the final positions. Use those values verbatim and
correct the comments that currently describe the translations as additive.

## P2 — PNG loading drops the reference mip chain

- [ ] Generate mipmaps for loaded PNG textures.

Location: [`odin_port/glyph/renderer/renderer.odin`](odin_port/glyph/renderer/renderer.odin#L301)

`load_texture_png` creates one immutable mip level. Several samples then use
mip-linear or anisotropic samplers with unrestricted LODs, so minified textures
are forced to sample full-resolution LOD 0 and can visibly alias or shimmer.

The C++ loader passes an immediate context to `CreateWICTextureFromFileEx` in
[`Source/RendererDX11.cpp`](Source/RendererDX11.cpp#L1303), enabling automatic
mipmap generation when the format supports it. The Odin loader should create a
default-usage texture with the required render-target/shader-resource flags,
upload level 0, create the SRV, and call `GenerateMips`, with appropriate
failure cleanup.

## P2 — Failed swap-chain resize leaves invalid renderer state

- [ ] Make `renderer.resize` transactional or propagate failure to every caller.

Location: [`odin_port/glyph/renderer/renderer.odin`](odin_port/glyph/renderer/renderer.odin#L203)

Before calling `ResizeBuffers`, the function unbinds and releases the RTV, DSV,
and backbuffer. If `ResizeBuffers` fails, it returns with all three fields nil.
Callers continue rendering, so the next frame dereferences nil views; another
resize fails even earlier while attempting to release them. Plausible causes
include an outstanding indirect backbuffer reference, device removal, and
allocation failure.

The C++ path logs a failed resize but still attempts to reacquire the existing
buffer and recreate its RTV in
[`Source/RendererDX11.cpp`](Source/RendererDX11.cpp#L1048). The Odin function
should restore valid old-size resources after failure, or return a status and
require callers to suspend rendering or terminate cleanly. Failures after
`ResizeBuffers` succeeds also need to leave the renderer in a defined state.

## P2 — Immediate mesh buffer allocation failures suppress retries

- [ ] Replace dynamic mesh buffers only after successful allocation and upload.

Location: [`odin_port/apps/immediate_renderer/mesh.odin`](odin_port/apps/immediate_renderer/mesh.odin#L113)

When a mesh needs a larger buffer, the current buffer is released before the
replacement `CreateBuffer` result is checked. Capacity is advanced even when
creation returns nil, and `dirty` is cleared even when allocation or mapping
fails. An initial allocation failure, or a later failure while growing, thus
makes the mesh disappear and prevents same-size commits from retrying; a growth
failure also discards a previously usable buffer.

Create replacement vertex and index buffers into temporaries, check every D3D
result, upload successfully, and only then swap them into the mesh and update
capacity. Keep `dirty` set when work fails so a later frame can retry.

## P2 — ImageProcessor discards valid targets before replacements succeed

- [ ] Validate new filter targets before installing them during image changes.

Location: [`odin_port/apps/image_processor/main.odin`](odin_port/apps/image_processor/main.odin#L458)

Pressing `I` destroys the current intermediate and output targets before
creating size-matched replacements, and both returned success flags are
ignored. If texture, SRV, or UAV creation fails, subsequent filtering continues
with partial or nil targets, leaving the viewer black and leaking partially
created objects until exit.

Create both replacement targets as temporaries, clean up either partial result
on failure, and keep the existing image and targets active until both new
targets are complete. Alternatively, stop processing with a clear error after
cleanly releasing all state.

## P3 — SkinAndBones effectively disables anisotropic filtering

- [ ] Set the cone material's anisotropy to the reference value of 16.

Location: [`odin_port/apps/skin_and_bones/main.odin`](odin_port/apps/skin_and_bones/main.odin#L319)

The sampler selects `ANISOTROPIC` filtering but sets `MaxAnisotropy` to 1,
which removes the intended quality improvement at oblique viewing angles. The
C++ cone material sets it to 16 in
[`Source/GeometryGeneratorDX11.cpp`](Source/GeometryGeneratorDX11.cpp#L932).

## P3 — Failed initialization leaks partially created resources

- [ ] Make renderer and scene constructors clean up partial results before returning failure.

Representative locations:

- [`odin_port/glyph/renderer/renderer.odin`](odin_port/glyph/renderer/renderer.odin#L85)
- [`odin_port/apps/skin_and_bones/main.odin`](odin_port/apps/skin_and_bones/main.odin#L227)

Construction procedures populate their result structs incrementally and may
return after any later shader, buffer, texture, view, or state creation fails.
Callers register their destruction `defer` only after receiving `ok == true`,
so an `ok == false` result containing earlier COM objects is discarded without
releasing them. `renderer.create` can similarly leak its device, context,
swap chain, or views after a later initialization failure.

Add failure cleanup inside each constructor, or arrange for the caller to
destroy partial results regardless of the success flag. Apply the solution as
a repeated pattern across the other scene and pipeline setup procedures rather
than fixing only the representative SkinAndBones path.

## P3 — InterlockingTerrainTiles starts at the wrong resolution

- [ ] Restore the reference application's 1024x768 initial client size.

Location: [`odin_port/apps/interlocking_terrain_tiles/main.odin`](odin_port/apps/interlocking_terrain_tiles/main.odin#L33)

The Odin sample requests 640x480, while the C++ application configures
1024x768 in
[`Applications/InterlockingTerrainTiles/App.cpp`](Applications/InterlockingTerrainTiles/App.cpp#L52).
Both are 4:3, so the projection shape is unchanged, but the lower resolution
changes the reference presentation and reduces the detail visible in a sample
specifically demonstrating tessellation and terrain LOD.

## P3 — DDS cube-map size arithmetic can wrap

- [ ] Validate DDS dimensions using checked wide arithmetic before indexing or narrowing.

Location: [`odin_port/apps/immediate_renderer/skybox.odin`](odin_port/apps/immediate_renderer/skybox.odin#L94)

The hand-written loader computes `width * height * 4` while both dimensions
are `u32`. A malformed DDS header can wrap this multiplication before it is
converted to `int`, allowing the truncation check to accept an undersized file.
Later face offsets can then index outside `data`; `width * 4` used for
`SysMemPitch` can wrap independently.

Compute sizes in a checked `u64` or `int`, reject dimensions outside the D3D11
limits, verify the complete six-face payload, and only then narrow values for
the D3D descriptors. The bundled texture is trusted, so this is input-hardening
rather than an ordinary sample-path failure.

## P3 — Screenshot formatting accumulates temporary allocations

- [ ] Bound the temporary allocator lifetime in samples that support repeated screenshots.

Representative locations:

- [`odin_port/apps/immediate_renderer/main.odin`](odin_port/apps/immediate_renderer/main.odin#L751)
- [`odin_port/glyph/renderer/renderer.odin`](odin_port/glyph/renderer/renderer.odin#L369)

Screenshot paths are built with `fmt.tprintf`, and `save_backbuffer_png` uses
`fmt.ctprintf`; both allocate from `context.temp_allocator`. Several sample
loops, including ImmediateRenderer, never reset that allocator. Memory usage
therefore grows with every screenshot until process exit. This is not a
per-frame leak when no screenshot is requested, but repeated captures make it
observable in a long-running session.

Reset the temporary allocator at a safe frame boundary, as the larger particle,
water, deferred, and light-prepass samples already do, or use an explicitly
scoped allocator for screenshot formatting.

## P3 — MS3D loader reads section counts past truncated input

- [ ] Bounds-check the vertex and triangle counts before reading them.

Location: [`odin_port/glyph/ms3d/ms3d.odin`](odin_port/glyph/ms3d/ms3d.odin#L65)

After accepting a valid 14-byte header, the loader immediately reads the
two-byte vertex count at offsets 14 and 15. A file truncated exactly after the
header therefore panics on a slice bounds check instead of returning
`ok = false`. The triangle-count read repeats the same issue when a file ends
exactly after its vertex records.

Before each `read_u16`, require `len(data) >= pos + 2` and return a descriptive
truncation error otherwise. Size calculations based on the counts should also
remain checked before multiplication and narrowing.

## Reviewed reports not classified as port regressions

The following review comments were investigated but are not included above as
Odin port regressions:

- Screenshot capture currently occurs after `Present`. With the discard swap
  effect, the saved backbuffer contents are not guaranteed. However, the C++
  [`Application::MessageLoop`](Source/Application.cpp#L125) also calls
  `Update`—which presents—before `TakeScreenShot`. This is a real inherited
  behavior issue. Fixing it would be a reasonable documented departure if
  reliable screenshots are preferred over exact call-order fidelity.
- DeferredRendering tests far-plane intersection using `light.Range` while
  drawing a volume scaled to `1.1 * light.Range`. The C++ implementation uses
  the same calculation in
  [`Applications/DeferredRendering/ViewLights.cpp`](Applications/DeferredRendering/ViewLights.cpp#L354).
- TessellationParams can retain a quad-only edge or inside selection after
  switching to the triangle domain. The C++ event handler preserves the same
  selection and rejects edits through its range checks.
- The reported STL face-count multiplication overflow was disproved: on the
  supported 64-bit target, the calculation and subsequent length comparison
  reject the malformed count.
- Converting `COLOR_WRITE_ENABLE_ALL` to the descriptor's `u8` field is valid;
  replacing the conversion with `transmute` is unnecessary.
- The old `run.bat` documentation typo is obsolete after replacing the batch
  launcher with the `Justfile` workflow.

## Review validation record

The review that produced this list ran the following local validation:

- `just verify`: all 15 applications passed strict `odin check`; all 8
  `glyph/d3d_math` tests passed with memory tracking.
- `just asan basic_application`: build passed; executable was not run.
- `just asan immediate_renderer`: build passed; executable was not run.

No Direct3D runtime, tracking-allocator application run, or debug-layer
validation was performed. Compiler checks and sanitizer builds do not establish
behavioral equivalence for the issues above.
