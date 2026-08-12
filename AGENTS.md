# Repository guidance

## Project intent

- Treat the Odin port as a learning-oriented reference implementation of the book's C++ code.
- Preserve the observable behavior and structure of the corresponding book sample unless Odin semantics, undefined behavior, or a clearly broken advertised path requires a documented deviation.
- Keep the legacy C++ sources available as the behavioral reference. Do not modernize or otherwise change them unless the task explicitly includes that work.
- This repository is a playground: prefer small, reviewable changes and explain intentional departures from the reference implementation.

## Local workflow

- Prefer Git Bash and portable POSIX shell commands for developer-facing instructions and scripts.
- From `odin_port/`, use the `Justfile` recipes for routine builds, checks, tests, and sanitizer builds.
- Local validation is the expected workflow. Do not add GitHub Actions, pre-commit hooks, or another enforcement system unless the task explicitly asks for one.
- Report the validation commands actually run. Do not imply that local checks were enforced by CI.

## Working on the Odin port

- Before changing a sample, locate and compare its counterpart under `Applications/` and any relevant engine code under `Source/`.
- Distinguish an Odin port regression from inherited book behavior, an intentional documented deviation, and optional robustness work.
- Preserve Direct3D lifecycle and ownership invariants, especially resource creation failure paths, resize handling, `Present` behavior, mapped-resource bounds, COM releases, and GPU/CPU synchronization.
- Check Odin-specific hazards such as integer and enum conversions, normalization of zero-length vectors, `defer` scope, temporary allocator lifetimes, slices that outlive their storage, and accidental shadowing.
- When one sample contains a defect caused by a repeated porting pattern, search the other samples and shared `glyph` code for the same pattern.

## Validation

- From `odin_port/`, run `just check <app>` for a changed sample and `just check-all` when shared `glyph` code changes.
- Run `just test` when math or other covered shared behavior changes.
- Run `just verify` before finishing a branch-wide review or change.
- For ownership, bounds, or lifetime changes, build the relevant sample with `just asan <app>` and run it when the environment supports the sample.
- Use the tracking allocator and Direct3D debug layer when the affected path needs leak, lifetime, or API validation. Compiler checks and sanitizer builds complement review; they do not establish behavioral equivalence by themselves.

## Review expectations

- Review the requested diff against its stated base, then inspect enough reference code and call sites to establish the affected behavior.
- Prioritize reproducible correctness, memory safety, API misuse, and behavioral divergence. Skip subjective style feedback unless it obscures a defect or conflicts with this file.
- Describe the concrete trigger and consequence of each issue, use the narrowest useful location, and avoid speculative findings.
- Treat passing `odin check`, ASan, the tracking allocator, and debug-layer validation as evidence when they were actually run, while still reviewing semantic behavior those tools cannot cover.
- Label inherited book issues as such; do not present them as regressions introduced by the port.
