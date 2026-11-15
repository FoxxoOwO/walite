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
use crate::state::{ConnectionStatus, SharedState};

type Clients = Arc<Mutex<HashMap<usize, tokio::sync::mpsc::UnboundedSender<String>>>>;

/// How many messages of the selected chat travel in one snapshot. Enough for a
/// scrollback that feels real, small enough that the 200 ms diff stays cheap.
const MESSAGE_WINDOW: usize = 200;

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
                    let _ = backend.send_command(Command::send_text(jid, text.to_string()));
                }
            }
        }
        Some("search") => {
            let query = value["q"].as_str().unwrap_or_default().to_string();
            let _ = backend.send_command(Command::search(query));
        }
        _ => {}
    }
}

fn snapshot(state: &SharedState) -> String {
    let s = state.read();

    let chats: Vec<Value> = s
        .filtered_chats()
        .into_iter()
        .map(|chat| {
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
                "muted": chat.is_muted(),
                "typing": chat.is_currently_typing(),
                "last": last,
            })
        })
        .collect();

    let mut messages: Vec<Value> = Vec::new();
    if let Some(selected) = s.selected_chat.as_ref() {
        if let Some(list) = s.get_chat_messages(selected) {
            for m in list.iter().skip(list.len().saturating_sub(MESSAGE_WINDOW)) {
                messages.push(json!({
                    "id": m.id,
                    "chat": m.chat_jid.to_string(),
                    "sender": m.sender_jid.to_string(),
                    "text": m.text,
                    "ts": m.timestamp.timestamp_millis(),
                    "from_me": m.from_me,
                    "status": format!("{:?}", m.status).to_lowercase(),
                    "media": m.media_type.as_ref().map(|t| format!("{t:?}").to_lowercase()),
                }));
            }
        }
    }

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
        "messages": messages,
    })
    .to_string()
}
