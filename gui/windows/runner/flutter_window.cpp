#include <winsock2.h>
#include <ws2tcpip.h>

#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cwchar>
#include <optional>
#include <variant>
#include <vector>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

namespace {
constexpr UINT kTrayIconId = 1;
constexpr UINT kWmTrayCallback = WM_APP + 101;
constexpr UINT kIdTrayShow = 41001;
constexpr UINT kIdTrayQuit = 41002;
constexpr uint16_t kBridgePort = 8787;

std::wstring Utf8ToWide(const std::string& s) {
  if (s.empty()) return L"";
  int len = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, nullptr, 0);
  if (len <= 0) return L"";
  std::wstring out(static_cast<size_t>(len - 1), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, out.data(), len);
  return out;
}

std::string WideToUtf8(const std::wstring& s) {
  if (s.empty()) return "";
  int len = WideCharToMultiByte(CP_UTF8, 0, s.data(), static_cast<int>(s.size()),
                                nullptr, 0, nullptr, nullptr);
  if (len <= 0) return "";
  std::string out(static_cast<size_t>(len), '\0');
  WideCharToMultiByte(CP_UTF8, 0, s.data(), static_cast<int>(s.size()),
                      out.data(), len, nullptr, nullptr);
  return out;
}

bool FileExistsW(const std::wstring& path) {
  DWORD attr = GetFileAttributesW(path.c_str());
  return attr != INVALID_FILE_ATTRIBUTES && !(attr & FILE_ATTRIBUTE_DIRECTORY);
}

std::wstring DirNameW(const std::wstring& path) {
  size_t pos = path.find_last_of(L"\\/");
  if (pos == std::wstring::npos) return L"";
  return path.substr(0, pos);
}

bool IsBridgePortOpen() {
  WSADATA wsa{};
  if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) return false;
  SOCKET sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  bool open = false;
  if (sock != INVALID_SOCKET) {
    u_long mode = 1;
    ioctlsocket(sock, FIONBIO, &mode);
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(kBridgePort);
    inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);
    int res = connect(sock, reinterpret_cast<sockaddr*>(&addr), sizeof(addr));
    if (res == 0) {
      open = true;
    } else if (WSAGetLastError() == WSAEWOULDBLOCK) {
      fd_set write_fds;
      fd_set err_fds;
      FD_ZERO(&write_fds);
      FD_ZERO(&err_fds);
      FD_SET(sock, &write_fds);
      FD_SET(sock, &err_fds);
      timeval tv{};
      tv.tv_sec = 0;
      tv.tv_usec = 100000;
      if (select(0, nullptr, &write_fds, &err_fds, &tv) > 0 &&
          FD_ISSET(sock, &write_fds) && !FD_ISSET(sock, &err_fds)) {
        int so_err = 0;
        int len = sizeof(so_err);
        if (getsockopt(sock, SOL_SOCKET, SO_ERROR,
                       reinterpret_cast<char*>(&so_err), &len) == 0 &&
            so_err == 0) {
          open = true;
        }
      }
    }
    closesocket(sock);
  }
  WSACleanup();
  return open;
}

std::wstring FindBackendExe() {
  wchar_t self_buf[MAX_PATH]{};
  DWORD n = GetModuleFileNameW(nullptr, self_buf, MAX_PATH);
  if (n == 0 || n >= MAX_PATH) return L"";

  std::wstring exe_dir = DirNameW(self_buf);
  std::vector<std::wstring> candidates;
  candidates.push_back(exe_dir + L"\\warust.exe");

  // Walk up from gui\build\windows\x64\runner\{Release,Debug} to repo root.
  std::wstring cur = exe_dir;
  for (int i = 0; i < 7 && !cur.empty(); ++i) {
    candidates.push_back(cur + L"\\target\\release\\warust.exe");
    candidates.push_back(cur + L"\\target\\debug\\warust.exe");
    cur = DirNameW(cur);
  }

  for (const auto& c : candidates) {
    if (FileExistsW(c)) return c;
  }
  return L"";
}

// Minimal 3x5 pixel glyphs for crisp 16x16 taskbar overlay digits 0-9 and '+'.
constexpr uint8_t kGlyphs[11][5] = {
    {0b111, 0b101, 0b101, 0b101, 0b111},  // 0
    {0b010, 0b110, 0b010, 0b010, 0b111},  // 1
    {0b111, 0b001, 0b111, 0b100, 0b111},  // 2
    {0b111, 0b001, 0b111, 0b001, 0b111},  // 3
    {0b101, 0b101, 0b111, 0b001, 0b001},  // 4
    {0b111, 0b100, 0b111, 0b001, 0b111},  // 5
    {0b111, 0b100, 0b111, 0b101, 0b111},  // 6
    {0b111, 0b001, 0b001, 0b010, 0b010},  // 7
    {0b111, 0b101, 0b111, 0b101, 0b111},  // 8
    {0b111, 0b101, 0b111, 0b001, 0b111},  // 9
    {0b000, 0b010, 0b111, 0b010, 0b000},  // +
};

void BlendPixel(uint32_t* dst, uint8_t r, uint8_t g, uint8_t b, uint8_t a) {
  if (a == 0) return;
  if (a == 255) {
    *dst = (static_cast<uint32_t>(a) << 24) |
           (static_cast<uint32_t>(r) << 16) |
           (static_cast<uint32_t>(g) << 8) | b;
    return;
  }
  uint32_t bg = *dst;
  uint8_t ba = static_cast<uint8_t>(bg >> 24);
  uint8_t br = static_cast<uint8_t>((bg >> 16) & 0xFF);
  uint8_t bgc = static_cast<uint8_t>((bg >> 8) & 0xFF);
  uint8_t bb = static_cast<uint8_t>(bg & 0xFF);
  double fa = a / 255.0;
  double inv = 1.0 - fa;
  uint8_t oa = static_cast<uint8_t>(std::min(255.0, a + ba * inv));
  uint8_t or_ = static_cast<uint8_t>(std::min(255.0, r * fa + br * inv));
  uint8_t og = static_cast<uint8_t>(std::min(255.0, g * fa + bgc * inv));
  uint8_t ob = static_cast<uint8_t>(std::min(255.0, b * fa + bb * inv));
  *dst = (static_cast<uint32_t>(oa) << 24) |
         (static_cast<uint32_t>(or_) << 16) |
         (static_cast<uint32_t>(og) << 8) | ob;
}

void DrawCircleAa(uint32_t* pixels, int size, double cx, double cy, double rad,
                  uint8_t r, uint8_t g, uint8_t b, uint8_t a = 255) {
  for (int y = 0; y < size; ++y) {
    for (int x = 0; x < size; ++x) {
      double dx = (x + 0.5) - cx;
      double dy = (y + 0.5) - cy;
      double dist = std::sqrt(dx * dx + dy * dy);
      double cov = std::clamp(rad + 0.5 - dist, 0.0, 1.0);
      if (cov > 0.0) {
        BlendPixel(&pixels[y * size + x], r, g, b,
                   static_cast<uint8_t>(cov * a));
      }
    }
  }
}

void DrawGlyph3x5(uint32_t* pixels, int size, int ox, int oy, int glyph_idx,
                  int scale) {
  for (int row = 0; row < 5; ++row) {
    uint8_t bits = kGlyphs[glyph_idx][row];
    for (int col = 0; col < 3; ++col) {
      if ((bits & (1 << (2 - col))) == 0) continue;
      for (int sy = 0; sy < scale; ++sy) {
        for (int sx = 0; sx < scale; ++sx) {
          int px = ox + col * scale + sx;
          int py = oy + row * scale + sy;
          if (px >= 0 && px < size && py >= 0 && py < size) {
            pixels[py * size + px] = 0xFFFFFFFFu;
          }
        }
      }
    }
  }
}

HICON BuildIconFromPixels(const std::vector<uint32_t>& pixels, int size) {
  BITMAPV5HEADER bi{};
  bi.bV5Size = sizeof(BITMAPV5HEADER);
  bi.bV5Width = size;
  bi.bV5Height = -size;
  bi.bV5Planes = 1;
  bi.bV5BitCount = 32;
  bi.bV5Compression = BI_BITFIELDS;
  bi.bV5RedMask = 0x00FF0000;
  bi.bV5GreenMask = 0x0000FF00;
  bi.bV5BlueMask = 0x000000FF;
  bi.bV5AlphaMask = 0xFF000000;

  void* dib_bits = nullptr;
  HDC hdc = GetDC(nullptr);
  HBITMAP hbm_color = CreateDIBSection(
      hdc, reinterpret_cast<BITMAPINFO*>(&bi), DIB_RGB_COLORS, &dib_bits,
      nullptr, 0);
  ReleaseDC(nullptr, hdc);
  if (!hbm_color || !dib_bits) {
    if (hbm_color) DeleteObject(hbm_color);
    return nullptr;
  }
  memcpy(dib_bits, pixels.data(), pixels.size() * sizeof(uint32_t));

  HBITMAP hbm_mask = CreateBitmap(size, size, 1, 1, nullptr);
  ICONINFO ii{};
  ii.fIcon = TRUE;
  ii.hbmColor = hbm_color;
  ii.hbmMask = hbm_mask;
  HICON out = CreateIconIndirect(&ii);

  DeleteObject(hbm_color);
  if (hbm_mask) DeleteObject(hbm_mask);
  return out;
}

HICON CreateTaskbarUnreadIcon(int unread) {
  if (unread <= 0) return nullptr;
  constexpr int kSize = 16;
  std::vector<uint32_t> pixels(kSize * kSize, 0);
  DrawCircleAa(pixels.data(), kSize, 8.0, 8.0, 7.2, 234, 67, 53);
  if (unread <= 9) {
    DrawGlyph3x5(pixels.data(), kSize, 5, 3, unread, 2);
  } else {
    DrawGlyph3x5(pixels.data(), kSize, 4, 5, 9, 1);
    DrawGlyph3x5(pixels.data(), kSize, 8, 5, 10, 1);
  }
  return BuildIconFromPixels(pixels, kSize);
}

HICON CreateTrayBadgedIcon(HICON base_icon, int size) {
  if (!base_icon || size <= 0) return nullptr;
  BITMAPINFO bi{};
  bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bi.bmiHeader.biWidth = size;
  bi.bmiHeader.biHeight = -size;
  bi.bmiHeader.biPlanes = 1;
  bi.bmiHeader.biBitCount = 32;
  bi.bmiHeader.biCompression = BI_RGB;

  void* dib_bits = nullptr;
  HDC screen = GetDC(nullptr);
  HDC mem = CreateCompatibleDC(screen);
  HBITMAP hbm = CreateDIBSection(mem, &bi, DIB_RGB_COLORS, &dib_bits, nullptr, 0);
  if (!hbm || !dib_bits) {
    if (hbm) DeleteObject(hbm);
    DeleteDC(mem);
    ReleaseDC(nullptr, screen);
    return nullptr;
  }
  HGDIOBJ old = SelectObject(mem, hbm);
  ZeroMemory(dib_bits, static_cast<size_t>(size) * size * 4);
  DrawIconEx(mem, 0, 0, base_icon, size, size, 0, nullptr, DI_NORMAL);
  GdiFlush();

  std::vector<uint32_t> pixels(static_cast<size_t>(size) * size);
  memcpy(pixels.data(), dib_bits, pixels.size() * 4);

  SelectObject(mem, old);
  DeleteObject(hbm);
  DeleteDC(mem);
  ReleaseDC(nullptr, screen);

  double rad = size * 0.24;
  double cx = size - rad - 0.5;
  double cy = rad + 0.5;
  DrawCircleAa(pixels.data(), size, cx, cy, rad + 1.0, 17, 27, 33);
  DrawCircleAa(pixels.data(), size, cx, cy, rad, 255, 59, 48);
  return BuildIconFromPixels(pixels, size);
}
}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project,
                             bool start_in_tray)
    : project_(project), start_in_tray_(start_in_tray) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  taskbar_created_msg_ = RegisterWindowMessageW(L"TaskbarCreated");
  taskbar_btn_created_msg_ = RegisterWindowMessageW(L"TaskbarButtonCreated");

  EnsureBackendRunning();

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  InitTrayChannel();
  CreateOrUpdateTrayIcon();
  if (HWND hwnd = GetHandle()) {
    DragAcceptFiles(hwnd, TRUE);
  }

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    if (start_in_tray_ && run_in_tray_) {
      this->NotifyFocus(false);
    } else {
      this->Show();
    }
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::EnsureBackendRunning() {
  if (quit_requested_) {
    return;
  }
  if (backend_process_) {
    if (WaitForSingleObject(backend_process_, 0) == WAIT_TIMEOUT) {
      return;
    }
    CloseHandle(backend_process_);
    backend_process_ = nullptr;
    if (backend_job_) {
      CloseHandle(backend_job_);
      backend_job_ = nullptr;
    }
  }
  if (IsBridgePortOpen()) {
    return;
  }
  std::wstring backend_exe = FindBackendExe();
  if (backend_exe.empty()) {
    return;
  }

  backend_job_ = CreateJobObjectW(nullptr, nullptr);
  if (backend_job_) {
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION jeli{};
    jeli.BasicLimitInformation.LimitFlags =
        JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_BREAKAWAY_OK;
    SetInformationJobObject(backend_job_, JobObjectExtendedLimitInformation,
                            &jeli, sizeof(jeli));
  }

  std::wstring cmd = L"\"" + backend_exe + L"\" --ui ws";
  std::vector<wchar_t> cmd_buf(cmd.begin(), cmd.end());
  cmd_buf.push_back(L'\0');

  std::wstring work_dir = DirNameW(backend_exe);
  STARTUPINFOW si{};
  si.cb = sizeof(si);
  PROCESS_INFORMATION pi{};
  BOOL ok = CreateProcessW(
      backend_exe.c_str(), cmd_buf.data(), nullptr, nullptr, FALSE,
      CREATE_NO_WINDOW, nullptr,
      work_dir.empty() ? nullptr : work_dir.c_str(), &si, &pi);
  if (ok) {
    if (backend_job_) {
      AssignProcessToJobObject(backend_job_, pi.hProcess);
    }
    CloseHandle(pi.hThread);
    backend_process_ = pi.hProcess;
  } else if (backend_job_) {
    CloseHandle(backend_job_);
    backend_job_ = nullptr;
  }
}

void FlutterWindow::ShutdownSpawnedBackend() {
  if (backend_process_) {
    TerminateProcess(backend_process_, 0);
    CloseHandle(backend_process_);
    backend_process_ = nullptr;
  }
  if (backend_job_) {
    CloseHandle(backend_job_);
    backend_job_ = nullptr;
  }
}

void FlutterWindow::InitTrayChannel() {
  tray_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "warust/tray",
          &flutter::StandardMethodCodec::GetInstance());

  tray_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "update") {
          if (const auto* map =
                  std::get_if<flutter::EncodableMap>(call.arguments())) {
            auto itRun = map->find(flutter::EncodableValue("runInTray"));
            if (itRun != map->end()) {
              if (const auto* v = std::get_if<bool>(&itRun->second)) {
                run_in_tray_ = *v;
              }
            }
            auto itClose = map->find(flutter::EncodableValue("closeToTray"));
            if (itClose != map->end()) {
              if (const auto* v = std::get_if<bool>(&itClose->second)) {
                close_to_tray_ = *v;
              }
            }
            auto itLang = map->find(flutter::EncodableValue("lang"));
            if (itLang != map->end()) {
              if (const auto* v = std::get_if<std::string>(&itLang->second)) {
                tray_lang_ = Utf8ToWide(*v);
              }
            }
            auto itTip = map->find(flutter::EncodableValue("tooltip"));
            if (itTip != map->end()) {
              if (const auto* v = std::get_if<std::string>(&itTip->second)) {
                tray_tooltip_ = Utf8ToWide(*v);
              }
            }
            auto itUnread = map->find(flutter::EncodableValue("unread"));
            if (itUnread != map->end()) {
              if (const auto* v = std::get_if<int32_t>(&itUnread->second)) {
                unread_count_ = *v;
              } else if (const auto* v64 =
                             std::get_if<int64_t>(&itUnread->second)) {
                unread_count_ = static_cast<int>(*v64);
              }
            }
          }
          CreateOrUpdateTrayIcon();
          UpdateTaskbarOverlay();
          result->Success();
        } else if (call.method_name() == "show") {
          RestoreFromTray();
          result->Success();
        } else if (call.method_name() == "hide") {
          HideToTray();
          result->Success();
        } else if (call.method_name() == "ensureBackend") {
          EnsureBackendRunning();
          result->Success();
        } else if (call.method_name() == "quit") {
          quit_requested_ = true;
          DestroyTrayIcon();
          if (HWND hwnd = GetHandle()) {
            PostMessage(hwnd, WM_CLOSE, 0, 0);
          }
          result->Success();
        } else {
          result->NotImplemented();
        }
      });
}

void FlutterWindow::CreateOrUpdateTrayIcon() {
  if (!run_in_tray_) {
    DestroyTrayIcon();
    return;
  }
  HWND hwnd = GetHandle();
  if (!hwnd) return;

  const int sm_cx = GetSystemMetrics(SM_CXSMICON);
  HICON base_icon = reinterpret_cast<HICON>(LoadImageW(
      GetModuleHandle(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON,
      sm_cx, GetSystemMetrics(SM_CYSMICON), LR_DEFAULTCOLOR | LR_SHARED));

  HICON prev_badge = badge_tray_icon_;
  HICON new_badge = nullptr;
  HICON active_icon = base_icon;
  if (unread_count_ > 0 && base_icon) {
    new_badge = CreateTrayBadgedIcon(base_icon, sm_cx);
    if (new_badge) {
      active_icon = new_badge;
    }
  }

  ZeroMemory(&nid_, sizeof(nid_));
  nid_.cbSize = sizeof(NOTIFYICONDATAW);
  nid_.hWnd = hwnd;
  nid_.uID = kTrayIconId;
  nid_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  nid_.uCallbackMessage = kWmTrayCallback;
  nid_.hIcon = active_icon;
  const std::wstring tip =
      tray_tooltip_.empty() ? L"WaLite" : tray_tooltip_;
  wcsncpy_s(nid_.szTip, _countof(nid_.szTip), tip.c_str(), _TRUNCATE);

  if (tray_added_) {
    if (!Shell_NotifyIconW(NIM_MODIFY, &nid_)) {
      tray_added_ = Shell_NotifyIconW(NIM_ADD, &nid_) != FALSE;
    }
  } else {
    tray_added_ = Shell_NotifyIconW(NIM_ADD, &nid_) != FALSE;
  }

  badge_tray_icon_ = new_badge;
  if (prev_badge) {
    DestroyIcon(prev_badge);
  }
}

void FlutterWindow::UpdateTaskbarOverlay() {
  HWND hwnd = GetHandle();
  if (!hwnd) return;
  if (!taskbar_list_) {
    if (SUCCEEDED(CoCreateInstance(CLSID_TaskbarList, nullptr,
                                   CLSCTX_INPROC_SERVER,
                                   IID_PPV_ARGS(&taskbar_list_)))) {
      if (FAILED(taskbar_list_->HrInit())) {
        taskbar_list_->Release();
        taskbar_list_ = nullptr;
      }
    }
  }
  if (!taskbar_list_) return;

  HICON prev_overlay = taskbar_overlay_icon_;
  if (unread_count_ > 0) {
    taskbar_overlay_icon_ = CreateTaskbarUnreadIcon(unread_count_);
    const wchar_t* desc =
        tray_lang_ == L"en" ? L"Unread messages" : L"Nepřečtené zprávy";
    taskbar_list_->SetOverlayIcon(hwnd, taskbar_overlay_icon_, desc);
  } else {
    taskbar_overlay_icon_ = nullptr;
    taskbar_list_->SetOverlayIcon(hwnd, nullptr, L"");
  }
  if (prev_overlay) {
    DestroyIcon(prev_overlay);
  }
}

void FlutterWindow::DestroyTrayIcon() {
  if (tray_added_) {
    Shell_NotifyIconW(NIM_DELETE, &nid_);
    tray_added_ = false;
  }
  if (badge_tray_icon_) {
    DestroyIcon(badge_tray_icon_);
    badge_tray_icon_ = nullptr;
  }
}

void FlutterWindow::ShowTrayMenu(HWND hwnd) {
  HMENU menu = CreatePopupMenu();
  if (!menu) return;

  const bool is_en = tray_lang_ == L"en";
  AppendMenuW(menu, MF_STRING, kIdTrayShow,
              is_en ? L"Open WaLite" : L"Otevřít WaLite");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kIdTrayQuit,
              is_en ? L"Quit WaLite" : L"Ukončit WaLite");

  POINT pt{};
  GetCursorPos(&pt);
  SetForegroundWindow(hwnd);
  UINT cmd = TrackPopupMenu(
      menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON, pt.x, pt.y, 0,
      hwnd, nullptr);
  DestroyMenu(menu);
  PostMessage(hwnd, WM_NULL, 0, 0);

  if (cmd == kIdTrayShow) {
    RestoreFromTray();
  } else if (cmd == kIdTrayQuit) {
    quit_requested_ = true;
    DestroyTrayIcon();
    PostMessage(hwnd, WM_CLOSE, 0, 0);
  }
}

void FlutterWindow::RestoreFromTray() {
  HWND hwnd = GetHandle();
  if (!hwnd) return;
  if (!IsWindowVisible(hwnd)) {
    ShowWindow(hwnd, SW_SHOW);
  }
  if (IsIconic(hwnd)) {
    ShowWindow(hwnd, SW_RESTORE);
  }
  SetForegroundWindow(hwnd);
  NotifyFocus(true);
}

void FlutterWindow::HideToTray() {
  HWND hwnd = GetHandle();
  if (!hwnd) return;
  ShowWindow(hwnd, SW_HIDE);
  NotifyFocus(false);
}

void FlutterWindow::NotifyFocus(bool focused) {
  if (tray_channel_) {
    tray_channel_->InvokeMethod(
        "onWindowFocus", std::make_unique<flutter::EncodableValue>(focused));
  }
}

void FlutterWindow::OnDestroy() {
  DestroyTrayIcon();
  if (taskbar_overlay_icon_) {
    DestroyIcon(taskbar_overlay_icon_);
    taskbar_overlay_icon_ = nullptr;
  }
  if (taskbar_list_) {
    taskbar_list_->Release();
    taskbar_list_ = nullptr;
  }
  ShutdownSpawnedBackend();
  tray_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  if (taskbar_created_msg_ != 0 && message == taskbar_created_msg_) {
    tray_added_ = false;
    CreateOrUpdateTrayIcon();
    return 0;
  }
  if (taskbar_btn_created_msg_ != 0 && message == taskbar_btn_created_msg_) {
    UpdateTaskbarOverlay();
    return 0;
  }

  switch (message) {
    case kWmTrayCallback:
      switch (LOWORD(lparam)) {
        case WM_LBUTTONUP:
        case WM_LBUTTONDBLCLK:
          RestoreFromTray();
          return 0;
        case WM_RBUTTONUP:
        case WM_CONTEXTMENU:
          ShowTrayMenu(hwnd);
          return 0;
      }
      break;
    case WM_CLOSE:
      if (run_in_tray_ && close_to_tray_ && !quit_requested_) {
        HideToTray();
        return 0;
      }
      DestroyTrayIcon();
      break;
    case WM_ACTIVATE:
      NotifyFocus(LOWORD(wparam) != WA_INACTIVE && IsWindowVisible(hwnd) &&
                  !IsIconic(hwnd));
      break;
    case WM_SIZE:
      if (wparam == SIZE_MINIMIZED) {
        NotifyFocus(false);
      }
      break;
    case WM_FONTCHANGE:
      if (flutter_controller_ && flutter_controller_->engine()) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;
    case WM_DROPFILES: {
      HDROP hdrop = reinterpret_cast<HDROP>(wparam);
      UINT count = DragQueryFileW(hdrop, 0xFFFFFFFF, nullptr, 0);
      flutter::EncodableList paths;
      for (UINT i = 0; i < count; ++i) {
        UINT len = DragQueryFileW(hdrop, i, nullptr, 0);
        if (len > 0) {
          std::wstring buf(len + 1, L'\0');
          if (DragQueryFileW(hdrop, i, buf.data(), len + 1) > 0) {
            buf.resize(len);
            std::string utf8 = WideToUtf8(buf);
            if (!utf8.empty()) {
              paths.emplace_back(utf8);
            }
          }
        }
      }
      DragFinish(hdrop);
      if (!paths.empty() && tray_channel_) {
        tray_channel_->InvokeMethod(
            "onFilesDropped",
            std::make_unique<flutter::EncodableValue>(std::move(paths)));
      }
      return 0;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
