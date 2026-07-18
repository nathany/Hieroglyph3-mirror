// Left-handed, 0..1-depth camera matrices in column-vector convention —
// ports of Matrix4f::PerspectiveFovLHMatrix and Matrix4f::LookAtLHMatrix
// (Source/Matrix4f.cpp, transposed from the engine's row-vector convention).
//
// These exist because core:math/linalg's matrix4_perspective / matrix4_look_at
// are OpenGL-convention (depth -1..1, -Z forward) — using them with D3D
// depth-clips the scene into oblivion (see the guide's camera-function trap).
// Everything else in linalg (rotations, translations, vector ops) is
// convention-agnostic and safe.
package camera

import "core:math"
import "core:math/linalg"

perspective_fov_lh :: proc(fov_y, aspect, near, far: f32) -> matrix[4, 4]f32 {
	y_scale := 1.0 / math.tan(fov_y * 0.5)
	x_scale := y_scale / aspect
	z_scale := far / (far - near)
	// Odin matrix literals read row-by-row (storage is column-major).
	return {
		x_scale, 0,       0,       0,
		0,       y_scale, 0,       0,
		0,       0,       z_scale, -near * z_scale,
		0,       0,       1,       0,
	}
}

// Off-center (asymmetric-frustum) LH projection with 0..1 depth — the
// column-vector form of XMMatrixPerspectiveOffCenterLH / the engine's
// Camera::SetOffsetProjectionParams.
perspective_off_center_lh :: proc(left, right, bottom, top, near, far: f32) -> matrix[4, 4]f32 {
	z_scale := far / (far - near)
	return {
		2 * near / (right - left), 0,                         (left + right) / (left - right), 0,
		0,                         2 * near / (top - bottom), (top + bottom) / (bottom - top), 0,
		0,                         0,                         z_scale,                         -near * z_scale,
		0,                         0,                         1,                               0,
	}
}

look_at_lh :: proc(eye, at, up: [3]f32) -> matrix[4, 4]f32 {
	z := linalg.normalize(at - eye)
	x := linalg.normalize(linalg.cross(up, z))
	y := linalg.cross(z, x)
	return {
		x.x, x.y, x.z, -linalg.dot(x, eye),
		y.x, y.y, y.z, -linalg.dot(y, eye),
		z.x, z.y, z.z, -linalg.dot(z, eye),
		0,   0,   0,   1,
	}
}
