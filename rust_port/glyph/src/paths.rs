//! Data-file lookup, standing in for the engine's `FileSystem` class (which
//! resolves `Data/Shaders/`, `Data/Textures/`, etc.). Here the data lives in
//! `rust_port/data/`.

use std::path::PathBuf;

/// Locate `data/<subdir>/<filename>`: try relative to the working directory
/// (the case when running via `cargo run` from `rust_port/`), then relative
/// to the executable's ancestors (`target/debug/` → `rust_port/`).
pub fn find_data_file(subdir: &str, filename: &str) -> Option<PathBuf> {
    let rel = PathBuf::from("data").join(subdir).join(filename);
    if rel.exists() {
        return Some(rel);
    }
    if let Ok(exe) = std::env::current_exe() {
        for ancestor in exe.ancestors().skip(1).take(4) {
            let candidate = ancestor.join("data").join(subdir).join(filename);
            if candidate.exists() {
                return Some(candidate);
            }
        }
    }
    None
}
