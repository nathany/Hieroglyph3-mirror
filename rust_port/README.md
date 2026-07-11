# rust_port

Rust reference implementations of the Hieroglyph3 sample applications from
*Practical Rendering and Computation with Direct3D 11*, written against raw
D3D11 via the `windows` crate. Companion to [D3D11-Rust-Guide.md](../D3D11-Rust-Guide.md);
each app mirrors the behavior of its C++ original (in `../Applications/`),
verified side by side against the VS2022 builds in `../Applications/Bin`.

## Layout

```
rust_port/
├── Cargo.toml          # workspace; shared deps in [workspace.dependencies]
├── glyph/              # support library — grows only as samples need it
│   └── src/window.rs   #   Win32 window wrappers (≈ Win32RenderWindow, Win32Window)
├── apps/
│   └── basic_window/   # one binary crate per sample application
└── data/               # shaders/textures copied from ../Applications/Data (as needed)
```

The `glyph` crate is deliberately **not** an engine port — it holds only the
support code the samples share, mirroring the behavior of the corresponding
engine classes (each module's docs name its C++ counterpart) without the
abstraction layers (`ResourceProxy`, `ParameterManager`, events, scene graph).

## Build & run

```
cargo run -p basic_window
```

## Applications

| App | C++ original | Book chapter | Status |
|---|---|---|---|
| `basic_window` | Applications/BasicWindow | 1 | ✅ matches C++ behavior |
| `basic_application` | Applications/BasicApplication | 1 | ✅ matches C++ behavior |

### basic_window

Pure Win32, no Direct3D. Two windows: the main 320×240 window at (200, 100)
(empty title), and a "Some Text" window that animates its width 170→310 right
after startup. Closing the main window quits; closing "Some Text" doesn't (its
messages go straight to `DefWindowProc` — a quirk preserved from the C++
sample). The app then spins in a `PeekMessage` loop, which is where later
samples put their per-frame update/render.

### basic_application

First Direct3D 11 sample: 640×320 window at (25, 25), cleared each frame to a
time-varying blue (`sin(t²) * 0.25 + 0.5` — the pulsing speeds up over time)
and presented uncapped (`SyncInterval = 0`, as the C++ framework does).
`Esc` quits; `Space` saves `BasicApplication<n>.png` (numbered from 100001)
to the working directory via a staging-texture readback + the `image` crate,
standing in for DirectXTK's `SaveWICTextureToFile`. Device creation mirrors
`RendererDX11::Initialize` — hardware adapters tried at exactly feature level
10.0, reference-driver fallback, debug layer in debug builds. Swap chain uses
the engine's defaults (`R8G8B8A8_UNORM_SRGB`, 2 buffers, `DISCARD`); depth is
`D32_FLOAT`. Resizing the window does not resize the swap chain — faithful to
the C++, where nothing consumes the resize event in this sample.
