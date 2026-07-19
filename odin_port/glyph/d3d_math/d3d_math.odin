// Row-vector matrix helpers in #row_major storage — the convention of the
// book's C++ (Matrix4f) and DirectXMath. With these, Odin reads like the
// book: world-view-projection composes left-to-right (`world * view * proj`),
// vertices transform as `v * m` matching the HLSL's `mul(v, M)`, translation
// sits in row 3 as printed, and (with glyph:shader's PACK_MATRIX_ROW_MAJOR
// compile flag) the shader sees exactly the matrix you built — HLSL
// `M[3][2]` is Odin `m[3, 2]`.
//
// Convention safety comes from the type system: #row_major matrix[4,4]f32
// is a distinct type, so passing a plain (column-vector) linalg matrix where
// a Matrix4f32 is expected is a compile error, not a silent shear.
//
// The builders wrap their core:math/linalg counterparts via transmute — a
// column-vector matrix stored column-major and its row-vector transpose
// stored row-major are the *same bytes*, so reinterpreting the type IS the
// convention change. No arithmetic, nothing to get wrong. The camera
// builders are written out instead: linalg has no LH 0..1-depth versions
// (see the guide's camera-function trap), and the explicit literals match
// the layouts DirectXMath documents (XMMatrixPerspectiveFovLH et al.).
//
// Vector operations (normalize, cross, dot, lerp, length) have no
// convention — keep using linalg's. `transpose(m)` is a builtin and accepts
// #row_major matrices directly.
//
// Naming follows core:math/linalg so call sites transition mechanically:
// linalg.matrix4_rotate_f32 -> d3d_math.matrix4_rotate_f32 (+ reversed
// composition order).
package d3d_math

import "core:math"
import "core:math/linalg"

Matrix4f32 :: #row_major matrix[4, 4]f32
Matrix3f32 :: #row_major matrix[3, 3]f32

// transmute requires identical sizes; Odin matrices carry no padding in
// either layout.
#assert(size_of(Matrix4f32) == size_of(linalg.Matrix4f32))
#assert(size_of(Matrix3f32) == size_of(linalg.Matrix3f32))

matrix4_rotate_f32 :: proc(angle_radians: f32, v: [3]f32) -> Matrix4f32 {
	return transmute(Matrix4f32)linalg.matrix4_rotate_f32(angle_radians, v)
}

matrix3_rotate_f32 :: proc(angle_radians: f32, v: [3]f32) -> Matrix3f32 {
	return transmute(Matrix3f32)linalg.matrix3_rotate_f32(angle_radians, v)
}

matrix4_translate_f32 :: proc(v: [3]f32) -> Matrix4f32 {
	return transmute(Matrix4f32)linalg.matrix4_translate_f32(v)
}

matrix4_scale_f32 :: proc(v: [3]f32) -> Matrix4f32 {
	return transmute(Matrix4f32)linalg.matrix4_scale_f32(v)
}

// (Mᵀ)⁻¹ = (M⁻¹)ᵀ: transmute in, invert as column-vector, transmute out —
// the two implicit transposes cancel.
inverse :: proc(m: Matrix4f32) -> Matrix4f32 {
	return transmute(Matrix4f32)linalg.inverse(transmute(linalg.Matrix4f32)m)
}

// --- camera (row-vector forms of glyph:camera; Matrix4f / D3DX layouts) ----

perspective_fov_lh :: proc(fov_y, aspect, near, far: f32) -> Matrix4f32 {
	y_scale := 1.0 / math.tan(fov_y * 0.5)
	x_scale := y_scale / aspect
	z_scale := far / (far - near)
	return {
		x_scale, 0,       0,               0,
		0,       y_scale, 0,               0,
		0,       0,       z_scale,         1,
		0,       0,       -near * z_scale, 0,
	}
}

// Off-center (asymmetric-frustum) LH projection with 0..1 depth —
// XMMatrixPerspectiveOffCenterLH.
perspective_off_center_lh :: proc(left, right, bottom, top, near, far: f32) -> Matrix4f32 {
	z_scale := far / (far - near)
	return {
		2 * near / (right - left),       0,                               0,               0,
		0,                               2 * near / (top - bottom),       0,               0,
		(left + right) / (left - right), (top + bottom) / (bottom - top), z_scale,         1,
		0,                               0,                               -near * z_scale, 0,
	}
}

look_at_lh :: proc(eye, at, up: [3]f32) -> Matrix4f32 {
	z := linalg.normalize(at - eye)
	x := linalg.normalize(linalg.cross(up, z))
	y := linalg.cross(z, x)
	return {
		x.x,                 y.x,                 z.x,                 0,
		x.y,                 y.y,                 z.y,                 0,
		x.z,                 y.z,                 z.z,                 0,
		-linalg.dot(x, eye), -linalg.dot(y, eye), -linalg.dot(z, eye), 1,
	}
}
