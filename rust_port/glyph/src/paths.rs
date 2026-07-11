//! Data-file lookup, standing in for the engine's `FileSystem` class. Files
//! resolve to the repository's original `Applications/Data` tree — the same
//! shaders and textures the C++ demos use — so nothing is copied into
//! `rust_port/`.

use std::path::PathBuf;

/// Locate `Applications/Data/<subdir>/<filename>`: try relative to the
/// working directory (running from the repository root), then its parent
/// (running via `cargo run` from `rust_port/`), then relative to the
/// executable's ancestors (`rust_port/target/debug/` → repository root).
pub fn find_data_file(subdir: &str, filename: &str) -> Option<PathBuf> {
    let tail = PathBuf::from("Applications").join("Data").join(subdir).join(filename);

    if tail.exists() {
        return Some(tail);
    }

    let from_parent = PathBuf::from("..").join(&tail);
    if from_parent.exists() {
        return Some(from_parent);
    }

    if let Ok(exe) = std::env::current_exe() {
        for ancestor in exe.ancestors().skip(1).take(5) {
            let candidate = ancestor.join(&tail);
            if candidate.exists() {
                return Some(candidate);
            }
        }
    }

    None
}
