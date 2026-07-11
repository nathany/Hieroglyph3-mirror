//! Binary STL loader, mirroring `STL::MeshSTL` (Include/MeshSTL.h): 80-byte
//! header, u32 face count, then 50-byte faces (normal + three vertices as
//! 3 x f32 each, plus a 2-byte attribute count). Like the C++, a missing or
//! malformed file just yields zero faces.

use glam::Vec3;

pub struct Face {
    pub normal: Vec3,
    pub v0: Vec3,
    pub v1: Vec3,
    pub v2: Vec3,
}

pub fn load(path: &std::path::Path) -> Vec<Face> {
    const FACE_SIZE: usize = 50;

    let Ok(bytes) = std::fs::read(path) else {
        return Vec::new();
    };
    if bytes.len() < 84 {
        return Vec::new();
    }

    let count = u32::from_le_bytes([bytes[80], bytes[81], bytes[82], bytes[83]]) as usize;
    if bytes.len() < 84 + count * FACE_SIZE {
        return Vec::new();
    }

    let vec3_at = |offset: usize| {
        let f = |o: usize| f32::from_le_bytes([bytes[o], bytes[o + 1], bytes[o + 2], bytes[o + 3]]);
        Vec3::new(f(offset), f(offset + 4), f(offset + 8))
    };

    (0..count)
        .map(|i| {
            let o = 84 + i * FACE_SIZE;
            Face {
                normal: vec3_at(o),
                v0: vec3_at(o + 12),
                v1: vec3_at(o + 24),
                v2: vec3_at(o + 36),
            }
        })
        .collect()
}
