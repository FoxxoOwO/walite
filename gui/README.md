# Warust — Flutter GUI

Flutter front end for Warust. It renders no WhatsApp logic of its own: the Rust
binary runs the backend and exposes it over a local WebSocket
(`src/ws_bridge.rs`), and this app is a client of that socket.

## Run

```sh
# terminal 1 — backend + WS bridge on 127.0.0.1:8787
cargo run -- --ui ws

# terminal 2 — UI
cd gui
flutter run -d windows      # or: flutter run -d chrome
```

The app reconnects on its own, so the order does not matter. `--port N` changes
the port; then set `_port` in `lib/main.dart` to match.

## Protocol

Server → client, on every change and once on connect:

```json
{"type":"snapshot","self":"…","self_name":"…",
 "connection":{"kind":"connected","detail":null},
 "selected":"<jid>","search":"",
 "chats":[{"jid":"…","name":"…","unread":0,"group":false,"pinned":false,
           "muted":false,"typing":false,
           "last":{"text":"…","ts":1700000000000,"from_me":false,"status":"sent"}}],
 "messages":[{"id":"…","chat":"…","sender":"…","text":"…","ts":0,
              "from_me":false,"status":"sent","media":null}]}
```

Client → server: `{"type":"select","chat":"<jid>"}`,
`{"type":"send","chat":"<jid>","text":"…"}`, `{"type":"search","q":"…"}`.

`connection.kind` is one of `disconnected`, `connecting`, `qr`, `pair`,
`connected`, `syncing`, `error`; for `qr`/`pair` the payload is in `detail`.
