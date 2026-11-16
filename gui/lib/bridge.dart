import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

/// One chat row from the Rust backend's snapshot.
class ChatItem {
  ChatItem({
    required this.jid,
    required this.name,
    this.last,
    this.unread = 0,
    this.pinned = false,
    this.archived = false,
    this.muted = false,
    this.typing = false,
  });

  final String jid;
  final String name;
  final LastMessage? last;
  final int unread;
  final bool pinned;
  final bool archived;
  final bool muted;
  final bool typing;

  factory ChatItem.fromJson(Map<String, dynamic> json) => ChatItem(
        jid: json['jid'] as String,
        name: json['name'] as String? ?? '',
        unread: json['unread'] as int? ?? 0,
        pinned: json['pinned'] as bool? ?? false,
        archived: json['archived'] as bool? ?? false,
        muted: json['muted'] as bool? ?? false,
        typing: json['typing'] as bool? ?? false,
        last: json['last'] == null
            ? null
            : LastMessage.fromJson(json['last'] as Map<String, dynamic>),
      );
}

class LastMessage {
  LastMessage(this.text, this.ts, this.fromMe);

  final String text;
  final int ts;
  final bool fromMe;

  factory LastMessage.fromJson(Map<String, dynamic> json) => LastMessage(
        json['text'] as String? ?? '',
        json['ts'] as int? ?? 0,
        json['from_me'] as bool? ?? false,
      );
}

class Msg {
  Msg({
    required this.id,
    required this.text,
    required this.ts,
    required this.fromMe,
    required this.sender,
    this.media,
    this.caption,
    this.downloaded = false,
    this.replyTo,
    this.edited = false,
    this.viewOnce = false,
    this.reactions = const [],
  });

  final String id;
  final String text;
  final int ts;
  final bool fromMe;
  final String sender;
  final String? media;
  final String? caption;
  final bool downloaded;
  final String? replyTo;
  final bool edited;
  final bool viewOnce;

  /// Emoji only; the same emoji from several people appears once.
  final List<String> reactions;

  factory Msg.fromJson(Map<String, dynamic> json) => Msg(
        id: json['id'] as String? ?? '',
        text: json['text'] as String? ?? '',
        ts: json['ts'] as int? ?? 0,
        fromMe: json['from_me'] as bool? ?? false,
        sender: json['sender'] as String? ?? '',
        media: json['media'] as String?,
        caption: json['caption'] as String?,
        downloaded: json['downloaded'] as bool? ?? false,
        replyTo: json['reply_to'] as String?,
        edited: json['edited'] as bool? ?? false,
        viewOnce: json['view_once'] as bool? ?? false,
        reactions: ((json['reactions'] as List<dynamic>? ?? const [])
                .map((e) => (e as Map<String, dynamic>)['emoji'] as String?)
                .whereType<String>())
            .toSet()
            .toList(),
      );
}

/// Group details for the selected chat, filled by [Bridge.requestGroupInfo].
class GroupInfo {
  GroupInfo({
    required this.subject,
    this.description,
    this.admins = const [],
    this.locked = false,
    this.announcement = false,
    this.inviteLink,
    this.ephemeral,
    this.participants = const [],
  });

  final String subject;
  final String? description;
  final List<String> admins;
  final bool locked;
  final bool announcement;
  final String? inviteLink;

  /// Disappearing-message timer in seconds, null when the chat has none.
  final int? ephemeral;
  final List<String> participants;

  bool isAdmin(String? jid) => jid != null && admins.contains(jid);

  factory GroupInfo.fromJson(Map<String, dynamic> json) => GroupInfo(
        subject: json['subject'] as String? ?? '',
        description: json['description'] as String?,
        admins: (json['admins'] as List<dynamic>? ?? const []).cast<String>(),
        locked: json['locked'] as bool? ?? false,
        announcement: json['announcement'] as bool? ?? false,
        inviteLink: json['invite_link'] as String?,
        ephemeral: json['ephemeral'] as int?,
        participants: (json['participants'] as List<dynamic>? ?? const [])
            .cast<String>(),
      );
}

/// Everything the backend pushes, already decoded.
/// A message queued for later. `status` is `pending` or `failed`; sent and
/// cancelled entries never leave the backend.
class Scheduled {
  Scheduled({
    required this.id,
    required this.chat,
    required this.text,
    required this.at,
    this.status = 'pending',
  });

  final String id;
  final String chat;
  final String text;
  final DateTime at;
  final String status;

  factory Scheduled.fromJson(Map<String, dynamic> json) => Scheduled(
        id: json['id'] as String,
        chat: json['chat'] as String? ?? '',
        text: json['text'] as String? ?? '',
        at: DateTime.tryParse(json['at'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        status: json['status'] as String? ?? 'pending',
      );
}

class Snapshot {
  Snapshot({
    required this.connection,
    required this.detail,
    required this.selected,
    required this.chats,
    required this.messages,
    this.self,
    this.group,
    this.archived = const [],
    this.scheduled = const [],
    this.contacts = const {},
  });

  final String connection;
  final String? detail;
  final String? selected;

  /// This account's own JID, needed to tell whether we are a group admin.
  final String? self;
  final List<ChatItem> chats;

  /// Details of the selected chat when it is a group.
  final GroupInfo? group;

  /// Archived chats: hidden from [chats] by the backend, shown in their own
  /// section so unarchiving stays possible.
  final List<ChatItem> archived;

  /// Queued messages the backend has not sent yet (or failed to send).
  final List<Scheduled> scheduled;
  final List<Msg> messages;

  /// JID → display name, so group bubbles can show who wrote what.
  final Map<String, String> contacts;

  factory Snapshot.fromJson(Map<String, dynamic> json) {
    final conn = json['connection'] as Map<String, dynamic>? ?? const {};
    return Snapshot(
      connection: conn['kind'] as String? ?? 'disconnected',
      detail: conn['detail']?.toString(),
      selected: json['selected'] as String?,
      self: json['self'] as String?,
      group: json['group'] == null
          ? null
          : GroupInfo.fromJson(json['group'] as Map<String, dynamic>),
      chats: (json['chats'] as List<dynamic>? ?? const [])
          .map((e) => ChatItem.fromJson(e as Map<String, dynamic>))
          .toList(),
      archived: (json['archived'] as List<dynamic>? ?? const [])
          .map((e) => ChatItem.fromJson(e as Map<String, dynamic>))
          .toList(),
      scheduled: (json['scheduled'] as List<dynamic>? ?? const [])
          .map((e) => Scheduled.fromJson(e as Map<String, dynamic>))
          .toList(),
      messages: (json['messages'] as List<dynamic>? ?? const [])
          .map((e) => Msg.fromJson(e as Map<String, dynamic>))
          .toList(),
      contacts: {
        for (final c in json['contacts'] as List<dynamic>? ?? const [])
          (c as Map<String, dynamic>)['jid'] as String:
              c['name'] as String? ?? '',
      },
    );
  }

  ChatItem? chat(String? jid) {
    if (jid == null) return null;
    for (final c in chats) {
      if (c.jid == jid) return c;
    }
    return null;
  }

  Msg? message(String? id) {
    if (id == null) return null;
    for (final m in messages) {
      if (m.id == id) return m;
    }
    return null;
  }
}

/// Client for `warust --ui ws`: reconnects on its own, so the app can be
/// started before the backend.
class Bridge {
  Bridge(this.port);

  final int port;

  final _snapshots = StreamController<Snapshot>.broadcast();
  final _link = StreamController<bool>.broadcast();
  Timer? _retry;
  WebSocketChannel? _channel;
  bool _connecting = false;

  Stream<Snapshot> get snapshots => _snapshots.stream;

  /// Emits true while the socket is open.
  Stream<bool> get link => _link.stream;

  void connect() {
    if (_connecting) return;
    _connecting = true;
    try {
      final channel = WebSocketChannel.connect(Uri.parse('ws://127.0.0.1:$port'));
      _channel = channel;
      _link.add(true);
      channel.stream.listen(
        (frame) {
          final decoded = jsonDecode(frame as String);
          if (decoded is Map<String, dynamic> && decoded['type'] == 'snapshot') {
            _snapshots.add(Snapshot.fromJson(decoded));
          }
        },
        onDone: _lost,
        onError: (_) => _lost(),
      );
    } catch (_) {
      _lost();
    }
  }

  void _lost() {
    _connecting = false;
    _channel = null;
    _link.add(false);
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 1), connect);
  }

  void _send(Map<String, Object?> message) {
    _channel?.sink.add(jsonEncode(message));
  }

  void select(String jid) => _send({'type': 'select', 'chat': jid});

  void sendText(String jid, String text, {String? reply}) => _send({
        'type': 'send',
        'chat': jid,
        'text': text,
        if (reply != null) 'reply': reply,
      });

  void search(String query) => _send({'type': 'search', 'q': query});

  /// Actions the egui client has: edit, react, delete, download, mark read.
  void edit(String chat, String id, String text) =>
      _send({'type': 'edit', 'chat': chat, 'id': id, 'text': text});

  void react(String chat, String id, String emoji) =>
      _send({'type': 'react', 'chat': chat, 'id': id, 'emoji': emoji});

  void deleteMessage(String chat, String id) =>
      _send({'type': 'delete', 'chat': chat, 'id': id});

  void download(String chat, String id) =>
      _send({'type': 'download', 'chat': chat, 'id': id});

  void markRead(String chat) => _send({'type': 'read', 'chat': chat});

  /// Grows the snapshot window and asks the phone for older messages.
  void more(String chat) => _send({'type': 'more', 'chat': chat});

  /// [path] is local to the machine running the bridge.
  void sendMedia(String chat, String path,
          {String? caption, String? replyTo, bool viewOnce = false}) =>
      _send({
        'type': 'send_media',
        'chat': chat,
        'path': path,
        if (caption != null && caption.isNotEmpty) 'caption': caption,
        if (replyTo != null) 'reply_to': replyTo,
        if (viewOnce) 'view_once': true,
      });

  /// Records from the microphone of the machine running the bridge.
  void recordStart() => _send({'type': 'record_start'});

  void recordStop(String chat) =>
      _send({'type': 'record_stop', 'chat': chat});

  void recordCancel() => _send({'type': 'record_cancel'});

  void forward(String from, String to, List<String> ids) =>
      _send({'type': 'forward', 'from': from, 'to': to, 'ids': ids});

  /// Delete for everyone. Only own messages can be revoked.
  void revoke(String chat, String id) =>
      _send({'type': 'revoke', 'chat': chat, 'id': id});

  void pinMessage(String chat, String id, {int? seconds}) => _send({
        'type': 'pin_message',
        'chat': chat,
        'id': id,
        if (seconds != null) 'duration': seconds,
      });

  void openViewOnce(String chat, String id) =>
      _send({'type': 'view_once', 'chat': chat, 'id': id});

  void pinChat(String chat) => _send({'type': 'pin_chat', 'chat': chat});

  void unpinChat(String chat) => _send({'type': 'unpin_chat', 'chat': chat});

  /// [hours] null mutes forever, matching the desktop UI.
  void muteChat(String chat, {int? hours}) => _send({
        'type': 'mute_chat',
        'chat': chat,
        if (hours != null) 'hours': hours,
      });

  void unmuteChat(String chat) => _send({'type': 'unmute_chat', 'chat': chat});

  void archiveChat(String chat) =>
      _send({'type': 'archive_chat', 'chat': chat});

  void unarchiveChat(String chat) =>
      _send({'type': 'unarchive_chat', 'chat': chat});

  void clearChat(String chat) => _send({'type': 'clear_chat', 'chat': chat});

  void deleteChat(String chat) => _send({'type': 'delete_chat', 'chat': chat});

  /// [format] is `txt`, `json` or `html`. The backend names the file
  /// (`<chat>_<timestamp>.<ext>`) inside [dir], or its default export folder
  /// when [dir] is null.
  void exportChat(String chat, String format, {String? dir}) => _send({
        'type': 'export_chat',
        'chat': chat,
        'format': format,
        if (dir != null) 'dir': dir,
      });

  // Group actions. Display names for the JIDs come from [Snapshot.contacts].
  void requestGroupInfo(String chat) =>
      _send({'type': 'group_info', 'chat': chat});

  void inviteLink(String chat) => _send({'type': 'invite_link', 'chat': chat});

  void addParticipants(String chat, List<String> participants) => _send({
        'type': 'add_participants',
        'chat': chat,
        'participants': participants,
      });

  void removeParticipants(String chat, List<String> participants) => _send({
        'type': 'remove_participants',
        'chat': chat,
        'participants': participants,
      });

  void setSubject(String chat, String subject) =>
      _send({'type': 'set_subject', 'chat': chat, 'subject': subject});

  void setDescription(String chat, String description) => _send(
      {'type': 'set_description', 'chat': chat, 'description': description});

  void setAnnounce(String chat, bool enabled) =>
      _send({'type': 'group_announce', 'chat': chat, 'enabled': enabled});

  void setLocked(String chat, bool enabled) =>
      _send({'type': 'group_locked', 'chat': chat, 'enabled': enabled});

  /// Zero turns disappearing messages off.
  void setEphemeral(String chat, int seconds) =>
      _send({'type': 'ephemeral', 'chat': chat, 'seconds': seconds});

  void leaveGroup(String chat) =>
      _send({'type': 'leave_group', 'chat': chat});

  /// [at] must be in the future; the backend sends it when its clock passes it.
  void schedule(String chat, String text, DateTime at) => _send({
        'type': 'schedule',
        'chat': chat,
        'text': text,
        'at': at.toUtc().toIso8601String(),
      });

  void cancelScheduled(String id) =>
      _send({'type': 'cancel_scheduled', 'id': id});

  void sendScheduledNow(String id) =>
      _send({'type': 'send_scheduled', 'id': id});

  void dispose() {
    _retry?.cancel();
    _channel?.sink.close();
  }
}
