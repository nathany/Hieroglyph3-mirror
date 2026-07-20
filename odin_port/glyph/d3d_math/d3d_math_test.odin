// Tests for the row-vector helpers. Run from odin_port/:
//
//   odin test glyph\d3d_math -collection:glyph=glyph
//
// Deliberately self-contained: the camera builders are checked against
// their defining properties — frustum corners land on NDC ±1, near/far map
// to depth 0/1 — rather than against another implementation.
package d3d_math

import "core:math/linalg"
import "core:testing"

approx :: proc(a, b: [4]f32, eps: f32 = 1e-4) -> bool {
	for i in 0 ..< 4 {if abs(a[i] - b[i]) > eps {return false}}
	return true
}

approx_m :: proc(a, b: Matrix4f32, eps: f32 = 1e-4) -> bool {
	for i in 0 ..< 4 {
		for j in 0 ..< 4 {if abs(a[i, j] - b[i, j]) > eps {return false}}
	}
	return true
}

// Row-vector v*R and column-vector R*v are the same rotation.
@(test)
rotate_semantics :: proc(t: ^testing.T) {
	v := [4]f32{1, 2, 3, 1}
	axis := [3]f32{0.267, 0.535, 0.802}
	r_rv := matrix4_rotate_f32(0.7, axis)
	r_cv := linalg.matrix4_rotate_f32(0.7, axis)
	testing.expect(t, approx(v * r_rv, r_cv * v), "v*R_rv != R_cv*v")

	v3 := [3]f32{1, 2, 3}
	r3_rv := matrix3_rotate_f32(0.7, axis)
	r3_cv := linalg.matrix3_rotate_f32(0.7, axis)
	d := v3 * r3_rv - r3_cv * v3
	testing.expect(t, abs(d.x) < 1e-4 && abs(d.y) < 1e-4 && abs(d.z) < 1e-4, "v*R3_rv != R3_cv*v")
}

// Translation sits in row 3 as the book prints it, and points pass through.
@(test)
translate_and_scale :: proc(t: ^testing.T) {
	tr := matrix4_translate_f32({10, 20, 30})
	testing.expect(t, tr[3, 0] == 10 && tr[3, 1] == 20 && tr[3, 2] == 30, "translation not in row 3")
	testing.expect(t, approx([4]f32{1, 2, 3, 1} * tr, {11, 22, 33, 1}), "point through T wrong")

	s := matrix4_scale_f32({2, 3, 4})
	testing.expect(t, approx([4]f32{1, 1, 1, 1} * s, {2, 3, 4, 1}), "point through S wrong")
}

@(test)
inverse_roundtrip :: proc(t: ^testing.T) {
	m := matrix4_rotate_f32(0.7, {0.267, 0.535, 0.802}) * matrix4_translate_f32({10, 20, 30})
	testing.expect(t, approx_m(m * inverse(m), 1), "affine M*inv(M) != I")

	// For an ill-conditioned projective product, M*inv(M) drifts from I in
	// f32 (~1e-3) — so instead pin the logic: our transmute round-trip must
	// be bit-identical to linalg.inverse on the same bytes.
	p := m * perspective_fov_lh(1.0, 1.5, 0.1, 100)
	inv_rv := transmute([16]f32)inverse(p)
	inv_cv := transmute([16]f32)linalg.inverse(transmute(linalg.Matrix4f32)p)
	testing.expect(t, inv_rv == inv_cv, "inverse differs from linalg column-vector path")
}

// project returns NDC (after the w-divide) of a row-vector point transform.
project :: proc(p: [3]f32, m: Matrix4f32) -> [3]f32 {
	h := [4]f32{p.x, p.y, p.z, 1} * m
	return h.xyz / h.w
}

@(test)
perspective_fov :: proc(t: ^testing.T) {
	near, far := f32(0.1), f32(100)
	p := perspective_fov_lh(1.0, 1.5, near, far)
	testing.expect(t, p[2, 3] == 1 && p[3, 3] == 0, "w column wrong (row-vector layout)")
	// LH 0..1 depth: near plane -> 0, far plane -> 1.
	testing.expect(t, abs(project({0, 0, near}, p).z) < 1e-6, "near plane depth != 0")
	testing.expect(t, abs(project({0, 0, far}, p).z - 1) < 1e-6, "far plane depth != 1")
	// A point on the top frustum edge (y = z*tan(fov_y/2)) lands on NDC y=1.
	testing.expect(t, abs(project({0, 5 * linalg.tan(f32(0.5)), 5}, p).y - 1) < 1e-5, "fov edge != NDC 1")
	// HLSL indexing parity (the book's shaders read ProjMatrix[3][2]).
	z_scale := far / (far - near)
	testing.expect(t, abs(p[3, 2] - (-near * z_scale)) < 1e-5, "p[3,2] != -near*z_scale")
}

@(test)
perspective_off_center :: proc(t: ^testing.T) {
	l, r, b, tp, near := f32(-2), f32(3), f32(-1), f32(1.5), f32(0.1)
	p := perspective_off_center_lh(l, r, b, tp, near, 100)
	// The near-plane corners map to the NDC corners at depth 0.
	testing.expect(t, approx(project({l, b, near}, p).xyzz, {-1, -1, 0, 0}), "(l,b,near) != NDC (-1,-1,0)")
	testing.expect(t, approx(project({r, tp, near}, p).xyzz, {1, 1, 0, 0}), "(r,t,near) != NDC (1,1,0)")
}

@(test)
look_at :: proc(t: ^testing.T) {
	eye, at := [3]f32{1, 2, 3}, [3]f32{4, 5, 6}
	v := look_at_lh(eye, at, {0, 1, 0})
	// The eye maps to the origin; the look-at point to +z at its distance.
	testing.expect(t, approx([4]f32{eye.x, eye.y, eye.z, 1} * v, {0, 0, 0, 1}), "eye != origin")
	testing.expect(t, approx([4]f32{at.x, at.y, at.z, 1} * v, {0, 0, linalg.length(at - eye), 1}), "at != +z axis")
}

// Composed row-vector world*view*proj and the reversed column-vector product
// upload the same cbuffer bytes. Single matrices are bit-exact; products
// agree to last-bit rounding (~5e-7, different SIMD association orders) —
// hence a tolerance, not ==.
@(test)
upload_bytes_across_conventions :: proc(t: ^testing.T) {
	w_rv := matrix4_rotate_f32(0.5, {0, 1, 0}) * matrix4_translate_f32({-3, 1, 7})
	v_rv := look_at_lh({1, 2, 3}, {4, 5, 6}, {0, 1, 0})
	p_rv := perspective_fov_lh(1.0, 1.5, 0.1, 100)
	wvp := transmute([16]f32)(w_rv * v_rv * p_rv)

	w_cv := linalg.matrix4_translate_f32({-3, 1, 7}) * linalg.matrix4_rotate_f32(0.5, {0, 1, 0})
	v_cv := transmute(linalg.Matrix4f32)v_rv
	p_cv := transmute(linalg.Matrix4f32)p_rv
	pvw := transmute([16]f32)(p_cv * v_cv * w_cv)

	worst: f32
	for i in 0 ..< 16 {worst = max(worst, abs(wvp[i] - pvw[i]))}
	testing.expect(t, worst <= 1e-4, "conventions disagree beyond rounding")
}

// transpose is convention-free and works on #row_major directly — the
// normal-matrix formula transpose(inverse(world)) carries over unchanged.
@(test)
transpose_row_major :: proc(t: ^testing.T) {
	r := matrix4_rotate_f32(0.7, {0.267, 0.535, 0.802})
	tr: Matrix4f32 = linalg.transpose(r)
	testing.expect(t, tr[0, 1] == r[1, 0] && tr[3, 2] == r[2, 3], "transpose elements wrong")
}
