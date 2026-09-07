// Row-vector matrix helpers in #row_major storage — the convention of the
// book's C++ (Matrix4f) and DirectXMath. With these, Odin reads like the
// book: world-view-projection composes left-to-right (`world * view * proj`),
// vertices transform as `v * m` matching the HLSL's `mul(v, M)`, translation
// sits in row 3 as printed, and (with glyph:shader's PACK_MATRIX_ROW_MAJOR
// compile flag) the shader sees exactly the matrix you built — HLSL
// `M[3][2]` is Odin `m[3, 2]`.
//
// This package is only the matrix layer the book assumes exists: the
// equivalents of Matrix4f's builders and DirectXMath's XMMatrix* functions.
// Vector operations (normalize, cross, dot, lerp, length) carry no
// convention — keep using core:math/linalg's. `transpose(m)` is a builtin
// and accepts #row_major matrices directly, returning the same type.
//
// Convention safety comes from the type system: #row_major matrix[4,4]f32
// is a distinct type, so passing a plain (column-vector) linalg matrix where
// a Matrix4f32 is expected is a compile error, not a silent shear. Take
// matrix builders from here, never from linalg.
//
// Naming follows core:math/linalg, so its documentation and call-site habits
// carry over: linalg.matrix4_rotate_f32 -> d3d_math.matrix4_rotate_f32.
package d3d_math

import "core:math"
import "core:math/linalg"

// A 4x4 row-vector matrix: row-major storage, translation in row 3.
Matrix4f32 :: #row_major matrix[4, 4]f32

// A 3x3 row-vector matrix, for rotating directions and normals.
Matrix3f32 :: #row_major matrix[3, 3]f32

// transmute requires identical sizes; Odin matrices carry no padding in
// either layout.
#assert(size_of(Matrix4f32) == size_of(linalg.Matrix4f32))
#assert(size_of(Matrix3f32) == size_of(linalg.Matrix3f32))

// --- why these builders are transmutes -------------------------------------
//
// Each builder below wraps its core:math/linalg counterpart in a transmute
// rather than computing anything. That works because of a coincidence of
// layout that is worth understanding before editing this file.
//
// A transform's row-vector matrix is the transpose of its column-vector
// matrix. Storing a matrix row-major is likewise the transpose of storing it
// column-major. The two transposes cancel: a column-vector matrix in
// column-major storage and its row-vector counterpart in row-major storage
// are, byte for byte, the SAME MEMORY. Only the interpretation differs.
//
// So reinterpreting the type IS the convention change — a free transpose,
// no arithmetic, and nothing to get wrong. linalg.matrix4_translate_f32
// writes its translation to the last column; read those same bytes as
// #row_major and the translation is in row 3, exactly where the book prints
// it.
//
// This is why transmute is load-bearing and NOT interchangeable with a
// conversion. Both compile:
//
//   transmute(Matrix4f32)m   preserves BYTES    -> the logical transpose (what we want)
//   Matrix4f32(m)            preserves ELEMENTS -> shuffles memory, leaving a
//                                                  column-vector matrix wearing
//                                                  row-major clothing (silently wrong)
//
// The camera builders further down are written out longhand instead: linalg
// has no left-handed 0..1-depth versions to borrow (see the guide's
// camera-function trap), and spelling the literals out lets them match the
// layouts DirectXMath documents.

// Rotation of `angle_radians` about the axis `v` through the origin
// (Matrix4f::RotationMatrixX/Y/Z, XMMatrixRotationAxis). The axis is
// normalized internally, so it need not arrive unit-length.
matrix4_rotate_f32 :: proc(angle_radians: f32, v: [3]f32) -> Matrix4f32 {
	return transmute(Matrix4f32)linalg.matrix4_rotate_f32(angle_radians, v)
}

// Rotation of `angle_radians` about the axis `v`, as a 3x3 — for directions
// and normals, which must not pick up translation.
matrix3_rotate_f32 :: proc(angle_radians: f32, v: [3]f32) -> Matrix3f32 {
	return transmute(Matrix3f32)linalg.matrix3_rotate_f32(angle_radians, v)
}

// Translation by `v` (Matrix4f::TranslationMatrix, XMMatrixTranslation).
// The offset lands in row 3, as the book prints it.
matrix4_translate_f32 :: proc(v: [3]f32) -> Matrix4f32 {
	return transmute(Matrix4f32)linalg.matrix4_translate_f32(v)
}

// Per-axis scale by `v` (Matrix4f::ScaleMatrixXYZ, XMMatrixScaling), placed
// on the diagonal.
matrix4_scale_f32 :: proc(v: [3]f32) -> Matrix4f32 {
	return transmute(Matrix4f32)linalg.matrix4_scale_f32(v)
}

// The inverse of `m` (Matrix4f::Inverse).
//
// Implemented as a transmute round-trip through linalg: because
// (Mᵀ)⁻¹ = (M⁻¹)ᵀ, inverting the column-vector view of the same bytes and
// reinterpreting the result gives the row-vector inverse — the two implicit
// transposes cancel.
inverse :: proc(m: Matrix4f32) -> Matrix4f32 {
	return transmute(Matrix4f32)linalg.inverse(transmute(linalg.Matrix4f32)m)
}

// --- camera (LH 0..1-depth; Matrix4f / D3DX layouts, row-vector) -----------

// Left-handed perspective projection from a symmetric frustum
// (Matrix4f::PerspectiveFovLHMatrix, XMMatrixPerspectiveFovLH).
// `fov_y` is the vertical field of view in radians and `aspect` is
// width/height; view-space z in [near, far] maps to depth 0..1, as D3D
// expects. Note linalg's matrix4_perspective is the OpenGL -1..1 form and
// will depth-clip your scene into oblivion.
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

// Left-handed perspective projection from an asymmetric frustum given by its
// near-plane edges (XMMatrixPerspectiveOffCenterLH). Same 0..1 depth range
// as perspective_fov_lh; use it for off-center or sheared views.
perspective_off_center_lh :: proc(left, right, bottom, top, near, far: f32) -> Matrix4f32 {
	z_scale := far / (far - near)
	return {
		2 * near / (right - left),       0,                               0,               0,
		0,                               2 * near / (top - bottom),       0,               0,
		(left + right) / (left - right), (top + bottom) / (bottom - top), z_scale,         1,
		0,                               0,                               -near * z_scale, 0,
	}
}

// Left-handed view matrix placing the camera at `eye` looking toward `at`
// (Matrix4f::LookAtLHMatrix, XMMatrixLookAtLH). Transforms world space into
// view space, +Z forward. `up` need not be perpendicular to the view
// direction, only non-parallel.
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
