//! WebSocket bridge for non-Rust front ends (the Flutter client in `gui/`).
//!
//! One JSON snapshot stream out, three commands in. The bridge owns the same
//! backend the egui window would use, so nothing about WhatsApp handling is
//! duplicated on the UI side.

use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result};
use futures::{SinkExt, StreamExt};
use parking_lot::{Mutex, RwLock};
use serde_json::{json, Value};
use tokio::net::{TcpListener, TcpStream};
use tokio_tungstenite::tungstenite::Message as WsMessage;
use whatsapp_rust::wacore_binary::Jid;

use crate::backend::BackendHandle;
use crate::commands::Command;
use crate::state::{ConnectionStatus, ScheduledStatus, SharedState};

type Clients = Arc<Mutex<HashMap<usize, tokio::sync::mpsc::UnboundedSender<String>>>>;

/// How many messages of the selected chat travel in one snapshot. Enough for a
/// scrollback that feels real, small enough that the 200 ms diff stays cheap.
const MESSAGE_WINDOW: usize = 200;

/// Raised by the `more` command as the user scrolls back; capped because every
/// snapshot re-serialises the whole window.
static MESSAGE_LIMIT: AtomicUsize = AtomicUsize::new(MESSAGE_WINDOW);
const MAX_MESSAGE_LIMIT: usize = 5000;

pub async fn run(port: u16) -> Result<()> {
    let loaded = crate::storage::load_state().await.unwrap_or_default();
    crate::i18n::set_language(loaded.preferences.language);
    let state: SharedState = Arc::new(RwLock::new(loaded));
    let backend = Arc::new(crate::backend::spawn_backend(state.clone()).await?);

    let listener = TcpListener::bind(("127.0.0.1", port))
        .await
        .with_context(|| format!("bridge cannot bind 127.0.0.1:{port}"))?;
    let bound = listener.local_addr()?.port();
    // The Flutter app reads this line; keep the prefix stable.
    println!("WARUST_BRIDGE ws://127.0.0.1:{bound}");
    tracing::info!("WS bridge listening on 127.0.0.1:{bound}");

    let clients: Clients = Arc::new(Mutex::new(HashMap::new()));

    {
        let clients = clients.clone();
        let state = state.clone();
        tokio::spawn(async move {
            let mut last = String::new();
            loop {
                tokio::time::sleep(Duration::from_millis(200)).await;
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

    let next_id = AtomicUsize::new(0);
    loop {
        let (stream, _) = listener.accept().await?;
        let id = next_id.fetch_add(1, Ordering::Relaxed);
        tokio::spawn(handle_conn(
            stream,
            id,
            clients.clone(),
            backend.clone(),
        ));
    }
}

async fn handle_conn(stream: TcpStream, id: usize, clients: Clients, backend: Arc<BackendHandle>) {
    let ws = match tokio_tungstenite::accept_async(stream).await {
        Ok(ws) => ws,
        Err(err) => {
            tracing::warn!("bridge handshake failed: {err}");
            return;
        }
    };
    let (mut sink, mut inbox) = ws.split();
    let (out_tx, mut out_rx) = tokio::sync::mpsc::unbounded_channel::<String>();
    clients.lock().insert(id, out_tx);
    // A client joining between changes would otherwise wait for the next one,
    // which may never come; hand it the current state straight away.
    {
        let map = clients.lock();
        if let Some(tx) = map.get(&id) {
            let _ = tx.send(snapshot(&backend.state));
        }
    }

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
                Some(Ok(WsMessage::Text(text))) => handle_command(text.as_str(), &backend),
                Some(Ok(WsMessage::Close(_))) | None => break,
                Some(Ok(_)) => {}
                Some(Err(err)) => {
                    tracing::debug!("bridge socket error: {err}");
                    break;
                }
            },
        }
    }

    clients.lock().remove(&id);
    tracing::info!("bridge client {id} left");
}

fn handle_command(raw: &str, backend: &BackendHandle) {
    let Ok(value) = serde_json::from_str::<Value>(raw) else {
        return;
    };
    match value["type"].as_str() {
        Some("select") => {
            let jid = value["chat"].as_str().and_then(|s| s.parse::<Jid>().ok());
            let _ = backend.send_command(Command::select_chat(jid));
        }
        Some("send") => {
            if let (Some(chat), Some(text)) = (value["chat"].as_str(), value["text"].as_str()) {
                if let Ok(jid) = chat.parse::<Jid>() {
                    let _ = backend.send_command(Command::SendText {
                        to: jid,
                        text: text.to_string(),
                        reply_to: value["reply"].as_str().map(str::to_string),
                        mentioned_jid: Vec::new(),
                    });
                }
            }
        }
        Some("edit") => {
            if let (Some(jid), Some(id), Some(text)) = (jid_field(&value, "chat"), id_field(&value), value["text"].as_str()) {
                let _ = backend.send_command(Command::EditText {
                    to: jid,
                    message_id: id,
                    text: text.to_string(),
                });
            }
        }
        Some("react") => {
            if let (Some(jid), Some(id), Some(emoji)) = (jid_field(&value, "chat"), id_field(&value), value["emoji"].as_str()) {
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
                let _ = backend.send_command(Command::SendMedia {
                    chat_jid: chat,
                    file_path: std::path::PathBuf::from(path),
                    caption: value["caption"].as_str().map(str::to_string),
                    reply_to: value["reply_to"].as_str().map(str::to_string),
                    view_once: value["view_once"].as_bool().unwrap_or(false),
                });
            }
        }
        // Voice notes: the bridge runs on the same machine as the GUI, so the
        // desktop recorder captures from the same microphone and encodes OGG/Opus.
        Some("record_start") => {
            if let Err(err) = crate::recorder::start() {
                tracing::warn!("bridge could not start recording: {err}");
            }
        }
        Some("record_stop") => {
            if let Some(chat) = jid_field(&value, "chat") {
                // shortcut: the encode blocks this socket for a moment, fine at mic length
                match crate::recorder::finish() {
                    Ok(rec) => {
                        let _ = backend.send_command(Command::SendVoiceNote {
                            chat_jid: chat,
                            file_path: rec.path,
                            duration_seconds: (rec.duration_ms / 1000).max(1) as u32,
                            waveform: rec.waveform,
                        });
                    }
                    Err(err) => tracing::warn!("bridge could not finish recording: {err}"),
                }
            }
        }
        Some("record_cancel") => crate::recorder::cancel(),
        Some("more") => {
            // Two halves of one gesture: ask the phone for older messages, then
            // let the next snapshot carry them (the desktop does the same).
            let step = value["count"].as_u64().unwrap_or(MESSAGE_WINDOW as u64) as usize;
            let grown = (MESSAGE_LIMIT.load(Ordering::Relaxed) + step).min(MAX_MESSAGE_LIMIT);
            MESSAGE_LIMIT.store(grown, Ordering::Relaxed);
            let _ = backend.send_command(Command::RequestHistorySync {
                chat_jid: jid_field(&value, "chat"),
                count: step.min(u32::MAX as usize) as u32,
            });
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
            // Only own messages are revocable here, so `Sender` is always right.
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
        Some("view_once") => {
            if let (Some(jid), Some(id)) = (jid_field(&value, "chat"), id_field(&value)) {
                let _ = backend.send_command(Command::OpenViewOnce {
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
            // `hours` absent = muted forever, which is what the desktop UI offers too.
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
        Some("search") => {
            let query = value["q"].as_str().unwrap_or_default().to_string();
            let _ = backend.send_command(Command::search(query));
        }
        _ => {}
    }
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

fn snapshot(state: &SharedState) -> String {
    let s = state.read();

    let chat_row = |chat: &crate::state::Chat| -> Value {
        let last = chat.last_message.as_ref().map(|m| {
                json!({
                    "text": m.text,
                    "ts": m.timestamp.timestamp_millis(),
                    "from_me": m.from_me,
                    "status": format!("{:?}", m.status).to_lowercase(),
                })
            });
        json!({
            "jid": chat.jid.to_string(),
            "name": chat.name,
            "unread": chat.unread_count,
            "group": chat.is_group,
            "pinned": chat.is_pinned,
            "archived": chat.is_archived,
            "muted": chat.is_muted(),
            "typing": chat.is_currently_typing(),
            "last": last,
        })
    };
    let chats: Vec<Value> = s.filtered_chats().into_iter().map(chat_row).collect();
    let archived: Vec<Value> = s.archived_chats().into_iter().map(chat_row).collect();

    // Only the selected group: the dialog needs one group at a time and every
    // snapshot re-serialises in full. `group_info` is empty until the GUI asks.
    let group = s.selected_chat.as_ref().and_then(|jid| {
        let chat = s.chats.get(jid)?;
        if !chat.is_group {
            return None;
        }
        let info = s.group_info.get(&jid.to_string());
        Some(json!({
            "subject": info.map(|i| i.subject.clone()).unwrap_or_else(|| chat.name.clone()),
            "description": info.and_then(|i| i.description.clone()),
            "admins": info
                .map(|i| i.admins.iter().map(|j| j.to_string()).collect::<Vec<_>>())
                .unwrap_or_default(),
            "locked": info.map(|i| i.is_locked).unwrap_or(false),
            "announcement": info.map(|i| i.is_announcement).unwrap_or(false),
            "invite_link": info.and_then(|i| i.invite_link.clone()),
            "ephemeral": s.ephemeral.get(jid).copied(),
            "participants": chat.participants.iter().map(|j| j.to_string()).collect::<Vec<_>>(),
        }))
    });

    let mut messages: Vec<Value> = Vec::new();
    if let Some(selected) = s.selected_chat.as_ref() {
        if let Some(list) = s.get_chat_messages(selected) {
            let window = MESSAGE_LIMIT.load(Ordering::Relaxed);
            for m in list.iter().skip(list.len().saturating_sub(window)) {
                let reactions: Vec<Value> = m
                    .reactions
                    .iter()
                    .map(|r| json!({"emoji": r.emoji, "sender": r.sender.to_string()}))
                    .collect();
                messages.push(json!({
                    "id": m.id,
                    "chat": m.chat_jid.to_string(),
                    "sender": m.sender_jid.to_string(),
                    "text": m.text,
                    "ts": m.timestamp.timestamp_millis(),
                    "from_me": m.from_me,
                    "status": format!("{:?}", m.status).to_lowercase(),
                    "media": m.media_type.as_ref().map(|t| format!("{t:?}").to_lowercase()),
                    "caption": m.media_caption,
                    "downloaded": m.media_path.is_some(),
                    "reply_to": m.reply_to,
                    "edited": m.edited,
                    "view_once": m.view_once,
                    "reactions": reactions,
                }));
            }
        }
    }

    // Only what the user can still act on: sent and cancelled entries stay in
    // state forever, so shipping them would grow every snapshot.
    // Only contacts we actually know something about, so the snapshot stays small.
    let presence: Vec<Value> = s
        .contacts
        .values()
        .filter(|c| c.is_online || c.last_seen.is_some())
        .map(|c| {
            json!({
                "jid": c.jid.to_string(),
                "online": c.is_online,
                "last_seen": c.last_seen.map(|t| t.to_rfc3339()),
            })
        })
        .collect();

    let scheduled: Vec<Value> = s
        .scheduled_messages
        .iter()
        .filter(|m| {
            !matches!(
                m.status,
                ScheduledStatus::Sent | ScheduledStatus::Cancelled
            )
        })
        .map(|m| {
            json!({
                "id": m.id,
                "chat": m.chat_jid.to_string(),
                "text": m.text,
                "at": m.scheduled_for.to_rfc3339(),
                "status": format!("{:?}", m.status).to_lowercase(),
            })
        })
        .collect();

    let connection = match &s.connection {
        ConnectionStatus::Disconnected => json!({"kind": "disconnected"}),
        ConnectionStatus::Connecting => json!({"kind": "connecting"}),
        ConnectionStatus::QrCode(code) => json!({"kind": "qr", "detail": code}),
        ConnectionStatus::PairCode(code) => json!({"kind": "pair", "detail": code}),
        ConnectionStatus::Connected => json!({"kind": "connected"}),
        ConnectionStatus::Syncing(pct) => json!({"kind": "syncing", "detail": pct}),
        ConnectionStatus::Error(err) => json!({"kind": "error", "detail": err}),
    };

    json!({
        "type": "snapshot",
        "self": s.self_jid.as_ref().map(|j| j.to_string()),
        "self_name": s.self_name,
        "connection": connection,
        "selected": s.selected_chat.as_ref().map(|j| j.to_string()),
        "search": s.search_query,
        "chats": chats,
        "archived": archived,
        "group": group,
        "scheduled": scheduled,
        "presence": presence,
        "messages": messages,
        "contacts": s
            .contacts
            .values()
            .filter_map(|c| {
                let name = c.name.clone().or_else(|| c.push_name.clone()).or_else(|| c.verified_name.clone())?;
                Some(json!({"jid": c.jid.to_string(), "name": name}))
            })
            .collect::<Vec<Value>>(),
    })
    .to_string()
}
