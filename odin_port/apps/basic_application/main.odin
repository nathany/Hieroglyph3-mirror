// Odin port of the BasicApplication sample
// (Applications/BasicApplication/App.cpp).
//
// The first sample with Direct3D 11: a 640x320 window at (25, 25) titled
// "BasicApplication" whose client area is cleared each frame to a
// time-varying blue — sin(t^2) * 0.25 + 0.5, so the pulsing speeds up over
// time — and presented with no vsync (the C++ framework presents with
// SyncInterval = 0 and logs the max framerate on exit).
//
// Behavior inherited from the C++ Application framework:
//   - Esc (key up) quits.
//   - Space (key up) saves a screenshot of the backbuffer to the working
//     directory, numbered from 100001 (the C++'s numbering; see the BMP note
//     in glyph:renderer).
//   - Closing the window quits.
//   - Resizing does nothing to the swap chain (no one handles the resize
//     event in this sample), so the 640x320 image is stretched — faithful
//     to the C++.
//
// Device creation mirrors RendererDX11::Initialize: each hardware adapter is
// tried at exactly FEATURE_LEVEL 10.0, then the reference driver, and the
// app aborts with a message box if both fail.
package main

import "core:fmt"
import "core:math"
import "core:time"
import win32 "core:sys/windows"
import "glyph:renderer"
import "glyph:window"

WIDTH :: 640
HEIGHT :: 320

// Mirrors the parts of Application::WindowProc + Application::HandleEvent
// this sample exercises: quit on window destruction or Esc, request a
// screenshot on Space.
App_State :: struct {
	save_screenshot: bool,
}

message_callback :: proc(data: rawptr, hwnd: win32.HWND, msg: win32.UINT, wparam: win32.WPARAM, lparam: win32.LPARAM) -> win32.LRESULT {
	state := cast(^App_State)data

	switch msg {
	case win32.WM_DESTROY:
		win32.PostQuitMessage(0)
		return 0

	case win32.WM_KEYUP:
		switch wparam {
		case win32.WPARAM(win32.VK_ESCAPE):
			win32.PostQuitMessage(0)
			return 0
		case win32.WPARAM(win32.VK_SPACE):
			state.save_screenshot = true
			return 0
		}
	}

	return win32.DefWindowProcW(hwnd, msg, wparam, lparam)
}

main :: proc() {
	state: App_State
	handler := window.Handler {
		data     = &state,
		callback = message_callback,
	}

	win := window.render_window_default()
	window.set_position(&win, 25, 25)
	window.set_size(&win, WIDTH, HEIGHT)
	window.set_caption(&win, "BasicApplication")
	window.initialize(&win, &handler)
	defer window.shutdown(&win)

	r, renderer_ok := renderer.create(win.hwnd, WIDTH, HEIGHT, ._10_0)
	if !renderer_ok {
		// Mirrors the C++ failure path: hide the window, tell the user, abort.
		win32.ShowWindow(win.hwnd, win32.SW_HIDE)
		win32.MessageBoxW(
			nil,
			win32.L("Could not create a hardware or software Direct3D 11 device - the program will now abort!"),
			win32.L("Hieroglyph 3 Rendering"),
			win32.MB_ICONEXCLAMATION | win32.MB_SYSTEMMODAL,
		)
		return
	}
	defer renderer.destroy(&r)

	start := time.tick_now()
	screenshot_number := 100_000

	msg: win32.MSG
	for {
		for win32.PeekMessageW(&msg, nil, 0, 0, win32.PM_REMOVE) {
			if msg.message == win32.WM_QUIT {
				return
			}

			win32.TranslateMessage(&msg)
			win32.DispatchMessageW(&msg)
		}

		// App::Update — clear the window to a time-varying color and present.
		runtime_s := f32(time.duration_seconds(time.tick_since(start)))
		f_blue := math.sin(runtime_s * runtime_s) * 0.25 + 0.5

		color := [4]f32{0.0, 0.0, f_blue, 0.0}
		r.ctx->ClearRenderTargetView(r.rtv, &color)
		r.ctx->ClearDepthStencilView(r.dsv, {.DEPTH}, 1.0, 0)
		renderer.present(&r)

		// Application::TakeScreenShot — triggered by Space.
		if state.save_screenshot {
			state.save_screenshot = false
			screenshot_number += 1
			renderer.save_backbuffer_bmp(&r, fmt.tprintf("BasicApplication%d.bmp", screenshot_number))
		}
	}
}
