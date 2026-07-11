//! Support library for the Rust ports of the Hieroglyph3 sample applications
//! (from *Practical Rendering and Computation with Direct3D 11*).
//!
//! This is deliberately **not** a port of the Hieroglyph3 engine. It only grows
//! the pieces each sample application actually needs, mirroring the behavior of
//! the corresponding engine classes (referenced in each module's docs) without
//! their abstraction layers.

pub mod renderer;
pub mod shader;
pub mod window;
