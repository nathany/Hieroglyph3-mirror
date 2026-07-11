//! Runtime HLSL compilation mirroring `ShaderFactoryDX11::GenerateShader`
//! (Source/ShaderFactoryDX11.cpp).
//!
//! Two details worth knowing:
//! - The engine compiles everything with `D3DCOMPILE_PACK_MATRIX_ROW_MAJOR`,
//!   so matrices in cbuffers are read row-major. That is what lets glam
//!   matrices (column-major memory, column-vector math) be uploaded without
//!   any transpose while the book's row-vector `mul(v, M)` shaders work
//!   unchanged: HLSL reads glam's columns as rows, i.e. the transpose, which
//!   is exactly the row-vector form.
//! - Shaders are found on disk at runtime, straight from the repository's
//!   `Applications/Data/Shaders/` — the same files the C++ demos compile.

use windows::Win32::Graphics::Direct3D::Fxc::{
    D3DCOMPILE_DEBUG, D3DCOMPILE_PACK_MATRIX_ROW_MAJOR, D3DCOMPILE_SKIP_OPTIMIZATION, D3DCompile,
};
use windows::Win32::Graphics::Direct3D::{D3D_SHADER_MACRO, ID3DBlob};
use windows::core::{Error, HRESULT, PCSTR, Result};

use crate::paths::find_data_file;

/// Compile `entry` from `Applications/Data/Shaders/<filename>` for the given
/// target (e.g. `"vs_4_0"`), returning the bytecode. Compile errors are
/// returned in the `Error` message (the C++ logs them and asserts).
pub fn compile_shader(filename: &str, entry: &str, target: &str) -> Result<Vec<u8>> {
    compile_shader_defines(filename, entry, target, &[])
}

/// [`compile_shader`] with preprocessor defines, mirroring the `LoadShader`
/// overload that takes a `D3D_SHADER_MACRO` array (TessellationParams uses
/// it to build one hull shader per partitioning mode from a single source).
pub fn compile_shader_defines(
    filename: &str,
    entry: &str,
    target: &str,
    defines: &[(&str, &str)],
) -> Result<Vec<u8>> {
    let path = find_data_file("Shaders", filename).ok_or_else(|| {
        Error::new(HRESULT(-1), format!("shader source not found: {filename}"))
    })?;
    let source = std::fs::read(&path)
        .map_err(|e| Error::new(HRESULT(-1), format!("failed to read {path:?}: {e}")))?;

    // NUL-terminated copies for the PCSTR parameters.
    let entry_z = format!("{entry}\0");
    let target_z = format!("{target}\0");
    let name_z = format!("{filename}\0");
    let define_strings: Vec<(String, String)> = defines
        .iter()
        .map(|(name, value)| (format!("{name}\0"), format!("{value}\0")))
        .collect();
    let mut macros: Vec<D3D_SHADER_MACRO> = define_strings
        .iter()
        .map(|(name, value)| D3D_SHADER_MACRO {
            Name: PCSTR(name.as_ptr()),
            Definition: PCSTR(value.as_ptr()),
        })
        .collect();
    // The macro array is NULL-terminated.
    macros.push(D3D_SHADER_MACRO { Name: PCSTR::null(), Definition: PCSTR::null() });

    let mut flags = D3DCOMPILE_PACK_MATRIX_ROW_MAJOR;
    if cfg!(debug_assertions) {
        flags |= D3DCOMPILE_DEBUG | D3DCOMPILE_SKIP_OPTIMIZATION;
    }

    let mut code: Option<ID3DBlob> = None;
    let mut errors: Option<ID3DBlob> = None;

    // SAFETY: Source pointer/length describe the buffer read above; the PCSTR
    // arguments (including the macro array's) point at NUL-terminated strings
    // that outlive the call; the macro array itself is NULL-terminated; out
    // params are valid. The blob pointers returned are owned smart pointers.
    let result = unsafe {
        D3DCompile(
            source.as_ptr() as *const _,
            source.len(),
            PCSTR(name_z.as_ptr()),
            Some(macros.as_ptr()),
            None, // include handler
            PCSTR(entry_z.as_ptr()),
            PCSTR(target_z.as_ptr()),
            flags,
            0,
            &mut code,
            Some(&mut errors),
        )
    };

    if let Err(e) = result {
        // SAFETY: A returned error blob holds a NUL-terminated ASCII message
        // of `GetBufferSize` bytes.
        let message = errors
            .map(|blob| unsafe {
                let bytes = std::slice::from_raw_parts(
                    blob.GetBufferPointer() as *const u8,
                    blob.GetBufferSize(),
                );
                String::from_utf8_lossy(bytes).into_owned()
            })
            .unwrap_or_else(|| e.message().to_string());
        return Err(Error::new(e.code(), format!("{filename}({entry}): {message}")));
    }

    let code = code.unwrap();
    // SAFETY: The blob's pointer/size describe its buffer; copied out before
    // the blob is dropped.
    let bytes = unsafe {
        std::slice::from_raw_parts(code.GetBufferPointer() as *const u8, code.GetBufferSize())
            .to_vec()
    };
    Ok(bytes)
}
