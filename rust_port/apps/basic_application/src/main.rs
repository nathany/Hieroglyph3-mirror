//! Rust port of the BasicApplication sample (Applications/BasicApplication/App.cpp).
//!
//! The first sample with Direct3D 11: a 640x320 window at (25, 25) titled
//! "BasicApplication" whose client area is cleared each frame to a
//! time-varying blue — `sin(t²) * 0.25 + 0.5`, so the pulsing speeds up over
//! time — and presented with no vsync (the C++ framework presents with
//! `SyncInterval = 0` and logs the max framerate on exit).
//!
//! Behavior inherited from the C++ `Application` framework (see
//! `glyph::window::AppMessageHandler` and `glyph::renderer::Renderer`):
//! - `Esc` (key up) quits.
//! - `Space` (key up) saves a PNG screenshot of the backbuffer to the working
//!   directory, named `BasicApplication100001.png`, `...100002.png`, ... (the
//!   C++ numbering starts at 100001).
//! - Closing the window quits.
//! - Resizing does nothing to the swap chain (no one handles the resize event
//!   in this sample), so the 640x320 image is stretched — faithful to C++.

#![windows_subsystem = "windows"]

use std::time::Instant;

use glyph::renderer::Renderer;
use glyph::window::{AppMessageHandler, RenderWindow};
use windows::Win32::Graphics::Direct3D11::D3D11_CLEAR_DEPTH;
use windows::Win32::UI::WindowsAndMessaging::{
    DispatchMessageW, MB_ICONEXCLAMATION, MB_SYSTEMMODAL, MSG, MessageBoxW, PM_REMOVE,
    PeekMessageW, SW_HIDE, ShowWindow, TranslateMessage, WM_QUIT,
};
use windows::core::w;

const WIDTH: u32 = 640;
const HEIGHT: u32 = 320;

fn main() {
    let mut handler = AppMessageHandler::default();

    let mut window = RenderWindow::new();
    window.set_position(25, 25);
    window.set_size(WIDTH as i32, HEIGHT as i32);
    window.set_caption("BasicApplication");
    window.initialize(&mut handler);

    let renderer = match Renderer::new(window.handle(), WIDTH, HEIGHT) {
        Ok(r) => r,
        Err(_) => {
            // Mirrors the C++ failure path: hide the window, tell the user,
            // and abort.
            // SAFETY: The window handle is live; MessageBoxW with constant
            // strings is safe.
            unsafe {
                let _ = ShowWindow(window.handle(), SW_HIDE);
                MessageBoxW(
                    None,
                    w!("Could not create a hardware or software Direct3D 11 device - the program will now abort!"),
                    w!("Hieroglyph 3 Rendering"),
                    MB_ICONEXCLAMATION | MB_SYSTEMMODAL,
                );
            }
            return;
        }
    };

    let start = Instant::now();
    let mut screenshot_number = 100_000u32;
    let mut msg = MSG::default();

    loop {
        // SAFETY: Standard message pump; `DispatchMessageW` re-enters
        // `handler.window_proc`, which is sound because `handler` lives until
        // `main` returns and is only touched here between pump iterations —
        // wndproc calls and these accesses are temporally disjoint on this
        // single thread.
        unsafe {
            while PeekMessageW(&mut msg, None, 0, 0, PM_REMOVE).as_bool() {
                if msg.message == WM_QUIT {
                    return;
                }

                let _ = TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        }

        // App::Update — clear the window to a time-varying color and present.
        let runtime = start.elapsed().as_secs_f32();
        let f_blue = (runtime * runtime).sin() * 0.25 + 0.5;

        // SAFETY: The views are alive for the whole loop; the clear color is
        // a valid [f32; 4].
        unsafe {
            renderer.context.ClearRenderTargetView(&renderer.rtv, &[0.0, 0.0, f_blue, 0.0]);
            renderer.context.ClearDepthStencilView(&renderer.dsv, D3D11_CLEAR_DEPTH.0 as u32, 1.0, 0);
        }
        renderer.present();

        // Application::TakeScreenShot — triggered by Space (see AppMessageHandler).
        if handler.save_screenshot {
            handler.save_screenshot = false;
            screenshot_number += 1;
            renderer.save_backbuffer_png(&format!("BasicApplication{screenshot_number}.png"));
        }
    }
}
