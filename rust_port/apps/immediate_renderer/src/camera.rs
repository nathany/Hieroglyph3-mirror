//! First-person camera, mirroring `FirstPersonCamera` + the engine's spatial
//! conventions:
//!
//! - Keys: W/S forward/back, A/D strafe, Q/E up/down, Ctrl = 3x speed
//!   (move speed 10 units/s), right-mouse drag rotates (0.24 * dt radians per
//!   pixel), pitch clamped to +/- pi/2.
//! - The engine's Euler composition is row-vector `Rz * Rx * Ry`; with z = 0
//!   the column-vector equivalent used here is `Ry(yaw) * Rx(pitch)`.
//! - `MoveForward` translates along the rotation matrix's forward basis
//!   (row 2 row-vector = the z column here); likewise right = x, up = y.

use glam::{Mat4, Vec3};

pub struct FirstPersonCamera {
    pub position: Vec3,
    /// (pitch, yaw) in radians — the engine's rotation.x / rotation.y.
    pub pitch: f32,
    pub yaw: f32,
}

#[derive(Default)]
pub struct CameraInput {
    pub forward: bool,
    pub back: bool,
    pub left: bool,
    pub right: bool,
    pub up: bool,
    pub down: bool,
    pub speed_up: bool,
    /// Accumulated right-drag mouse deltas since the last update.
    pub mouse_dx: f32,
    pub mouse_dy: f32,
}

impl FirstPersonCamera {
    pub fn new(position: Vec3, pitch: f32, yaw: f32) -> Self {
        Self { position, pitch, yaw }
    }

    /// Per-frame movement/rotation, mirroring `FirstPersonCamera::Update`.
    pub fn update(&mut self, input: &mut CameraInput, dt: f32) {
        let mut move_speed = 10.0 * dt;
        let rot_speed = 0.24 * dt;

        if input.speed_up {
            move_speed *= 3.0;
        }

        let rotation = self.rotation();
        let right = rotation.x_axis.truncate();
        let up = rotation.y_axis.truncate();
        let forward = rotation.z_axis.truncate();

        if input.right {
            self.position += right * move_speed;
        } else if input.left {
            self.position -= right * move_speed;
        }
        if input.up {
            self.position += up * move_speed;
        } else if input.down {
            self.position -= up * move_speed;
        }
        if input.forward {
            self.position += forward * move_speed;
        } else if input.back {
            self.position -= forward * move_speed;
        }

        self.pitch += input.mouse_dy * rot_speed;
        self.yaw += input.mouse_dx * rot_speed;
        input.mouse_dx = 0.0;
        input.mouse_dy = 0.0;

        self.pitch = self.pitch.clamp(
            -std::f32::consts::FRAC_PI_2,
            std::f32::consts::FRAC_PI_2,
        );
    }

    fn rotation(&self) -> Mat4 {
        Mat4::from_rotation_y(self.yaw) * Mat4::from_rotation_x(self.pitch)
    }

    /// View matrix: the inverse of the camera's world transform
    /// (translate * rotate, column-vector).
    pub fn view_matrix(&self) -> Mat4 {
        self.rotation().transpose() * Mat4::from_translation(-self.position)
    }
}
