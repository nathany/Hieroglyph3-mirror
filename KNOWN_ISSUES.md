# Known Issues

This record revalidates the reports collected on 2026-08-11 against the current
Odin and C++ source at `f92da47` on 2026-09-06. It is a current-tree audit, not a
new diff review against `master`. A subsequent runtime baseline at `9a91a68`
used Odin `dev-2026-09-nightly:a2fb372`: all 15 demos launched and closed normally,
but selected controls and visual comparisons exposed the defects below, including
KI-019. Successful startup is not a clean visual or API-validation result.
See [validation records](odin_port/VALIDATION.md) for coverage and limitations.

The executable C++ applications, their helpers, and the dependency versions used
here are the behavioral reference. An inherited problem is still real, but fixing
it is an intentional improvement rather than a port correction. IDs remain stable
when reclassified. Checkboxes describe proposed work; optional improvements are
not commitments to expand sample scope.

## Triage and proposed order

P1 denotes a shared critical-path concern, P2 a correctness or advertised-behavior
defect worth addressing, and P3 lower urgency fidelity or robustness work. Priority,
origin, and effort are separate: tiny P3 fixes can be worth batching early. Source
and API evidence do not imply a failure was reproduced on the local GPU.

| ID | Report | Classification | Priority | Minimum change / divergence |
|---|---|---|---|---|
| KI-001 | DXGI factory relationship | ✅ Fixed port defect (2026-09-06) | P1 | Small ownership correction; restores reference |
| KI-002 | Terrain complex LOD | ✅ Fixed port omission | P2 | Moderate compute-prepass addition; restores lesson |
| KI-019 | Terrain shaded-mode cbuffer slot | ✅ Fixed port binding defect | P2 | Small per-variant binding correction; restores reference |
| KI-020 | Particle startup UAV hazard | Confirmed port binding-cleanup omission | P3 | Unbind priming UAVs; preserve append counters |
| KI-003 | Skin camera and resize | Confirmed port omission | P2 | Moderate local input/resize addition |
| KI-004 | Cone apex normals | ✅ Fixed semantic translation defect | P2 | `normalize0`; preserves reference zero input |
| KI-008 | Failed swap-chain resize | Confirmed port failure-path defect | P2 | Return failure and stop cleanly; recovery optional |
| KI-005 | Water feature level/profiles | Confirmed compatibility departure | P3; P2 if FL10 is required | Restore profiles and feature level together |
| KI-006 | Particle/water cameras | Confirmed port fidelity defect | P3 | Two translations and their explanations |
| KI-011 | Skin anisotropy | Confirmed port fidelity defect | P3 | Set reference value 16 |
| KI-012 | Partial initialization | Confirmed ownership defects | P3 | Consistent cleanup; no normal-path change |
| KI-013 | Terrain requested resolution | Confirmed port fidelity defect | P3 | Restore 1024x768 |
| KI-014 | DDS size arithmetic | Confirmed input-hardening issue | P3 | Bound dimensions and validate wide sizes |
| KI-015 | Temporary allocations | Confirmed Odin lifetime issue | P3 | Scope/reset scratch allocations |
| KI-016 | MS3D count reads | Confirmed input-hardening issue | P3 | Two explicit bounds checks |
| KI-017 | Particle debug-count buffer | Confirmed optional-path ownership defect | P3 | Check creation and release the buffer |
| KI-018 | Actual startup dimensions | Confirmed port fidelity defect | P3 | Use actual client/backbuffer dimensions |
| KI-009 | Immediate mesh replacement | Real inherited weakness | P3 | Clean failure exit; rollback/retry optional |
| KI-010 | ImageProcessor replacement | Real inherited weakness | P3 | Clean failure exit or complete temporary target pair |
| KI-007 | Claimed missing mip chain | Disproved as a port regression | None | Mips would be an optional quality enhancement |

Prefer one semantic fix, relevant tests, then one commit. Keep KI-001 isolated,
and fix KI-019 separately from KI-002 so the shading and LOD improvements have
distinct evidence. Small shared-cause batches such as KI-006's two camera values
are reasonable; KI-004 and KI-011 can share a SkinAndBones test session. Split
KI-012 by ownership boundary instead of rewriting every constructor together.
Shared renderer startup changes require all 14 rendering demos; local changes
normally need the affected demo and modes. See the validation record's test-scope
table. Prefer explicit error, cleanup, and exit where recovery would obscure the lesson.

## Confirmed port and input-handling issues

### KI-001 — Shared renderer uses an unrelated DXGI factory

- [x] Use the factory associated with the D3D device for swap-chain creation.

Before the fix, `renderer.create` created a second factory unrelated to the one
that enumerated the device's adapter. Mixing those DXGI objects is unsupported;
rejection would prevent every rendering sample from starting. No driver-specific
rejection was reproduced during this audit.

The corrected [`renderer.create`](odin_port/glyph/renderer/renderer.odin#L119)
follows device -> DXGI adapter -> parent factory, matching the
[C++ implementation](Source/RendererDX11.cpp#L478). Each successful temporary
interface acquisition has a deferred release. The misleading equivalence comment
was replaced. See
[Microsoft's DXGI guidance](https://learn.microsoft.com/en-us/windows/win32/direct3darticles/dxgi-best-practices).

Validation confirmed matching canonical factory identities for the actual device
and swap chain, clean probe initialization/teardown diagnostics, all 15 compiler
checks and eight math tests, 14 rendering demo runs, and two ASan executions.
Known baseline diagnostics remain; see [the validation record](odin_port/VALIDATION.md).
Partial-initialization cleanup remains separate work under KI-012.

### KI-002 — Complex interlocking-terrain LOD is nonfunctional

- [x] ✅ Port the lookup compute prepass and bind its result at hull-shader `t1`.

The port previously left `texLODLookup` unbound. Selecting `hsComplex` with `L`
read zeros and produced minimum tessellation instead of height-variance,
neighbour-aware LOD.

C++ calls `CreateComputeShaderResources` and `RunComputeShader` during
initialization. Their [implementations](Applications/InterlockingTerrainTiles/App.cpp#L619)
create a 32x32 `R32G32B32A32_FLOAT` UAV/SRV, dispatch the supplied compute shader,
and bind the output for the hull shader. The port now follows these stages,
unbinds compute input/output before drawing, and releases temporary compute
resources after the one-time prepass. The lookup texture/SRV live with the scene.
It rejects height maps other than the supplied 512x512 size, making the shader's
16x16-samples-per-tile requirement explicit rather than dispatching out of bounds.

Validation: terrain compiler check and ASan build/run passed; all shading/hull
modes ran without D3D diagnostics. Readback verified 1,024 finite lookup entries,
unit plane normals, and varying deviations; live-object reporting confirmed
cleanup. Complex wireframe refinement and LOD debug colors were visually checked.
The independent shading correction remains recorded as KI-019.

### KI-019 — Terrain shaded mode binds camera data as height-map dimensions

- [x] ✅ Bind the domain shader's second cbuffer according to its compiled variant.

Before the fix, freezing with `A`, selecting shaded mode with `D`, then solid
rendering with `W` produced mostly black terrain instead of C++'s smooth gray
shading, even without `L`. The port always bound `[cb_main, cb_patch, cb_sample]`
at domain-shader slots `b0–b2`. Compilation/disassembly with the debug flags confirmed:

| Variant | Compiled cbuffers |
|---|---|
| `SHADING_SOLID` | `main → b0` |
| `SHADING_SIMPLE` | `main → b0`, `sampleparams → b1` |
| `SHADING_DEBUG_LOD` | `main → b0`, `patch → b1` |

Shaded mode therefore read camera position as height-map dimensions, corrupting
the Sobel filter's sample offsets and resulting normals. C++
[binds by reflected slot](Source/ShaderReflectionDX11.cpp#L229).
The corrected bindings select `cb_sample` or `cb_patch` at `b1` according to the
variant, and nil for solid color. No shader edits or reflection framework were
needed. `just check interlocking_terrain_tiles` passed; all three shading variants
under both hull modes ran with no D3D diagnostics (18 captures, normal exit).
Gray shading and the colored simple-LOD view were visually verified. Complex LOD
remains KI-002. An API-valid wrong buffer can evade debug-layer diagnostics.

### KI-003 — SkinAndBones omits camera and resize behavior

- [ ] Forward camera input and recreate size-dependent state on `WM_SIZE`.

The [callback](odin_port/apps/skin_and_bones/main.odin#L82) handles quit, screenshots,
and replay, while [fixed matrices](odin_port/apps/skin_and_bones/main.odin#L415)
leave the camera and 800x600 projection unchanged after input or resizing.

The [C++ event handler](Applications/SkinAndBones/App.cpp#L224) delegates to
[`RenderApplication`](Source/RenderApplication.cpp#L183), which forwards camera
events and resizes the swap chain, views, and aspect ratio. Reuse the existing
plain Odin camera and pending-resize pattern.

Preserve `A` replay while clearing camera state on release. C++ forwards `A`
key-down but consumes key-up for replay, which can latch left movement.
Avoiding that inherited input conflict is a small documented improvement.

The runtime baseline confirmed missing forward movement before replay and a
stretched fixed projection after a wide resize; animation and replay ran.

### KI-004 — SkinAndBones generates NaN normals at the cone apex

- [x] ✅ Preserve zero-vector normalization behavior.

At [cone.odin](odin_port/apps/skin_and_bones/cone.odin#L291), ring `v == 0`
deterministically supplied zero to `linalg.normalize`, producing NaNs. The C++
generator supplies the same zero vector, but
[`Vector3f::Normalize`](Source/Vector3f.cpp#L42) leaves it zero. The port now uses
`linalg.normalize0`. A probe of the actual generator with the demo parameters
verified all 322 normals finite, exactly 16 collapsed-ring zero normals, and
unit length for the rest. The sample check and debug runtime animation/replay
passed with no D3D diagnostics. This preserves CPU geometry semantics; it does
not establish that all inherited shader-side degenerate normals are solved.

### KI-008 — Failed swap-chain resize leaves invalid renderer state

- [ ] Propagate resize failure to every caller and stop rendering safely.

[`renderer.resize`](odin_port/glyph/renderer/renderer.odin#L203) releases the RTV,
DSV, and backbuffer before `ResizeBuffers`. Failure returns without views while
callers keep rendering; another resize calls `Release` through missing pointers.
Device removal, allocation failure, or an outstanding backbuffer reference can
trigger this. Later view-recreation steps can fail independently.

The [C++ path](Source/RendererDX11.cpp#L1048) attempts to reacquire the buffer even
after a failed resize, although it is not a complete recovery model. The simplest
Odin remedy is a status return, defined partial-state cleanup, and clean exit.
Recovery of old-size resources is optional. Current callers are ImmediateRenderer,
ImageProcessor, ParticleStorm, WaterSimulation, DeferredRendering, and LightPrepass.

### KI-005 — WaterSimulation requires a higher feature level than the reference

- [ ] Restore feature level 10 and shader-model 4 profiles together.

The port [compiles SM5](odin_port/apps/water_simulation/main.odin#L311) and
[requests FL11](odin_port/apps/water_simulation/main.odin#L459). The reference
[requests FL10](Applications/WaterSimulationI/App.cpp#L48), uses `vs_4_0` /
`ps_4_0`, and uses [`cs_4_0`](Applications/WaterSimulationI/ViewSimulation.cpp#L84).
This excludes the reference's lower-feature-level path. Treat it as P3 for the
tested modern-hardware demos, P2 if FL10 is required. Compile and exercise that
path when changing it; an FL11 run does not establish FL10 compute support on
every device.

### KI-006 — ParticleStorm and WaterSimulation start from the wrong cameras

- [ ] Use final reference translations without adding the default node offset.

The [particle](odin_port/apps/particle_storm/main.odin#L483) and
[water](odin_port/apps/water_simulation/main.odin#L488) ports add `(0, 10, -20)`.
Correct starting positions are `(-100, 60.5, -100)` and `(-100, 30.5, -100)`.

[`SpatialController::Update`](Include/SpatialController.inl#L32) assigns its
translation to the root node. The [particle](Applications/ParticleStorm/App.cpp#L75)
and [water](Applications/WaterSimulationI/App.cpp#L115) values are already final.
Change the constants and additive-offset explanations, including README notes.

Both simulations animated in the runtime baseline, with visibly different startup
framing from C++. The difference was not attributed to the compiler update.

### KI-011 — SkinAndBones effectively disables anisotropic filtering

- [ ] Set the cone material's `MaxAnisotropy` to 16.

The [Odin sampler](odin_port/apps/skin_and_bones/main.odin#L319) selects anisotropic
filtering with maximum 1; the [C++ material](Source/GeometryGeneratorDX11.cpp#L936)
uses 16. This tiny correction restores the setting. It does not require a mip
chain: KI-007 establishes that the reference PNG loader also creates one mip.

### KI-012 — Failed initialization leaks owned resources

- [ ] Establish consistent partial-result and local-resource cleanup.

Representative paths include [renderer creation](odin_port/glyph/renderer/renderer.odin#L94)
and [SkinAndBones setup](odin_port/apps/skin_and_bones/main.odin#L227). They acquire
resources incrementally, while callers install destruction defers only after
success. Later failure discards earlier owned objects. This repeats across scene
and pipeline construction.

Prefer constructors that clean partial results on failure, with an explicit
ownership contract for every return. Register cleanup immediately after acquiring
a local. A scene destructor alone is insufficient:

- DeferredRendering [setup](odin_port/apps/deferred_rendering/main.odin#L683)
  acquires local shader blobs before their eventual defers.
- DeferredRendering and LightPrepass create scene and targets before checking both
  success flags ([example](odin_port/apps/deferred_rendering/main.odin#L1013)).
  A successful sibling needs cleanup when the other fails. ParticleStorm and
  WaterSimulation have the corresponding scene/depth pattern.
- Partial nested-helper values that never reach an owning field cannot be cleaned
  by the outer destructor.
- ImageProcessor checks its [initial pair](odin_port/apps/image_processor/main.odin#L422)
  before registering cleanup. This startup leak is distinct from KI-010.

No normal rendering behavior needs to change. Use one visible ownership convention
rather than a new abstraction framework.

### KI-013 — Terrain starts at the wrong requested resolution

- [ ] Restore the reference's 1024x768 requested client size.

The [port](odin_port/apps/interlocking_terrain_tiles/main.odin#L33) requests 640x480;
[C++](Applications/InterlockingTerrainTiles/App.cpp#L52) requests 1024x768. Both
are 4:3, but lower resolution changes visible terrain detail. This differs from
respecting the actual size Windows creates (KI-018).

At the baseline desktop's 150% scaling, the captured client sizes were 960x720
physical pixels for Odin and 1536x1152 for C++, confirming the requested-size gap.

### KI-014 — DDS cube-map size arithmetic can wrap

- [ ] Validate dimensions and the six-face payload before indexing or narrowing.

The [DDS reader](odin_port/apps/immediate_renderer/skybox.odin#L94) computes
`width * height * 4` in `u32` before widening. An otherwise accepted 128-byte
header with width and height 65536 wraps the face size to zero, passes validation,
and reaches `&data[128]` outside the slice. Zero dimensions do likewise.
This is a source-derived trigger, not a runtime reproduction here.

Reject zero and out-of-range dimensions, calculate sizes widely, validate the
complete payload, then narrow. Pitch `width * 4` must also fit. The bundled
texture is trusted; this is isolated hardening, not a request for a general DDS
decoder or an ordinary-path failure.

### KI-015 — Scratch allocations accumulate on screenshots and title changes

- [ ] Bound temporary allocation lifetimes after their last use.

Screenshot callers use `fmt.tprintf`, and
[`save_backbuffer_png`](odin_port/glyph/renderer/renderer.odin#L343) uses
`fmt.ctprintf`. Several loops never reset `context.temp_allocator`.
TessellationParams also allocates for repeated
[title changes](odin_port/apps/tessellation_params/main.odin#L149), including
UTF-16 conversion. The PLY parser retains startup scratch allocations too.

This is event-driven growth, not per-frame growth while idle. Reset at a safe
frame boundary, as particle/water/deferred/light-prepass already do, or scope the
allocations. Include conversions as well as formatting; do not reset while a
retained slice or string still refers to temporary storage.

### KI-016 — MS3D loader reads counts past truncated input

- [ ] Check two bytes exist before each section-count read.

After the accepted 14-byte header, [the loader](odin_port/glyph/ms3d/ms3d.odin#L65)
reads a two-byte vertex count without checking it exists. It repeats this after
the vertex records for the triangle count. Either truncation panics instead of
returning `ok = false`.

Add explicit two-byte checks and descriptive errors. The `u16` counts already
widen to `int` before record-size multiplication and fit the supported x64 target;
a general checked-arithmetic framework is unnecessary here.

### KI-017 — ParticleStorm debug-count buffer lacks cleanup

- [ ] Check creation and release the optional staging buffer.

With `-define:DEBUG_COUNTS=true`, the
[debug block](odin_port/apps/particle_storm/main.odin#L640) creates a static staging
buffer and never releases it. This is one retained allocation, not per-frame
growth. Failed creation can also send nil to `CopyStructureCount` and `Map`.
The [C++ equivalent](Applications/ParticleStorm/ViewSimulation.cpp#L195) registers
the resource with the renderer, whose shutdown deletes owned resources.

Create the optional buffer in main/scene initialization, check success, and
release it normally. Direct `CopyStructureCount` into staging is supported;
the defect is ownership and failure handling, not that destination usage. See
[Microsoft's contract](https://learn.microsoft.com/en-us/windows/win32/api/d3d11/nf-d3d11-id3d11devicecontext-copystructurecount).

### KI-018 — Rendering samples ignore actual startup dimensions

- [ ] Initialize backbuffers and dependent targets from the actual created size.

All 14 rendering applications pass `WIDTH, HEIGHT` to `renderer.create`, although
[window initialization](odin_port/glyph/window/window.odin#L130) records actual
`GetClientRect` dimensions. If Windows constrains the initial client area, the
backbuffer is oversized and scaled into the smaller window. Dependent targets
also use requested dimensions, for example in
[DeferredRendering](odin_port/apps/deferred_rendering/main.odin#L1000).

C++ [swap-chain setup](Source/RenderApplication.cpp#L114) uses
[`GetWidth`/`GetHeight`](Source/RenderWindow.cpp#L53), which query the client
rectangle. Deferred rendering derives dimensions from the
[actual target](Applications/DeferredRendering/ViewDeferredRenderer.cpp#L35).
Pass validated `win.width/height` to renderer creation, then `r.width/height`
to dependent targets. Keep constants for requesting the window size.

Do not call every projection/viewport adjustment reference restoration: some
C++ samples retain requested values there. Compare each one. RotatingCube uses
actual dimensions for its [C++ projection](Applications/RotatingCube/App.cpp#L305),
while [Odin](odin_port/apps/rotating_cube/main.odin#L234) uses constants.
No constrained-desktop runtime reproduction was performed during this audit.

### KI-020 — ParticleStorm leaves priming UAVs bound for the first insertion

- [ ] Explicitly unbind the priming UAVs before the next pass.

The first-frame [priming dispatch](odin_port/apps/particle_storm/main.odin#L575)
leaves `next` at `u0` and `current` at `u1`. When the first insertion runs that
frame, [binding only `u0`](odin_port/apps/particle_storm/main.odin#L596) attempts to
bind `current` in both slots. The debug layer reports
`DEVICE_CSSETUNORDEREDACCESSVIEWS_HAZARD` and automatically clears `u1`.
Both messages were captured before KI-001; no particle loss was demonstrated.

C++ [Dispatch](Source/PipelineManagerDX11.cpp#L558) clears desired shader resources
between passes and applies the changed UAV slots together. Clear both priming
slots after the dispatch, or supply the complete insertion binding state. Keep
the append counters intact. This is a small educational correction, not a new
simulation algorithm. Other compute samples already unbind after their dispatches.

## Real inherited weaknesses: optional improvements

### KI-009 — Immediate mesh replacement failures suppress retries

- [ ] Optionally make allocation/upload failure explicit and terminate cleanly.

[`mesh_commit`](odin_port/apps/immediate_renderer/mesh.odin#L113) releases old
buffers before replacement succeeds, advances capacity even on failure, and
clears `dirty` after failed allocation or mapping. This can remove the mesh and
suppress same-size retries.

The [C++ growable buffer](Include/TGrowableBufferDX11.inl#L55) also advances
capacity, deletes its resource, then creates the replacement. Its
[vertex uploader](Include/TGrowableVertexBufferDX11.inl#L30) and index equivalent
clear the upload flag before mapping and copying. Recovery is an improvement to
inherited behavior, not fidelity restoration.

A status return and clean exit suffice for the demo. Preserving a complete
previous vertex/index state and retrying is optional; if implemented, capacities
and `dirty` must reflect only a complete successful commit.

### KI-010 — ImageProcessor discards targets before replacement succeeds

- [ ] Optionally handle replacement failure without continuing with invalid targets.

Pressing `I` [destroys the pair](odin_port/apps/image_processor/main.odin#L458)
before creating replacements and ignores success. Partial results remain stored
and can be released on the next switch or exit; they are not orphaned
replacement-time leaks. The distinct startup leak is KI-012.

The [C++ image switch](Applications/ImageProcessor/App.cpp#L318) also advances
the image and resizes twice. Despite its comment,
[`ResizeTexture`](Source/RendererDX11.cpp#L846) uses `ReleaseAndGetAddressOf`
before successful creation, then attempts view recreation despite failure.

Either report failure and exit cleanly, or create both targets as temporaries and
install them with the new image index only after both succeed. Both improve
inherited failure behavior without changing filtering algorithms.

### Other inherited behavior to preserve or change explicitly

- **Screenshots after presentation:** C++
  [`Application::MessageLoop`](Source/Application.cpp#L125) calls `Update` (which
  presents) before capture, as do the ports. Discard presentation does not promise
  preserved backbuffer contents. Capture before `Present` is a small optional
  departure for reliable screenshots.
- **Deferred light-volume clipping:** the
  [reference](Applications/DeferredRendering/ViewLights.cpp#L362) tests `Range`
  while drawing at `1.1 * Range`. Its matrix-vector helper was checked; Odin
  computes the same value. An adjustment is an inherited correction.
- **Tessellation selection:** quad-to-triangle switching preserves a potentially
  quad-only selection in both versions; C++ setters reject out-of-range edits.
- **Curved PN adaptive mode:** C++ loads PLY without adjacency (the default in
  [GeometryLoaderDX11.h](Include/GeometryLoaderDX11.h#L37)), producing three-point
  patches while the alternate hull shader expects six. Runtime captures show
  malformed/incomplete patches in both versions, not necessarily a blank image.
  Native diagnostics report `DEVICE_DRAW_HULL_SHADER_INPUT_TOPOLOGY_MISMATCH`
  (#2097222); the retained pre-KI-001 executable reproduces the same error.
  Repair needs adjacency generation and is a separate optional exercise.
- **Deferred/LightPrepass camera wiring:** the C++ setup overrides create a camera
  ([Deferred](Applications/DeferredRendering/App.cpp#L74),
  [LightPrepass](Applications/LightPrepass/App.cpp#L72)) but omit
  `SetEventManager(&CameraEventHub)`, which the
  [base setup](Source/RenderApplication.cpp#L149) supplies. `IEventListener` starts
  with a null manager and only registers events when assigned one; scene insertion
  does not repair this. The C++ viewpoint stays fixed while Odin responds to input.
  Preserve Odin's useful camera behavior and document the departure. Both camera
  implementations use 10 units/second; reducing Odin's speed is not a remedy.
- **LightPrepass mask warning:** the
  [depth/stencil-only pass](odin_port/apps/light_prepass/main.odin#L973) uses
  `MaskLP`, whose pixel shader declares `SV_Target0` although its color write is
  intentionally discarded. The debug layer reports
  `DEVICE_DRAW_RENDERTARGETVIEW_NOT_SET`; C++
  [uses the same mask pass](Applications/LightPrepass/ViewGBuffer.cpp#L139).
  Treat this specific warning as explained inherited behavior, not a missing color
  target to add or a reason to mute unrelated validation messages.

## Disproved or obsolete reports

### KI-007 — PNG loading does not drop a reference mip chain

The prior P2 report was incorrect. The
[C++ call](Source/RendererDX11.cpp#L1303) passes an immediate context to
`CreateWICTextureFromFileEx`, but passes `nullptr` for the SRV output.
The matching [October 2025 DirectXTK implementation](https://github.com/microsoft/DirectXTK/blob/oct2025/Src/WICTextureLoader.cpp)
enables autogeneration only when `d3dContext && textureView` is true. It therefore
creates one mip here. `ResourceProxyDX11` creates a view later, which does not
generate mips. The Odin PNG loader also creates one mip.

Generating mips could improve minification quality but changes reference output
and resource setup. Retain it only as an optional extension. This was verified
against the release identified by the installed NuGet package, not inferred
solely from the loader's advertised capabilities.

- **STL count overflow:** disproved on supported x64. The count widens before
  multiplication, the maximum byte total fits, and the length check rejects
  truncated input.
- **Color-write-mask conversion:** conversion to the descriptor's `u8` field is
  valid. Replacing it with `transmute` is unnecessary.
- **Particle staging-copy misuse:** rejected; KI-017 concerns ownership and failed
  creation, not the supported staging destination.
- **Old `run.bat` typo:** obsolete after the `Justfile` workflow.

## Explanations to correct alongside later implementation

The guide and sample README now describe the observed limitations and accepted
departures. Matching code explanations remain work for the relevant implementation
changes. In addition to explanations attached to issues above:

- `skin_and_bones/cone.odin` describes `world * inv_bind`, although the correct
  implementation uses `inv_bind * world`. Its statement that compositions of
  rotation and translation can shear is wrong: rigid transforms stay rigid;
  blending skinning transforms can introduce non-rigid behavior.
- Camera copies accumulate mouse deltas and clamp total pitch, while C++ overwrites
  deltas and clamps each frame's increment. These reasonable usability departures
  should be distinguished from exact parity.

## Validation and limits

The 2026-09-06 current-tree audit ran `just verify`: all 15 applications passed
strict `odin check`, and all 8 `glyph/d3d_math` tests passed with memory tracking.
The suite was rerun successfully during the documentation update. Temporary Odin
probes outside the repository confirmed `normalize0` versus `normalize` at zero,
affine/projective transforms, cbuffer offsets, and that API-invalid flag sets can
be expressed. The installed compiler was `dev-2026-09-nightly:a2fb372`; its matrix
alignment is 4 bytes, disproving the guide's stale 32-byte rule, which was removed.
The optional particle path also passed
`odin check apps/particle_storm -collection:glyph=glyph -define:DEBUG_COUNTS=true -warnings-as-errors -strict-style -error-pos-style:unix`
from `odin_port/`; it was not run. Documentation checks validated 58 local links,
line-reference bounds, code fences, and 18 unique issue IDs. `git diff --check`
passed after the edits.
These checks do not establish visual equivalence, failure recovery, or runtime
shader compilation.

The earlier 2026-08-11 record reports the same suite and successful
`just asan basic_application` / `just asan immediate_renderer` builds, without
executing them. Those are historical results, not new sanitizer runs.

Those source/documentation audits did not perform new graphical comparisons,
application tracking-allocator runs, debug-layer validation, constrained-desktop
tests, or failure injection.
Reported paths and repeated patterns were traced; this is not proof that every
combination of sample controls and hardware behavior is defect-free.

The later `9a91a68` baseline ran all 15 Odin demos and existing C++ executables,
saved 195 screen-client captures, and exercised selected controls, resize, and
minimize/restore. KI-002, KI-003, KI-006, and KI-013 were visible; KI-019 was newly
confirmed. The reference executables were not rebuilt. Animated frames were not
synchronized, and text omissions were treated as documented differences. A
transient black C++ ImageProcessor restore capture did not persist on retest.
That baseline requested the D3D debug layer but did not collect its messages.
Subsequent probes verified the debug flag, interfaces, deliberate diagnostic,
native message collection, and live-object reporting before KI-001 was changed.
Those runs identified KI-020. KI-001 then passed the post-change checks described
in [VALIDATION.md](odin_port/VALIDATION.md); the remaining issues were left unfixed.
