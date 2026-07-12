// Win32 window wrappers mirroring the engine's window classes:
//
//   - Handler        <-> IWindowProc          (Include/IWindowProc.h)
//   - Render_Window  <-> Win32RenderWindow + its RenderWindow base
//                                             (Source/Win32RenderWindow.cpp)
//   - Simple_Window  <-> Win32Window          (Source/Win32Window.cpp)
//
// The C++ engine routes messages by storing an IWindowProc* in the window's
// extra bytes (cbWndExtra) and reading it back inside a shared wndproc. The
// Odin version keeps the same mechanism, storing a ^Handler — a callback +
// user-data pair, Odin's stand-in for the C++ virtual interface.
package window

import "base:runtime"
import win32 "core:sys/windows"

// Message handler, mirroring IWindowProc. The callback receives every
// message for the window and is responsible for calling DefWindowProcW for
// anything it doesn't fully handle — the same contract the C++ interface has.
Handler :: struct {
	data:     rawptr,
	callback: proc(data: rawptr, hwnd: win32.HWND, msg: win32.UINT, wparam: win32.WPARAM, lparam: win32.LPARAM) -> win32.LRESULT,
}

// The window the renderer draws into, mirroring Win32RenderWindow and the
// defaults of its RenderWindow base class: empty caption, 640x480 client
// area at (100, 100), style WS_OVERLAPPEDWINDOW | WS_VISIBLE.
//
// Set the fields (or use the setters below, mirroring the C++ API), then
// call initialize to create the Win32 window.
Render_Window :: struct {
	hwnd:    win32.HWND,
	caption: string,
	width:   i32,
	height:  i32,
	left:    i32,
	top:     i32,
	style:   win32.DWORD,
}

render_window_default :: proc() -> Render_Window {
	return {
		caption = "",
		width = 640,
		height = 480,
		left = 100,
		top = 100,
		style = win32.WS_OVERLAPPEDWINDOW | win32.WS_VISIBLE,
	}
}

// Desired client-area size / position / caption. Only meaningful before
// initialize (mirrors RenderWindow::SetSize etc.).
set_size :: proc(w: ^Render_Window, width, height: i32) {
	w.width = width
	w.height = height
}

set_position :: proc(w: ^Render_Window, left, top: i32) {
	w.left = left
	w.top = top
}

set_caption :: proc(w: ^Render_Window, caption: string) {
	w.caption = caption
}

// Shared wndproc for Render_Window: recovers the ^Handler stored in the
// window's extra bytes and forwards the message, or falls back to
// DefWindowProc until that pointer has been set (messages sent during
// CreateWindowExW arrive before it is). Mirrors InternalWindowProc in
// Source/Win32RenderWindow.cpp.
@(private)
internal_window_proc :: proc "system" (hwnd: win32.HWND, msg: win32.UINT, wparam: win32.WPARAM, lparam: win32.LPARAM) -> win32.LRESULT {
	handler := cast(^Handler)cast(uintptr)win32.GetWindowLongPtrW(hwnd, 0)
	if handler == nil || handler.callback == nil {
		return win32.DefWindowProcW(hwnd, msg, wparam, lparam)
	}
	// The Win32 callback has no Odin context; give the handler a default one.
	context = runtime.default_context()
	return handler.callback(handler.data, hwnd, msg, wparam, lparam)
}

// Registers the window class and creates the window, storing `handler` in
// the window's extra bytes so internal_window_proc can route messages to it.
//
// The same raw-pointer contract as the C++ engine applies: `handler` must
// outlive the window and must not move. Messages dispatched by later Win32
// calls re-enter it.
initialize :: proc(w: ^Render_Window, handler: ^Handler) {
	wc := win32.WNDCLASSEXW {
		cbSize        = size_of(win32.WNDCLASSEXW),
		style         = win32.CS_HREDRAW | win32.CS_VREDRAW,
		lpfnWndProc   = internal_window_proc,
		cbClsExtra    = 0,
		cbWndExtra    = size_of(rawptr),
		hIcon         = win32.LoadIconW(nil, transmute(win32.wstring)win32._IDI_APPLICATION),
		hCursor       = win32.LoadCursorW(nil, transmute(win32.wstring)win32._IDC_ARROW),
		hbrBackground = win32.HBRUSH(win32.GetStockObject(win32.BLACK_BRUSH)),
		lpszClassName = win32.L("HieroglyphWin32"),
		// IDI_APPLICATION / IDC_ARROW are MAKEINTRESOURCE ids (fake
		// pointers), so the ANSI constants transmute to the W flavor.
		hIconSm       = win32.LoadIconW(nil, transmute(win32.wstring)win32._IDI_APPLICATION),
	}
	win32.RegisterClassExW(&wc)

	// Adjust the window size so the *client* area gets the desired size.
	rc := win32.RECT{0, 0, w.width, w.height}
	win32.AdjustWindowRectEx(&rc, w.style, false, 0)

	w.hwnd = win32.CreateWindowExW(
		0,
		wc.lpszClassName,
		win32.utf8_to_wstring(w.caption),
		w.style,
		w.left,
		w.top,
		rc.right - rc.left,
		rc.bottom - rc.top,
		nil, // parent
		nil, // menu
		nil, // instance
		nil, // creation params
	)
	assert(w.hwnd != nil, "CreateWindowExW failed")

	// Record the client area actually created (desktop limits can make it
	// smaller than requested).
	rect: win32.RECT
	win32.GetClientRect(w.hwnd, &rect)
	w.width = rect.right - rect.left
	w.height = rect.bottom - rect.top

	// Store the message-handler pointer in the extra bytes, then show.
	win32.SetWindowLongPtrW(w.hwnd, 0, win32.LONG_PTR(uintptr(handler)))
	win32.ShowWindow(w.hwnd, win32.SW_SHOWNORMAL)
	win32.UpdateWindow(w.hwnd)
}

// Mirrors Win32RenderWindow::Shutdown; the hwnd is nulled so the window is
// never destroyed twice.
shutdown :: proc(w: ^Render_Window) {
	if w.hwnd != nil {
		win32.DestroyWindow(w.hwnd)
		w.hwnd = nil
	}
}

// Plain wndproc for Simple_Window: everything goes to DefWindowProc (mirrors
// InternalWindowProc2 in Source/Win32Window.cpp, whose custom dispatch is
// commented out in the engine).
@(private)
simple_window_proc :: proc "system" (hwnd: win32.HWND, msg: win32.UINT, wparam: win32.WPARAM, lparam: win32.LPARAM) -> win32.LRESULT {
	return win32.DefWindowProcW(hwnd, msg, wparam, lparam)
}

// A basic standalone window created immediately on construction, mirroring
// Win32Window: class "HieroglyphWin32-2", positioned at (10, 10), shown at
// creation. Note that closing it does not quit the application — its
// messages go straight to DefWindowProc, which never posts WM_QUIT.
Simple_Window :: struct {
	hwnd: win32.HWND,
}

simple_window_create :: proc(width, height: i32, caption: string) -> Simple_Window {
	wc := win32.WNDCLASSEXW {
		cbSize        = size_of(win32.WNDCLASSEXW),
		style         = win32.CS_HREDRAW | win32.CS_VREDRAW,
		lpfnWndProc   = simple_window_proc,
		cbClsExtra    = 0,
		cbWndExtra    = size_of(rawptr),
		hIcon         = win32.LoadIconW(nil, transmute(win32.wstring)win32._IDI_APPLICATION),
		hCursor       = win32.LoadCursorW(nil, transmute(win32.wstring)win32._IDC_ARROW),
		hbrBackground = win32.HBRUSH(win32.GetStockObject(win32.BLACK_BRUSH)),
		lpszClassName = win32.L("HieroglyphWin32-2"),
		// IDI_APPLICATION / IDC_ARROW are MAKEINTRESOURCE ids (fake
		// pointers), so the ANSI constants transmute to the W flavor.
		hIconSm       = win32.LoadIconW(nil, transmute(win32.wstring)win32._IDI_APPLICATION),
	}
	win32.RegisterClassExW(&wc)

	// Quirk preserved from the C++ engine: the size is adjusted for
	// WS_OVERLAPPEDWINDOW, but the window is *created* with style 0
	// (WS_OVERLAPPED), so the client area comes out slightly larger than
	// requested.
	rc := win32.RECT{0, 0, width, height}
	win32.AdjustWindowRectEx(&rc, win32.WS_OVERLAPPEDWINDOW, false, 0)

	hwnd := win32.CreateWindowExW(
		0,
		wc.lpszClassName,
		win32.utf8_to_wstring(caption),
		0,
		10,
		10,
		rc.right - rc.left,
		rc.bottom - rc.top,
		nil,
		nil,
		nil,
		nil,
	)
	assert(hwnd != nil, "CreateWindowExW failed")

	win32.ShowWindow(hwnd, win32.SW_SHOWNORMAL)
	win32.UpdateWindow(hwnd)

	return {hwnd = hwnd}
}

// Resizes the *client* area of the live window, keeping its position
// (mirrors Win32Window::SetSize).
simple_window_set_size :: proc(w: ^Simple_Window, width, height: i32) {
	if w.hwnd == nil {
		return
	}

	style := win32.DWORD(win32.GetWindowLongPtrW(w.hwnd, win32.GWL_STYLE))
	exstyle := win32.DWORD(win32.GetWindowLongPtrW(w.hwnd, win32.GWL_EXSTYLE))

	old_client, old_window: win32.RECT
	win32.GetClientRect(w.hwnd, &old_client)
	win32.GetWindowRect(w.hwnd, &old_window)

	// Desired client rect, adjusted to a full window rect for the style.
	new_window := win32.RECT{
		old_client.left,
		old_client.top,
		old_client.left + width,
		old_client.top + height,
	}
	win32.AdjustWindowRectEx(&new_window, style, false, exstyle)

	win32.MoveWindow(
		w.hwnd,
		old_window.left,
		old_window.top,
		new_window.right - new_window.left,
		new_window.bottom - new_window.top,
		true,
	)
}

simple_window_destroy :: proc(w: ^Simple_Window) {
	if w.hwnd != nil {
		win32.DestroyWindow(w.hwnd)
		w.hwnd = nil
	}
}
