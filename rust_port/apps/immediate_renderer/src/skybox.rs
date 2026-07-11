//! Skybox, mirroring `SkyboxActor` (Source/SkyboxActor.cpp): a scaled cube of
//! 8 corner vertices rendered with `Skybox.hlsl` (which pushes positions to
//! the far plane via `.xyww` and samples a cube map by direction), depth
//! compare LESS_EQUAL so it fills exactly the untouched depth = 1.0 pixels.
//!
//! The cube map itself is `TropicalSunnyDay.dds` — a legacy uncompressed
//! 32-bit BGRA cube map, hand-parsed here (the C++ goes through DirectXTK's
//! DDSTextureLoader; the format is simple enough that a dependency isn't
//! warranted: 128-byte header, then 6 faces of width*height*4 bytes in
//! +X, -X, +Y, -Y, +Z, -Z order).

use glyph::paths::find_data_file;
use windows::Win32::Graphics::Direct3D::D3D_SRV_DIMENSION_TEXTURECUBE;
use windows::Win32::Graphics::Direct3D11::{
    D3D11_BIND_SHADER_RESOURCE, D3D11_RESOURCE_MISC_TEXTURECUBE, D3D11_SHADER_RESOURCE_VIEW_DESC,
    D3D11_SHADER_RESOURCE_VIEW_DESC_0, D3D11_SUBRESOURCE_DATA, D3D11_TEX2D_SRV,
    D3D11_TEXTURE2D_DESC, D3D11_USAGE_IMMUTABLE, ID3D11Device, ID3D11ShaderResourceView,
    ID3D11Texture2D,
};
use windows::Win32::Graphics::Dxgi::Common::{DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_SAMPLE_DESC};
use windows::core::{Error, HRESULT, Result};

/// The skybox vertex mirrors the engine's `TexturedVertex` (position +
/// texcoords, 20 bytes): the shader only *uses* the position, but its input
/// signature declares TEXCOORD0, so the layout must supply it.
#[repr(C)]
pub struct SkyboxVertex {
    pub position: [f32; 3],
    pub texcoords: [f32; 2],
}

/// The skybox cube's 8 corners and 36 indices, exactly as `SkyboxActor`
/// builds them (positions get scaled by the constructor's `scale`).
pub const CORNERS: [([f32; 3], [f32; 2]); 8] = [
    ([-1.0, 1.0, 1.0], [0.0, 0.0]),   // top left front
    ([1.0, 1.0, 1.0], [1.0, 0.0]),    // top right front
    ([-1.0, -1.0, 1.0], [0.0, 1.0]),  // bottom left front
    ([1.0, -1.0, 1.0], [1.0, 1.0]),   // bottom right front
    ([-1.0, 1.0, -1.0], [0.0, 0.0]),  // top left back
    ([1.0, 1.0, -1.0], [1.0, 0.0]),   // top right back
    ([-1.0, -1.0, -1.0], [0.0, 1.0]), // bottom left back
    ([1.0, -1.0, -1.0], [1.0, 1.0]),  // bottom right back
];

pub const INDICES: [u32; 36] = [
    0, 1, 2, 1, 3, 2, // front
    1, 5, 3, 5, 7, 3, // right
    5, 4, 6, 5, 6, 7, // back
    0, 2, 4, 2, 6, 4, // left
    4, 5, 0, 5, 1, 0, // top
    2, 3, 6, 3, 7, 6, // bottom
];

/// Load a legacy uncompressed BGRA cube-map DDS and create the cube SRV.
pub fn load_cubemap_dds(
    device: &ID3D11Device,
    filename: &str,
) -> Result<(ID3D11Texture2D, ID3D11ShaderResourceView)> {
    let path = find_data_file("Textures", filename)
        .ok_or_else(|| Error::new(HRESULT(-1), format!("cubemap not found: {filename}")))?;
    let bytes = std::fs::read(&path)
        .map_err(|e| Error::new(HRESULT(-1), format!("failed to read {path:?}: {e}")))?;

    // DDS layout: "DDS " magic, then a 124-byte header.
    if bytes.len() < 128 || &bytes[0..4] != b"DDS " {
        return Err(Error::new(HRESULT(-1), format!("{filename}: not a DDS file")));
    }
    let u32_at = |o: usize| u32::from_le_bytes([bytes[o], bytes[o + 1], bytes[o + 2], bytes[o + 3]]);
    let height = u32_at(12);
    let width = u32_at(16);
    let pf_flags = u32_at(80);
    let bit_count = u32_at(88);
    let caps2 = u32_at(112);

    // Only the exact shape this sample's asset has: uncompressed 32-bit RGB+A
    // (pf flags 0x41), full cube map (caps2 bit 0x200), no mip chain.
    if pf_flags & 0x40 == 0 || bit_count != 32 || caps2 & 0x200 == 0 {
        return Err(Error::new(
            HRESULT(-1),
            format!("{filename}: unsupported DDS variant (this loader only handles uncompressed 32-bit cube maps)"),
        ));
    }

    let face_size = (width * height * 4) as usize;
    if bytes.len() < 128 + 6 * face_size {
        return Err(Error::new(HRESULT(-1), format!("{filename}: truncated cube map data")));
    }

    let desc = D3D11_TEXTURE2D_DESC {
        Width: width,
        Height: height,
        MipLevels: 1,
        ArraySize: 6,
        Format: DXGI_FORMAT_B8G8R8A8_UNORM,
        SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
        Usage: D3D11_USAGE_IMMUTABLE,
        BindFlags: D3D11_BIND_SHADER_RESOURCE.0 as u32,
        CPUAccessFlags: 0,
        MiscFlags: D3D11_RESOURCE_MISC_TEXTURECUBE.0 as u32,
    };

    let init: Vec<D3D11_SUBRESOURCE_DATA> = (0..6)
        .map(|face| D3D11_SUBRESOURCE_DATA {
            pSysMem: bytes[128 + face * face_size..].as_ptr() as *const _,
            SysMemPitch: width * 4,
            SysMemSlicePitch: 0,
        })
        .collect();

    let srv_desc = D3D11_SHADER_RESOURCE_VIEW_DESC {
        Format: DXGI_FORMAT_B8G8R8A8_UNORM,
        ViewDimension: D3D_SRV_DIMENSION_TEXTURECUBE,
        Anonymous: D3D11_SHADER_RESOURCE_VIEW_DESC_0 {
            // TextureCube shares the Texture2D layout for mip fields.
            Texture2D: D3D11_TEX2D_SRV { MostDetailedMip: 0, MipLevels: 1 },
        },
    };

    // SAFETY: The descriptor matches the pixel data (6 subresources of
    // width*height BGRA rows, pitch width*4) which lives in `bytes` across
    // the call; view desc and out-params are valid.
    unsafe {
        let mut texture: Option<ID3D11Texture2D> = None;
        device.CreateTexture2D(&desc, Some(init.as_ptr()), Some(&mut texture))?;
        let texture = texture.unwrap();

        let mut srv: Option<ID3D11ShaderResourceView> = None;
        device.CreateShaderResourceView(&texture, Some(&srv_desc), Some(&mut srv))?;

        Ok((texture, srv.unwrap()))
    }
}
