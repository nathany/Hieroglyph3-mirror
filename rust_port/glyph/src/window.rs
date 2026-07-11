//! Win32 window wrappers mirroring the engine's window classes:
//!
//! - [`WindowProc`] ↔ `IWindowProc` (Include/IWindowProc.h)
//! - [`RenderWindow`] ↔ `Win32RenderWindow` + its `RenderWindow` base
//!   (Source/Win32RenderWindow.cpp, Source/RenderWindow.cpp)
//! - [`SimpleWindow`] ↔ `Win32Window` (Source/Win32Window.cpp)
//!
//! The C++ engine routes messages by storing an `IWindowProc*` in the window's
//! extra bytes (`cbWndExtra`) and reading it back inside a shared wndproc. The
//! Rust version keeps the same mechanism, but stores a thin `*mut W` and lets a
//! generic thunk (`internal_window_proc::<W>`) recover the concrete type — no
//! boxing, no dynamic dispatch.

use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::Graphics::Gdi::{BLACK_BRUSH, GetStockObject, HBRUSH, UpdateWindow};
use windows::Win32::UI::WindowsAndMessaging::{
    AdjustWindowRectEx, CS_HREDRAW, CS_VREDRAW, CreateWindowExW, DefWindowProcW, DestroyWindow,
    GWL_EXSTYLE, GWL_STYLE, GetClientRect, GetWindowLongPtrW, GetWindowRect, IDC_ARROW,
    IDI_APPLICATION, LoadCursorW, LoadIconW, MoveWindow, RegisterClassExW, SW_SHOWNORMAL,
    SetWindowLongPtrW, ShowWindow, WINDOW_EX_STYLE, WINDOW_LONG_PTR_INDEX, WINDOW_STYLE,
    WNDCLASSEXW, WS_OVERLAPPEDWINDOW, WS_VISIBLE,
};
use windows::core::{HSTRING, w};

use windows::Win32::Foundation::RECT;

/// Message handler interface, mirroring `IWindowProc`.
///
/// Implementations receive every message for the window and are responsible
/// for calling [`DefWindowProcW`] for anything they don't fully handle — the
/// same contract the C++ interface has.
pub trait WindowProc {
    fn window_proc(&mut self, hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT;

    /// Hook to customize the window class before registration
    /// (mirrors `IWindowProc::BeforeRegisterWindowClass`).
    fn before_register_window_class(&mut self, wc: &mut WNDCLASSEXW) {
        let _ = wc;
    }
}

/// Shared wndproc for [`RenderWindow`]: recovers the `*mut W` stored in the
/// window's extra bytes and forwards the message, or falls back to
/// `DefWindowProc` until that pointer has been set (mirrors
/// `InternalWindowProc` in Source/Win32RenderWindow.cpp).
unsafe extern "system" fn internal_window_proc<W: WindowProc>(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    unsafe {
        let obj_ptr = GetWindowLongPtrW(hwnd, WINDOW_LONG_PTR_INDEX(0)) as *mut W;
        if obj_ptr.is_null() {
            DefWindowProcW(hwnd, msg, wparam, lparam)
        } else {
            (*obj_ptr).window_proc(hwnd, msg, wparam, lparam)
        }
    }
}

/// The window the renderer draws into, mirroring `Win32RenderWindow` and the
/// defaults of its `RenderWindow` base class: empty caption, 640x480 client
/// area at (100, 100), style `WS_OVERLAPPEDWINDOW | WS_VISIBLE`.
///
/// Configure with the setters, then call [`initialize`](Self::initialize) to
/// create the Win32 window.
pub struct RenderWindow {
    hwnd: HWND,
    caption: String,
    width: i32,
    height: i32,
    left: i32,
    top: i32,
    style: WINDOW_STYLE,
}

impl RenderWindow {
    pub fn new() -> Self {
        Self {
            hwnd: HWND::default(),
            caption: String::new(),
            width: 640,
            height: 480,
            left: 100,
            top: 100,
            style: WINDOW_STYLE(WS_OVERLAPPEDWINDOW.0 | WS_VISIBLE.0),
        }
    }

    /// Desired client-area size. Only meaningful before `initialize`.
    pub fn set_size(&mut self, width: i32, height: i32) {
        self.width = width;
        self.height = height;
    }

    /// Desired window position. Only meaningful before `initialize`.
    pub fn set_position(&mut self, left: i32, top: i32) {
        self.left = left;
        self.top = top;
    }

    pub fn set_caption(&mut self, caption: &str) {
        self.caption = caption.to_string();
    }

    /// Registers the window class and creates the window, storing a pointer to
    /// `window_proc` in the window's extra bytes so `internal_window_proc::<W>`
    /// can route messages to it.
    ///
    /// The same raw-pointer contract as the C++ engine applies: `window_proc`
    /// must outlive this window and must not move (keep it in a variable that
    /// lives for the duration of the program, as the samples do). Messages
    /// dispatched by later Win32 calls re-enter it.
    pub fn initialize<W: WindowProc>(&mut self, window_proc: &mut W) {
        unsafe {
            let mut wc = WNDCLASSEXW {
                cbSize: size_of::<WNDCLASSEXW>() as u32,
                style: CS_HREDRAW | CS_VREDRAW,
                lpfnWndProc: Some(internal_window_proc::<W>),
                cbClsExtra: 0,
                cbWndExtra: size_of::<*mut W>() as i32,
                hIcon: LoadIconW(None, IDI_APPLICATION).unwrap_or_default(),
                hCursor: LoadCursorW(None, IDC_ARROW).unwrap_or_default(),
                hbrBackground: HBRUSH(GetStockObject(BLACK_BRUSH).0),
                lpszClassName: w!("HieroglyphWin32"),
                hIconSm: LoadIconW(None, IDI_APPLICATION).unwrap_or_default(),
                ..Default::default()
            };

            window_proc.before_register_window_class(&mut wc);
            RegisterClassExW(&wc);

            // Adjust the window size so the *client* area gets the desired size.
            let mut rc = RECT { left: 0, top: 0, right: self.width, bottom: self.height };
            let _ = AdjustWindowRectEx(&mut rc, self.style, false, WINDOW_EX_STYLE(0));

            self.hwnd = CreateWindowExW(
                WINDOW_EX_STYLE(0),
                wc.lpszClassName,
                &HSTRING::from(self.caption.as_str()),
                self.style,
                self.left,
                self.top,
                rc.right - rc.left,
                rc.bottom - rc.top,
                None, // parent
                None, // menu
                None, // instance
                None, // creation params
            )
            .expect("CreateWindowExW failed");

            // Record the client area actually created (desktop limits can make
            // it smaller than requested).
            let mut rect = RECT::default();
            let _ = GetClientRect(self.hwnd, &mut rect);
            self.width = rect.right - rect.left;
            self.height = rect.bottom - rect.top;

            // Store the message-handler pointer in the extra bytes, then show.
            SetWindowLongPtrW(self.hwnd, WINDOW_LONG_PTR_INDEX(0), window_proc as *mut W as isize);
            let _ = ShowWindow(self.hwnd, SW_SHOWNORMAL);
            let _ = UpdateWindow(self.hwnd);
        }
    }

    pub fn handle(&self) -> HWND {
        self.hwnd
    }

    pub fn width(&self) -> i32 {
        self.width
    }

    pub fn height(&self) -> i32 {
        self.height
    }

    pub fn shutdown(&mut self) {
        if !self.hwnd.is_invalid() {
            unsafe {
                let _ = DestroyWindow(self.hwnd);
            }
            self.hwnd = HWND::default();
        }
    }
}

impl Default for RenderWindow {
    fn default() -> Self {
        Self::new()
    }
}

impl Drop for RenderWindow {
    fn drop(&mut self) {
        self.shutdown();
    }
}

/// Plain wndproc for [`SimpleWindow`]: everything goes to `DefWindowProc`
/// (mirrors `InternalWindowProc2` in Source/Win32Window.cpp, whose custom
/// dispatch is commented out in the engine).
unsafe extern "system" fn simple_window_proc(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) }
}

/// A basic standalone window created immediately on construction, mirroring
/// `Win32Window`: class `HieroglyphWin32-2`, positioned at (10, 10), shown at
/// creation. Note that closing it does not quit the application — its messages
/// go straight to `DefWindowProc`, which never posts `WM_QUIT`.
pub struct SimpleWindow {
    hwnd: HWND,
}

impl SimpleWindow {
    pub fn new(width: i32, height: i32, caption: &str) -> Self {
        unsafe {
            let wc = WNDCLASSEXW {
                cbSize: size_of::<WNDCLASSEXW>() as u32,
                style: CS_HREDRAW | CS_VREDRAW,
                lpfnWndProc: Some(simple_window_proc),
                cbClsExtra: 0,
                cbWndExtra: size_of::<*mut core::ffi::c_void>() as i32,
                hIcon: LoadIconW(None, IDI_APPLICATION).unwrap_or_default(),
                hCursor: LoadCursorW(None, IDC_ARROW).unwrap_or_default(),
                hbrBackground: HBRUSH(GetStockObject(BLACK_BRUSH).0),
                lpszClassName: w!("HieroglyphWin32-2"),
                hIconSm: LoadIconW(None, IDI_APPLICATION).unwrap_or_default(),
                ..Default::default()
            };
            RegisterClassExW(&wc);

            // Quirk preserved from the C++ engine: the size is adjusted for
            // WS_OVERLAPPEDWINDOW, but the window is *created* with style 0
            // (WS_OVERLAPPED), so the client area comes out slightly larger
            // than requested.
            let style = WS_OVERLAPPEDWINDOW;
            let mut rc = RECT { left: 0, top: 0, right: width, bottom: height };
            let _ = AdjustWindowRectEx(&mut rc, style, false, WINDOW_EX_STYLE(0));

            let hwnd = CreateWindowExW(
                WINDOW_EX_STYLE(0),
                wc.lpszClassName,
                &HSTRING::from(caption),
                WINDOW_STYLE(0),
                10,
                10,
                rc.right - rc.left,
                rc.bottom - rc.top,
                None,
                None,
                None,
                None,
            )
            .expect("CreateWindowExW failed");

            let _ = ShowWindow(hwnd, SW_SHOWNORMAL);
            let _ = UpdateWindow(hwnd);

            Self { hwnd }
        }
    }

    pub fn handle(&self) -> HWND {
        self.hwnd
    }

    /// Resizes the *client* area of the live window, keeping its position
    /// (mirrors `Win32Window::SetSize`).
    pub fn set_size(&mut self, width: i32, height: i32) {
        if self.hwnd.is_invalid() {
            return;
        }
        unsafe {
            let style = WINDOW_STYLE(GetWindowLongPtrW(self.hwnd, GWL_STYLE) as u32);
            let exstyle = WINDOW_EX_STYLE(GetWindowLongPtrW(self.hwnd, GWL_EXSTYLE) as u32);

            let mut old_client = RECT::default();
            let mut old_window = RECT::default();
            let _ = GetClientRect(self.hwnd, &mut old_client);
            let _ = GetWindowRect(self.hwnd, &mut old_window);

            // Desired client rect, adjusted to a full window rect for the style.
            let mut new_window = RECT {
                left: old_client.left,
                top: old_client.top,
                right: old_client.left + width,
                bottom: old_client.top + height,
            };
            let _ = AdjustWindowRectEx(&mut new_window, style, false, exstyle);

            let _ = MoveWindow(
                self.hwnd,
                old_window.left,
                old_window.top,
                new_window.right - new_window.left,
                new_window.bottom - new_window.top,
                true,
            );
        }
    }
}

impl Drop for SimpleWindow {
    fn drop(&mut self) {
        if !self.hwnd.is_invalid() {
            unsafe {
                let _ = DestroyWindow(self.hwnd);
            }
            self.hwnd = HWND::default();
        }
    }
}
