// Odin port of the BasicWindow sample (Applications/BasicWindow/main.cpp).
//
// Demonstrates raw Win32 windowing with no Direct3D involved:
//   - window1: a 320x240 Render_Window at (200, 100) whose messages are
//     handled by window_processor — closing it quits the application.
//   - window2: a Simple_Window titled "Some Text" that animates its width
//     from 170 to 310 in 10-pixel steps, 100 ms apart, right after startup.
//     Its messages go to DefWindowProc, so closing it does *not* quit.
//
// After the animation, the app spins in a PeekMessage loop (as the C++
// sample does — this is where a render/update call goes in later samples)
// until WM_QUIT arrives.
package main

import win32 "core:sys/windows"
import "glyph:window"

window_processor :: proc(data: rawptr, hwnd: win32.HWND, msg: win32.UINT, wparam: win32.WPARAM, lparam: win32.LPARAM) -> win32.LRESULT {
	switch msg {
	case win32.WM_CREATE:
		// Return 0 to allow the window to proceed in the creation process.
		return 0

	case win32.WM_DESTROY:
		// Sent when a window has been destroyed.
		win32.PostQuitMessage(0)
		return 0
	}

	return win32.DefWindowProcW(hwnd, msg, wparam, lparam)
}

main :: proc() {
	handler := window.Handler{callback = window_processor}

	window1 := window.render_window_default()
	window.set_size(&window1, 320, 240)
	window.set_position(&window1, 200, 100)
	window.initialize(&window1, &handler)
	defer window.shutdown(&window1)

	window2 := window.simple_window_create(160, 240, "Some Text")
	defer window.simple_window_destroy(&window2)

	for i: i32 = 170; i < 320; i += 10 {
		window.simple_window_set_size(&window2, i, 240)
		win32.Sleep(100)
	}

	msg: win32.MSG
	for {
		for win32.PeekMessageW(&msg, nil, 0, 0, win32.PM_REMOVE) {
			if msg.message == win32.WM_QUIT {
				return
			}

			win32.TranslateMessage(&msg)
			win32.DispatchMessageW(&msg)
		}

		// In later samples, the per-frame update/render call goes here.
	}
}
