# Odin and Direct3D 11 review checklist

Use this checklist for reviews that include `odin_port/`. Search results are starting points; trace the relevant call order and data flow before deciding whether a finding is actionable. In diff reviews, inspect affected behavior and its dependencies; in current-tree audits, inspect the requested scope, including unchanged code. State material coverage gaps and unverified runtime paths.

## Reference fidelity

- For every in-scope application, compare requested and actual window dimensions, startup camera and transforms, controls, inherited event and resize handling, feature level, shader profiles, resource bindings, mip generation, sampler settings, and visible output with its C++ counterpart.
- Verify claims in Odin comments and documentation against executable C++ code.
- When equivalent-looking calls depend on helpers, compare the helpers' behavior for zero values, invalid input, allocation failure, conversion, and ownership.
- Follow the exact call arguments through relevant helper conditions and the dependency version actually used. Check nullable output pointers and flags rather than inferring behavior from a helper's name or documentation summary. Record unavailable dependency evidence as a limitation.

## Frame and resource lifecycle

- Inspect every capture or backbuffer-copy path relative to `Present`; account for the configured swap effect and whether backbuffer contents remain defined.
- Trace resize success or failure through every caller. Do not assume a `void` helper succeeded when callers immediately use recreated resources.
- For resource replacement, require successful creation of the replacement before destroying or overwriting the valid resource, unless failure terminates the application safely.
- Trace the corresponding C++ replacement and failure path before classifying a port regression. Distinguish an inherited weakness from an Odin-specific failure; clean exit can be sufficient without transactional recovery.
- Trace each initialization early return after the first owned allocation. Confirm partial COM objects and Odin allocations are released even when the caller receives `ok == false`.
- Include local shader blobs, partial nested-helper returns, and successful sibling results when another constructor fails. An outer destructor only covers values that reached its ownership fields.
- Inspect long-running loops for temporary allocations and verify their allocator is reset at an appropriate lifetime boundary.
- Include event-driven allocations such as title conversions and screenshots, and optional debug paths. Distinguish repeated growth, startup scratch retention, and a single unreleased resource.

## Odin data and numeric hazards

- For every normalization, determine whether the input can be zero and compare Odin's result with the C++ helper's zero handling.
- Check bounds before each parser read, including count fields that are themselves used to validate later data.
- Perform byte-count and element-count multiplication in a sufficiently wide type, check overflow and input length, then narrow for the API.
- Establish the supported target and count ranges before alleging overflow; widening before multiplication can make a reported overflow impossible. Do not recommend generic arithmetic machinery when simple proven bounds suffice.
- Verify explicit enum, bit-set, integer, and pointer conversions by their actual Odin semantics; do not recommend `transmute` merely because the source and destination types differ.
- Use actual client or resource dimensions after creation when the platform can adjust the requested size.
- Compare each C++ backbuffer, target, viewport, and projection calculation separately: an actual-size correction in one does not establish that all reference calculations use actual dimensions.

## Required sweep

Run repository-wide searches covering these pattern families and trace the relevant in-scope call sites. Keep occurrences outside a requested diff separate from introduced defects:

```text
present, capture, save_backbuffer
resize, ResizeBuffers, resource creation followed by Release
normalize
or_return and early return in setup/create procedures
temp_allocator, tprintf, free_all
parser offsets, count reads, and size multiplication
```

If one occurrence is defective, search all applications and shared `glyph` code for the same translation pattern before reporting the final scope.
