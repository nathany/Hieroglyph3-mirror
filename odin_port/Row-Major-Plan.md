# Plan: move the demos to row-vector / `#row_major` (`glyph:d3d_math`)

Goal: every demo uses the guide's Setup A — `dm.Matrix4f32` fields, `dm.*`
builders, book-order composition (`world * view * proj`, `v * m`). No
column-vector support survives: `glyph:camera` is deleted at the end.

The book's C++ is already row-vector, so the finished Odin should read
line-for-line like the original — **the C++ source is the answer key** for
every reversed composition. `glyph:shader`'s compile flag is already correct
for Setup A and does not change.

Why this is safe: the `d3d_math` test suite proves the builders equivalent
(`odin test glyph\d3d_math -collection:glyph=glyph`), and the two conventions
upload the same cbuffer bytes — bit-exact for single matrices, ~5e-7 for
composed products — so the rendered output is unchanged.

## The recipe (per demo)

1. **Change the field types.** Every `matrix[4, 4]f32` in a cbuffer/upload
   struct (including `[N]matrix[4, 4]f32` arrays) becomes `dm.Matrix4f32`.
   Because it's a distinct type, the compiler now lists every line that
   needs converting — the migration checklist is the error output.
2. **Chase the errors.** `linalg.matrix4_*` → `dm.matrix4_*`,
   `linalg.matrix3_rotate_f32` → `dm.matrix3_rotate_f32`,
   `linalg.inverse` (on 4×4s) → `dm.inverse`, `camera.*` → `dm.*` (identical
   names and signatures — just swap the import).
3. **Reverse the math** — the one step the compiler *cannot* check, since
   both orders type-check:
   - every matrix product: `proj * view * world` → `world * view * proj`
   - every point/vector transform: `m * v` → `v * m`
   Verify each against the corresponding C++ line, which already reads in
   the target order.
4. **Leave alone** (verified by the test suite):
   - `linalg.transpose(dm.inverse(world))` — the normal-matrix formula is
     form-invariant, and `transpose` preserves the `#row_major` type.
   - `transmute([16]f32)m` upload workarounds (gotcha #6): the fields stay
     `[16]f32`; transmuting the `dm` matrix yields the same bytes.
   - Diagonal/single-element reads like `proj[0, 0]` (transpose-invariant),
     and HLSL-indexing reads, which now match *without* mirroring:
     `ProjMatrix[3][2]` is simply `proj[3, 2]`.
5. **Rewrite the convention comments** in the file (they currently explain
   the column-vector cancellation; see the sweep list below).

**Gotcha when scripting the swaps:** `sed -i` rewrites the whole file with LF
endings. Three files are stored CRLF — `apps/basic_tessellation/main.odin`,
`apps/curved_pn_triangles/ply.odin`, `glyph/ms3d/ms3d.odin` — and a converted
one shows up as an every-line diff. Check with `file`, restore with
`perl -pi -e 's/(?<!\r)\n/\r\n/'`, and confirm `git diff --stat` shows only
the real lines.

## Progress

- ✅ rotating_cube — bytes bit-exact at six animation times; visually
  spot-checked against the C++ by Nathan.
- ✅ basic_tessellation, tessellation_params, curved_pn_triangles,
  interlocking_terrain_tiles — every uploaded matrix bit-exact (including
  the normal matrix, confirming form-invariance empirically).

## Inventory

`fp_camera.odin` is byte-identical in 5 apps (water_simulation,
particle_storm, deferred_rendering, immediate_renderer, light_prepass):
port it **once** — `camera_rotation` reverses to
`dm.matrix4_rotate_f32(pitch, {1,0,0}) * dm.matrix4_rotate_f32(yaw, {0,1,0})`,
`camera_view_matrix` to `translate(-pos) * transpose(rotation)` — then copy
to the other four.

| App | Matrix work beyond the recipe |
|---|---|
| basic_window, basic_application, basic_compute_shader, image_processor | none — no matrix code |
| rotating_cube | 1 wvp; `world` becomes `Ry(t) * Rx(t)`, matching the C++ comment already in the file |
| basic_tessellation | world + view_proj, two structs |
| tessellation_params | world + view_proj |
| water_simulation | wvp + fp_camera |
| interlocking_terrain_tiles | inv_tpose_world normal matrix (form-invariant) |
| curved_pn_triangles | inv_tpose_world + orbit camera |
| particle_storm | world_view + proj split + fp_camera |
| skin_and_bones | densest math: `euler_rotation` (reverse to Z·X·Y order), `bones_update` locals, `inv_bind`/skin/normal matrices, `[NUM_BONES]` arrays, hand-built view `translate * transpose(rot)` |
| light_prepass | `inv_proj = dm.inverse(proj)`, fp_camera, convention comment at main.odin:77 |
| deferred_rendering | largest: `[16]f32` proj/inv_proj fields (transmute source swaps 1:1), `calc_scissor_rect`'s `view * center` → `center * view`, `volume_world` reversal, fp_camera |
| immediate_renderer | largest surface: `object_world_matrix`, mesh.odin's 3×3 shape rotations (`rot * v` → `v * rot`), `light_pos_3`, off-center projections; skybox.odin has no matrix code |

## Order of attack

1. **rotating_cube** — smallest, and the canary: one matrix through the
   whole pipeline. Verify before continuing.
2. basic_tessellation, tessellation_params, curved_pn_triangles,
   interlocking_terrain_tiles — fixed cameras, adds the normal matrix.
3. water_simulation — first fp_camera consumer; port the shared file here,
   then copy into particle_storm and verify both.
4. skin_and_bones — the bone math.
5. light_prepass, deferred_rendering, immediate_renderer — the big three.

## Verification (per demo, before moving on)

- Build & run via `odrun.bat`; exercise the demo's keys (the README section
  lists each one's behaviors). For side-by-side comparison, build all apps
  *before* starting and stash the exes from `bin\` — old vs new should be
  visually indistinguishable.
- `Space` screenshots where supported for closer inspection of stills.
- After each app: the full `odin check` sweep still passes and the
  `d3d_math` test suite stays green (it never depended on `glyph:camera`).

## Cleanup (after all demos)

- Delete `glyph/camera` (d3d_math supersedes it; nothing else imports it).
- `glyph/shader/shader.odin` header: collapse the two-pairings note to
  Setup A; drop "what these demos use" from the column-vector bullet.
- Guide: the addendum's "what `odin_port`'s demos use" framing becomes
  historical/informational; the camera-function trap's `glyph:camera`
  reference updates to `glyph:d3d_math` only.
- README: rewrite rotating_cube's matrix paragraph (composition order is now
  the book's); sweep remaining "column-vector" mentions.
- Comment sweep — files whose comments explain the old cancellation:
  rotating_cube/main.odin (~13, 44, 308), immediate_renderer/main.odin
  (~48–53), light_prepass/main.odin (~77–78), deferred_rendering/main.odin
  (~163, 1163). Grep `column-vector|no transpose` over `odin_port` to catch
  stragglers.
