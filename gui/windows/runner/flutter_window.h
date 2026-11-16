#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <shellapi.h>
#include <shobjidl.h>

#include <memory>
#include <string>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project,
                         bool start_in_tray = false);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void EnsureBackendRunning();
  void ShutdownSpawnedBackend();
  void InitTrayChannel();
  void CreateOrUpdateTrayIcon();
  void DestroyTrayIcon();
  void UpdateTaskbarOverlay();
  void ShowTrayMenu(HWND hwnd);
  void RestoreFromTray();
  void HideToTray();
  void NotifyFocus(bool focused);

  // The project to run.
  flutter::DartProject project_;
  bool start_in_tray_ = false;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> tray_channel_;

  HANDLE backend_job_ = nullptr;
  HANDLE backend_process_ = nullptr;
  NOTIFYICONDATAW nid_{};
  bool tray_added_ = false;
  bool run_in_tray_ = true;
  bool close_to_tray_ = true;
  bool quit_requested_ = false;
  int unread_count_ = 0;
  HICON badge_tray_icon_ = nullptr;
  HICON taskbar_overlay_icon_ = nullptr;
  ITaskbarList3* taskbar_list_ = nullptr;
  std::wstring tray_lang_ = L"cs";
  std::wstring tray_tooltip_ = L"WaLite";
  UINT taskbar_created_msg_ = 0;
  UINT taskbar_btn_created_msg_ = 0;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
