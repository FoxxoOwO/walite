//! WebSocket bridge for non-Rust front ends (the Flutter client in `gui/`).
//!
//! One JSON snapshot stream out (plus targeted query replies), and commands in.
//! The bridge owns the same backend the egui window would use, so nothing about
//! WhatsApp handling is duplicated on the UI side.

use std::collections::HashMap;
use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, LazyLock};
use std::time::{Duration, Instant, SystemTime};

use anyhow::{Context, Result};
use futures::{SinkExt, StreamExt};
use parking_lot::{Mutex, RwLock};
use serde::Serialize;
use serde_json::{json, Value};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc::UnboundedSender;
use tokio::sync::Notify;
use tokio_tungstenite::tungstenite::Message as WsMessage;
use whatsapp_rust::wacore_binary::Jid;

use crate::backend::BackendHandle;
use crate::commands::Command;
use crate::search::{
    search_messages, MessageSearchFilter, SearchContentType, SearchDateRange, SearchScope,
    SearchSender,
};
use crate::state::{CallStatus, ConnectionStatus, ScheduledStatus, SharedState};

type Clients = Arc<Mutex<HashMap<usize, UnboundedSender<String>>>>;

/// How many messages of the selected chat travel in one snapshot. Enough for a
/// scrollback that feels real, small enough that the 200 ms diff stays cheap.
const MESSAGE_WINDOW: usize = 200;

/// Raised by `more` or `jump_to_message` as the user scrolls back; capped
/// because every snapshot re-serialises the whole window.
static MESSAGE_LIMIT: AtomicUsize = AtomicUsize::new(MESSAGE_WINDOW);
const MAX_MESSAGE_LIMIT: usize = 5000;

/// Cached avatar disk lookups keyed by `avatars::revision()` so 200 ms
/// snapshots don't stat hundreds of files repeatedly.
static AVATAR_CACHE: LazyLock<Mutex<(u64, HashMap<String, Option<String>>)>> =
    LazyLock::new(|| Mutex::new((0, HashMap::new())));

/// Cached sticker list keyed by `media::MEDIA_REV`.
/// Uses `Option<u64>` so an empty sticker folder is also cached instead of
/// rescanning `media_dir` on every snapshot.
static STICKER_CACHE: Mutex<(Option<u64>, Vec<String>)> = Mutex::new((None, Vec::new()));

/// Short-lived cache for `Path::is_file()` checks in 200 ms snapshots.
const MEDIA_EXISTS_TTL: Duration = Duration::from_secs(5);
static MEDIA_EXISTS_CACHE: LazyLock<Mutex<(u64, Instant, HashMap<String, bool>)>> =
    LazyLock::new(|| Mutex::new((0, Instant::now(), HashMap::new())));

/// Cached base64 encodings of message thumbnails keyed by message ID.
static THUMB_B64_CACHE: LazyLock<Mutex<HashMap<String, String>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

fn sync_connection_status(backend: &BackendHandle) {
    let status = backend.connection_status();
    if backend.state.read().connection == status {
        return;
    }
    let mut s = backend.state.write();
    if s.connection != status {
        s.connection = status;
    }
}

pub async fn run(port: u16) -> Result<()> {
    // Headless bridge starts unfocused until a connected GUI reports focus.
    crate::notifications::set_window_focused(false);
    let loaded = crate::storage::load_state().await.unwrap_or_default();
    crate::i18n::set_language(loaded.preferences.language);
    crate::notifications::configure_sound(
        loaded.preferences.notification_sound.as_deref(),
        loaded.preferences.custom_sound_path.as_deref(),
    );
    let state: SharedState = Arc::new(RwLock::new(loaded));
    let backend = Arc::new(crate::backend::spawn_backend(state.clone()).await?);
    crate::updater::spawn_periodic_check(state.clone());

    let listener = TcpListener::bind(("127.0.0.1", port))
        .await
        .with_context(|| format!("bridge cannot bind 127.0.0.1:{port}"))?;
    let bound = listener.local_addr()?.port();
    // The Flutter app reads this line; keep the prefix stable.
    println!("WARUST_BRIDGE ws://127.0.0.1:{bound}");
    tracing::info!("WS bridge listening on 127.0.0.1:{bound}");

    let clients: Clients = Arc::new(Mutex::new(HashMap::new()));
    let snap_notify = Arc::new(Notify::new());

    {
        let clients = clients.clone();
        let state = state.clone();
        let backend = backend.clone();
        let snap_notify = snap_notify.clone();
        tokio::spawn(async move {
            let mut last = String::new();
            loop {
                tokio::select! {
                    _ = tokio::time::sleep(Duration::from_millis(200)) => {}
                    _ = snap_notify.notified() => {
                        // Brief coalesce window so a burst of commands emits one snapshot.
                        tokio::time::sleep(Duration::from_millis(16)).await;
                    }
                }
                if clients.lock().is_empty() {
                    continue;
                }
                sync_connection_status(&backend);
                let snap = snapshot(&state);
                if snap == last {
                    continue;
                }
                last = snap;
                let mut map = clients.lock();
                map.retain(|_, tx| tx.send(last.clone()).is_ok());
            }
        });
    }

    {
        let clients = clients.clone();
        let backend = backend.clone();
        let snap_notify = snap_notify.clone();
        let mut rx = crate::notifications::subscribe_activations();
        tokio::spawn(async move {
            while let Ok(chat_opt) = rx.recv().await {
                if let Some(ref raw_chat) = chat_opt {
                    if let Ok(jid) = raw_chat.parse::<Jid>() {
                        {
                            let mut s = backend.state.write();
                            let canon = s.canonical_jid(&jid);
                            if s.selected_chat.as_ref() != Some(&canon) {
                                MESSAGE_LIMIT.store(MESSAGE_WINDOW, Ordering::Relaxed);
                            }
                            s.selected_chat = Some(canon.clone());
                            if let Some(c) = s.chats.get_mut(&canon) {
                                c.unread_count = 0;
                            }
                        }
                        let _ = backend.send_command(Command::select_chat(Some(jid)));
                        snap_notify.notify_one();
                    }
                }
                let payload = json!({
                    "type": "activate_window",
                    "chat": chat_opt,
                })
                .to_string();
                let mut map = clients.lock();
                map.retain(|_, tx| tx.send(payload.clone()).is_ok());
            }
        });
    }

    let next_id = AtomicUsize::new(0);
    loop {
        let (stream, _) = listener.accept().await?;
        let id = next_id.fetch_add(1, Ordering::Relaxed);
        tokio::spawn(handle_conn(
            stream,
            id,
            clients.clone(),
            backend.clone(),
            snap_notify.clone(),
        ));
    }
}

async fn handle_conn(
    stream: TcpStream,
    id: usize,
    clients: Clients,
    backend: Arc<BackendHandle>,
    snap_notify: Arc<Notify>,
) {
    let ws = match tokio_tungstenite::accept_async(stream).await {
        Ok(ws) => ws,
        Err(err) => {
            tracing::warn!("bridge handshake failed: {err}");
            return;
        }
    };
    let (mut sink, mut inbox) = ws.split();
    let (out_tx, mut out_rx) = tokio::sync::mpsc::unbounded_channel::<String>();
    clients.lock().insert(id, out_tx.clone());
    sync_connection_status(&backend);
    // A client joining between changes would otherwise wait for the next one,
    // which may never come; hand it the current state straight away.
    let _ = out_tx.send(snapshot(&backend.state));

    loop {
        tokio::select! {
            out = out_rx.recv() => match out {
                Some(text) => {
                    if sink.send(WsMessage::Text(text.into())).await.is_err() {
                        break;
                    }
                }
                None => break,
            },
            incoming = inbox.next() => match incoming {
                Some(Ok(WsMessage::Text(text))) => {
                    handle_command(text.as_str(), &backend, &out_tx, &snap_notify);
                }
                Some(Ok(WsMessage::Close(_))) | None => break,
                Some(Ok(_)) => {}
                Some(Err(err)) => {
                    tracing::debug!("bridge socket error: {err}");
                    break;
                }
            },
        }
    }

    {
        let mut map = clients.lock();
        map.remove(&id);
        if map.is_empty() {
            crate::notifications::set_window_focused(false);
        }
    }
    tracing::info!("bridge client {id} left");
}

fn handle_command(
    raw: &str,
    backend: &Arc<BackendHandle>,
    reply_tx: &UnboundedSender<String>,
    snap_notify: &Arc<Notify>,
) {
    let Ok(value) = serde_json::from_str::<Value>(raw) else {
        return;
    };
    let mut notify_snap = true;
    match value["type"].as_str() {
        Some("window_focus") => {
            let focused = value["focused"].as_bool().unwrap_or(false);
            crate::notifications::set_window_focused(focused);
        }
        Some("connect") => {
            let _ = backend.send_command(Command::Connect);
        }
        Some("disconnect") => {
            let _ = backend.send_command(Command::Disconnect);
        }
        Some("dismiss_syncing") => {
            let _ = backend.send_command(Command::DismissSyncing);
        }
        Some("request_pair_code") => {
            if let Some(phone) = value["phone"].as_str().map(str::trim).filter(|s| !s.is_empty()) {
                backend.state.write().pair_phone_number = phone.to_string();
                let _ = backend.send_command(Command::RequestPairCode {
                    phone_number: phone.to_string(),
                });
            }
        }
        Some("cancel_pair_code") => {
            let _ = backend.send_command(Command::CancelPairCode);
        }
        Some("select") => {
            let jid = value["chat"].as_str().and_then(|s| s.parse::<Jid>().ok());
            MESSAGE_LIMIT.store(MESSAGE_WINDOW, Ordering::Relaxed);
            if let Some(ref j) = jid {
                let mut s = backend.state.write();
                let canon = s.canonical_jid(j);
                s.selected_chat = Some(canon.clone());
                if let Some(chat) = s.chats.get_mut(&canon) {
                    chat.unread_count = 0;
                }
            } else {
                backend.state.write().selected_chat = None;
            }
            let _ = backend.send_command(Command::select_chat(jid));
        }
        Some("start_chat") => {
            if let Some(raw_phone) = value["phone"].as_str() {
                if let Some(target_jid) = crate::util::parse_jid(raw_phone) {
                    MESSAGE_LIMIT.store(MESSAGE_WINDOW, Ordering::Relaxed);
                    let selected_jid = {
                        let mut s = backend.state.write();
                        let canon = s.canonical_jid(&target_jid);
                        let name = crate::util::format_jid(&canon);
                        let _ = s.get_or_create_chat(canon.clone(), name, false);
                        s.selected_chat = Some(canon.clone());
                        s.dirty = true;
                        canon
                    };
                    let _ = backend.send_command(Command::SelectChat {
                        chat_jid: Some(selected_jid),
                    });
                }
            }
        }
        Some("refresh_chats") => {
            let _ = backend.send_command(Command::RefreshChats);
        }
        Some("save_draft") => {
            if let Some(jid) = jid_field(&value, "chat") {
                let text = value["text"].as_str().unwrap_or_default().to_string();
                let mut s = backend.state.write();
                let canon = s.canonical_jid(&jid);
                if text.trim().is_empty() {
                    if s.drafts.remove(&canon).is_some() {
                        s.dirty = true;
                    }
                } else {
                    s.drafts.insert(canon, text);
                    s.dirty = true;
                }
            }
        }
        Some("typing") => {
            if let Some(jid) = jid_field(&value, "chat") {
                let composing = value["composing"].as_bool().unwrap_or(true);
                let _ = backend.send_command(Command::SendChatState {
                    chat_jid: jid,
                    composing,
                });
            }
        }
        Some("send") => {
            if let (Some(chat), Some(text)) = (value["chat"].as_str(), value["text"].as_str()) {
                if let Ok(jid) = chat.parse::<Jid>() {
                    let mentioned_jid = strings_field(&value, "mentions");
                    {
                        let mut s = backend.state.write();
                        let canon = s.canonical_jid(&jid);
                        if s.drafts.remove(&canon).is_some() {
                            s.dirty = true;
                        }
                    }
                    let _ = backend.send_command(Command::SendText {
                        to: jid,
                        text: text.to_string(),
                        reply_to: value["reply"].as_str().map(str::to_string),
                        mentioned_jid,
                    });
                }
            }
        }
        Some("send_contact") => {
            if let (Some(chat), Some(contact)) =
                (jid_field(&value, "chat"), jid_field(&value, "contact"))
            {
                let _ = backend.send_command(Command::SendContact {
                    chat_jid: chat,
                    contact_jid: contact,
                    reply_to: value["reply"].as_str().map(str::to_string),
                });
            }
        }
        Some("edit") => {
            if let (Some(jid), Some(id), Some(text)) =
                (jid_field(&value, "chat"), id_field(&value), value["text"].as_str())
            {
                let _ = backend.send_command(Command::EditText {
                    to: jid,
                    message_id: id,
                    text: text.to_string(),
                });
            }
        }
        Some("react") => {
            if let (Some(jid), Some(id), Some(emoji)) =
                (jid_field(&value, "chat"), id_field(&value), value["emoji"].as_str())
            {
                let _ = backend.send_command(Command::SendReaction {
                    chat_jid: jid,
                    message_id: id,
                    emoji: emoji.to_string(),
                });
            }
        }
        Some("delete") => {
            if let (Some(jid), Some(id)) = (jid_field(&value, "chat"), id_field(&value)) {
                let _ = backend.send_command(Command::DeleteMessageForMe {
                    chat_jid: jid,
                    message_id: id,
                });
            }
        }
        Some("download") => {
            if let (Some(jid), Some(id)) = (jid_field(&value, "chat"), id_field(&value)) {
                let _ = backend.send_command(Command::DownloadMedia {
                    chat_jid: jid,
                    message_id: id,
                });
            }
        }
        Some("send_media") => {
            // The path is local to this machine: the picker runs next to the bridge.
            if let (Some(chat), Some(path)) =
                (jid_field(&value, "chat"), value["path"].as_str())
            {
                {
                    let mut s = backend.state.write();
                    let canon = s.canonical_jid(&chat);
                    if s.drafts.remove(&canon).is_some() {
                        s.dirty = true;
                    }
                }
                let _ = backend.send_command(Command::SendMedia {
                    chat_jid: chat,
                    file_path: std::path::PathBuf::from(path),
                    caption: value["caption"].as_str().map(str::to_string),
                    reply_to: value["reply_to"].as_str().map(str::to_string),
                    view_once: value["view_once"].as_bool().unwrap_or(false),
                });
            }
        }
        Some("paste_clipboard_image") => {
            notify_snap = false;
            let reply_tx = reply_tx.clone();
            tokio::spawn(async move {
                let res =
                    tokio::task::spawn_blocking(crate::clipboard::save_clipboard_image).await;
                let reply = match res {
                    Ok(Ok(Some(path))) => json!({
                        "type": "clipboard_image",
                        "path": path.to_string_lossy(),
                    }),
                    Ok(Ok(None)) => json!({
                        "type": "clipboard_image",
                        "path": null,
                    }),
                    Ok(Err(err)) => json!({
                        "type": "clipboard_image",
                        "path": null,
                        "error": err,
                    }),
                    Err(err) => json!({
                        "type": "clipboard_image",
                        "path": null,
                        "error": err.to_string(),
                    }),
                };
                let _ = reply_tx.send(reply.to_string());
            });
        }
        // Voice notes: the bridge runs on the same machine as the GUI, so the
        // desktop recorder captures from the same microphone and encodes OGG/Opus.
        Some("record_start") => {
            notify_snap = false;
            tokio::task::spawn_blocking(|| {
                if let Err(err) = crate::recorder::start() {
                    tracing::warn!("bridge could not start recording: {err}");
                }
            });
        }
        Some("record_stop") => {
            notify_snap = false;
            if let Some(chat) = jid_field(&value, "chat") {
                let backend = backend.clone();
                tokio::spawn(async move {
                    match tokio::task::spawn_blocking(crate::recorder::finish).await {
                        Ok(Ok(rec)) => {
                            let _ = backend.send_command(Command::SendVoiceNote {
                                chat_jid: chat,
                                file_path: rec.path,
                                duration_seconds: (rec.duration_ms / 1000).max(1) as u32,
                                waveform: rec.waveform,
                            });
                        }
                        Ok(Err(err)) => tracing::warn!("bridge could not finish recording: {err}"),
                        Err(err) => tracing::warn!("bridge record task panicked: {err}"),
                    }
                });
            }
        }
        Some("record_cancel") => {
            notify_snap = false;
            tokio::task::spawn_blocking(crate::recorder::cancel);
        }
        Some("audio_toggle") => {
            notify_snap = false;
            if let (Some(id), Some(path)) = (
                id_field(&value),
                value["path"].as_str().map(str::to_string),
            ) {
                let snap_notify = snap_notify.clone();
                tokio::spawn(async move {
                    let res = tokio::task::spawn_blocking(move || {
                        crate::audio::toggle(&id, Path::new(&path))
                    })
                    .await;
                    if let Ok(Err(err)) = res {
                        tracing::warn!("bridge audio toggle failed: {err}");
                    }
                    snap_notify.notify_one();
                });
            }
        }
        Some("audio_pause") => {
            notify_snap = false;
            let snap_notify = snap_notify.clone();
            tokio::spawn(async move {
                let _ = tokio::task::spawn_blocking(crate::audio::pause).await;
                snap_notify.notify_one();
            });
        }
        Some("audio_resume") => {
            notify_snap = false;
            let snap_notify = snap_notify.clone();
            tokio::spawn(async move {
                let _ = tokio::task::spawn_blocking(crate::audio::resume).await;
                snap_notify.notify_one();
            });
        }
        Some("audio_seek") => {
            notify_snap = false;
            if let Some(ms) = value["ms"].as_u64() {
                let snap_notify = snap_notify.clone();
                tokio::spawn(async move {
                    let _ = tokio::task::spawn_blocking(move || {
                        crate::audio::seek(Duration::from_millis(ms))
                    })
                    .await;
                    snap_notify.notify_one();
                });
            }
        }
        Some("open_file") => {
            notify_snap = false;
            if let Some(path) = value["path"].as_str().map(str::to_string) {
                tokio::task::spawn_blocking(move || crate::media::open_file(Path::new(&path)));
            }
        }
        Some("show_in_folder") => {
            notify_snap = false;
            if let Some(path) = value["path"].as_str().map(str::to_string) {
                tokio::task::spawn_blocking(move || crate::media::show_in_folder(Path::new(&path)));
            }
        }
        Some("open_media_dir") => {
            notify_snap = false;
            tokio::task::spawn_blocking(|| crate::media::open_file(&crate::media::media_dir()));
        }
        Some("more") => {
            let step = value["count"].as_u64().unwrap_or(MESSAGE_WINDOW as u64) as usize;
            let grown = (MESSAGE_LIMIT.load(Ordering::Relaxed) + step).min(MAX_MESSAGE_LIMIT);
            MESSAGE_LIMIT.store(grown, Ordering::Relaxed);
            let _ = backend.send_command(Command::RequestHistorySync {
                chat_jid: jid_field(&value, "chat"),
                count: step.min(u32::MAX as usize) as u32,
            });
        }
        Some("jump_to_message") => {
            if let (Some(jid), Some(id)) = (jid_field(&value, "chat"), id_field(&value)) {
                let needed = {
                    let mut s = backend.state.write();
                    let canon = s.canonical_jid(&jid);
                    s.selected_chat = Some(canon.clone());
                    if let Some(chat) = s.chats.get_mut(&canon) {
                        chat.unread_count = 0;
                    }
                    s.get_chat_messages(&canon).and_then(|msgs| {
                        msgs.iter()
                            .position(|m| m.id == id)
                            .map(|idx| msgs.len() - idx)
                    })
                };
                if let Some(window_needed) = needed {
                    let cur = MESSAGE_LIMIT.load(Ordering::Relaxed);
                    if window_needed > cur {
                        MESSAGE_LIMIT.store(window_needed.min(20_000), Ordering::Relaxed);
                    }
                }
                let _ = backend.send_command(Command::select_chat(Some(jid)));
            }
        }
        Some("read") => {
            if let Some(jid) = jid_field(&value, "chat") {
                let _ = backend.send_command(Command::MarkChatAsRead { chat_jid: jid });
            }
        }
        Some("forward") => {
            if let (Some(to), Some(from)) = (jid_field(&value, "to"), jid_field(&value, "from")) {
                let ids = value["ids"]
                    .as_array()
                    .map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_string)).collect::<Vec<_>>())
                    .unwrap_or_default();
                if !ids.is_empty() {
                    let _ = backend.send_command(Command::ForwardMessages {
                        to,
                        from_chat: from,
                        message_ids: ids,
                    });
                }
            }
        }
        Some("revoke") => {
            if let (Some(jid), Some(id)) = (jid_field(&value, "chat"), id_field(&value)) {
                let _ = backend.send_command(Command::RevokeMessage {
                    chat_jid: jid,
                    message_id: id,
                    is_admin: false,
                    original_sender: None,
                });
            }
        }
        Some("pin_message") => {
            if let (Some(jid), Some(id)) = (jid_field(&value, "chat"), id_field(&value)) {
                let duration = value["duration"].as_u64().map(|v| v as u32);
                let _ = backend.send_command(Command::PinMessage {
                    chat_jid: jid,
                    message_id: id,
                    duration_secs: duration,
                });
            }
        }
        Some("star") => {
            if let (Some(jid), Some(id)) = (jid_field(&value, "chat"), id_field(&value)) {
                let starred = value["starred"].as_bool().unwrap_or(true);
                backend.state.write().set_message_starred(&jid, &id, starred);
                let cmd = if starred {
                    Command::StarMessage {
                        chat_jid: jid,
                        message_id: id,
                    }
                } else {
                    Command::UnstarMessage {
                        chat_jid: jid,
                        message_id: id,
                    }
                };
                let _ = backend.send_command(cmd);
            }
        }
        Some("get_starred") => {
            let target = jid_field(&value, "chat");
            let reply = {
                let s = backend.state.read();
                let mut rows: Vec<(chrono::DateTime<chrono::Utc>, Value)> = Vec::new();
                let chat_keys: Vec<Jid> = match target {
                    Some(ref j) => vec![s.canonical_jid(j)],
                    None => s.messages.keys().cloned().collect(),
                };
                for cj in chat_keys {
                    let chat_name = s
                        .chats
                        .get(&cj)
                        .map(|c| c.name.clone())
                        .unwrap_or_else(|| crate::util::format_jid(&cj));
                    if let Some(msgs) = s.get_chat_messages(&cj) {
                        for m in msgs.iter().filter(|m| m.starred) {
                            let sender_name = if m.from_me {
                                "Vy".to_string()
                            } else {
                                s.resolve_display_name(&m.sender_jid)
                                    .unwrap_or_else(|| crate::util::format_jid(&m.sender_jid))
                            };
                            rows.push((
                                m.timestamp,
                                json!({
                                    "id": m.id,
                                    "chat": cj.to_string(),
                                    "chat_name": chat_name,
                                    "sender_name": sender_name,
                                    "text": m.text,
                                    "media": m.media_type.as_ref().map(|t| format!("{t:?}").to_lowercase()),
                                    "ts": m.timestamp.timestamp_millis(),
                                    "from_me": m.from_me,
                                }),
                            ));
                        }
                    }
                }
                rows.sort_by(|a, b| b.0.cmp(&a.0));
                let items: Vec<Value> = rows.into_iter().take(500).map(|(_, v)| v).collect();
                json!({
                    "type": "starred_messages",
                    "chat": target.map(|j| j.to_string()),
                    "items": items,
                })
            };
            let _ = reply_tx.send(reply.to_string());
            notify_snap = false;
        }
        Some("view_once") => {
            if let (Some(jid), Some(id)) = (jid_field(&value, "chat"), id_field(&value)) {
                let _ = backend.send_command(Command::OpenViewOnce {
                    chat_jid: jid,
                    message_id: id,
                });
            }
        }
        Some("consume_view_once") => {
            if let (Some(jid), Some(id)) = (jid_field(&value, "chat"), id_field(&value)) {
                let _ = backend.send_command(Command::ConsumeViewOnce {
                    chat_jid: jid,
                    message_id: id,
                });
            }
        }
        Some("pin_chat") => {
            if let Some(jid) = jid_field(&value, "chat") {
                let _ = backend.send_command(Command::PinChat { chat_jid: jid });
            }
        }
        Some("unpin_chat") => {
            if let Some(jid) = jid_field(&value, "chat") {
                let _ = backend.send_command(Command::UnpinChat { chat_jid: jid });
            }
        }
        Some("mute_chat") => {
            if let Some(jid) = jid_field(&value, "chat") {
                let until = value["hours"]
                    .as_i64()
                    .map(|h| chrono::Utc::now() + chrono::Duration::hours(h));
                let _ = backend.send_command(Command::MuteChat { chat_jid: jid, until });
            }
        }
        Some("unmute_chat") => {
            if let Some(jid) = jid_field(&value, "chat") {
                let _ = backend.send_command(Command::UnmuteChat { chat_jid: jid });
            }
        }
        Some("archive_chat") => {
            if let Some(jid) = jid_field(&value, "chat") {
                let _ = backend.send_command(Command::ArchiveChat { chat_jid: jid });
            }
        }
        Some("unarchive_chat") => {
            if let Some(jid) = jid_field(&value, "chat") {
                let _ = backend.send_command(Command::UnarchiveChat { chat_jid: jid });
            }
        }
        Some("clear_chat") => {
            if let Some(jid) = jid_field(&value, "chat") {
                let _ = backend.send_command(Command::ClearChat { chat_jid: jid });
            }
        }
        Some("delete_chat") => {
            if let Some(jid) = jid_field(&value, "chat") {
                let _ = backend.send_command(Command::DeleteChat { chat_jid: jid });
            }
        }
        Some("export_chat") => {
            notify_snap = false;
            if let Some(jid) = jid_field(&value, "chat") {
                let format = match value["format"].as_str() {
                    Some("json") => crate::export::ExportFormat::Json,
                    Some("html") => crate::export::ExportFormat::Html,
                    _ => crate::export::ExportFormat::Txt,
                };
                let custom_dir = value["dir"].as_str().map(std::path::PathBuf::from);
                let (chat_opt, msgs, contacts, self_name) = {
                    let s = backend.state.read();
                    let canon = s.canonical_jid(&jid);
                    let chat = s.chats.get(&canon).or_else(|| s.chats.get(&jid)).cloned();
                    let msgs = s.get_chat_messages(&canon).cloned().unwrap_or_default();
                    let contacts = s.contacts.clone();
                    let self_name = s.self_name.clone().unwrap_or_else(|| "You".to_string());
                    (chat, msgs, contacts, self_name)
                };
                if let Some(chat) = chat_opt {
                    let reply_tx = reply_tx.clone();
                    tokio::spawn(async move {
                        let res = tokio::task::spawn_blocking(move || {
                            crate::export::save_export(
                                &chat,
                                &msgs,
                                &contacts,
                                &self_name,
                                format,
                                custom_dir.as_deref(),
                            )
                        })
                        .await;
                        let reply = match res {
                            Ok(Ok(path)) => json!({
                                "type": "export_result",
                                "ok": true,
                                "path": path.to_string_lossy(),
                            }),
                            Ok(Err(err)) => json!({
                                "type": "export_result",
                                "ok": false,
                                "error": err.to_string(),
                            }),
                            Err(err) => json!({
                                "type": "export_result",
                                "ok": false,
                                "error": err.to_string(),
                            }),
                        };
                        let _ = reply_tx.send(reply.to_string());
                    });
                } else {
                    let reply = json!({
                        "type": "export_result",
                        "ok": false,
                        "error": "Chat nenalezen",
                    });
                    let _ = reply_tx.send(reply.to_string());
                }
            }
        }
        Some("save_contact") => {
            if let (Some(jid), Some(name)) = (jid_field(&value, "jid"), value["name"].as_str()) {
                let trimmed = name.trim().to_string();
                if !trimmed.is_empty() {
                    let _ = backend.send_command(Command::SaveContact {
                        jid,
                        name: trimmed,
                    });
                }
            }
        }
        Some("block_contact") => {
            if let Some(jid) = jid_field(&value, "jid") {
                let _ = backend.send_command(Command::BlockContact { jid });
            }
        }
        Some("unblock_contact") => {
            if let Some(jid) = jid_field(&value, "jid") {
                let _ = backend.send_command(Command::UnblockContact { jid });
            }
        }
        Some("create_group") => {
            let subject = value["subject"].as_str().unwrap_or_default().trim().to_string();
            let participants = jids_field(&value, "participants");
            if !subject.is_empty() && !participants.is_empty() {
                let _ = backend.send_command(Command::CreateGroup {
                    subject,
                    participants,
                });
            }
        }
        Some("join_group") => {
            let code = value["code"].as_str().unwrap_or_default().trim().to_string();
            if !code.is_empty() {
                let _ = backend.send_command(Command::JoinGroup { invite_code: code });
            }
        }
        Some("group_info") => {
            if let Some(jid) = jid_field(&value, "chat") {
                let _ = backend.send_command(Command::RequestGroupInfo { chat_jid: jid });
            }
        }
        Some("invite_link") => {
            if let Some(jid) = jid_field(&value, "chat") {
                let _ = backend.send_command(Command::GetGroupInviteLink { chat_jid: jid });
            }
        }
        Some("add_participants") => {
            if let Some(jid) = jid_field(&value, "chat") {
                let participants = jids_field(&value, "participants");
                if !participants.is_empty() {
                    let _ = backend.send_command(Command::AddParticipants {
                        chat_jid: jid,
                        participants,
                    });
                }
            }
        }
        Some("remove_participants") => {
            if let Some(jid) = jid_field(&value, "chat") {
                let participants = jids_field(&value, "participants");
                if !participants.is_empty() {
                    let _ = backend.send_command(Command::RemoveParticipants {
                        chat_jid: jid,
                        participants,
                    });
                }
            }
        }
        Some("promote_participants") => {
            if let Some(jid) = jid_field(&value, "chat") {
                let participants = jids_field(&value, "participants");
                if !participants.is_empty() {
                    let _ = backend.send_command(Command::PromoteParticipants {
                        chat_jid: jid,
                        participants,
                    });
                }
            }
        }
        Some("demote_participants") => {
            if let Some(jid) = jid_field(&value, "chat") {
                let participants = jids_field(&value, "participants");
                if !participants.is_empty() {
                    let _ = backend.send_command(Command::DemoteParticipants {
                        chat_jid: jid,
                        participants,
                    });
                }
            }
        }
        Some("set_subject") => {
            if let (Some(jid), Some(subject)) = (jid_field(&value, "chat"), value["subject"].as_str()) {
                let _ = backend.send_command(Command::SetGroupSubject {
                    chat_jid: jid,
                    subject: subject.to_string(),
                });
            }
        }
        Some("set_description") => {
            if let Some(jid) = jid_field(&value, "chat") {
                let _ = backend.send_command(Command::SetGroupDescription {
                    chat_jid: jid,
                    description: value["description"].as_str().unwrap_or_default().to_string(),
                });
            }
        }
        Some("group_announce") => {
            if let (Some(jid), Some(enabled)) = (jid_field(&value, "chat"), value["enabled"].as_bool()) {
                let _ = backend.send_command(Command::SetGroupAnnounce {
                    chat_jid: jid,
                    enabled,
                });
            }
        }
        Some("group_locked") => {
            if let (Some(jid), Some(enabled)) = (jid_field(&value, "chat"), value["enabled"].as_bool()) {
                let _ = backend.send_command(Command::SetGroupLocked {
                    chat_jid: jid,
                    enabled,
                });
            }
        }
        Some("ephemeral") => {
            if let Some(jid) = jid_field(&value, "chat") {
                let _ = backend.send_command(Command::SetEphemeral {
                    chat_jid: jid,
                    expiration: value["seconds"].as_u64().unwrap_or(0) as u32,
                });
            }
        }
        Some("leave_group") => {
            if let Some(jid) = jid_field(&value, "chat") {
                let _ = backend.send_command(Command::LeaveGroup { chat_jid: jid });
            }
        }
        // `at` is RFC3339; the date/time pickers in the GUI build it.
        Some("schedule") => {
            if let (Some(jid), Some(text)) =
                (jid_field(&value, "chat"), value["text"].as_str())
            {
                if let Ok(at) = chrono::DateTime::parse_from_rfc3339(
                    value["at"].as_str().unwrap_or_default(),
                ) {
                    let _ = backend.send_command(Command::ScheduleMessage {
                        chat_jid: jid,
                        text: text.to_string(),
                        scheduled_for: at.with_timezone(&chrono::Utc),
                    });
                }
            }
        }
        Some("cancel_scheduled") => {
            if let Some(id) = id_field(&value) {
                let _ = backend.send_command(Command::CancelScheduledMessage { id });
            }
        }
        Some("send_scheduled") => {
            if let Some(id) = id_field(&value) {
                let _ = backend.send_command(Command::SendScheduledMessageNow { id });
            }
        }
        Some("create_poll") => {
            if let Some(jid) = jid_field(&value, "chat") {
                let question = value["question"].as_str().unwrap_or_default().trim().to_string();
                let options = strings_field(&value, "options");
                if !question.is_empty() && options.len() >= 2 {
                    let _ = backend.send_command(Command::CreatePoll {
                        chat_jid: jid,
                        question,
                        options,
                        selectable_count: value["selectable"].as_u64().unwrap_or(1) as u32,
                    });
                }
            }
        }
        Some("vote_poll") => {
            if let (Some(jid), Some(id)) = (jid_field(&value, "chat"), id_field(&value)) {
                let poll = {
                    let s = backend.state.read();
                    s.get_chat_messages(&jid)
                        .and_then(|msgs| msgs.iter().find(|m| m.id == id))
                        .and_then(|m| m.poll.as_ref())
                        .map(|p| (p.creator.clone(), p.secret.clone()))
                };
                if let Some((poll_creator, message_secret)) = poll {
                    let _ = backend.send_command(Command::VotePoll {
                        chat_jid: jid,
                        message_id: id,
                        poll_creator,
                        message_secret,
                        option_names: strings_field(&value, "options"),
                    });
                }
            }
        }
        Some("start_call") => {
            if let Some(peer_jid) = jid_field(&value, "peer") {
                let is_video = value["video"].as_bool().unwrap_or(false);
                let _ = backend.send_command(Command::StartCall { peer_jid, is_video });
            }
        }
        Some("accept_call") => {
            if let Some(call_id) = id_field(&value) {
                let _ = backend.send_command(Command::AcceptCall { call_id });
            }
        }
        Some("reject_call") => {
            if let Some(call_id) = id_field(&value) {
                let _ = backend.send_command(Command::RejectCall { call_id });
            }
        }
        Some("end_call") => {
            if let Some(call_id) = id_field(&value) {
                let _ = backend.send_command(Command::EndCall { call_id });
            }
        }
        Some("toggle_call_mute") => {
            let _ = backend.send_command(Command::ToggleCallMute);
        }
        Some("toggle_call_video") => {
            let _ = backend.send_command(Command::ToggleCallVideo);
        }
        Some("search_messages") => {
            let filter = MessageSearchFilter {
                query: value["q"].as_str().unwrap_or_default().to_string(),
                scope: match value["scope"].as_str() {
                    Some("all") => SearchScope::AllChats,
                    _ => SearchScope::CurrentChat,
                },
                sender: match value["sender"].as_str() {
                    Some("me") => SearchSender::SentByMe,
                    Some("received") => SearchSender::Received,
                    _ => SearchSender::All,
                },
                content_type: match value["content_type"].as_str() {
                    Some("text") => SearchContentType::TextOnly,
                    Some("media") => SearchContentType::MediaOnly,
                    Some("links") => SearchContentType::LinksOnly,
                    Some("polls") => SearchContentType::PollsOnly,
                    Some("reactions") => SearchContentType::WithReactionsOnly,
                    Some("starred") => SearchContentType::StarredOnly,
                    _ => SearchContentType::All,
                },
                date_range: match value["date_range"].as_str() {
                    Some("today") => SearchDateRange::Today,
                    Some("7d") => SearchDateRange::Last7Days,
                    Some("30d") => SearchDateRange::Last30Days,
                    _ => SearchDateRange::AllTime,
                },
            };
            let (items, total_hits, scanned_messages): (Vec<Value>, usize, usize) = {
                let s = backend.state.read();
                let scanned = match filter.scope {
                    SearchScope::CurrentChat => s
                        .selected_chat
                        .as_ref()
                        .and_then(|j| s.get_chat_messages(j))
                        .map_or(0, |m| m.len()),
                    SearchScope::AllChats => s.messages.values().map(|v| v.len()).sum(),
                };
                let all_hits = search_messages(&s, &filter);
                let total = all_hits.len();
                let items = all_hits
                    .into_iter()
                    .take(500)
                    .map(|hit| {
                        json!({
                            "id": hit.message.id,
                            "chat": hit.message.chat_jid.to_string(),
                            "chat_name": hit.chat_name,
                            "sender_name": hit.sender_name,
                            "text": hit.message.text,
                            "media": hit.message.media_type.as_ref().map(|t| format!("{t:?}").to_lowercase()),
                            "ts": hit.message.timestamp.timestamp_millis(),
                            "from_me": hit.message.from_me,
                        })
                    })
                    .collect();
                (items, total, scanned)
            };
            let _ = reply_tx.send(
                json!({
                    "type": "search_results",
                    "items": items,
                    "total_hits": total_hits,
                    "scanned_messages": scanned_messages,
                })
                .to_string(),
            );
            notify_snap = false;
        }
        Some("get_chat_gallery") => {
            let reply = {
                let s = backend.state.read();
                let target = jid_field(&value, "chat")
                    .map(|j| s.canonical_jid(&j))
                    .or_else(|| s.selected_chat.clone());
                match target {
                    Some(jid) => compute_chat_gallery_json(&s, &jid),
                    None => json!({
                        "type": "chat_gallery",
                        "chat": "",
                        "total_messages": 0,
                        "syncing": false,
                        "exhausted": false,
                        "media": [],
                        "docs": [],
                        "links": [],
                    }),
                }
            };
            let _ = reply_tx.send(reply.to_string());
            notify_snap = false;
        }
        Some("sync_full_history") => {
            let chat_jid = jid_field(&value, "chat");
            let _ = backend.send_command(Command::SyncFullHistory { chat_jid });
        }
        Some("cancel_history_sync") => {
            let _ = backend.send_command(Command::CancelFullHistorySync);
        }
        Some("set_push_name") => {
            if let Some(name) = value["name"].as_str() {
                let trimmed = name.trim().to_string();
                {
                    let mut s = backend.state.write();
                    s.self_name = if trimmed.is_empty() {
                        None
                    } else {
                        Some(trimmed.clone())
                    };
                    s.dirty = true;
                }
                if !trimmed.is_empty() {
                    let _ = backend.send_command(Command::SetPushName { name: trimmed });
                }
            }
        }
        Some("set_status_text") => {
            if let Some(text) = value["text"].as_str() {
                let trimmed = text.trim().to_string();
                {
                    let mut s = backend.state.write();
                    s.self_status = (!trimmed.is_empty()).then(|| trimmed.clone());
                    s.dirty = true;
                }
                let _ = backend.send_command(Command::SetStatusText { text: trimmed });
            }
        }
        Some("set_profile_picture") => {
            if let Some(path) = value["path"].as_str() {
                let path = std::path::PathBuf::from(path);
                let tx_command = backend.tx_command.clone();
                let reply_tx = reply_tx.clone();
                tokio::spawn(async move {
                    let prepared = tokio::task::spawn_blocking(move || {
                        crate::avatars::prepare_profile_jpeg(&path)
                    })
                    .await;
                    let reply = match prepared {
                        Ok(Ok(data)) => {
                            let _ = tx_command.send(Command::SetProfilePicture { data });
                            json!({ "type": "profile_result", "kind": "picture", "ok": true })
                        }
                        Ok(Err(err)) => json!({
                            "type": "profile_result",
                            "kind": "picture",
                            "ok": false,
                            "error": err.to_string(),
                        }),
                        Err(err) => json!({
                            "type": "profile_result",
                            "kind": "picture",
                            "ok": false,
                            "error": err.to_string(),
                        }),
                    };
                    let _ = reply_tx.send(reply.to_string());
                });
            }
        }
        Some("remove_profile_picture") => {
            let _ = backend.send_command(Command::SetProfilePicture { data: Vec::new() });
            let reply = json!({ "type": "profile_result", "kind": "remove_picture", "ok": true });
            let _ = reply_tx.send(reply.to_string());
        }
        Some("test_notification") => {
            notify_snap = false;
            tokio::task::spawn_blocking(|| {
                let _ = crate::notifications::show_toast(
                    "WaLite",
                    "Takto vypadá oznámení o nové zprávě.",
                );
                crate::notifications::play_sound();
            });
        }
        Some("preview_sound") => {
            notify_snap = false;
            let preset = value["preset"].as_str().map(str::to_string);
            let path = value["path"].as_str().map(str::to_string);
            tokio::task::spawn_blocking(move || {
                crate::notifications::play_sound_preview(preset.as_deref(), path.as_deref());
            });
        }
        Some("media_stats") => {
            notify_snap = false;
            let state = backend.state.clone();
            let reply_tx = reply_tx.clone();
            tokio::spawn(async move {
                if let Ok(reply) = tokio::task::spawn_blocking(move || {
                    compute_media_stats_json(&state, None).to_string()
                })
                .await
                {
                    let _ = reply_tx.send(reply);
                }
            });
        }
        Some("clean_media") => {
            notify_snap = false;
            let mode = value["mode"].as_str().unwrap_or("stale").to_string();
            let state = backend.state.clone();
            let reply_tx = reply_tx.clone();
            let snap_notify = snap_notify.clone();
            tokio::spawn(async move {
                let res = tokio::task::spawn_blocking(move || {
                    let stats = {
                        let s = state.read();
                        let referenced = s.referenced_media_paths();
                        crate::media::media_stats(
                            &crate::media::media_dir(),
                            &referenced,
                            Duration::from_secs(30 * 24 * 60 * 60),
                            SystemTime::now(),
                        )
                    };
                    let targets = if mode == "old" {
                        &stats.old_paths
                    } else {
                        &stats.stale_paths
                    };
                    let mut removed = 0usize;
                    let mut freed = 0u64;
                    for path in targets {
                        let size = std::fs::metadata(path).map(|m| m.len()).unwrap_or(0);
                        if std::fs::remove_file(path).is_ok() {
                            removed += 1;
                            freed += size;
                        }
                    }
                    if removed > 0 {
                        crate::media::MEDIA_REV.fetch_add(1, Ordering::Relaxed);
                        snap_notify.notify_one();
                    }
                    compute_media_stats_json(&state, Some((removed, freed))).to_string()
                })
                .await;
                if let Ok(reply) = res {
                    let _ = reply_tx.send(reply);
                }
            });
        }
        Some("check_updates") => {
            crate::updater::spawn_check(backend.state.clone());
        }
        Some("install_update") => {
            let info = backend.state.read().update_available.clone();
            if let Some(info) = info {
                crate::updater::spawn_install(backend.state.clone(), info);
            }
        }
        Some("set_pref") => {
            let Some(key) = value["key"].as_str() else {
                return;
            };
            let v = &value["value"];
            let mut s = backend.state.write();
            let changed = match key {
                "auto_scroll_to_bottom" => assign_bool(&mut s.auto_scroll_to_bottom, v),
                _ => {
                    let p = &mut s.preferences;
                    match key {
                        "enter_is_send" => assign_bool(&mut p.enter_is_send, v),
                        "sound_notifications" => assign_bool(&mut p.sound_notifications, v),
                        "show_previews" => assign_bool(&mut p.show_previews, v),
                        "desktop_notifications" => assign_bool(&mut p.desktop_notifications, v),
                        "auto_download_photos" => assign_bool(&mut p.auto_download_photos, v),
                        "auto_download_videos" => assign_bool(&mut p.auto_download_videos, v),
                        "auto_download_docs" => assign_bool(&mut p.auto_download_docs, v),
                        "check_updates" => assign_bool(&mut p.check_updates, v),
                        "auto_install_updates" => assign_bool(&mut p.auto_install_updates, v),
                        "run_in_tray" => assign_bool(&mut p.run_in_tray, v),
                        "close_to_tray" => assign_bool(&mut p.close_to_tray, v),
                        "start_with_windows" => {
                            let ok = assign_bool(&mut p.start_with_windows, v);
                            if ok {
                                let _ = crate::autostart::set_autostart_enabled(p.start_with_windows);
                            }
                            ok
                        }
                        "font_size" => match v.as_f64() {
                            Some(size) => {
                                p.font_size = size.clamp(12.0, 20.0) as f32;
                                true
                            }
                            None => false,
                        },
                        "dark_theme_preset" => match v.as_u64() {
                            Some(idx) if idx <= 2 => {
                                p.dark_theme_preset = idx as usize;
                                true
                            }
                            _ => false,
                        },
                        "language" => match v.as_str() {
                            Some("en") => {
                                p.language = crate::i18n::Language::En;
                                crate::i18n::set_language(p.language);
                                true
                            }
                            Some("cs") => {
                                p.language = crate::i18n::Language::Cs;
                                crate::i18n::set_language(p.language);
                                true
                            }
                            _ => false,
                        },
                        "chat_wallpaper_color" => {
                            if v.is_null() {
                                p.chat_wallpaper_color = None;
                                true
                            } else if let Some(s) = v.as_str() {
                                p.chat_wallpaper_color =
                                    (!s.trim().is_empty()).then(|| s.trim().to_string());
                                true
                            } else {
                                false
                            }
                        }
                        "chat_wallpaper_path" => {
                            if v.is_null() {
                                p.chat_wallpaper_path = None;
                                true
                            } else if let Some(path_str) = v.as_str() {
                                let trimmed = path_str.trim();
                                if trimmed.is_empty() {
                                    p.chat_wallpaper_path = None;
                                    true
                                } else if std::path::Path::new(trimmed).is_file() {
                                    p.chat_wallpaper_path = Some(trimmed.to_string());
                                    true
                                } else {
                                    false
                                }
                            } else {
                                false
                            }
                        }
                        "chat_wallpaper_doodles" => assign_bool(&mut p.chat_wallpaper_doodles, v),
                        "notification_sound" => {
                            if v.is_null() {
                                p.notification_sound = None;
                                crate::notifications::configure_sound(
                                    None,
                                    p.custom_sound_path.as_deref(),
                                );
                                true
                            } else if let Some(preset) = v.as_str() {
                                let trimmed = preset.trim();
                                if crate::notifications::is_valid_sound_preset(trimmed) {
                                    p.notification_sound = Some(trimmed.to_string());
                                    crate::notifications::configure_sound(
                                        p.notification_sound.as_deref(),
                                        p.custom_sound_path.as_deref(),
                                    );
                                    true
                                } else {
                                    false
                                }
                            } else {
                                false
                            }
                        }
                        "custom_sound_path" => {
                            if v.is_null() {
                                p.custom_sound_path = None;
                                if p.notification_sound.as_deref() == Some("custom") {
                                    p.notification_sound = Some("chime".to_string());
                                }
                                crate::notifications::configure_sound(
                                    p.notification_sound.as_deref(),
                                    None,
                                );
                                true
                            } else if let Some(path_str) = v.as_str() {
                                let trimmed = path_str.trim();
                                if trimmed.is_empty() {
                                    p.custom_sound_path = None;
                                    if p.notification_sound.as_deref() == Some("custom") {
                                        p.notification_sound = Some("chime".to_string());
                                    }
                                    crate::notifications::configure_sound(
                                        p.notification_sound.as_deref(),
                                        None,
                                    );
                                    true
                                } else if std::path::Path::new(trimmed).is_file() {
                                    p.custom_sound_path = Some(trimmed.to_string());
                                    p.notification_sound = Some("custom".to_string());
                                    crate::notifications::configure_sound(
                                        p.notification_sound.as_deref(),
                                        p.custom_sound_path.as_deref(),
                                    );
                                    true
                                } else {
                                    false
                                }
                            } else {
                                false
                            }
                        }
                        _ => false,
                    }
                }
            };
            if changed {
                s.dirty = true;
                drop(s);
                tracing::info!("nastavení {key} = {v}");
            }
        }
        Some("search") => {
            let query = value["q"].as_str().unwrap_or_default().to_string();
            let _ = backend.send_command(Command::search(query));
        }
        _ => {
            notify_snap = false;
        }
    }
    if notify_snap {
        snap_notify.notify_one();
    }
}

fn compute_chat_gallery_json(s: &crate::state::AppState, chat_jid: &Jid) -> Value {
    let canon = s.canonical_jid(chat_jid);
    let msgs = s.get_chat_messages(&canon).map(|v| v.as_slice()).unwrap_or(&[]);
    let mut media = Vec::new();
    let mut docs = Vec::new();
    let mut links = Vec::new();

    for m in msgs.iter().rev() {
        let media_path = m
            .media_path
            .as_ref()
            .filter(|p| media_file_exists_cached(p))
            .cloned();
        let thumb = if !m.view_once
            && (media_path.is_none()
                || matches!(m.media_type, Some(crate::state::MediaType::Video)))
        {
            m.media_jpeg_thumbnail
                .as_deref()
                .filter(|b| !b.is_empty() && b.len() <= 32 * 1024)
                .map(|b| thumb_base64_cached(&m.id, b))
        } else {
            None
        };

        if crate::ui::chat_info::is_gallery_media(m.media_type) {
            media.push(json!({
                "id": m.id,
                "chat": canon.to_string(),
                "sender": m.sender_jid.to_string(),
                "text": m.text,
                "ts": m.timestamp.timestamp_millis(),
                "from_me": m.from_me,
                "status": format!("{:?}", m.status).to_lowercase(),
                "media": m.media_type.as_ref().map(|t| format!("{t:?}").to_lowercase()),
                "caption": m.media_caption,
                "downloaded": media_path.is_some(),
                "media_path": media_path,
                "thumb": thumb,
                "file_size": m.media_file_length,
                "mimetype": m.media_mimetype,
                "view_once": m.view_once,
                "view_once_opened": m.view_once_opened,
            }));
        } else if m.media_type == Some(crate::state::MediaType::Document) {
            docs.push(json!({
                "id": m.id,
                "chat": canon.to_string(),
                "sender": m.sender_jid.to_string(),
                "text": m.text,
                "label": crate::ui::chat_info::document_label(m),
                "ts": m.timestamp.timestamp_millis(),
                "from_me": m.from_me,
                "status": format!("{:?}", m.status).to_lowercase(),
                "media": "document",
                "caption": m.media_caption,
                "downloaded": media_path.is_some(),
                "media_path": media_path,
                "file_size": m.media_file_length,
                "mimetype": m.media_mimetype,
            }));
        }

        if !m.text.is_empty() {
            for url in crate::ui::chat_info::extract_links(&m.text) {
                links.push(json!({
                    "id": m.id,
                    "chat": canon.to_string(),
                    "url": url,
                    "text": m.text,
                    "ts": m.timestamp.timestamp_millis(),
                    "from_me": m.from_me,
                }));
            }
        }
        if let Some(cap) = m.media_caption.as_deref().filter(|c| !c.is_empty()) {
            for url in crate::ui::chat_info::extract_links(cap) {
                links.push(json!({
                    "id": m.id,
                    "chat": canon.to_string(),
                    "url": url,
                    "text": cap,
                    "ts": m.timestamp.timestamp_millis(),
                    "from_me": m.from_me,
                }));
            }
        }
    }

    json!({
        "type": "chat_gallery",
        "chat": canon.to_string(),
        "total_messages": msgs.len(),
        "syncing": s.history_syncing_chats.contains(&canon),
        "exhausted": s.history_exhausted_chats.contains(&canon),
        "media": media,
        "docs": docs,
        "links": links,
    })
}

fn compute_media_stats_json(state: &SharedState, cleaned: Option<(usize, u64)>) -> Value {
    let media_dir = crate::media::media_dir();
    let referenced = state.read().referenced_media_paths();
    let stats = crate::media::media_stats(
        &media_dir,
        &referenced,
        Duration::from_secs(30 * 24 * 60 * 60),
        SystemTime::now(),
    );
    json!({
        "type": "media_stats",
        "dir": media_dir.to_string_lossy(),
        "files": stats.files,
        "total_bytes": stats.total_bytes,
        "stale_files": stats.stale_files,
        "stale_bytes": stats.stale_bytes,
        "old_files": stats.old_paths.len(),
        "cleaned_files": cleaned.map(|(n, _)| n),
        "cleaned_bytes": cleaned.map(|(_, b)| b),
    })
}

fn assign_bool(slot: &mut bool, value: &Value) -> bool {
    match value.as_bool() {
        Some(v) => {
            *slot = v;
            true
        }
        None => false,
    }
}

#[derive(Serialize)]
struct PrefsJson<'a> {
    enter_is_send: bool,
    sound_notifications: bool,
    show_previews: bool,
    desktop_notifications: bool,
    auto_download_photos: bool,
    auto_download_videos: bool,
    auto_download_docs: bool,
    font_size: f32,
    auto_scroll_to_bottom: bool,
    dark_theme_preset: usize,
    language: &'static str,
    check_updates: bool,
    auto_install_updates: bool,
    run_in_tray: bool,
    close_to_tray: bool,
    start_with_windows: bool,
    chat_wallpaper_color: Option<&'a str>,
    chat_wallpaper_path: Option<&'a str>,
    chat_wallpaper_doodles: bool,
    notification_sound: Option<&'a str>,
    custom_sound_path: Option<&'a str>,
}

fn prefs_json<'a>(s: &'a crate::state::AppState) -> PrefsJson<'a> {
    let p = &s.preferences;
    PrefsJson {
        enter_is_send: p.enter_is_send,
        sound_notifications: p.sound_notifications,
        show_previews: p.show_previews,
        desktop_notifications: p.desktop_notifications,
        auto_download_photos: p.auto_download_photos,
        auto_download_videos: p.auto_download_videos,
        auto_download_docs: p.auto_download_docs,
        font_size: p.font_size,
        auto_scroll_to_bottom: s.auto_scroll_to_bottom,
        dark_theme_preset: p.dark_theme_preset,
        language: p.language.code(),
        check_updates: p.check_updates,
        auto_install_updates: p.auto_install_updates,
        run_in_tray: p.run_in_tray,
        close_to_tray: p.close_to_tray,
        start_with_windows: p.start_with_windows,
        chat_wallpaper_color: p.chat_wallpaper_color.as_deref(),
        chat_wallpaper_path: p.chat_wallpaper_path.as_deref(),
        chat_wallpaper_doodles: p.chat_wallpaper_doodles,
        notification_sound: p.notification_sound.as_deref(),
        custom_sound_path: p.custom_sound_path.as_deref(),
    }
}

fn avatar_path_cached(jid: &Jid) -> Option<String> {
    let rev = crate::avatars::revision();
    let key = jid.to_string();
    let mut cache = AVATAR_CACHE.lock();
    if cache.0 != rev {
        cache.0 = rev;
        cache.1.clear();
    }
    if let Some(found) = cache.1.get(&key) {
        return found.clone();
    }
    let path = crate::avatars::cached_path(jid);
    cache.1.insert(key, path.clone());
    path
}

fn media_file_exists_cached(path: &str) -> bool {
    let rev = crate::media::MEDIA_REV.load(Ordering::Relaxed);
    let mut cache = MEDIA_EXISTS_CACHE.lock();
    let now = Instant::now();
    if cache.0 != rev || now.duration_since(cache.1) >= MEDIA_EXISTS_TTL || cache.2.len() > 4096 {
        cache.0 = rev;
        cache.1 = now;
        cache.2.clear();
    }
    if let Some(&exists) = cache.2.get(path) {
        return exists;
    }
    let exists = Path::new(path).is_file();
    cache.2.insert(path.to_string(), exists);
    exists
}

fn thumb_base64_cached(id: &str, bytes: &[u8]) -> String {
    let mut cache = THUMB_B64_CACHE.lock();
    if let Some(encoded) = cache.get(id) {
        return encoded.clone();
    }
    if cache.len() >= 4096 {
        cache.clear();
    }
    let encoded = encode_base64(bytes);
    cache.insert(id.to_string(), encoded.clone());
    encoded
}

fn sticker_paths_cached() -> Vec<String> {
    let rev = crate::media::MEDIA_REV.load(Ordering::Relaxed);
    let mut cache = STICKER_CACHE.lock();
    if cache.0 == Some(rev) {
        return cache.1.clone();
    }
    let list: Vec<String> = crate::media::sticker_files()
        .into_iter()
        .map(|p| p.to_string_lossy().into_owned())
        .collect();
    cache.0 = Some(rev);
    cache.1 = list.clone();
    list
}

fn encode_base64(input: &[u8]) -> String {
    const TABLE: &[u8; 64] =
        b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(input.len().div_ceil(3) * 4);
    for chunk in input.chunks(3) {
        let b0 = chunk[0] as usize;
        let b1 = *chunk.get(1).unwrap_or(&0) as usize;
        let b2 = *chunk.get(2).unwrap_or(&0) as usize;
        let n = (b0 << 16) | (b1 << 8) | b2;
        out.push(TABLE[(n >> 18) & 0x3F] as char);
        out.push(TABLE[(n >> 12) & 0x3F] as char);
        out.push(if chunk.len() > 1 { TABLE[(n >> 6) & 0x3F] as char } else { '=' });
        out.push(if chunk.len() > 2 { TABLE[n & 0x3F] as char } else { '=' });
    }
    out
}

fn jid_field(value: &Value, key: &str) -> Option<Jid> {
    value[key].as_str().and_then(|s| s.parse::<Jid>().ok())
}

fn id_field(value: &Value) -> Option<String> {
    value["id"].as_str().map(str::to_string)
}

fn jids_field(value: &Value, key: &str) -> Vec<Jid> {
    value[key]
        .as_array()
        .map(|a| a.iter().filter_map(|v| v.as_str().and_then(|s| s.parse::<Jid>().ok())).collect())
        .unwrap_or_default()
}

/// Trimmed, non-empty strings from an array field.
fn strings_field(value: &Value, key: &str) -> Vec<String> {
    value[key]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|v| v.as_str())
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect()
        })
        .unwrap_or_default()
}

fn message_status_str(status: crate::state::MessageStatus) -> &'static str {
    match status {
        crate::state::MessageStatus::Sending => "sending",
        crate::state::MessageStatus::Sent => "sent",
        crate::state::MessageStatus::Delivered => "delivered",
        crate::state::MessageStatus::Read => "read",
        crate::state::MessageStatus::Failed => "failed",
    }
}

fn media_type_str(media: crate::state::MediaType) -> &'static str {
    match media {
        crate::state::MediaType::Image => "image",
        crate::state::MediaType::Video => "video",
        crate::state::MediaType::Audio => "audio",
        crate::state::MediaType::Document => "document",
        crate::state::MediaType::Sticker => "sticker",
        crate::state::MediaType::Voice => "voice",
    }
}

#[derive(Serialize)]
struct ChatLastJson<'a> {
    text: &'a str,
    ts: i64,
    from_me: bool,
    status: &'static str,
    media: Option<&'static str>,
}

#[derive(Serialize)]
struct ChatRowJson<'a> {
    jid: String,
    name: &'a str,
    unread: u32,
    group: bool,
    pinned: bool,
    archived: bool,
    muted: bool,
    typing: bool,
    participants_count: usize,
    avatar: Option<String>,
    draft: Option<&'a str>,
    last: Option<ChatLastJson<'a>>,
}

#[derive(Serialize)]
struct GroupJson<'a> {
    subject: &'a str,
    description: Option<&'a str>,
    admins: Vec<String>,
    locked: bool,
    announcement: bool,
    invite_link: Option<&'a str>,
    ephemeral: Option<u32>,
    participants: Vec<String>,
}

#[derive(Serialize)]
struct PinnedJson<'a> {
    id: &'a str,
    until: Option<i64>,
}

#[derive(Serialize)]
struct ReactionJson<'a> {
    emoji: &'a str,
    sender: String,
}

#[derive(Serialize)]
struct PollTallyJson {
    option: String,
    votes: usize,
}

#[derive(Serialize)]
struct PollJson<'a> {
    question: &'a str,
    options: &'a [String],
    selectable: u32,
    quiz: bool,
    voters: usize,
    mine: Vec<String>,
    tallies: Vec<PollTallyJson>,
}

#[derive(Serialize)]
struct MessageJson<'a> {
    id: &'a str,
    chat: String,
    sender: String,
    text: &'a str,
    ts: i64,
    from_me: bool,
    status: &'static str,
    media: Option<&'static str>,
    caption: Option<&'a str>,
    downloaded: bool,
    media_path: Option<&'a str>,
    thumb: Option<String>,
    file_size: Option<u64>,
    mimetype: Option<&'a str>,
    reply_to: Option<&'a str>,
    edited: bool,
    starred: bool,
    gif_playback: bool,
    contacts: &'a [crate::vcard::ContactCard],
    view_once: bool,
    view_once_opened: bool,
    poll: Option<PollJson<'a>>,
    reactions: Vec<ReactionJson<'a>>,
}

#[derive(Serialize)]
struct PresenceJson {
    jid: String,
    online: bool,
    last_seen: Option<String>,
}

#[derive(Serialize)]
struct ScheduledJson<'a> {
    id: &'a str,
    chat: String,
    text: &'a str,
    at: String,
    status: String,
}

#[derive(Serialize)]
#[serde(untagged)]
enum ConnectionDetailJson<'a> {
    Str(&'a str),
    Pct(u8),
}

#[derive(Serialize)]
struct ConnectionJson<'a> {
    kind: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    detail: Option<ConnectionDetailJson<'a>>,
}

#[derive(Serialize)]
struct CallJson<'a> {
    id: &'a str,
    peer_jid: String,
    peer_name: &'a str,
    peer_avatar: Option<String>,
    is_video: bool,
    is_group: bool,
    status: &'static str,
    reason: Option<&'a str>,
    muted: bool,
    video_enabled: bool,
    started_at: i64,
    connected_at: Option<i64>,
}

#[derive(Serialize)]
struct AudioJson {
    playing_id: String,
    paused: bool,
    pos_ms: u64,
    dur_ms: Option<u64>,
}

#[derive(Serialize)]
struct UpdateAvailJson<'a> {
    version: &'a str,
    tag: &'a str,
    page_url: &'a str,
    notes: &'a str,
    has_asset: bool,
}

#[derive(Serialize)]
struct UpdateJson<'a> {
    current: &'static str,
    status: String,
    busy: bool,
    available: Option<UpdateAvailJson<'a>>,
}

#[derive(Serialize)]
struct ContactJson<'a> {
    jid: String,
    name: &'a str,
    blocked: bool,
    business: bool,
    verified_name: Option<&'a str>,
    avatar: Option<String>,
}

#[derive(Serialize)]
struct SnapshotJson<'a> {
    #[serde(rename = "type")]
    kind: &'static str,
    #[serde(rename = "self")]
    self_jid: Option<String>,
    self_name: Option<&'a str>,
    self_status: Option<&'a str>,
    self_avatar: Option<String>,
    avatar_rev: u64,
    connection: ConnectionJson<'a>,
    selected: Option<String>,
    selected_total_messages: usize,
    history_syncing: Vec<String>,
    history_exhausted: Vec<String>,
    search: &'a str,
    chats: Vec<ChatRowJson<'a>>,
    archived: Vec<ChatRowJson<'a>>,
    group: Option<GroupJson<'a>>,
    pinned_message: Option<PinnedJson<'a>>,
    ephemeral: Option<u32>,
    scheduled: Vec<ScheduledJson<'a>>,
    presence: Vec<PresenceJson>,
    prefs: PrefsJson<'a>,
    messages: Vec<MessageJson<'a>>,
    call: Option<CallJson<'a>>,
    audio: Option<AudioJson>,
    stickers: Vec<String>,
    update: UpdateJson<'a>,
    contacts: Vec<ContactJson<'a>>,
}

fn chat_row<'a>(s: &'a crate::state::AppState, chat: &'a crate::state::Chat) -> ChatRowJson<'a> {
    let last = chat.last_message.as_ref().map(|m| ChatLastJson {
        text: &m.text,
        ts: m.timestamp.timestamp_millis(),
        from_me: m.from_me,
        status: message_status_str(m.status),
        media: m.media_type.map(media_type_str),
    });
    let draft = s.drafts.get(&chat.jid).map(String::as_str).filter(|d| !d.is_empty());
    ChatRowJson {
        jid: chat.jid.to_string(),
        name: &chat.name,
        unread: chat.unread_count,
        group: chat.is_group,
        pinned: chat.is_pinned,
        archived: chat.is_archived,
        muted: chat.is_muted(),
        typing: chat.is_currently_typing(),
        participants_count: chat.participants.len(),
        avatar: avatar_path_cached(&chat.jid),
        draft,
        last,
    }
}

fn snapshot(state: &SharedState) -> String {
    let s = state.read();

    let chats: Vec<ChatRowJson<'_>> = s
        .filtered_chats()
        .into_iter()
        .map(|c| chat_row(&s, c))
        .collect();
    let archived: Vec<ChatRowJson<'_>> = s
        .archived_chats()
        .into_iter()
        .map(|c| chat_row(&s, c))
        .collect();

    let group = s.selected_chat.as_ref().and_then(|jid| {
        let chat = s.chats.get(jid)?;
        if !chat.is_group {
            return None;
        }
        let info = s.group_info.get(&jid.to_string());
        Some(GroupJson {
            subject: info.map(|i| i.subject.as_str()).unwrap_or(&chat.name),
            description: info.and_then(|i| i.description.as_deref()),
            admins: info
                .map(|i| i.admins.iter().map(|j| j.to_string()).collect::<Vec<_>>())
                .unwrap_or_default(),
            locked: info.map(|i| i.is_locked).unwrap_or(false),
            announcement: info.map(|i| i.is_announcement).unwrap_or(false),
            invite_link: info.and_then(|i| i.invite_link.as_deref()),
            ephemeral: s.ephemeral.get(jid).copied(),
            participants: chat.participants.iter().map(|j| j.to_string()).collect::<Vec<_>>(),
        })
    });

    let pinned_message = s.selected_chat.as_ref().and_then(|jid| {
        let pin = s.pinned.get(jid).filter(|p| !p.expired())?;
        Some(PinnedJson {
            id: &pin.message_id,
            until: pin.until.map(|t| t.timestamp_millis()),
        })
    });

    let ephemeral = s
        .selected_chat
        .as_ref()
        .and_then(|jid| s.ephemeral.get(jid).copied());

    let mut messages: Vec<MessageJson<'_>> = Vec::new();
    let me = s.self_jid.as_ref().map(|j| j.to_string()).unwrap_or_default();
    if let Some(selected) = s.selected_chat.as_ref() {
        if let Some(list) = s.get_chat_messages(selected) {
            let window = MESSAGE_LIMIT.load(Ordering::Relaxed);
            for m in list.iter().skip(list.len().saturating_sub(window)) {
                let reactions: Vec<ReactionJson<'_>> = m
                    .reactions
                    .iter()
                    .map(|r| ReactionJson {
                        emoji: &r.emoji,
                        sender: r.sender.to_string(),
                    })
                    .collect();
                let media_path = m
                    .media_path
                    .as_deref()
                    .filter(|p| media_file_exists_cached(p));
                let thumb = if !m.view_once
                    && (media_path.is_none()
                        || matches!(m.media_type, Some(crate::state::MediaType::Video)))
                {
                    m.media_jpeg_thumbnail
                        .as_deref()
                        .filter(|b| !b.is_empty() && b.len() <= 32 * 1024)
                        .map(|b| thumb_base64_cached(&m.id, b))
                } else {
                    None
                };
                messages.push(MessageJson {
                    id: &m.id,
                    chat: m.chat_jid.to_string(),
                    sender: m.sender_jid.to_string(),
                    text: &m.text,
                    ts: m.timestamp.timestamp_millis(),
                    from_me: m.from_me,
                    status: message_status_str(m.status),
                    media: m.media_type.map(media_type_str),
                    caption: m.media_caption.as_deref(),
                    downloaded: media_path.is_some(),
                    media_path,
                    thumb,
                    file_size: m.media_file_length,
                    mimetype: m.media_mimetype.as_deref(),
                    reply_to: m.reply_to.as_deref(),
                    edited: m.edited,
                    starred: m.starred,
                    gif_playback: m.gif_playback,
                    contacts: &m.contacts,
                    view_once: m.view_once,
                    view_once_opened: m.view_once_opened,
                    poll: m.poll.as_ref().map(|p| PollJson {
                        question: &p.question,
                        options: &p.options,
                        selectable: p.selectable_count,
                        quiz: p.is_quiz,
                        voters: p.total_voters(),
                        mine: p.my_vote(&me),
                        tallies: p
                            .tallies()
                            .into_iter()
                            .map(|(option, votes)| PollTallyJson { option, votes })
                            .collect(),
                    }),
                    reactions,
                });
            }
        }
    }

    let presence: Vec<PresenceJson> = s
        .contacts
        .values()
        .filter(|c| c.is_online || c.last_seen.is_some())
        .map(|c| PresenceJson {
            jid: c.jid.to_string(),
            online: c.is_online,
            last_seen: c.last_seen.map(|t| t.to_rfc3339()),
        })
        .collect();

    let scheduled: Vec<ScheduledJson<'_>> = s
        .scheduled_messages
        .iter()
        .filter(|m| {
            !matches!(
                m.status,
                ScheduledStatus::Sent | ScheduledStatus::Cancelled
            )
        })
        .map(|m| ScheduledJson {
            id: &m.id,
            chat: m.chat_jid.to_string(),
            text: &m.text,
            at: m.scheduled_for.to_rfc3339(),
            status: format!("{:?}", m.status).to_lowercase(),
        })
        .collect();

    let connection = match &s.connection {
        ConnectionStatus::Disconnected => ConnectionJson {
            kind: "disconnected",
            detail: None,
        },
        ConnectionStatus::Connecting => ConnectionJson {
            kind: "connecting",
            detail: None,
        },
        ConnectionStatus::QrCode(code) => ConnectionJson {
            kind: "qr",
            detail: Some(ConnectionDetailJson::Str(code)),
        },
        ConnectionStatus::PairCode(code) => ConnectionJson {
            kind: "pair",
            detail: Some(ConnectionDetailJson::Str(code)),
        },
        ConnectionStatus::Connected => ConnectionJson {
            kind: "connected",
            detail: None,
        },
        ConnectionStatus::Syncing(pct) => ConnectionJson {
            kind: "syncing",
            detail: Some(ConnectionDetailJson::Pct(*pct)),
        },
        ConnectionStatus::Error(err) => ConnectionJson {
            kind: "error",
            detail: Some(ConnectionDetailJson::Str(err)),
        },
    };

    let call = s.active_call.as_ref().map(|c| {
        let (status, reason) = match &c.status {
            CallStatus::Incoming => ("incoming", None),
            CallStatus::OutgoingRinging => ("ringing", None),
            CallStatus::Connected => ("connected", None),
            CallStatus::Ended(r) => ("ended", Some(r.as_str())),
        };
        CallJson {
            id: &c.call_id,
            peer_jid: c.peer_jid.to_string(),
            peer_name: &c.peer_name,
            peer_avatar: avatar_path_cached(&c.peer_jid),
            is_video: c.is_video,
            is_group: c.is_group,
            status,
            reason,
            muted: c.is_muted,
            video_enabled: c.is_video_enabled,
            started_at: c.started_at.timestamp_millis(),
            connected_at: c.connected_at.map(|t| t.timestamp_millis()),
        }
    });

    let playing_id = crate::audio::playing_id();
    let audio = playing_id.map(|id| AudioJson {
        playing_id: id,
        paused: crate::audio::is_paused(),
        pos_ms: crate::audio::position().as_millis() as u64,
        dur_ms: crate::audio::duration().map(|d| d.as_millis() as u64),
    });

    let update = UpdateJson {
        current: crate::updater::CURRENT_VERSION,
        status: s.update_status.label(),
        busy: s.update_status.is_busy(),
        available: s.update_available.as_ref().map(|u| UpdateAvailJson {
            version: &u.version,
            tag: &u.tag,
            page_url: &u.page_url,
            notes: &u.notes,
            has_asset: u.has_asset(),
        }),
    };

    let selected_total_messages = s
        .selected_chat
        .as_ref()
        .and_then(|j| s.get_chat_messages(j))
        .map_or(0, |m| m.len());

    let contacts: Vec<ContactJson<'_>> = s
        .contacts
        .values()
        .filter_map(|c| {
            let name = c
                .name
                .as_deref()
                .or(c.push_name.as_deref())
                .or(c.verified_name.as_deref())
                .unwrap_or("");
            if name.is_empty() && !c.is_blocked {
                return None;
            }
            Some(ContactJson {
                jid: c.jid.to_string(),
                name,
                blocked: c.is_blocked,
                business: c.is_business,
                verified_name: c.verified_name.as_deref(),
                avatar: avatar_path_cached(&c.jid.to_non_ad()),
            })
        })
        .collect();

    let snap = SnapshotJson {
        kind: "snapshot",
        self_jid: s.self_jid.as_ref().map(|j| j.to_string()),
        self_name: s.self_name.as_deref(),
        self_status: s.self_status.as_deref(),
        self_avatar: s.self_jid.as_ref().and_then(|j| avatar_path_cached(&j.to_non_ad())),
        avatar_rev: crate::avatars::revision(),
        connection,
        selected: s.selected_chat.as_ref().map(|j| j.to_string()),
        selected_total_messages,
        history_syncing: s
            .history_syncing_chats
            .iter()
            .map(|j| j.to_string())
            .collect(),
        history_exhausted: s
            .history_exhausted_chats
            .iter()
            .map(|j| j.to_string())
            .collect(),
        search: &s.search_query,
        chats,
        archived,
        group,
        pinned_message,
        ephemeral,
        scheduled,
        presence,
        prefs: prefs_json(&s),
        messages,
        call,
        audio,
        stickers: sticker_paths_cached(),
        update,
        contacts,
    };
    serde_json::to_string(&snap).unwrap_or_else(|_| "{}".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::{AppState, Chat, PinnedMessage};

    #[test]
    fn base64_encodes_bytes_with_padding() {
        assert_eq!(encode_base64(b""), "");
        assert_eq!(encode_base64(b"f"), "Zg==");
        assert_eq!(encode_base64(b"fo"), "Zm8=");
        assert_eq!(encode_base64(b"foo"), "Zm9v");
        assert_eq!(encode_base64(b"foobar"), "Zm9vYmFy");
    }

    #[test]
    fn snapshot_includes_pinned_message_ephemeral_and_extended_prefs() {
        let mut s = AppState::default();
        let jid: Jid = "420111222333@s.whatsapp.net".parse().unwrap();
        s.chats.insert(
            jid.clone(),
            Chat {
                jid: jid.clone(),
                name: "Alice".to_string(),
                last_message: None,
                unread_count: 1,
                is_group: false,
                is_archived: false,
                is_pinned: true,
                mute_until: None,
                last_activity: chrono::Utc::now(),
                participants: Default::default(),
                is_typing: false,
                typing_until: None,
            },
        );
        s.selected_chat = Some(jid.clone());
        s.pinned
            .insert(jid.clone(), PinnedMessage::new("MSG1", Some(3600), None));
        s.ephemeral.insert(jid.clone(), 86400);
        s.drafts.insert(jid.clone(), "rozpsaný".to_string());
        s.preferences.dark_theme_preset = 2;
        s.preferences.language = crate::i18n::Language::En;

        let shared: SharedState = Arc::new(RwLock::new(s));
        let parsed: Value = serde_json::from_str(&snapshot(&shared)).unwrap();

        assert_eq!(parsed["pinned_message"]["id"], "MSG1");
        assert_eq!(parsed["ephemeral"], 86400);
        assert_eq!(parsed["chats"][0]["draft"], "rozpsaný");
        assert_eq!(parsed["prefs"]["dark_theme_preset"], 2);
        assert_eq!(parsed["prefs"]["language"], "en");
    }

    #[test]
    fn gallery_scans_all_loaded_messages_beyond_snapshot_window() {
        use crate::state::{MediaType, Message, MessageStatus};

        let mut s = AppState::default();
        let jid: Jid = "420111222333@s.whatsapp.net".parse().unwrap();
        s.chats.insert(
            jid.clone(),
            Chat {
                jid: jid.clone(),
                name: "Bob".to_string(),
                last_message: None,
                unread_count: 0,
                is_group: false,
                is_archived: false,
                is_pinned: false,
                mute_until: None,
                last_activity: chrono::Utc::now(),
                participants: Default::default(),
                is_typing: false,
                typing_until: None,
            },
        );
        s.selected_chat = Some(jid.clone());

        let mut old_img = Message::new_text(
            "OLD_IMG".to_string(),
            jid.clone(),
            jid.clone(),
            "".to_string(),
            chrono::Utc::now() - chrono::Duration::days(10),
            false,
            MessageStatus::Read,
            None,
            None,
        );
        old_img.media_type = Some(MediaType::Image);

        let mut old_doc = Message::new_text(
            "OLD_DOC".to_string(),
            jid.clone(),
            jid.clone(),
            "faktura.pdf".to_string(),
            chrono::Utc::now() - chrono::Duration::days(9),
            false,
            MessageStatus::Read,
            None,
            None,
        );
        old_doc.media_type = Some(MediaType::Document);

        let old_link = Message::new_text(
            "OLD_LINK".to_string(),
            jid.clone(),
            jid.clone(),
            "Koukni na https://example.com/spec".to_string(),
            chrono::Utc::now() - chrono::Duration::days(8),
            false,
            MessageStatus::Read,
            None,
            None,
        );

        let mut msgs = vec![old_img, old_doc, old_link];
        for i in 0..250 {
            msgs.push(Message::new_text(
                format!("M{i}"),
                jid.clone(),
                jid.clone(),
                format!("Zprava {i}"),
                chrono::Utc::now() - chrono::Duration::minutes(250 - i),
                false,
                MessageStatus::Read,
                None,
                None,
            ));
        }
        s.messages.insert(jid.clone(), msgs);

        let gallery = compute_chat_gallery_json(&s, &jid);
        assert_eq!(gallery["total_messages"], 253);
        assert_eq!(gallery["media"].as_array().unwrap().len(), 1);
        assert_eq!(gallery["media"][0]["id"], "OLD_IMG");
        assert_eq!(gallery["docs"].as_array().unwrap().len(), 1);
        assert_eq!(gallery["docs"][0]["id"], "OLD_DOC");
        assert_eq!(gallery["links"].as_array().unwrap().len(), 1);
        assert_eq!(gallery["links"][0]["url"], "https://example.com/spec");

        s.self_status = Some("V práci (Dunder Mifflin)".to_string());
        let snap: Value = serde_json::from_str(&snapshot(&Arc::new(RwLock::new(s)))).unwrap();
        assert_eq!(snap["selected_total_messages"], 253);
        assert_eq!(snap["messages"].as_array().unwrap().len(), 200);
        assert_eq!(snap["self_status"], "V práci (Dunder Mifflin)");
        assert!(snap["avatar_rev"].as_u64().unwrap() >= 1);
    }

    #[test]
    fn select_none_clears_selected_chat_and_start_chat_canonicalizes_dirty() {
        let mut s = AppState::default();
        let lid: Jid = "999888777@lid".parse().unwrap();
        let pn: Jid = "420555111222@s.whatsapp.net".parse().unwrap();
        s.lid_to_pn.insert(lid.clone(), pn.clone());
        s.selected_chat = Some(pn.clone());
        s.dirty = false;

        let shared: SharedState = Arc::new(RwLock::new(s));
        let (tx_command, mut rx_command) = tokio::sync::mpsc::unbounded_channel();
        let (_tx_status, rx_status) = tokio::sync::watch::channel(ConnectionStatus::Disconnected);
        let backend = Arc::new(BackendHandle {
            tx_command,
            rx_status,
            state: shared.clone(),
            bot_handle: Arc::new(tokio::sync::Mutex::new(None)),
        });
        let (reply_tx, _reply_rx) = tokio::sync::mpsc::unbounded_channel();
        let snap_notify = Arc::new(Notify::new());

        handle_command(
            r#"{"type":"select","chat":null}"#,
            &backend,
            &reply_tx,
            &snap_notify,
        );
        assert!(shared.read().selected_chat.is_none());
        assert!(matches!(
            rx_command.try_recv(),
            Ok(Command::SelectChat { chat_jid: None })
        ));

        handle_command(
            r#"{"type":"start_chat","phone":"999888777@lid"}"#,
            &backend,
            &reply_tx,
            &snap_notify,
        );
        {
            let guard = shared.read();
            assert_eq!(guard.selected_chat.as_ref(), Some(&pn));
            assert!(guard.chats.contains_key(&pn));
            assert!(guard.dirty);
        }
        assert!(matches!(
            rx_command.try_recv(),
            Ok(Command::SelectChat { chat_jid: Some(j) }) if j == pn
        ));
    }

    #[test]
    fn sticker_paths_cached_records_revision_even_when_empty() {
        let rev = crate::media::MEDIA_REV.load(Ordering::Relaxed);
        let _ = sticker_paths_cached();
        assert_eq!(STICKER_CACHE.lock().0, Some(rev));
    }
}
