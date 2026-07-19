// First-person camera, mirroring FirstPersonCamera + the engine's spatial
// conventions:
//
//   - Keys: W/S forward/back, A/D strafe, Q/E up/down, Ctrl = 3x speed
//     (move speed 10 units/s), right-mouse drag rotates (0.24 * dt radians
//     per pixel), pitch clamped to +/- pi/2.
//   - The engine's Euler composition is row-vector Rz * Rx * Ry; with z = 0
//     the column-vector equivalent used here is Ry(yaw) * Rx(pitch).
//   - MoveForward translates along the rotation matrix's forward basis
//     (row 2 row-vector = the z column here); likewise right = x, up = y.
package main

import "core:math"
import "core:math/linalg"

Fp_Camera :: struct {
	position: [3]f32,
	pitch:    f32,
	yaw:      f32,
}

Camera_Input :: struct {
	forward:  bool,
	back:     bool,
	left:     bool,
	right:    bool,
	up:       bool,
	down:     bool,
	speed_up: bool,
	// Accumulated right-drag mouse deltas since the last update.
	mouse_dx: f32,
	mouse_dy: f32,
}

camera_rotation :: proc(c: ^Fp_Camera) -> matrix[4, 4]f32 {
	return linalg.matrix4_rotate_f32(c.yaw, {0, 1, 0}) * linalg.matrix4_rotate_f32(c.pitch, {1, 0, 0})
}

// Per-frame movement/rotation, mirroring FirstPersonCamera::Update.
camera_update :: proc(c: ^Fp_Camera, input: ^Camera_Input, dt: f32) {
	move_speed := 10.0 * dt
	rot_speed := 0.24 * dt

	if input.speed_up {
		move_speed *= 3.0
	}

	rotation := camera_rotation(c)
	right := [3]f32{rotation[0, 0], rotation[1, 0], rotation[2, 0]}
	up := [3]f32{rotation[0, 1], rotation[1, 1], rotation[2, 1]}
	forward := [3]f32{rotation[0, 2], rotation[1, 2], rotation[2, 2]}

	if input.right {
		c.position += right * move_speed
	} else if input.left {
		c.position -= right * move_speed
	}
	if input.up {
		c.position += up * move_speed
	} else if input.down {
		c.position -= up * move_speed
	}
	if input.forward {
		c.position += forward * move_speed
	} else if input.back {
		c.position -= forward * move_speed
	}

	c.pitch += input.mouse_dy * rot_speed
	c.yaw += input.mouse_dx * rot_speed
	input.mouse_dx = 0
	input.mouse_dy = 0

	c.pitch = clamp(c.pitch, -math.PI / 2, math.PI / 2)
}

// View matrix: the inverse of the camera's world transform
// (translate * rotate, column-vector).
camera_view_matrix :: proc(c: ^Fp_Camera) -> matrix[4, 4]f32 {
	return linalg.transpose(camera_rotation(c)) * linalg.matrix4_translate_f32(-c.position)
}
