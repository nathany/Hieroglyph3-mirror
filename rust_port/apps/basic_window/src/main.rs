//! Rust port of the BasicWindow sample (Applications/BasicWindow/main.cpp).
//!
//! Demonstrates raw Win32 windowing with no Direct3D involved:
//! - `window1`: a 320x240 `RenderWindow` at (200, 100) whose messages are
//!   handled by `WindowProcessor` — closing it quits the application.
//! - `window2`: a `SimpleWindow` titled "Some Text" that animates its width
//!   from 170 to 310 in 10-pixel steps, 100 ms apart, right after startup.
//!   Its messages go to `DefWindowProc`, so closing it does *not* quit.
//!
//! After the animation, the app spins in a `PeekMessage` loop (as the C++
//! sample does — this is where a render/update call goes in later samples)
//! until `WM_QUIT` arrives.

#![windows_subsystem = "windows"]

use std::thread::sleep;
use std::time::Duration;

use glyph::window::{RenderWindow, SimpleWindow, WindowProc};
use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::UI::WindowsAndMessaging::{
    DefWindowProcW, DispatchMessageW, MSG, PM_REMOVE, PeekMessageW, PostQuitMessage,
    TranslateMessage, WM_CREATE, WM_DESTROY, WM_QUIT,
};

struct WindowProcessor;

impl WindowProc for WindowProcessor {
    fn window_proc(&mut self, hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
        match msg {
            // Return 0 to allow the window to proceed in the creation process.
            WM_CREATE => return LRESULT(0),

            // Sent when a window has been destroyed.
            WM_DESTROY => {
                // SAFETY: Trivially safe to call from the thread that owns the
                // window; only marked unsafe as an FFI function.
                unsafe { PostQuitMessage(0) };
                return LRESULT(0);
            }

            _ => {}
        }

        // SAFETY: Forwarding a message to the default handler with the exact
        // arguments Win32 passed in is always valid.
        unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) }
    }
}

fn main() {
    let mut wndproc = WindowProcessor;

    let mut window1 = RenderWindow::new();
    window1.set_size(320, 240);
    window1.set_position(200, 100);
    window1.initialize(&mut wndproc);

    let mut window2 = SimpleWindow::new(160, 240, "Some Text");

    for i in (170..320).step_by(10) {
        window2.set_size(i, 240);
        sleep(Duration::from_millis(100));
    }

    let mut msg = MSG::default();

    loop {
        // SAFETY: Standard message pump: `msg` is a valid out-param, and
        // `DispatchMessageW` re-enters our wndprocs, which is sound because
        // `wndproc` (the handler window1 points at) lives until `main` returns
        // and nothing else borrows it while the pump runs.
        unsafe {
            while PeekMessageW(&mut msg, None, 0, 0, PM_REMOVE).as_bool() {
                if msg.message == WM_QUIT {
                    return;
                }

                let _ = TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        }

        // In later samples, the per-frame update/render call goes here.
    }
}
