# Runtime baseline and issue-fix validation

Recorded 2026-09-06 using Odin `dev-2026-09-nightly:a2fb372` on Windows.
The original visual baseline used source revision `9a91a68`; the subsequent
documentation commit `b1cf63b` did not change demo code. The KI-001 results below
cover the factory-chain correction to that code.

**Result:** the instrumentation works, and KI-001 passed the checks below with
no observed new visual regression. The baseline still contains known defects;
successful startup and normal exit do not mean every rendering mode is correct.
See [KNOWN_ISSUES.md](../KNOWN_ISSUES.md) for classifications and repair scope.

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

## Retained local evidence

### P2 follow-up: KI-019

Starting from `1cfd19c`, terrain DS slot b1 now follows the compiled shading
variant. `just check interlocking_terrain_tiles` passed. The retained debug build
ran all three shading modes with both hull modes plus resize/minimize/restore:
18 screen-client captures, exit 0, no D3D messages or debugger read errors.
Gray shaded terrain and the colored simple-LOD view now render as intended;
complex LOD remains a separate unfixed omission at this checkpoint. Evidence is
in `p2-fixes/KI-019/` beside the earlier artifact directories below.

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

These local artifacts are not distributed with the repository. This document
retains the conclusions and limits; the local scripts/logs retain the exact actions.
