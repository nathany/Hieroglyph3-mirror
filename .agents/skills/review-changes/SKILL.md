---
name: review-changes
description: Review local branches, commit ranges, or working-tree changes for actionable defects. Use when Codex is asked to review code against a base, recent commits, staged changes, or unstaged changes in this repository.
---

# Review Changes

Perform an evidence-driven review using repository instructions and local validation rather than relying on the diff alone.

## Establish scope

1. Read the root and applicable scoped `AGENTS.md` files before evaluating changes.
2. Use the base, merge base, commit range, or file scope given by the user. If omitted, infer the default branch and compute a local merge base without fetching or changing refs.
3. Inspect the complete diff, then open affected definitions, call sites, tests, and reference implementations needed to establish behavior.
4. For each changed sample, inventory its observable behavior and major lifecycle stages before dividing the review: initialization, input, resize, update, rendering, capture, presentation, and cleanup.
5. Preserve unrelated working-tree changes and perform no fixes unless the user asks for implementation.

## Separate deterministic validation

1. From `odin_port/`, run `just verify` when the review includes the Odin port. For a narrow sample-only change, `just check <app>` may be used first, but use `just verify` before completing a branch-wide review.
2. If the Windows sandbox cannot read a winget-installed `just`, request narrowly scoped permission to run `just` outside the sandbox; do not silently replace or skip the repository recipe.
3. Use `just asan <app>` for relevant ownership, bounds, or lifetime changes. Distinguish a successful sanitizer build from executing the affected runtime path.
4. Use tracking-allocator or Direct3D debug-layer evidence when available and relevant.
5. Run `git diff --check` against the reviewed range. Keep failures from unrelated working-tree files separate from branch findings.
6. Report tool failures separately from semantic review findings. Assume a check is covered only when its current result is available; the mere existence of a recipe is not evidence.

## Review semantically

When the review includes `odin_port/`, read and apply [references/odin-d3d11-checklist.md](references/odin-d3d11-checklist.md) completely. Do not finalize until every applicable checklist category has been inspected or marked not applicable.

Perform distinct passes rather than assigning every file to only one reviewer:

1. **Reference parity:** Compare startup camera and transforms, controls, resize forwarding, feature levels, shader profiles, resource bindings, mip and sampler settings, and output behavior with the corresponding code under `Applications/` and `Source/`. Treat port comments and documentation as claims to verify, not as proof of inherited behavior.
2. **Semantic translation:** For apparently equivalent calls, inspect C++ helper implementations when zero values, conversions, ownership, allocation, or other language semantics could produce different results in Odin. Classify differences as port regressions, inherited book behavior, documented deviations, or optional robustness improvements.
3. **Lifecycle and call order:** Trace partial initialization and failure cleanup, the frame loop, input, resize, capture, `Present`, temporary-allocation reset, and shutdown. Inspect every caller when shared `glyph` behavior or a repeated application pattern is involved.
4. **Direct3D contracts:** Trace resource ownership and replacement, mapped-resource bounds, COM lifetime, GPU/CPU synchronization, actual resource dimensions, and shader or pipeline contracts. Verify API assumptions against authoritative documentation when necessary.
5. **Odin hazards:** Check size arithmetic before narrowing, integer and enum conversions, zero-length normalization, `defer` scope, allocator lifetime, slice backing storage, shadowing, and platform assumptions.
6. **Ordinary review:** Retain actionable correctness, security, performance, and maintainability findings not covered by the project-specific passes.

After confirming any defect caused by a shared helper or repeated translation pattern, use `rg` across all applications and shared `glyph` code and report every affected changed location or the common fix point.

For a large diff with independent risk areas, use available subagents for focused, read-only investigations. Prefer distinct lenses such as reference parity, shared Direct3D lifecycle, and Odin safety over simple file partitions. Give investigators the raw diff and repository guidance without expected findings, then independently verify and deduplicate their candidates. Keep small or tightly coupled reviews in one agent.

## Apply the finding bar

Report an issue only when it is introduced by the reviewed change, has a concrete trigger and consequence, is actionable at a specific location, and is something the author would likely fix. Do not report subjective style preferences, speculative risks, or inherited book defects as regressions.

Use severity sparingly:

- `P0`: release-blocking or catastrophic in ordinary use.
- `P1`: high-impact failure on a common or critical path, supported by reproduction or an authoritative API contract.
- `P2`: real correctness problem under a plausible condition.
- `P3`: limited-impact but still worthwhile, actionable defect.

## Present the review

- Put findings first, ordered by severity. Attach changed-line feedback with `::code-comment{...}` when the review interface supports it, using the shortest useful line range.
- For each finding, identify the trigger, consequence, and practical remedy concisely.
- Follow findings with validation performed and any meaningful residual risks.
- If no actionable findings remain, say so directly rather than manufacturing feedback.
