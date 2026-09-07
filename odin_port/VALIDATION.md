# Runtime baseline and issue-fix validation

Recorded 2026-09-06 using Odin `dev-2026-09-nightly:a2fb372` on Windows.
The original visual baseline used source revision `9a91a68`; the subsequent
documentation commit `b1cf63b` did not change demo code. The KI-001 results below
cover the factory-chain correction to that code.

**Current result:** instrumentation is working; KI-001, all five P2 issues and
all thirteen P3 issues have verified fixes. The original baseline and intermediate
checkpoints below preserve what was observed before each repair. LightPrepass's
mask-pass warning and CurvedPN's adaptive-topology diagnostic remain documented
inherited behavior; they are not newly introduced regressions. See
[sample notes](README.md) for current behavior and retained limitations. The retired
issue tracker, including classifications and rejected reports, remains available
with `git show c6b394a:KNOWN_ISSUES.md`; the sections below retain fix evidence.

## Original visual baseline

All 15 Odin demos were rebuilt using `just run <app>`, compared with the existing
`Applications/Bin/*_Desktop.exe` programs, and closed normally. C++ binaries were
not rebuilt; their hashes and timestamps are retained in the artifact manifest.
Their normal `WinMain` returns `true` (exit code 1); Odin returned 0. `odin run`
removes its executable after completion, so the original Odin baseline is
identified by source, compiler, commands, and captures rather than binary hashes.

The final inventories contain 195 screen-client captures across 30 runs. All 14
rendering demos received a normal resize; selected demos also exercised controls
and minimize/restore. BasicWindow's two empty Win32 windows were checked separately.
The comparisons established terrain shading/LOD/resolution defects (KI-019,
KI-002, KI-013), missing SkinAndBones camera/resize behavior (KI-003), and simulation
camera differences (KI-006). Curved PN adaptive rendering is malformed in both
implementations. Functional Odin camera input in DeferredRendering and LightPrepass
is an accepted improvement over omitted C++ camera event registration.

The desktop was 3840x2160 at 150% scaling. Host inventory included an AMD Radeon
RX 9070 XT (driver 32.0.31041.1004) and AMD Radeon Graphics (32.0.21045.5002);
the selected D3D adapter was not separately measured. Captures used the actual,
unobscured screen client area after checking window ownership at the capture
corners and center. A preliminary `PrintWindow` scaling artifact was excluded.
Animations were not frame-locked; comparisons concern structure and behavior,
not pixel equality. ImageProcessor was allowed extra settling time after restore.

## Instrumentation confirmation

An isolated probe exercised the actual `glyph:renderer.create_device` implementation:

- Device creation flags contained `D3D11_CREATE_DEVICE_DEBUG` (`0x2`), with FL11.0.
- `QueryInterface` for `ID3D11Debug` and `ID3D11InfoQueue` succeeded.
- A deliberate zero-byte buffer creation returned `E_INVALIDARG`, a nil buffer,
  and the expected `CREATEBUFFER_INVALIDDIMENSIONS` / `CREATEBUFFER_INVALIDARG_RETURN`
  errors. These intentional probe messages were cleared before the clean phase.
- `ReportLiveDeviceObjects` detected an intentionally retained buffer. After its
  release, context clearing/flushing, and renderer destruction, only the device
  retained by diagnostic interfaces remained; those interfaces were then released.

A temporary native Windows debugger collected `OutputDebugString` from each demo
it launched. The probe also verified this collection channel by producing the
expected errors and live-object messages. Demo stdout/stderr alone was not used
as evidence that the debug layer was quiet. No global warning filters were added.
See Microsoft's [debug-layer overview](https://learn.microsoft.com/en-us/windows/win32/direct3d11/overviews-direct3d-11-devices-layers)
and [InfoQueue API](https://learn.microsoft.com/en-us/windows/win32/api/d3d11sdklayers/nn-d3d11sdklayers-id3d11infoqueue).

RenderDoc **1.46** was found at `C:/Program Files/RenderDoc/renderdoccmd.exe`, and
its version and capture CLI options were checked. No RenderDoc capture or replay
was performed. It remains an optional tool for future binding investigations;
the native diagnostics and factory-identity probe directly covered KI-001.

### Observed application diagnostics

| Demo / path | Diagnostic | Interpretation |
|---|---|---|
| ParticleStorm startup, before and after KI-001 | Two `DEVICE_CSSETUNORDEREDACCESSVIEWS_HAZARD` warnings (#2097354); runtime clears UAV slot 1 | New KI-020, a port cleanup omission. No demonstrated particle loss; left unfixed. |
| LightPrepass mask pass, before and after KI-001 | Repeated `DEVICE_DRAW_RENDERTARGETVIEW_NOT_SET` warning (#3146081) | Inherited depth/stencil-only pass discards unused color output. Expected in this sample; preserve the book shader. |
| Curved PN after selecting adaptive mode | Repeated `DEVICE_DRAW_HULL_SHADER_INPUT_TOPOLOGY_MISMATCH` error (#2097222): six HS input points versus three IA patch points | Inherited adjacency/topology defect. Reproduced with the retained pre-fix binary using the same controls; not introduced by KI-001. |

Other collected demo runs produced no D3D warnings/errors. That does not establish
correct shader data: KI-019's wrong cbuffer is API-valid. Its source conclusion was
checked by compiling/disassembling all three terrain domain-shader variants.
Diagnostic repetition counts depend on the number of frames and are not a severity metric.

## KI-001 change and post-change checks

The shared renderer now follows device -> `IDXGIDevice` -> adapter -> parent
`IDXGIFactory1`, matching `Source/RendererDX11.cpp`. Each successful temporary
interface acquisition has a matching deferred release. Existing partial-initialization
cleanup concerns remain KI-012; this change does not add a recovery framework.

A second isolated probe called the corrected `renderer.create` with a hidden HWND.
The actual swap chain's parent factory and the device adapter's parent factory had
matching canonical `IUnknown` identities. Initialization, clear/present, and
destruction queues were empty. The hidden-window `Present` returned the expected
nonfailure `DXGI_STATUS_OCCLUDED`. Live-object reporting after teardown showed only
the device held by the probe's diagnostic interfaces, subsequently released.

Before editing source, all 14 rendering demos were debug-built and launched under
the native debugger (28 startup/later captures). After KI-001, all 14 were rebuilt
and rerun (100 captures), with normal resize and minimize/restore in each run.
Every run exited normally with code 0, without forced shutdown or debugger read errors.
Startup comparison sheets showed consistent rendering at unsynchronized animation
phases; restore and selected alternate-mode sheets were also inspected. Known
baseline exceptions and the diagnostics above remain unresolved.

| Demos | Additional post-change paths exercised |
|---|---|
| BasicApplication, RotatingCube, BasicComputeShader, BasicTessellation | Clear/animation/computed image/tessellated geometry, respectively |
| TessellationParams | Geometry, partition, and tessellation-factor controls |
| SkinAndBones | Settled animation, forward input, replay before/after restore |
| Curved PN Triangles | Rasterizer toggle and adaptive mode |
| InterlockingTerrainTiles | Freeze; simple/complex LOD; shaded wire/solid and LOD debug views |
| ImmediateRenderer | Three off-center projections and forward movement |
| ImageProcessor | Five filters, five images, alternate sampler, additional restore settling |
| LightPrepass | Three light counts and forward movement |
| DeferredRendering | None/SSAA/MSAA; optimized G-buffer; volume/none/scissor lighting; three light counts; G-buffer display; movement |
| WaterSimulation, ParticleStorm | Evolving simulations and forward movement |

Routine commands run from `odin_port/` after the code change:

```sh
just verify
just asan basic_application
just asan immediate_renderer
```

`just verify` passed all 15 strict compiler checks and all eight math tests with
test allocator tracking. Both ASan builds were also executed standalone: their
windows rendered, they exited with code 0, and sanitizer stderr was empty. An
earlier run under the native debugger produced handled first-chance exceptions;
standalone runs avoided confusing debugger interception with sanitizer failures.
These short runs are not an application-wide leak or stress audit.

Documentation checks passed for 78 local links, source-line bounds, code fences
in seven Markdown files, and 20 unique issue headings. The review-changes skill
passed its skill validator. `git diff --check` also passed.

To retain binaries for debugger launches and before/after hashes, the graphical
suite used the debug build equivalent of `just run` (there is no build-only recipe):

```sh
odin build apps/<app> -collection:glyph=glyph -out:<artifact-dir>/<app>.exe -subsystem:windows -debug
```

BasicWindow was compiler-checked but not rerun for KI-001 because it does not use
Direct3D. No forced allocation/device failures, FL10-only hardware, alternate
drivers, exhaustive control combinations, or long-duration stress were tested.
The probe's ownership check does not establish leak-free teardown in every demo.

## Repair sequence and test scope

Use one semantic change and one commit after relevant validation. Share build and
capture setup to save time; avoid rerunning every graphical demo for a local
constant. Keep shared contracts and their callers in the same change. Run the
repository's required checks, and preserve each fix's before/after evidence.

| Work unit | Suggested scope and relevant runtime tests |
|---|---|
| KI-019, then KI-002 | Separate terrain commits: first correct shading slots, then restore the compute lookup. Test all three shading variants with both hull modes; validate UAV/SRV transitions for KI-002. |
| KI-020 | Small ParticleStorm-only commit; check priming-to-insertion UAV transition and append counts with the debug layer. |
| KI-004 and KI-011 | Separate tiny commits sharing one SkinAndBones session, or an explicit two-item local batch. Check finite cone normals and oblique textured views. |
| KI-006 | Natural two-demo batch: water and particle startup framing/movement. Keep KI-005 feature-level work separate. |
| KI-013 | Local terrain dimensions/composition check; keep separate from shading and LOD changes. |
| KI-008 | Shared resize contract plus all six callers: ImmediateRenderer, ImageProcessor, ParticleStorm, WaterSimulation, DeferredRendering, LightPrepass. Test resize/minimize/restore and inject resize failure; normal resizing cannot prove failure handling. |
| KI-003 | Skin input/replay/aspect/resize after the resize contract is settled; include key-release behavior and right-drag. |
| KI-012 | Split by ownership boundary: shared renderer first, then individual scene/target groups. Inject relevant partial failures; use ASan and D3D ownership diagnostics. Shared startup changes require all 14 rendering demos. |
| KI-018 | All 14 rendering demos under constrained client sizes; check dependent targets and projection decisions. |
| KI-015 | Separate shared capture helper and local frame-loop groups; exercise repeated captures/title updates and measure allocator lifetimes. |
| KI-014 / KI-016 | Separate parser fixes with malformed/truncated input tests. DDS: ImmediateRenderer cube map. MS3D: BasicTessellation, SkinAndBones, DeferredRendering, LightPrepass valid-model smoke tests. |
| KI-005 / KI-017 | Explicit alternate paths: water's intended FL10/SM4 path; ParticleStorm with `DEBUG_COUNTS` enabled, including cleanup. |
| KI-009 / KI-010 | Separate inherited replacement-failure improvements for ImmediateRenderer / ImageProcessor; inject failures. A clear error and clean exit are sufficient. |
| KI-007 | No defect fix; mip generation would change the reference output. |

## P2 follow-up validation

### P2 follow-up: KI-019

Starting from `1cfd19c`, terrain DS slot b1 now follows the compiled shading
variant. `just check interlocking_terrain_tiles` passed. The retained debug build
ran all three shading modes with both hull modes plus resize/minimize/restore:
18 screen-client captures, exit 0, no D3D messages or debugger read errors.
Gray shaded terrain and the colored simple-LOD view now render as intended;
complex LOD remains a separate unfixed omission at this checkpoint. Evidence is
in `p2-fixes/KI-019/` beside the earlier artifact directories below.

### KI-002

After `f54515a`, the terrain compute prepass, lookup binding, and cleanup were
restored. `just check interlocking_terrain_tiles` and
`just asan interlocking_terrain_tiles` passed. The debug mode sweep captured 18
states with exit 0 and no D3D messages; the standalone ASan run rendered and
exited 0 with empty sanitizer stderr. Complex-mode wireframe and LOD debug
captures show varying refinement instead of minimum tessellation.

An external probe compiled a copy of the actual sample setup, read back the
32x32 RGBA32F lookup, and verified all 1,024 entries were finite with unit plane
normals and deviations spanning 0..0.95456916. Compute SRV/UAV slots were nil
after dispatch. After scene/renderer teardown, live-object reporting found only
the probe's diagnostic device references. Informational destruction messages
were allowed; no warnings other than that retained device were accepted.
Evidence: `p2-fixes/KI-002/`, `KI-002-asan/`, and `terrain-probe-output.txt`.

### KI-004

After `f7b6689`, `normalize0` restores C++ zero-input semantics in the cone
generator. `just check skin_and_bones` passed. An external copy of the actual
generator with the demo's `(16, 20, 2, 40, 6)` parameters produced 322 finite
normals: exactly 16 zero normals on the collapsed ring, all others unit length.
The debug demo completed its animation, movement attempt, resize/restore, and
replay run with seven captures, exit 0, and no D3D messages. Rendered cones and
the box remained consistent with the baseline; KI-003 was still unfixed here.
Evidence: `p2-fixes/KI-004/` and `cone-probe-output.txt`.

### KI-008

After `b4554ca`, shared resize returns success only after all resources and
dimensions are ready; every caller exits on failure. `just verify` passed all
15 checks and eight math tests. All six callers ran normal resize/minimize/restore
and their selected controls (53 captures total, all exit 0). Restored renders
were inspected; only the previously recorded ParticleStorm and LightPrepass
warnings appeared.

Six isolated app copies retained an extra backbuffer reference and set a pending
resize before their loops. Every copy exited 0 with `ResizeBuffers failed` and
exactly the expected DXGI outstanding-reference error (#19); no later invalid
rendering diagnostic occurred. A hidden probe of the actual shared helper covered
successful resize plus failures at `ResizeBuffers`, `GetBuffer`, RTV creation,
depth texture creation, and DSV creation. Probe-owned interface proxies forwarded
real calls except the selected failure. Failed cases returned false, left all
three view fields nil and dimensions unchanged, and stopped at the expected call.
Live-object reports after teardown showed only retained diagnostic device references.

`just asan immediate_renderer` passed; the executable rendered through resize
and restore and exited 0 with empty stderr. An ASan build of the isolated forced-
failure copy also exited 0 with only the expected resize diagnostic. Evidence:
`p2-fixes/KI-008/`, `KI-008-failure/`, `KI-008-asan/`, and `resize-probe/`.

### KI-003

After `42af028`, SkinAndBones gained the existing small Odin camera pattern and
checked resize/projection updates. `just check skin_and_bones` and
`just asan skin_and_bones` passed. Ten debug captures covered startup, settled
animation, forward movement, resize/restore, held/released A with replay, further
movement, and right-drag. All rendered with normal exit 0 and no D3D diagnostics.
The standalone ASan build also rendered through resize/restore and exited 0 with
empty sanitizer stderr. A forced outstanding-reference resize in an isolated
copy exited 0 with only the expected DXGI error and `ResizeBuffers failed`.

A probe of the actual callback/camera code verified the original startup view,
10 units/s movement, stationary position after key release, A replay without
latched strafe, consumed right-drag deltas, and forwarded resize dimensions.
Evidence: `p2-fixes/KI-003/`, `KI-003-asan/`, `KI-003-failure/`, and
`skin-input-probe-output.txt`. KI-005's optional FL10 path and other P3 work
remain outside this five-fix P2 sequence.

The final `just verify` passed all 15 strict compiler checks and eight tracked
math tests. Documentation checks passed for 75 local links/source-line bounds,
balanced fences in seven files, 20 unique issue headings, and all five P2 rows
marked fixed. `git diff --check` passed. `p2-fixes/summary.json` records hashes,
diagnostics, and 106 screen-client captures across the ten debug demo runs in
this sequence. The failure and ASan probes are additional, separately recorded runs.

## P3 follow-up validation

Each issue below was committed after its recorded checks. Artifacts are under
`p3-fixes/` beside the earlier `p2-fixes/` directory.

### KI-006

From ea0b0a1, ParticleStorm and WaterSimulation camera translations were corrected to (-100,60.5,-100) and (-100,30.5,-100). Both just check recipes passed. Both debug runs exercised movement, resize and restore (five captures each, exit 0). Startup rendering was inspected. Water had no D3D messages; ParticleStorm retained only the known KI-020 UAV hazard. Evidence: p3-fixes/KI-006/.

### KI-011

SkinAndBones just check passed. A hidden probe of actual setup queried ANISOTROPIC/MaxAnisotropy=16 with no setup warnings/errors. The ten-capture debug run exercised animation, replay, movement, oblique right-drag views and resize/restore, with exit 0 and no D3D messages. No mip-chain changes were made. Evidence: p3-fixes/KI-011/ and sampler-probe-output.txt.

### KI-013

just check interlocking_terrain_tiles passed. The 18-capture debug run covered all shading/hull combinations and resize/restore, exit 0 with no D3D messages. The initial 1536x1152 screen-client capture matches the C++ baseline at 150% scaling; gray shading and composition were inspected. This corrects requested size only; actual-size handling remains KI-018. Evidence: p3-fixes/KI-013/.

### KI-020

just check particle_storm passed. Normal and DEBUG_COUNTS=true builds each ran startup, animation, movement and resize/restore (five captures, exit 0). The normal build had no D3D messages; the counter build had no UAV hazard but reported the known KI-017 live-object leak at shutdown. Counter output showed current=0 and positive, increasing next counts, confirming unbinding preserved append counters. Particle rendering was inspected. Optional staging-buffer ownership remains KI-017 at this checkpoint. Evidence: p3-fixes/KI-020/ and KI-020-counts/.

### KI-017

Normal and DEBUG_COUNTS checks passed, along with just asan particle_storm and an additional ASan build with DEBUG_COUNTS=true. Normal startup (two captures), enabled movement/resize run (five captures), and enabled ASan resize/restore all rendered and exited 0. The enabled native debug log is now empty, where KI-020-counts had reported 40 live-object messages. An isolated zero-byte staging descriptor produced exactly the two expected CreateBuffer errors and a clean exit before readback. Evidence: p3-fixes/KI-017/, KI-017-counts/, KI-017-asan/, and particle-count-failure/.

### KI-014

just check immediate_renderer and just asan immediate_renderer passed. An ASan hidden probe tested zero dimensions, 65536x65536 overflow input, oversized dimensions, maximum-size truncated input, header-only and one-byte-short payloads, plus a valid 2x2 six-face cube. All invalid inputs returned false before D3D creation; valid creation had no D3D warnings/errors. The bundled skybox rendered in an eight-capture debug mode sweep and an ASan resize/restore run, both exit 0 with clean diagnostics. Evidence: p3-fixes/KI-014/, KI-014-asan/, dds-probe-output.txt.

### KI-016

`just verify` passed all 15 strict checks and eight tracked math tests; `just asan basic_tessellation` and its standalone startup/resize/restore run passed. An ASan probe importing the actual MS3D loader rejected six missing/partial vertex or triangle count fixtures and loaded hedra, box, and Sample_Scene. Debugger-backed startup runs of BasicTessellation, SkinAndBones, DeferredRendering, and LightPrepass exited normally; the only diagnostic was LightPrepass's retained mask-pass warning. All four startup captures were inspected. Evidence: `p3-fixes/ms3d-probe/`, `ms3d-probe-output.txt`, `KI-016/`, and `KI-016-asan/`.

### KI-009

`just check immediate_renderer` and `just asan immediate_renderer` passed. The demo passed eight debugger-backed startup/control/resize captures and a standalone ASan startup/resize/restore run, with normal exits and no diagnostics. An ASan probe using an unchanged copy of mesh.odin and private COM forwarding proxies exercised successful growth and failures in vertex creation, index creation, vertex Map, and index Map; dirty/capacity state, balanced Unmap calls, and cleanup passed, with no D3D warnings/errors. Startup geometry was visually inspected. Evidence: `p3-fixes/KI-009/`, `KI-009-asan/`, `mesh-probe/`, and `mesh-probe-output.txt`.

### KI-010

`just check image_processor` and `just asan image_processor` passed. Fourteen debugger-backed captures covered all five images/algorithms, sampler, pan/zoom and resize; the standalone ASan run covered startup/resize/restore. Both exited normally with no diagnostics, and startup output was visually inspected. Two isolated app copies injected failure after texture/SRV acquisition in the first or second replacement target; both printed the expected error, exited normally and produced no debug-layer or live-object warnings. Evidence: `p3-fixes/KI-010/`, `KI-010-asan/`, and `image-replacement-failure-{3,4}/`.

### KI-005

`just check water_simulation` passed. A hidden probe confirmed GetFeatureLevel == FL10_0, the optional compute/structured-buffer capability, successful SM4 shader compilation and actual scene creation without D3D warnings/errors. The real demo passed five debugger-backed startup/camera/resize/restore captures, exited normally and emitted no diagnostics; the wireframe water output was visually inspected. This establishes the FL10 device path on the installed AMD GPU, not compatibility with every historical FL10 adapter. Microsoft documents the optional capability and structured SRVs across shader stages in [Compute Shaders on Downlevel Hardware](https://learn.microsoft.com/en-us/windows/win32/direct3d11/overviews-direct3d-11-devices-downlevel-compute-shaders). Evidence: `p3-fixes/KI-005/`, `water-fl10-probe/`, and `water-fl10-probe-output.txt`.

### KI-015

`just verify` passed all 15 checks and eight tracked math tests. All ten changed demos passed debugger-backed startup runs with no diagnostics; CurvedPN and TessellationParams startup visuals were inspected. `just asan tessellation_params` and `just asan curved_pn_triangles` builds and standalone resize/restore runs passed. Isolated ASan copies wrapped the actual temp allocator with tracking and forced repeated screenshots (three frames per screenshot-capable demo, 32 screenshot/title-update frames for TessellationParams); ImageProcessor exercised three message iterations. Every subsequent iteration observed zero outstanding scratch bytes. A separate ASan/heap-tracking PLY probe loaded CPNTest three times: only its two mesh arrays remained after each load, and destruction left zero tracked heap bytes. Evidence: `p3-fixes/KI-015/`, `KI-015-asan/`, `scratch-probes/`, `ply-scratch-probe/`, and `ply-scratch-output.txt`.

### KI-018

`just verify` passed all 15 strict checks and eight tracked math tests. All 14 rendering demos passed normal debugger-backed startup runs. A separate copied glyph/window collection constrained only creation to 480x270 while leaving sample WIDTH/HEIGHT constants intact; all 14 passed assertions on actual client, backbuffer, depth and viewport sizes and rendered normally. Extra assertions covered LightPrepass targets, all Deferred targets including 960x540 SSAA, Water/Particle depth and image-sized filter targets. This is a controlled constrained-creation simulation, not a natural desktop-limit reproduction. Physical captures were 720x405 at 150% scaling. The three changed-aspect startup views were inspected. Both sets exited normally; only LightPrepass's retained mask warning appeared. Evidence: `p3-fixes/KI-018/`, `constrained-probes/`, `KI-018-constrained-build/`, and `KI-018-constrained/`.

### KI-012 — shared renderer boundary

`just verify` passed. All 14 demos passed debugger-backed startup runs (only the retained LightPrepass mask warning); `just asan basic_application` and standalone resize/restore passed. An ASan probe exercised success, nine synthetic early returns after successive acquisitions, and a real CreateSwapChain failure with a null HWND. Every failure returned an empty renderer before caller destruction; live-object reports showed only the intentionally retained diagnostic device. The probe caught Odin's return-before-defer copy behavior, prompting a separate local construction value; `just verify` passed again after that correction. Evidence: `p3-fixes/KI-012-renderer/`, `KI-012-renderer-asan/`, `renderer-ownership-probe/`, and `renderer-ownership-output.txt`.

### KI-012

`just verify` passed all 15 checks and eight tracked math tests. All 13 changed samples passed debugger-backed startup; only LightPrepass's retained mask warning appeared. `just asan deferred_rendering`, `just asan image_processor`, and `just asan curved_pn_triangles` builds and standalone resize/restore runs passed. Isolated ASan probes passed 38 successful/failed constructor cases across all 13 samples, including nested patch/target/lookup failures and four Deferred shader-compilation failure positions. Each failed result was empty before caller destruction; real D3D live-object reports retained only diagnostic devices, wrapped compiler-blob reference counts returned to zero, and tracked Odin heap storage returned to zero. Ten tests exercised both failure orders in the five actual copied startup sibling blocks. Three malformed PLY fixtures failed after array allocation without leaks. Failure gates were synthetic early returns/failed conditions, not simulated GPU exhaustion. A separate read-only review found no correctness issue. Evidence: `p3-fixes/KI-012-samples/`, `KI-012-samples-asan/`, `sample-ownership-probes/`, `sibling-ownership-probes/`, `ply-ownership-probe/`, and `ply-ownership-output.txt`.

## Retained local evidence

Artifacts are outside the repository under:

```text
%USERPROFILE%/.codex/visualizations/2026/09/06/01a078e7-6aba-7140-bd26-d0e1d547b055/
```

- `runtime-baseline-9a91a68/`: `BASELINE.md`, comparison `index.html`, `manifest.json`,
  per-run captures/actions, GPU inventory, and terrain shader-binding probe/output.
- `instrumentation-ki001/`: device and factory probes with outputs; temporary native
  debugger and launch scripts; retained `before/` and `after/` binaries, hashes and
  captures; diagnostic `summary.json`; `inherited-check/` reproducing curved PN's
  error with the old binary; and `asan-standalone/` results.
- `p2-fixes/`: per-issue demo captures, debug logs, sanitizer runs and targeted
  shader, terrain, input and resize-failure probes.
- `p3-fixes/`: per-issue retained binaries, screen-client captures and native
  debug logs; ASan runs; parser, feature-level, constrained-window, allocator,
  resource-failure and compiler-blob ownership probes. Final `just verify` passed;
  documentation checks passed 74 local links, line bounds and code fences.

These local artifacts are not distributed with the repository. This document
retains the conclusions and limits; the local scripts/logs retain the exact actions.

## Documentation cleanup after c6b394a

Retired `KNOWN_ISSUES.md` after preserving accepted departures and inherited
limitations in sample notes and nearby code comments. The tracker is recoverable
from the revision named above; the historical checkpoints in this record remain
unchanged. Corrected the skin-matrix explanation, guide dispatch/depth examples,
screenshot location, and camera coverage; removed resolved issue labels and
repeated curriculum advice from reader-facing material.

Validation: `just verify` passed all 15 strict application checks and all eight
tracked math tests. A diff check confirmed that every changed Odin source line
was a comment or whitespace; executable code and shaders were unchanged. All nine
local Markdown links in AGENTS, the guide, README, and this record resolved,
including their heading/line anchors; code fences were balanced and no live link
to the retired tracker remained. `git diff --check` passed. No new graphical,
ASan, or D3D debug-layer runs were needed for this documentation-only cleanup;
the preceding runtime evidence remains the applicable baseline.
