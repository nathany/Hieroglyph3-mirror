//! MilkShape3D (.ms3d) loader, mirroring `GeometryLoaderDX11::loadMS3DFile2`
//! (Source/GeometryLoaderDX11.cpp): reads the vertex and triangle sections of
//! the binary format, then expands to three unique vertices per triangle —
//! interleaved POSITION/TEXCOORD/NORMAL, exactly the element order the engine
//! adds them in — negating Z (the format is right-handed) and flipping the
//! winding (indices i, i+2, i+1).

use windows::core::{Error, HRESULT, Result};

/// Interleaved as the engine's GeometryDX11 lays it out: position, texcoord,
/// normal (stride 32, offsets 0/12/20).
#[repr(C)]
pub struct Ms3dVertex {
    pub position: [f32; 3],
    pub texcoords: [f32; 2],
    pub normal: [f32; 3],
}

pub struct Ms3dMesh {
    pub vertices: Vec<Ms3dVertex>,
    pub indices: Vec<u32>,
}

pub fn load(filename: &str) -> Result<Ms3dMesh> {
    let path = glyph::paths::find_data_file("Models", filename)
        .ok_or_else(|| Error::new(HRESULT(-1), format!("model not found: {filename}")))?;
    let bytes = std::fs::read(&path)
        .map_err(|e| Error::new(HRESULT(-1), format!("failed to read {path:?}: {e}")))?;

    let err = |what: &str| Error::new(HRESULT(-1), format!("{filename}: {what}"));

    // Header: 10-byte id + i32 version (3 or 4).
    if bytes.len() < 14 || &bytes[0..10] != b"MS3D000000" {
        return Err(err("not an MS3D file"));
    }
    let version = i32::from_le_bytes(bytes[10..14].try_into().unwrap());
    if version != 3 && version != 4 {
        return Err(err("unsupported MS3D version"));
    }

    let f32_at = |o: usize| f32::from_le_bytes(bytes[o..o + 4].try_into().unwrap());
    let u16_at = |o: usize| u16::from_le_bytes(bytes[o..o + 2].try_into().unwrap());

    // Vertex section: u16 count, then 15-byte records
    // (u8 flags, 3 x f32 position, i8 bone, u8 refcount).
    let mut pos = 14;
    let vertex_count = u16_at(pos) as usize;
    pos += 2;
    const VERTEX_SIZE: usize = 15;
    if bytes.len() < pos + vertex_count * VERTEX_SIZE {
        return Err(err("truncated vertex data"));
    }
    let positions: Vec<[f32; 3]> = (0..vertex_count)
        .map(|i| {
            let o = pos + i * VERTEX_SIZE + 1; // skip flags byte
            [f32_at(o), f32_at(o + 4), f32_at(o + 8)]
        })
        .collect();
    pos += vertex_count * VERTEX_SIZE;

    // Triangle section: u16 count, then 70-byte records (u16 flags,
    // 3 x u16 indices, 3 x 3 x f32 normals, 3 x f32 s, 3 x f32 t,
    // u8 smoothing group, u8 group index).
    let triangle_count = u16_at(pos) as usize;
    pos += 2;
    const TRIANGLE_SIZE: usize = 70;
    if bytes.len() < pos + triangle_count * TRIANGLE_SIZE {
        return Err(err("truncated triangle data"));
    }

    let mut vertices = Vec::with_capacity(triangle_count * 3);
    let mut indices = Vec::with_capacity(triangle_count * 3);

    for i in 0..triangle_count {
        let o = pos + i * TRIANGLE_SIZE;
        let idx = [u16_at(o + 2) as usize, u16_at(o + 4) as usize, u16_at(o + 6) as usize];
        let normals_at = o + 8; // 3 normals x 3 floats
        let s_at = o + 44;
        let t_at = o + 56;

        for corner in 0..3 {
            let p = positions
                .get(idx[corner])
                .ok_or_else(|| err("vertex index out of range"))?;
            let n = normals_at + corner * 12;
            vertices.push(Ms3dVertex {
                position: [p[0], p[1], -p[2]],
                texcoords: [f32_at(s_at + corner * 4), f32_at(t_at + corner * 4)],
                normal: [f32_at(n), f32_at(n + 4), -f32_at(n + 8)],
            });
        }

        // Winding flipped along with the Z negation.
        let base = (i * 3) as u32;
        indices.push(base);
        indices.push(base + 2);
        indices.push(base + 1);
    }

    Ok(Ms3dMesh { vertices, indices })
}
