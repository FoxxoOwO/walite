# WaLite (formerly Warust)

[![Rust](https://img.shields.io/badge/rust-1.80%2B-orange.svg?style=flat-square&logo=rust)](https://www.rust-lang.org/)
[![Flutter](https://img.shields.io/badge/flutter-3.x-02569B.svg?style=flat-square&logo=flutter)](https://flutter.dev/)
[![License](https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-green.svg?style=flat-square)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20Linux%20%7C%20macOS-lightgrey.svg?style=flat-square)]()

**WaLite** is a fast, lightweight desktop client for WhatsApp powered by a **Flutter** front end and an asynchronous **Rust** backend (`whatsapp-rust`) communicating over a local WebSocket bridge.

Built as a lean alternative to resource-heavy Electron clients, WaLite pairs responsive desktop ergonomics with native Windows integration, direct multi-device WhatsApp protocol support, and low runtime memory overhead.

> [!NOTE]
> **Independent Project:** WaLite is an independent open-source client and is not affiliated with, authorized, maintained, or endorsed by WhatsApp or Meta. Use at your own discretion.

---

## Features

### Messaging & Conversations
* **WhatsApp Desktop Layout**: Three-column shell with navigation rail, searchable chat list, threaded conversation view, and collapsible chat info drawer.
* **Chat Management**: Pin/unpin chats, mute notifications, archive conversations, mark read/unread, jump to next unread (`Alt+Down`), and edit contact names.
* **Contact & Identity Resolution**: Automatically merges Phone Number (`@s.whatsapp.net`) and Linked Identity (`@lid`) threads into unified chats.
* **Message Editing & Revocation**: Edit sent messages inline (`edited`) or delete for yourself / everyone.
* **Replies, Forwarding & Multi-Select**: Swipe/menu reply quotes, multi-message selection, and forwarding across chats (re-uploading cached media or falling back to text).
* **Interactive vCards**: Received contact cards (`ContactMessage` / `ContactsArrayMessage`) render with avatar, phone number, **Start chat** button, and one-click number copy.
* **Polls & Scheduled Messages**: Create single/multi-choice polls with live tallies, and queue scheduled messages to send automatically at a chosen date and time.
* **Starred Messages**: Star/unstar messages from the bubble menu, inspect per-chat starred messages in the info drawer, or browse all starred messages from the navigation rail.
* **QR & Phone Pairing**: Sign in via QR code or 8-character phone-number pairing code.

### Rich Media, Drag & Drop & Video/GIF Playback
* **Drag & Drop Attachments**: Drag one or more files directly into the chat window from File Explorer to preview and add captions before sending, or paste images from the clipboard (`Ctrl+V`).
* **Built-in Video & GIF Player**: Play MP4 videos inside the in-app `VideoLightboxDialog` powered by `media_kit` (`libmpv`), with automatic silent looping for WhatsApp MP4-GIF messages.
* **Images, Stickers & Documents**: Image lightbox viewer, WebP sticker picker, file previews, and view-once media handling.
* **Voice Notes & Audio**: In-app audio recording and waveform playback with Opus transcoding.

### Search, Export & Customization
* **Global & In-Chat Search (`Ctrl+F`)**: Filter across all chats or the current chat by sender, date range, and content type (*All*, *Text*, *Media*, *Links*, *Polls*, *Reacted*, *Starred*) — jumping to a hit highlights matching text directly in the chat.
* **Quick Chat Switcher (`Ctrl+K`)**: Keyboard command palette to jump between conversations.
* **Chat Export**: Export any conversation to **TXT**, **HTML**, or **JSON**.
* **Custom Chat Wallpapers & Themes**: Choose between dark presets (*WhatsApp Dark*, *OLED Black*, *Midnight Blue*), set a custom chat background color or wallpaper image, and toggle subtle WhatsApp doodle patterns.
* **Profile & Localization**: Edit your display name, **About / Status** text, and profile photo (auto-cropped and resized to `640×640` JPEG) directly in Settings; switch between **English** and **Czech**.

### Windows Integration & VoIP
* **Interactive Windows Toast Notifications**: Clicking an incoming message or call toast brings WaLite up from the system tray and opens the corresponding chat; respects window focus, muted chats, and preview privacy settings.
* **System Tray & Taskbar Badges**: Runs cleanly in the Windows notification area (`--tray` / `--minimized`), displays an unread badge overlay on the taskbar icon (`ITaskbarList3`) and tray icon, and supports Windows startup integration.
* **Single-Launcher Auto-Backend**: `warust_gui.exe` automatically starts `warust.exe --ui ws` hidden in the background (bound via Windows Job Object so no orphan process remains on exit).
* **Voice & Video Calls (VoIP)**: Incoming call overlays and active call controls powered by `whatsapp-rust`'s MLOW/WebRTC signaling.
* **Built-in Updater**: Checks GitHub Releases for new versions and supports in-app updates.

---

## Architecture

```
+--------------------------------------------------------+
|              Flutter Desktop GUI (WaLite)              |
|        warust_gui.exe · media_kit · Win32 Tray         |
+---------------------------+----------------------------+
                            |
             Local WebSocket Bridge (127.0.0.1:8787)
                            |
+---------------------------v----------------------------+
|                 Rust Backend (warust)                  |
|   Tokio Runtime · SQLite Session Store · VoIP · Sync   |
+---------------------------+----------------------------+
                            |
               WhatsApp Multi-Device Protocol
                            |
+---------------------------v----------------------------+
|                  WhatsApp Web Servers                  |
+--------------------------------------------------------+
```

Existing session credentials, chat history, and cached media stored in `%APPDATA%\warust` remain fully compatible across updates.

---

## Getting Started

### Prebuilt Release (Windows)
1. Download `WaLite-v1.0.0-windows-x86_64.zip` from the [Releases page](https://github.com/FoxxoOwO/warust/releases).
2. Extract all files into a folder (keep `warust_gui.exe`, `warust.exe`, `data/`, and the bundled `.dll` files together).
3. Run `warust_gui.exe` — it launches the Rust backend automatically on `127.0.0.1:8787`.

### Building from Source

#### Prerequisites
* [Rust 1.80+](https://rustup.rs/) (stable toolchain)
* [Flutter 3.x](https://flutter.dev/) with Windows desktop toolchain (Visual Studio C++ workload / CMake)
* Optional: `ffmpeg` / `ffprobe` on `PATH` (or alongside `warust.exe`) for audio transcoding

#### Build Commands
1. **Clone and test the Rust backend**:
   ```bash
   git clone https://github.com/FoxxoOwO/warust.git
   cd warust
   cargo test
   cargo build --release
   ```

2. **Test and build the Flutter GUI**:
   ```bash
   cd gui
   flutter analyze
   flutter test
   flutter build windows
   ```

3. **Bundle backend alongside GUI (Windows Release)**:
   ```powershell
   Copy-Item target\release\warust.exe gui\build\windows\x64\runner\Release\warust.exe -Force
   ```
   Launch `gui\build\windows\x64\runner\Release\warust_gui.exe`.

---

## License

This project is licensed under either the [MIT License](LICENSE-MIT) or the [Apache License 2.0](LICENSE-APACHE) at your option.
