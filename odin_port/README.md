# odin_port

Odin reference implementations of the Hieroglyph3 sample applications from
*Practical Rendering and Computation with Direct3D 11*, written against raw
D3D11 via `vendor:directx`. Companion to
[D3D11-Odin-Guide.md](../D3D11-Odin-Guide.md); each app mirrors the behavior
of its C++ original (in `../Applications/`). The sibling `rust_port/` (on the
`rust` branch) is the same exercise in Rust — behavioral findings from those
ports (engine quirks, sRGB texture metadata, per-stage cbuffer registers)
carry over here.

## Layout

```
odin_port/
├── odrun.bat          # build + run one app: `.\odrun.bat basic_window`
├── glyph/             # support library, imported as the `glyph:` collection
│   ├── window/        #   Win32 window wrappers (≈ Win32RenderWindow, Win32Window)
│   └── renderer/      #   device/swap chain/depth/screenshot (≈ RendererDX11 subset)
└── apps/              # one package per sample application
```

The `glyph` collection is deliberately **not** an engine port — it holds only
the support code the samples share, mirroring the behavior of the
corresponding engine classes (each file names its C++ counterpart) without
the abstraction layers. Shaders and textures load directly from the
repository's `../Applications/Data/` tree, unchanged and uncopied.

## Build & run

```
.\odrun.bat basic_window
```

In PowerShell the leading `.\` is required — PowerShell doesn't search the
current directory, so a bare `odrun` (or `run`) can find a same-named script
elsewhere on PATH. In cmd, `odrun basic_window` works. `odrun.bat` wraps
`odin run apps\<name> -collection:glyph=glyph -subsystem:windows -debug`; drop
`-subsystem:windows` to get a console for debug prints. Text rendering is
permanently out of scope for these ports.

Data files (shaders, textures, models) load from the repo's
`../Applications/Data` tree — the path is baked in at compile time from the
source location, so lookup doesn't depend on the working directory.

## Applications

| App | C++ original | Book chapter | Status |
|---|---|---|---|
| `basic_window` | Applications/BasicWindow | 1 | ✅ matches C++ behavior |
| `basic_application` | Applications/BasicApplication | 1 | ✅ matches C++ behavior |

### basic_window

Pure Win32, no Direct3D. Two windows: the main 320×240 window at (200, 100)
(empty title), and a "Some Text" window that animates its width 170→310 right
after startup. Closing the main window quits; closing "Some Text" doesn't
(its messages go straight to `DefWindowProc` — a quirk preserved from the C++
sample). The app then spins in a `PeekMessage` loop, which is where later
samples put their per-frame update/render.

### basic_application

First Direct3D 11 sample: 640×320 window at (25, 25), cleared each frame to
a time-varying blue (`sin(t²) * 0.25 + 0.5` — the pulsing speeds up over
time) and presented uncapped. `Esc` quits; `Space` saves a numbered
screenshot of the backbuffer. One deviation: screenshots are **BMP**, not
PNG — Odin's core has a PNG decoder but no encoder, and the vendored
`stb_image_write` ships without a prebuilt lib, so `glyph:renderer` writes an
uncompressed 32-bit BMP (same pixels, alpha forced opaque like DirectXTK's
output). Device creation mirrors `RendererDX11::Initialize` — hardware
adapters tried at exactly feature level 10.0, reference-driver fallback,
debug layer under `-debug`. Swap chain uses the engine's defaults
(`R8G8B8A8_UNORM_SRGB`, 2 buffers, `DISCARD`); depth is `D32_FLOAT`.
Resizing does not resize the swap chain — faithful to the C++.
