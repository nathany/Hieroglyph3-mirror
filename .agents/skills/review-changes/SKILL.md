---
name: review-changes
description: Review repository diffs or audit the current Odin port against its C++ reference. Use for branch, commit, or working-tree reviews, fresh reference-fidelity audits, and validation of reported issues in this repository.
---

# Review Changes

Review the requested scope using executable reference behavior and local validation. Separate whether a report is real, where it originates, and whether fixing it serves the educational purpose.

## Establish scope

1. Read the root and applicable scoped `AGENTS.md` files before evaluating changes.
2. Select the requested review mode:
   - **Diff review:** use the supplied base, commit range, or staged/unstaged scope. For a branch review without a base, infer the default branch and compute a local merge base without fetching or changing refs.
   - **Current-tree audit:** use the requested file/sample scope, record the revision and relevant uncommitted changes, and compare against the C++ reference. Do not invent a historical diff or exclude a defect solely because it predates the audit.
3. Inspect the complete requested diff or audit scope, then open definitions, call sites, tests, and reference implementations needed to establish behavior. When validating a prior issue list, treat both accepted and rejected reports as hypotheses.
4. For each in-scope sample, inventory its observable behavior and major lifecycle stages: initialization, input, resize, update, rendering, capture, presentation, and cleanup. In a diff review, trace affected behavior beyond the changed lines; in an audit, include unchanged in-scope paths.
5. Preserve unrelated working-tree changes and perform no fixes unless the user asks for implementation.

## Separate deterministic validation

1. From `odin_port/`, run `just verify` when the review includes the Odin port. For a narrow sample-only change, `just check <app>` may be used first, but use `just verify` before completing a branch-wide review.
2. If the Windows sandbox cannot read a winget-installed `just`, request narrowly scoped permission to run `just` outside the sandbox; do not silently replace or skip the repository recipe.
3. Use `just asan <app>` for relevant ownership, bounds, or lifetime changes. Distinguish a successful sanitizer build from executing the affected runtime path.
4. Use tracking-allocator or Direct3D debug-layer evidence when available and relevant.
5. Run `git diff --check` against the reviewed range or relevant working-tree changes. Keep unrelated failures separate; a clean diff does not validate unchanged audit targets.
6. Report tool failures separately from semantic review findings. Assume a check is covered only when its current result is available; the mere existence of a recipe is not evidence.

## Review semantically

When reviewing Odin code, read [references/odin-d3d11-checklist.md](references/odin-d3d11-checklist.md) and apply its categories to the requested scope. Distinguish full inspection, targeted inspection, not applicable, and uninspected or runtime-unverified paths. An uninspected category is not evidence of correctness; report material gaps rather than implying exhaustive coverage.

Perform distinct passes rather than assigning every file to only one reviewer:

1. **Reference parity:** Compare startup camera and transforms, controls, resize forwarding, feature levels, shader profiles, resource bindings, mip and sampler settings, and output behavior with the corresponding code under `Applications/` and `Source/`. Treat port comments and documentation as claims to verify, not as proof of inherited behavior.
2. **Semantic translation:** Trace actual arguments through the relevant C++ helper branches, including the dependency version used by the repository. Check nullable outputs, flags, defaults, and conversions that enable or suppress behavior. A helper's advertised capability does not prove this call uses it. If the matching implementation cannot be verified, qualify the conclusion.
3. **Lifecycle and call order:** Trace partial initialization and failure cleanup, the frame loop, input, resize, capture, `Present`, temporary-allocation reset, and shutdown. Inspect every caller when shared `glyph` behavior or a repeated application pattern is involved.
4. **Direct3D contracts:** Trace resource ownership and replacement, mapped-resource bounds, COM lifetime, GPU/CPU synchronization, actual resource dimensions, and shader or pipeline contracts. Verify API assumptions against authoritative documentation when necessary.
5. **Odin hazards:** Check size arithmetic before narrowing, integer and enum conversions, zero-length normalization, `defer` scope, allocator lifetime, slice backing storage, shadowing, and platform assumptions.
6. **Ordinary review:** Retain actionable correctness, security, performance, and maintainability findings not covered by the project-specific passes.
7. **Reader-facing documentation, when requested:** Check guide examples and claimed translations against executable code, including shader-stage dependencies and compiler-sensitive layout claims. Use small temporary probes where they resolve uncertainty; record the toolchain and distinguish a compile check from execution. Keep workflow instructions in `AGENTS.md`, and separate factual corrections from optional curriculum or style suggestions.

After confirming a shared-helper or repeated-pattern defect, use `rg` across applications and shared `glyph` code. Report affected in-scope locations or the common fix point; identify occurrences outside a requested diff separately rather than presenting them as introduced by it.

For a large diff or audit with independent risk areas, use available subagents for focused, read-only investigations. Prefer distinct lenses such as reference parity, shared Direct3D lifecycle, and Odin safety over simple file partitions. Give investigators the requested scope, raw artifacts, and repository guidance without expected conclusions, then independently verify and deduplicate their candidates. Keep small or tightly coupled reviews in one agent.

## Apply the finding bar

For a **diff review**, an actionable defect must be introduced by the reviewed change, have a concrete trigger and consequence, and be something the author would likely fix. For a **current-tree audit**, the same evidence bar applies without the introduced-by-change requirement; inherited defects and optional improvements may be reported under their own labels.

Evaluate validity, origin, and priority separately. Compare failure behavior in the C++ helper as well as Odin before calling it a port regression. Consider supported hardware, trusted assets, normal versus optional paths, effect on the lesson, and fix complexity. Prefer a clear error, cleanup, and exit where adequate; do not require rollback, retry, or general device recovery merely to harden a demo. Do not report speculative risks or subjective preferences as defects.

Use severity sparingly:

- `P0`: release-blocking or catastrophic in ordinary use.
- `P1`: high-impact failure on a common or critical path, supported by reproduction or an authoritative API contract.
- `P2`: real correctness problem under a plausible condition.
- `P3`: limited-impact but still worthwhile, actionable defect.

An authoritative API contract can establish a violation without establishing its frequency on local hardware. State that distinction. An inherited defect may deserve repair, and a tiny low-priority fidelity correction may be worth doing early.

## Present the review

- Put confirmed actionable findings first, ordered by severity. For diff reviews, attach changed-line feedback with `::code-comment{...}` when the review interface supports it, using the shortest useful line range.
- For each finding, identify the trigger, consequence, and practical remedy concisely.
- When validating reports, record **confirmed / disproved / unresolved**, C++ and Odin evidence, origin, priority, and the minimum educational divergence of the remedy. Keep decisive evidence for rejected or reclassified reports, preserving existing issue IDs when updating a tracker. Do not turn proposed fixes into edits without authorization.
- Follow findings with validation performed and any meaningful residual risks.
- If no actionable findings remain, say so directly rather than manufacturing feedback.
