# Changelog

All notable changes to **WaLite** (formerly Warust) are recorded here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project
uses [semantic versioning](https://semver.org/). Release notes for every version
are also published on the [Releases page](https://github.com/FoxxoOwO/walite/releases).

## [Unreleased]

## [1.0.1] - 2026-11-17

### Added
- **Customizable Notification Sounds**: Choose between built-in notification sound presets (*Default*, *Chime*, *Pop*, *Ping*, *Bell*, *Silent*) or select a custom audio file from *Settings → Notifications*, complete with a live preview button.
- **Windows Installer**: Added an Inno Setup installer script (`installer/walite.iss`) and now ship `WaLite-v1.0.1-windows-x86_64-setup.exe` alongside the portable ZIP archive.

### Fixed
- **Stale Chat Drafts After Sending**: Fixed a race condition where sending a message within 350 ms of the last keystroke could leave the sent text behind as a chat draft (`_draftTimer` is now cancelled and cleared on submit, and `send_media` clears any active draft as well).

## [1.0.0] - 2026-11-16

First **1.0.0** release under the **WaLite** brand, featuring the Flutter desktop
front end backed by the Rust `whatsapp-rust` engine over a local WebSocket
bridge, deep Windows shell integration, inline video/GIF playback, and full
day-to-day WhatsApp desktop workflows.

### Added
- **Flutter Desktop Front End & WebSocket Bridge (`ws_bridge`)**: Full
  three-column WhatsApp layout (`WaNavRail`, `ChatListPanel`,
  `ConversationView`, `ChatInfoPanel`), command palette (`Ctrl+K`), poll
  creation & voting, scheduled messages, multi-format export (`TXT`/`JSON`/`HTML`),
  voice recording/playback, clipboard image paste (`Ctrl+V`), and CS/EN localization.
- **Single-Process Windows Launcher (`warust_gui.exe`)**: Automatically spawns
  the headless Rust backend (`warust.exe --ui ws`) without a console window,
  binds it to a Windows Job Object (`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`) to
  prevent orphan processes, and supports `--tray` / `--minimized` startup flags.
- **Interactive Windows Toast Notifications & Badges**: Clicking a message or
  incoming-call toast brings WaLite out of the system tray and opens the target
  chat directly; taskbar (`ITaskbarList3`) and tray icons display live unread
  count badges.
- **Profile Photo & "About" Status Editing**: Edit push name, *About / Status*
  text (`maxLength: 139`), and upload/remove your profile picture (auto center-cropped
  and resized to `640×640` JPEG) from *Settings → Account & profile*, synced on
  connect and via live `UserAboutUpdate` events.
- **Drag & Drop Attachments**: Native Win32 `WM_DROPFILES` support lets users
  drop one or multiple files directly into a conversation with preview and
  caption support.
- **Starred Messages**: Star or unstar messages from the bubble context menu,
  view starred indicators on bubbles, inspect chat-level starred messages in
  `ChatInfoPanel`, or browse all starred messages via the navigation rail.
- **Built-in Video & MP4-GIF Playback**: Powered by `media_kit` (`libmpv`),
  with an in-app `VideoLightboxDialog` and silent looping playback (`PlaylistMode.single`)
  for WhatsApp MP4-GIF messages.
- **Search Match Highlighting & Extended Filters**: Added *Polls*, *With reactions*,
  and *Starred* search filters plus query matching inside polls/contacts and
  case-insensitive text match highlighting after jumping to a search hit.
- **Interactive vCard Contact Cards**: Parsed `ContactMessage` and
  `ContactsArrayMessage` payloads render as contact cards with *Message*
  (`Start chat`) and *Copy number* buttons.
- **Custom Chat Wallpapers**: Added per-app dark background color presets, custom
  wallpaper image selection, and an optional doodle-pattern toggle in *Settings → Appearance*.

### Changed
- Rebranded application UI, Windows runner metadata, system tray tooltips/menus,
  autostart registry entry (`WaLite`), Web manifest, and desktop notification
  AUMID to **WaLite** while preserving existing `%APPDATA%\warust` data.
- Updated autostart integration (`autostart.rs`) to target `warust_gui.exe --tray`.

### Fixed
- Enabled `/utf-8` compilation in `gui/windows/runner/CMakeLists.txt` so MSVC on
  non-English Windows locales renders Czech tray menu strings cleanly instead of
  Windows-1250 mojibake.
- Fixed avatar `FileImage` cache invalidation on avatar changes via `avatar_rev`
  tracking and fixed `Command::StarMessage` / `UnstarMessage` canonical JID
  resolution and state persistence.

## [0.3.5] - 2026-11-15

Messages show up again in long chats, quit means quit, the built-in updater can
download its own package, and the interface speaks English.

### Fixed
- A chat with a long history drew nothing at all after 0.3.4: the visible window
  was computed by subtracting a content-space row offset from a screen-space
  cursor, so scrolling down pushed the window past the end of the history (a 1901
  message chat scrolled to the bottom asked for a start roughly twice the length
  of the whole history and drew zero rows). The window is now computed in one
  coordinate system and its start is clamped to the end of the history.
- "Quit Warust" in the notification area only hid the window: the close-to-tray
  rule cancelled the close request, so the process kept running and never logged
  a shutdown. A tray quit now carries a flag that the rule respects.
- "Download and install" always failed with "the response body is larger than
  request limit: 10485760": the package is 144 241 688 bytes, but the body was
  read into memory through an API capped at 10 MiB. The body now streams straight
  to disk, a partial file is deleted after a failure instead of being left to look
  like a valid package, and an empty response is rejected.

### Added
- English interface: Settings → Appearance → Interface language switches between
  Čeština and English and applies immediately (the notification-area icon follows
  after a restart). Czech strings stay the translation keys, so a missing English
  text falls back to Czech instead of disappearing, and a test fails the build when
  a `tr!` string has no English counterpart or a translation is unused.
- A jump-to-newest-messages button appears above the composer while you are
  reading older history, and hides again once the tail is on screen.

### Changed
- The update dialog and update statuses are translated, and the dialog reports a
  failed download where you can see it instead of closing silently.

## [0.3.4] - 2026-11-15

Scrolls smoothly in long chats: the message panel no longer draws, nor copies, the
whole history every frame.

### Changed
- The message list draws only the messages around the viewport. Heights measured
  while drawing are cached per message, so the rows above and below are replaced by
  blank space of the right height — the scrollbar and "stick to bottom" stay honest.
- The panel takes the history out of the app state for the duration of the frame
  and puts it back, instead of cloning it (a clone of 2000 messages with thumbnails
  cost 1.9 ms per frame).
- Jumping to a message from search or the info panel now computes the scroll offset
  from the row model, because the target may not be drawn yet.

### Fixed
- A 2000-message chat spent 4.67 ms per frame just laying out rows nobody could
  see; it now spends 0.08 ms and the cost no longer grows with history length
  (measured by `bench_conversation_frames`).

## [0.3.3] - 2026-11-14

Saves work on this machine, lighter idle rendering, and a log file to attach to a
bug report.

### Fixed
- Long links and document names in the chat info panel pushed the whole row past
  the panel width and squeezed the conversation next to it. Rows now fit the panel
  and the name is truncated instead of stretched.
- The window asked the compositor for a new frame ten times a second even when
  nothing was happening (typing indicator, jump flash, queue drain). Repaints are
  now driven by actual animation state with a one second fallback, so an idle
  window costs almost nothing.
- Revoking an admin message could panic on `client.lid().unwrap()` when the client
  had no linked-device identity; it now tries the original sender, PN, then LID and
  returns a clear error instead of panicking.
- A failed state save was silently dropped at 26 call sites (`let _ =`), which on a
  full disk means a sent message disappears after a restart with no trace. The
  error is logged now, and so is a failed `current_session.txt` write.

### Added
- `%APPDATA%\warust\warust.log`: the app logs to a file next to the session
  database and rotates at 2 MB to `warust.1.log`, so a window that was never
  attached to a console still leaves evidence behind.
- `warust.exe --test-update`: downloads the latest package and unpacks it with the
  system tar into a temporary folder without installing anything, checks that a
  runnable `warust.exe` came out of it, then cleans up. This tests the installer
  path on a machine that has nothing newer to install.

### Changed
- Message list work per frame is smaller: one arrival-window snapshot per frame
  instead of three map lookups per visible bubble, and only the newest 30 messages
  are tracked for fade-in instead of the whole history.
- `docs/QA-PLAN.md` (verification steps, smoke matrix, bug capture protocol) and
  `docs/BUG-PLAN.md` (findings log, fix and verification protocol) are now part of
  the repository.

## [0.3.2] - 2026-11-14

The built-in updater actually installs the update now.

### Fixed
- "Download and install" did nothing: the update script called `tar` from `PATH`,
  which on Windows resolves to the GNU tar shipped with Git. Tar archives only, no
  zip, so extraction failed silently, the app exited and came back as the old
  version. The script now uses `%SystemRoot%\System32\tar.exe` and falls back to
  PowerShell `Expand-Archive`.
- The package is unpacked into a temporary folder first, so a failed extraction
  leaves the previous version in place instead of a half-written install, and why
  it failed is recorded in `%TEMP%\warust-update.log`.
- The update dialog stays open while downloading, shows progress and reports a
  failed download instead of closing as if nothing happened.

## [0.3.1] - 2026-11-14

Updates arrive on their own from this version on, and the interface finally
moves instead of snapping.

### Added — updates
- Automatic update checks against the GitHub releases API: a background check
  every six hours, a manual "Check for updates" button and an update dialog with
  the release notes.
- Self-update: the app downloads the platform package, replaces its own
  executable through a detached script, and restarts.
- Update preferences: background checking and silent auto-install.

### Added — interface
- Animation pass across the main surfaces. Chat list rows cross-fade on hover and
  selection and grow an accent bar; switching chats fades the whole conversation
  in; messages that arrive fade in with a short stagger; the history scrolls
  smoothly; and the jump-to-message highlight now fades in and back out instead of
  blinking off after two seconds.

### Fixed
- Faded accent colours no longer darken towards black while they lose opacity.
- The message history no longer paints over the composer.

## [0.2.0] - 2026-11-14

A large feature jump since 0.1.2: the whole November 2026 development wave.

### Added — messaging
- Edit sent messages in place.
- Multi-select and forwarding, including forwarding to several chats at once.
- Pinned messages: a banner above the conversation, with 24 h, 7 day and 30 day
  durations, mirrored from server pin updates.
- View-once media: photos and videos open exactly once and are deleted locally
  afterwards; a "view once" toggle while sending.
- Per-chat drafts, preserved across chat switches and restarts.
- Media gallery in the chat info panel, split into photos and videos, documents
  and links.
- Jump to a message from the search results, with a short highlight.

### Added — groups
- Group creation, member management, admin promotion and removal.
- Joining groups by invite link, including groups that require approval.
- Admin-only toggles for posting and for editing group information.
- `@mentions` with member autocomplete, highlighted names in bubbles and a
  "Mention" prefix in desktop notifications.
- Contact sharing as vCard and sticker sending (WebP).

### Added — voice and media
- Voice notes with a waveform, recorded and converted to Opus with the bundled
  ffmpeg.
- Pasting images from the clipboard: Ctrl+V turns a screenshot into an
  attachment.
- Attachment previews, thumbnails and a local media cache.

### Added — UI and controls
- Polls: creation, voting, live tallies and quiz mode.
- Archived chats rendered as their own collapsible section.
- Jump to the next unread chat with Alt+Down.
- Keyboard shortcuts: Ctrl+K chat switcher, Ctrl+F message search, Esc closes the
  topmost window.
- Chat info panel, mute durations and disappearing messages.

### Added — maintenance
- Storage tab with media folder statistics and cleanup of files no message
  references any more.

### Changed
- Application state is split into a core file plus one message file per chat,
  which makes startup and writes considerably cheaper.

## [0.1.2] - 2026-11-13

- Desktop notifications, system tray behaviour and background startup.
- Message scheduling, chat export and global message search.

Earlier versions: see the [Releases page](https://github.com/FoxxoOwO/warust/releases).
