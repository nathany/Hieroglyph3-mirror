# Repository guidance

## Project intent

- Treat the Odin port as a learning-oriented reference implementation of the book's C++ code.
- Treat `D3D11-Odin-Guide.md` as a human-facing companion for readers implementing the book's examples by hand. Keep agent-specific workflow, review, and automation instructions in `AGENTS.md`, not in the guide.
- Preserve the observable behavior and structure of the corresponding book sample unless Odin semantics, undefined behavior, or a clearly broken advertised path requires a documented deviation.
- Preserve the sample's rendering stages, shader contracts, and behavior while replacing engine architecture with small Odin structs and procedures where useful. Recreating the scene graph, reflection system, or event framework is not required.
- Record accepted deviations in reader-facing sample notes and concise matching code comments. Prefer a clear error and clean exit for an unrecoverable demo failure; a general retry or device-recovery framework is not required.
- Keep the legacy C++ sources available as the behavioral reference. Do not modernize or otherwise change them unless the task explicitly includes that work.
- This repository is a playground: prefer small, reviewable changes and explain intentional departures from the reference implementation.

## Local workflow

- Prefer Git Bash and portable POSIX shell commands for developer-facing instructions and scripts.
- From `odin_port/`, use the `Justfile` recipes for routine builds, checks, tests, and sanitizer builds.
- Local validation is the expected workflow. Do not add GitHub Actions, pre-commit hooks, or another enforcement system unless the task explicitly asks for one.
- Report the validation commands actually run. Do not imply that local checks were enforced by CI.

## Working on the Odin port

- Before changing a sample, locate and compare its counterpart under `Applications/` and any relevant engine code under `Source/`.
- Treat executable C++ behavior, including the semantics of helpers it calls, as the authority for reference fidelity. Treat comments and documentation that claim a quirk is inherited as hypotheses to verify against the C++ implementation.
- Trace actual arguments and conditional branches through helpers, including the dependency version used by the repository. A helper's advertised capability does not establish that this call enables it; nullable output parameters and flags can change behavior.
- Distinguish an Odin port regression from inherited book behavior, an intentional documented deviation, and optional robustness work.
- Classify an issue separately from its repair priority. Consider its concrete trigger, effect on the lesson, supported hardware and trusted assets, and the smallest useful fix. An inherited defect may deserve repair; an input-hardening issue may remain low priority.
- Compare the complete behavior surface of a changed sample: startup camera and transforms, input and resize forwarding, requested feature levels and shader profiles, resource creation and binding, mip and sampler settings, and render/capture/`Present` ordering.
- Preserve Direct3D lifecycle and ownership invariants, especially resource creation failure paths, resize handling, `Present` behavior, mapped-resource bounds, COM releases, and GPU/CPU synchronization.
- Check Odin-specific hazards such as checked size arithmetic before narrowing, integer and enum conversions, normalization of zero-length vectors, partial-initialization cleanup, `defer` scope, temporary allocator lifetimes in long-running loops, slices that outlive their storage, actual versus requested dimensions, and accidental shadowing.
- Odin copies return values before running deferred cleanup. A constructor that cleans partial resources in a defer should build in a separate local value and return it only on success; otherwise failure can return stale handles. Failure probes must inspect returned ownership and cleanup before calling the caller's destructor.
- When one sample contains a defect caused by a repeated porting pattern, search the other samples and shared `glyph` code for the same pattern.
- Verify resource slots for every affected compiled shader variant and stage. Unused cbuffers can disappear and change implicit slots; legal bindings can supply semantically wrong data without a debug-layer error.
- Trace camera event registration as well as input forwarding. The C++ DeferredRendering and LightPrepass setup overrides omit camera registration; preserve and document the useful Odin camera behavior.

## Validation

- From `odin_port/`, run `just check <app>` for a changed sample and `just check-all` when shared `glyph` code changes.
- Run `just test` when math or other covered shared behavior changes.
- Run `just verify` before finishing a branch-wide review or change.
- For ownership, bounds, or lifetime changes, build the relevant sample with `just asan <app>` and run it when the environment supports the sample.
- Use the tracking allocator and Direct3D debug layer when the affected path needs leak, lifetime, or API validation. Compiler checks and sanitizer builds complement review; they do not establish behavioral equivalence by themselves.
- Distinguish requesting the debug layer from observing it. When establishing instrumentation, verify the device's debug flag and debug interfaces, observe a controlled diagnostic in an isolated probe, and collect actual demo messages. Keep deliberate probe errors separate from application findings; do not globally mute warnings to obtain a clean result.
- Use shader reflection/disassembly or a RenderDoc frame when binding or rendering evidence is needed. RenderDoc is optional; record whether capture and replay actually worked rather than treating installation as validation.
- For graphical baselines, record revision, compiler, executable provenance, controls, dimensions/DPI, and capture method. Verify that captures show the actual client area; allow slow frames to settle and avoid pixel-equality claims for unsynchronized animation. Retain observed exceptions when comparing later fixes.
- Consult [odin_port/VALIDATION.md](odin_port/VALIDATION.md) for the established baseline and instrumentation evidence. Update it and the issue's status after a validated fix; distinguish new regressions from retained baseline diagnostics. Reuse working instrumentation without repeating its setup probes unless the environment or collection path changes.
- Prefer one semantic fix per commit after relevant validation. Keep shared API-contract changes and their callers together; use small batches only when they share a cause or narrowly shared test scope. Retest all 14 rendering demos for shared renderer startup changes; target local fixes to their affected demos and modes. BasicWindow does not use Direct3D.

## Review expectations

- Review the requested diff against its stated base, then inspect enough reference code and call sites to establish the affected behavior.
- For a fresh audit, review the requested current-tree scope and record the revision instead of inferring a historical diff. The introduced-by-change finding bar applies to diff reviews; current-tree audits may report older defects with their provenance stated.
- For reference-fidelity conclusions, verify both the corresponding C++ call site and any helper implementation whose language-specific semantics could change the result.
- Prioritize reproducible correctness, memory safety, API misuse, and behavioral divergence. Skip subjective style feedback unless it obscures a defect or conflicts with this file.
- Describe the concrete trigger and consequence of each issue, use the narrowest useful location, and avoid speculative findings.
- Treat passing `odin check`, ASan, the tracking allocator, and debug-layer validation as evidence when they were actually run, while still reviewing semantic behavior those tools cannot cover.
- Label inherited book issues as such; do not present them as regressions introduced by the port.
- Treat previous findings and rejected reports as hypotheses to revalidate. Record the evidence for rejecting or reclassifying a report as well as for accepting it, and state any uninspected scope or runtime path.
