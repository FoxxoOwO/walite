//! Desktop notifications and the notification sound.
//!
//! Two independent channels, because they are configured separately and either
//! can be unavailable: an OS toast (via `notify-rust`) and a short two-tone
//! chime synthesized with rodio, so there is no asset to ship.
//!
//! Notifications are suppressed when the window is focused - WhatsApp behaves
//! the same way, and it is the difference between a usable client and one that
//! toasts about messages you are already looking at.

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::LazyLock;
use std::time::{Duration, Instant};

use parking_lot::Mutex;
use tokio::sync::broadcast;
use tracing::{debug, info, warn};

/// Broadcasts `Some(chat_jid)` (or `None`) when the user clicks a desktop toast.
static ACTIVATIONS: LazyLock<broadcast::Sender<Option<String>>> = LazyLock::new(|| {
    let (tx, _) = broadcast::channel(16);
    tx
});

pub fn subscribe_activations() -> broadcast::Receiver<Option<String>> {
    ACTIVATIONS.subscribe()
}

/// Set from the UI thread every frame.
static WINDOW_FOCUSED: AtomicBool = AtomicBool::new(true);

/// Minimum gap between two toasts, so a burst of messages does not stack up.
const MIN_GAP: Duration = Duration::from_secs(2);

/// Only the first toast failure is reported per process lifetime; a platform
/// without a notification daemon should not spam the log on every message.
static FAILURE_REPORTED: AtomicBool = AtomicBool::new(false);

/// Burst suppression. A struct rather than a bare `static Option` so the
/// decision can be tested without sharing process-global state.
struct RateLimiter {
    last: Option<Instant>,
}

impl RateLimiter {
    const fn new() -> Self {
        Self { last: None }
    }

    fn allow(&mut self, now: Instant) -> bool {
        match self.last {
            Some(previous) if now.duration_since(previous) < MIN_GAP => false,
            _ => {
                self.last = Some(now);
                true
            }
        }
    }
}

static LIMITER: Mutex<RateLimiter> = Mutex::new(RateLimiter::new());

pub fn set_window_focused(focused: bool) {
    WINDOW_FOCUSED.store(focused, Ordering::Relaxed);
}

pub fn window_focused() -> bool {
    WINDOW_FOCUSED.load(Ordering::Relaxed)
}

/// Rate limiter. `now` is passed in so the logic can be tested without sleeping.
fn allow_at(now: Instant) -> bool {
    LIMITER.lock().allow(now)
}

/// Show a toast, subject to rate limiting.
///
/// Returns `true` when a notification was actually handed to the OS.
pub fn notify(title: &str, body: &str, sound: bool) -> bool {
    notify_for_chat(None, title, body, sound)
}

/// Show a toast tied to `chat_jid` so clicking it can focus and open that chat.
pub fn notify_for_chat(chat_jid: Option<&str>, title: &str, body: &str, sound: bool) -> bool {
    if window_focused() {
        debug!("skipping notification, window is focused");
        return false;
    }
    if !allow_at(Instant::now()) {
        debug!("skipping notification, rate limited");
        return false;
    }

    if sound {
        play_sound();
    }

    show_toast_for_chat(chat_jid, title, body)
}

fn should_play_unfocused(focused: bool, limiter: &mut RateLimiter, now: Instant) -> bool {
    !focused && limiter.allow(now)
}

/// Play the notification sound when desktop toasts are turned off,
/// honoring both window focus and the burst rate limiter.
pub fn play_sound_if_unfocused() -> bool {
    let allowed = {
        let mut limiter = LIMITER.lock();
        should_play_unfocused(window_focused(), &mut limiter, Instant::now())
    };
    if !allowed {
        return false;
    }
    play_sound();
    true
}

/// Ensure the `Warust` AppUserModelID and icon exist under `HKCU\Software\Classes\AppUserModelId\Warust`
/// so Windows 10/11 Action Center displays the app name and icon on native toasts.
#[cfg(target_os = "windows")]
fn windows_toast_icon() -> Option<String> {
    use std::os::windows::process::CommandExt;
    use std::process::Command;
    use std::sync::OnceLock;

    static CACHED: OnceLock<Option<String>> = OnceLock::new();
    CACHED
        .get_or_init(|| {
            const CREATE_NO_WINDOW: u32 = 0x0800_0000;
            let data_dir = dirs::data_dir()?.join("warust");
            let _ = std::fs::create_dir_all(&data_dir);
            let icon_path = data_dir.join("icon.png");
            let icon_bytes = include_bytes!("../assets/icon.png");
            let needs_write = std::fs::metadata(&icon_path)
                .map(|m| m.len() != icon_bytes.len() as u64)
                .unwrap_or(true);
            if needs_write {
                let _ = std::fs::write(&icon_path, icon_bytes);
            }
            let icon_str = icon_path.to_string_lossy().to_string();
            let reg_key = r"HKCU\Software\Classes\AppUserModelId\WaLite";
            let _ = Command::new("reg")
                .args(["add", reg_key, "/v", "DisplayName", "/t", "REG_SZ", "/d", "WaLite", "/f"])
                .creation_flags(CREATE_NO_WINDOW)
                .status();
            let _ = Command::new("reg")
                .args(["add", reg_key, "/v", "IconUri", "/t", "REG_SZ", "/d", &icon_str, "/f"])
                .creation_flags(CREATE_NO_WINDOW)
                .status();
            Some(icon_str)
        })
        .clone()
}

/// Send a toast without any of the focus/rate-limit logic. Used by the
/// "test notification" button in settings.
pub fn show_toast(title: &str, body: &str) -> bool {
    show_toast_for_chat(None, title, body)
}

const MAX_ACTIVATION_LISTENERS: usize = 16;
static ACTIVE_ACTIVATION_LISTENERS: AtomicUsize = AtomicUsize::new(0);

fn spawn_activation_listener(handle: notify_rust::NotificationHandle, chat_jid: Option<String>) {
    #[cfg(target_os = "windows")]
    {
        if ACTIVE_ACTIVATION_LISTENERS
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |n| {
                (n < MAX_ACTIVATION_LISTENERS).then_some(n + 1)
            })
            .is_err()
        {
            debug!("skipping toast activation listener: {} active listeners", MAX_ACTIVATION_LISTENERS);
            return;
        }
        struct ListenerGuard;
        impl Drop for ListenerGuard {
            fn drop(&mut self) {
                ACTIVE_ACTIVATION_LISTENERS.fetch_sub(1, Ordering::SeqCst);
            }
        }
        std::thread::spawn(move || {
            let _guard = ListenerGuard;
            let _ = handle.wait_for_response(|resp: &notify_rust::NotificationResponse| {
                if matches!(
                    resp,
                    notify_rust::NotificationResponse::Default
                        | notify_rust::NotificationResponse::Action(_)
                ) {
                    let _ = ACTIVATIONS.send(chat_jid);
                }
            });
        });
    }
    #[cfg(not(target_os = "windows"))]
    {
        let _ = (handle, chat_jid);
    }
}

/// Permanently increments the process COM Multi-Threaded Apartment (MTA)
/// usage count on Windows so temporary WASAPI audio threads calling
/// `CoUninitialize` on exit never drop the MTA refcount to zero and unload
/// in-proc WinRT DLLs (`Windows.Data.Xml.Dom.dll`) cached by `windows-core`.
#[cfg(target_os = "windows")]
pub fn ensure_com_mta() {
    use std::sync::Once;
    #[link(name = "ole32")]
    extern "system" {
        fn CoIncrementMTAUsage(pcookie: *mut *mut std::ffi::c_void) -> i32;
    }
    static INIT: Once = Once::new();
    INIT.call_once(|| unsafe {
        let mut cookie = std::ptr::null_mut();
        let _ = CoIncrementMTAUsage(&mut cookie);
    });
}

fn show_toast_for_chat(chat_jid: Option<&str>, title: &str, body: &str) -> bool {
    #[cfg(target_os = "windows")]
    ensure_com_mta();

    let mut notification = notify_rust::Notification::new();
    notification
        .summary(title)
        .body(body)
        .appname("WaLite")
        .timeout(notify_rust::Timeout::Milliseconds(6000));

    #[cfg(target_os = "windows")]
    {
        if let Some(icon_path) = windows_toast_icon() {
            notification.icon(&icon_path);
        }
        notification.app_id("WaLite");
    }

    let chat_owned = chat_jid.map(str::to_string);
    match notification.show() {
        Ok(handle) => {
            info!("notification shown: {}", title);
            spawn_activation_listener(handle, chat_owned);
            true
        }
        Err(first_err) => {
            #[cfg(target_os = "windows")]
            {
                // Fallback to Windows PowerShell's built-in registered AUMID if custom AUMID fails.
                notification.app_id(
                    r"{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe",
                );
                if let Ok(handle) = notification.show() {
                    info!("notification shown via PowerShell AUMID fallback: {}", title);
                    spawn_activation_listener(handle, chat_owned);
                    return true;
                }
            }
            if !FAILURE_REPORTED.swap(true, Ordering::Relaxed) {
                warn!(
                    "desktop notifications unavailable ({}); sound will still play",
                    first_err
                );
            }
            false
        }
    }
}

/// Supported built-in notification sound presets (`custom` uses `custom_sound_path`).
pub const SOUND_PRESETS: &[&str] = &["chime", "pop", "bell", "soft", "triple", "custom"];

#[derive(Clone, Default)]
struct SoundConfig {
    preset: String,
    custom_path: Option<String>,
}

static SOUND_CONFIG: once_cell::sync::Lazy<Mutex<SoundConfig>> = once_cell::sync::Lazy::new(|| {
    Mutex::new(SoundConfig {
        preset: "chime".to_string(),
        custom_path: None,
    })
});

pub fn is_valid_sound_preset(preset: &str) -> bool {
    SOUND_PRESETS.contains(&preset)
}

/// Update the active notification sound preset and optional custom audio file path.
pub fn configure_sound(preset: Option<&str>, custom_path: Option<&str>) {
    let mut cfg = SOUND_CONFIG.lock();
    cfg.preset = preset
        .map(str::trim)
        .filter(|s| is_valid_sound_preset(s))
        .unwrap_or("chime")
        .to_string();
    cfg.custom_path = custom_path
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string);
}

/// Short notification sound using the configured preset or custom file.
/// Does nothing when there is no output device - notifications must not panic
/// on a headless or locked-down machine.
pub fn play_sound() {
    let cfg = SOUND_CONFIG.lock().clone();
    std::thread::spawn(move || {
        if let Err(e) = play_sound_blocking(&cfg.preset, cfg.custom_path.as_deref()) {
            debug!("notification sound skipped: {}", e);
        }
    });
}

/// Immediately play a specific sound preset or custom file (for Settings preview).
pub fn play_sound_preview(preset: Option<&str>, custom_path: Option<&str>) {
    let fallback = SOUND_CONFIG.lock().clone();
    let chosen_preset = preset
        .map(str::trim)
        .filter(|s| is_valid_sound_preset(s))
        .unwrap_or(&fallback.preset)
        .to_string();
    let chosen_path = custom_path
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .or(fallback.custom_path);
    std::thread::spawn(move || {
        if let Err(e) = play_sound_blocking(&chosen_preset, chosen_path.as_deref()) {
            debug!("notification sound preview skipped: {}", e);
        }
    });
}

fn play_sound_blocking(preset: &str, custom_path: Option<&str>) -> Result<(), String> {
    use rodio::Source;

    #[cfg(target_os = "windows")]
    ensure_com_mta();

    let stream = rodio::DeviceSinkBuilder::open_default_sink()
        .map_err(|e| format!("no audio device: {e}"))?;
    let player = rodio::Player::connect_new(stream.mixer());
    player.set_volume(0.6);

    if preset == "custom" {
        if let Some(path) = custom_path {
            if let Ok(file) = std::fs::File::open(path) {
                match rodio::Decoder::try_from(std::io::BufReader::new(file)) {
                    Ok(source) => {
                        player.append(source.take_duration(Duration::from_secs(6)));
                        player.sleep_until_end();
                        std::thread::sleep(Duration::from_millis(50));
                        return Ok(());
                    }
                    Err(e) => {
                        debug!("failed to decode custom sound '{}': {}, falling back to chime", path, e);
                    }
                }
            } else {
                debug!("custom sound file '{}' not found, falling back to chime", path);
            }
        }
    }

    let note = |freq: f32, millis: u64, amp: f32| {
        rodio::buffer::SamplesBuffer::new(
            std::num::NonZero::new(1).unwrap(),
            std::num::NonZero::new(48_000).unwrap(),
            generate_tone_samples(freq, millis, amp),
        )
    };

    match preset {
        "pop" => {
            player.append(note(520.0, 50, 0.24));
            player.append(note(980.0, 70, 0.26));
        }
        "bell" => {
            player.append(note(1046.5, 115, 0.24));
            player.append(note(1568.0, 200, 0.20));
        }
        "soft" => {
            player.append(note(659.25, 85, 0.16));
            player.append(note(784.0, 125, 0.14));
        }
        "triple" => {
            player.append(note(659.25, 75, 0.22));
            player.append(note(880.0, 75, 0.24));
            player.append(note(1318.5, 125, 0.24));
        }
        _ => {
            player.append(note(880.0, 95, 0.25));
            player.append(note(1174.7, 135, 0.25));
        }
    }
    player.sleep_until_end();
    // Let the OS audio backend finish draining its hardware buffer before dropping the sink.
    std::thread::sleep(Duration::from_millis(50));
    Ok(())
}

/// Generates a 48 kHz mono sine tone with raised-cosine attack and release
/// envelopes so consecutive notes and stream ends never click or pop.
fn generate_tone_samples(freq: f32, millis: u64, amp: f32) -> Vec<f32> {
    const SAMPLE_RATE: usize = 48_000;
    let total = (SAMPLE_RATE * millis as usize) / 1000;
    if total == 0 {
        return Vec::new();
    }
    let attack = (SAMPLE_RATE * 8 / 1000).min(total / 3).max(1);
    let release = (SAMPLE_RATE * 28 / 1000).min(total / 2).max(1);
    let release_start = total.saturating_sub(release);

    (0..total)
        .map(|i| {
            let t = i as f32 / SAMPLE_RATE as f32;
            let wave = (2.0 * std::f32::consts::PI * freq * t).sin();
            let env = if i < attack {
                0.5 * (1.0 - (std::f32::consts::PI * i as f32 / attack as f32).cos())
            } else if i >= release_start {
                let pos = (i - release_start + 1) as f32 / release as f32;
                0.5 * (1.0 + (std::f32::consts::PI * pos).cos())
            } else {
                1.0
            };
            wave * amp * env
        })
        .collect()
}

/// Message body used in toasts: keep it short and on one line.
pub fn preview(text: &str) -> String {
    let collapsed: String = text
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    if collapsed.chars().count() > 120 {
        let cut: String = collapsed.chars().take(117).collect();
        format!("{cut}...")
    } else {
        collapsed
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rate_limiter_allows_first_then_blocks_burst() {
        let mut limiter = RateLimiter::new();
        let now = Instant::now();

        assert!(limiter.allow(now));
        assert!(!limiter.allow(now + Duration::from_millis(500)));
        assert!(!limiter.allow(now + Duration::from_millis(1999)));
        assert!(limiter.allow(now + Duration::from_secs(5)));
    }

    #[test]
    fn focused_window_suppresses_notifications() {
        set_window_focused(true);
        assert!(!notify("Chat", "hello", false));
        // A suppressed call must not consume the rate limiter, otherwise the
        // first real notification after losing focus would be dropped.
        assert!(LIMITER.lock().last.is_none());
    }

    #[test]
    fn preview_collapses_whitespace_and_truncates() {
        assert_eq!(preview("  hello \n world  "), "hello world");

        let long = "a".repeat(400);
        let short = preview(&long);
        assert_eq!(short.chars().count(), 120);
        assert!(short.ends_with("..."));
    }

    #[test]
    fn preview_never_splits_a_multibyte_char() {
        let czech = "ěščřžýáíé".repeat(30);
        let out = preview(&czech);
        assert_eq!(out.chars().count(), 120);
        assert!(out.ends_with("..."));
    }

    #[test]
    fn configure_sound_validates_presets_and_custom_path() {
        configure_sound(Some("bell"), Some("C:\\sounds\\ding.wav"));
        {
            let cfg = SOUND_CONFIG.lock();
            assert_eq!(cfg.preset, "bell");
            assert_eq!(cfg.custom_path.as_deref(), Some("C:\\sounds\\ding.wav"));
        }
        configure_sound(Some("invalid_preset"), Some("   "));
        {
            let cfg = SOUND_CONFIG.lock();
            assert_eq!(cfg.preset, "chime");
            assert!(cfg.custom_path.is_none());
        }
    }

    #[test]
    fn tone_samples_start_and_end_at_zero_without_clicks() {
        let samples = generate_tone_samples(880.0, 95, 0.25);
        assert_eq!(samples.len(), 4560);
        assert!(samples[0].abs() < 1e-6);
        assert!(samples.last().unwrap().abs() < 1e-6);
        let max_step = samples
            .windows(2)
            .map(|w| (w[1] - w[0]).abs())
            .fold(0.0_f32, f32::max);
        assert!(max_step < 0.04, "unexpected waveform jump: {max_step}");
    }

    #[cfg(target_os = "windows")]
    #[test]
    fn ensure_com_mta_is_idempotent() {
        ensure_com_mta();
        ensure_com_mta();
    }

    #[test]
    fn play_sound_if_unfocused_respects_focus_and_rate_limiter() {
        set_window_focused(true);
        assert!(!play_sound_if_unfocused());

        let mut limiter = RateLimiter::new();
        let t0 = Instant::now();
        assert!(!should_play_unfocused(true, &mut limiter, t0));
        assert!(
            limiter.last.is_none(),
            "focused call must not consume rate limiter"
        );

        assert!(should_play_unfocused(false, &mut limiter, t0));
        assert!(!should_play_unfocused(
            false,
            &mut limiter,
            t0 + Duration::from_millis(500)
        ));
        assert!(should_play_unfocused(
            false,
            &mut limiter,
            t0 + Duration::from_secs(3)
        ));
    }
}
