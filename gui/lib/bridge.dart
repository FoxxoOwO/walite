import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/painting.dart' show FileImage;
import 'package:web_socket_channel/web_socket_channel.dart';

/// One chat row from the Rust backend's snapshot.
class ChatItem {
  ChatItem({
    required this.jid,
    required this.name,
    this.last,
    this.unread = 0,
    this.group = false,
    this.pinned = false,
    this.archived = false,
    this.muted = false,
    this.typing = false,
    this.participantsCount = 0,
    this.avatar,
    this.draft,
  });

  final String jid;
  final String name;
  final LastMessage? last;
  final int unread;
  final bool group;
  final bool pinned;
  final bool archived;
  final bool muted;
  final bool typing;
  final int participantsCount;
  final String? avatar;
  final String? draft;

  factory ChatItem.fromJson(Map<String, dynamic> json) => ChatItem(
        jid: json['jid'] as String,
        name: json['name'] as String? ?? '',
        unread: json['unread'] as int? ?? 0,
        group: json['group'] as bool? ?? false,
        pinned: json['pinned'] as bool? ?? false,
        archived: json['archived'] as bool? ?? false,
        muted: json['muted'] as bool? ?? false,
        typing: json['typing'] as bool? ?? false,
        participantsCount: json['participants_count'] as int? ?? 0,
        avatar: json['avatar'] as String?,
        draft: json['draft'] as String?,
        last: json['last'] == null
            ? null
            : LastMessage.fromJson(json['last'] as Map<String, dynamic>),
      );
}

class LastMessage {
  LastMessage(
    this.text,
    this.ts,
    this.fromMe, {
    this.status = 'sent',
    this.media,
  });

  final String text;
  final int ts;
  final bool fromMe;
  final String status;
  final String? media;

  factory LastMessage.fromJson(Map<String, dynamic> json) => LastMessage(
        json['text'] as String? ?? '',
        json['ts'] as int? ?? 0,
        json['from_me'] as bool? ?? false,
        status: json['status'] as String? ?? 'sent',
        media: json['media'] as String?,
      );
}

class ReactionDetail {
  const ReactionDetail({required this.emoji, required this.sender});

  final String emoji;
  final String sender;

  factory ReactionDetail.fromJson(Map<String, dynamic> json) => ReactionDetail(
        emoji: json['emoji'] as String? ?? '',
        sender: json['sender'] as String? ?? '',
      );
}

class ContactCard {
  const ContactCard({required this.name, required this.phone, this.waid});

  final String name;
  final String phone;
  final String? waid;

  factory ContactCard.fromJson(Map<String, dynamic> json) => ContactCard(
        name: json['name'] as String? ?? '',
        phone: json['phone'] as String? ?? '',
        waid: json['waid'] as String?,
      );
}

class Msg {
  Msg({
    required this.id,
    required this.text,
    required this.ts,
    required this.fromMe,
    required this.sender,
    this.status = 'sent',
    this.media,
    this.caption,
    this.downloaded = false,
    this.mediaPath,
    this.thumbBase64,
    this.fileSize,
    this.mimetype,
    this.replyTo,
    this.edited = false,
    this.starred = false,
    this.gifPlayback = false,
    this.contactCards = const [],
    this.viewOnce = false,
    this.viewOnceOpened = false,
    this.poll,
    this.reactions = const [],
    this.reactionDetails = const [],
  });

  final String id;
  final String text;
  final int ts;
  final bool fromMe;
  final String sender;
  final String status;
  final String? media;
  final String? caption;
  final bool downloaded;
  final String? mediaPath;
  final String? thumbBase64;
  final int? fileSize;
  final String? mimetype;
  final String? replyTo;
  final bool edited;
  final bool starred;
  final bool gifPlayback;
  final List<ContactCard> contactCards;
  final bool viewOnce;
  final bool viewOnceOpened;

  /// Present when the message is a poll, from either side.
  final Poll? poll;

  /// Emoji only; the same emoji from several people appears once.
  final List<String> reactions;

  /// Full reaction entries including sender JIDs.
  final List<ReactionDetail> reactionDetails;

  factory Msg.fromJson(Map<String, dynamic> json) {
    final rawReactions = (json['reactions'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(ReactionDetail.fromJson)
        .where((r) => r.emoji.isNotEmpty)
        .toList();
    return Msg(
      id: json['id'] as String? ?? '',
      text: json['text'] as String? ?? '',
      ts: json['ts'] as int? ?? 0,
      fromMe: json['from_me'] as bool? ?? false,
      sender: json['sender'] as String? ?? '',
      status: json['status'] as String? ?? 'sent',
      media: json['media'] as String?,
      caption: json['caption'] as String?,
      downloaded: json['downloaded'] as bool? ?? false,
      mediaPath: json['media_path'] as String?,
      thumbBase64: json['thumb'] as String?,
      fileSize: (json['file_size'] as num?)?.toInt(),
      mimetype: json['mimetype'] as String?,
      replyTo: json['reply_to'] as String?,
      edited: json['edited'] as bool? ?? false,
      starred: json['starred'] as bool? ?? false,
      gifPlayback: json['gif_playback'] as bool? ?? false,
      contactCards: (json['contacts'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(ContactCard.fromJson)
          .toList(),
      viewOnce: json['view_once'] as bool? ?? false,
      viewOnceOpened: json['view_once_opened'] as bool? ?? false,
      poll: json['poll'] == null
          ? null
          : Poll.fromJson(json['poll'] as Map<String, dynamic>),
      reactions: rawReactions.map((r) => r.emoji).toSet().toList(),
      reactionDetails: rawReactions,
    );
  }
}

/// A poll attached to a message. Vote counts are already tallies, so the GUI
/// never sees who voted for what.
class Poll {
  Poll({
    required this.question,
    this.options = const [],
    this.selectable = 1,
    this.quiz = false,
    this.voters = 0,
    this.mine = const [],
    this.tallies = const {},
  });

  final String question;
  final List<String> options;

  /// `1` = single choice, `2`+ = up to N, `0` = unlimited.
  final int selectable;
  final bool quiz;
  final int voters;

  /// Option names this account already picked.
  final List<String> mine;

  /// Option name → vote count, in the poll's own option order.
  final Map<String, int> tallies;

  factory Poll.fromJson(Map<String, dynamic> json) => Poll(
        question: json['question'] as String? ?? '',
        options: ((json['options'] as List<dynamic>? ?? const [])
            .whereType<String>()
            .toList()),
        selectable: json['selectable'] as int? ?? 1,
        quiz: json['quiz'] as bool? ?? false,
        voters: json['voters'] as int? ?? 0,
        mine: ((json['mine'] as List<dynamic>? ?? const [])
            .whereType<String>()
            .toList()),
        tallies: {
          for (final t in (json['tallies'] as List<dynamic>? ?? const []))
            (t as Map<String, dynamic>)['option'] as String:
                t['votes'] as int? ?? 0,
        },
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

/// A message queued for later. `status` is `pending` or `failed`.
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

/// The preferences the settings dialog edits. Rust owns the values, so
/// a switch only takes effect once the next snapshot echoes it back.
class Prefs {
  const Prefs({
    this.enterIsSend = true,
    this.soundNotifications = true,
    this.showPreviews = true,
    this.desktopNotifications = true,
    this.autoDownloadPhotos = true,
    this.autoDownloadVideos = false,
    this.autoDownloadDocs = false,
    this.fontSize = 14,
    this.autoScrollToBottom = true,
    this.darkThemePreset = 0,
    this.language = 'cs',
    this.checkUpdates = true,
    this.autoInstallUpdates = false,
    this.runInTray = true,
    this.closeToTray = true,
    this.startWithWindows = false,
    this.chatWallpaperColor,
    this.chatWallpaperPath,
    this.chatWallpaperDoodles = true,
  });

  final bool enterIsSend;
  final bool soundNotifications;
  final bool showPreviews;
  final bool desktopNotifications;
  final bool autoDownloadPhotos;
  final bool autoDownloadVideos;
  final bool autoDownloadDocs;
  final double fontSize;
  final bool autoScrollToBottom;
  final int darkThemePreset;
  final String language;
  final bool checkUpdates;
  final bool autoInstallUpdates;
  final bool runInTray;
  final bool closeToTray;
  final bool startWithWindows;
  final String? chatWallpaperColor;
  final String? chatWallpaperPath;
  final bool chatWallpaperDoodles;

  factory Prefs.fromJson(Map<String, dynamic> json) => Prefs(
        enterIsSend: json['enter_is_send'] as bool? ?? true,
        soundNotifications: json['sound_notifications'] as bool? ?? true,
        showPreviews: json['show_previews'] as bool? ?? true,
        desktopNotifications: json['desktop_notifications'] as bool? ?? true,
        autoDownloadPhotos: json['auto_download_photos'] as bool? ?? true,
        autoDownloadVideos: json['auto_download_videos'] as bool? ?? false,
        autoDownloadDocs: json['auto_download_docs'] as bool? ?? false,
        fontSize: (json['font_size'] as num?)?.toDouble() ?? 14,
        autoScrollToBottom: json['auto_scroll_to_bottom'] as bool? ?? true,
        darkThemePreset: json['dark_theme_preset'] as int? ?? 0,
        language: json['language'] as String? ?? 'cs',
        checkUpdates: json['check_updates'] as bool? ?? true,
        autoInstallUpdates: json['auto_install_updates'] as bool? ?? false,
        runInTray: json['run_in_tray'] as bool? ?? true,
        closeToTray: json['close_to_tray'] as bool? ?? true,
        startWithWindows: json['start_with_windows'] as bool? ?? false,
        chatWallpaperColor: json['chat_wallpaper_color'] as String?,
        chatWallpaperPath: json['chat_wallpaper_path'] as String?,
        chatWallpaperDoodles: json['chat_wallpaper_doodles'] as bool? ?? true,
      );
}

/// Whether a contact is online, and when they were last seen otherwise.
class Presence {
  const Presence({required this.online, this.lastSeen});

  final bool online;
  final DateTime? lastSeen;

  factory Presence.fromJson(Map<String, dynamic> json) => Presence(
        online: json['online'] as bool? ?? false,
        lastSeen: DateTime.tryParse(json['last_seen'] as String? ?? '')?.toLocal(),
      );
}

class ContactInfo {
  const ContactInfo({
    required this.jid,
    required this.name,
    this.blocked = false,
    this.business = false,
    this.verifiedName,
    this.avatar,
  });

  final String jid;
  final String name;
  final bool blocked;
  final bool business;
  final String? verifiedName;
  final String? avatar;

  factory ContactInfo.fromJson(Map<String, dynamic> json) => ContactInfo(
        jid: json['jid'] as String,
        name: json['name'] as String? ?? '',
        blocked: json['blocked'] as bool? ?? false,
        business: json['business'] as bool? ?? false,
        verifiedName: json['verified_name'] as String?,
        avatar: json['avatar'] as String?,
      );
}

class PinnedMsg {
  const PinnedMsg({required this.id, this.untilMs});

  final String id;
  final int? untilMs;

  factory PinnedMsg.fromJson(Map<String, dynamic> json) => PinnedMsg(
        id: json['id'] as String? ?? '',
        untilMs: (json['until'] as num?)?.toInt(),
      );
}

class CallInfo {
  const CallInfo({
    required this.id,
    required this.peerJid,
    required this.peerName,
    this.peerAvatar,
    required this.isVideo,
    required this.isGroup,
    required this.status,
    this.reason,
    required this.muted,
    required this.videoEnabled,
    required this.startedAt,
    this.connectedAt,
  });

  final String id;
  final String peerJid;
  final String peerName;
  final String? peerAvatar;
  final bool isVideo;
  final bool isGroup;
  final String status; // incoming | ringing | connected | ended
  final String? reason;
  final bool muted;
  final bool videoEnabled;
  final int startedAt;
  final int? connectedAt;

  factory CallInfo.fromJson(Map<String, dynamic> json) => CallInfo(
        id: json['id'] as String? ?? '',
        peerJid: json['peer_jid'] as String? ?? '',
        peerName: json['peer_name'] as String? ?? '',
        peerAvatar: json['peer_avatar'] as String?,
        isVideo: json['is_video'] as bool? ?? false,
        isGroup: json['is_group'] as bool? ?? false,
        status: json['status'] as String? ?? 'ringing',
        reason: json['reason'] as String?,
        muted: json['muted'] as bool? ?? false,
        videoEnabled: json['video_enabled'] as bool? ?? false,
        startedAt: (json['started_at'] as num?)?.toInt() ?? 0,
        connectedAt: (json['connected_at'] as num?)?.toInt(),
      );
}

class AudioState {
  const AudioState({
    required this.playingId,
    required this.paused,
    required this.posMs,
    this.durMs,
  });

  final String playingId;
  final bool paused;
  final int posMs;
  final int? durMs;

  factory AudioState.fromJson(Map<String, dynamic> json) => AudioState(
        playingId: json['playing_id'] as String? ?? '',
        paused: json['paused'] as bool? ?? false,
        posMs: (json['pos_ms'] as num?)?.toInt() ?? 0,
        durMs: (json['dur_ms'] as num?)?.toInt(),
      );
}

class UpdateRelease {
  const UpdateRelease({
    required this.version,
    required this.tag,
    required this.pageUrl,
    required this.notes,
    required this.hasAsset,
  });

  final String version;
  final String tag;
  final String pageUrl;
  final String notes;
  final bool hasAsset;

  factory UpdateRelease.fromJson(Map<String, dynamic> json) => UpdateRelease(
        version: json['version'] as String? ?? '',
        tag: json['tag'] as String? ?? '',
        pageUrl: json['page_url'] as String? ?? '',
        notes: json['notes'] as String? ?? '',
        hasAsset: json['has_asset'] as bool? ?? false,
      );
}

class UpdateState {
  const UpdateState({
    this.current = '1.0.0',
    this.status = '',
    this.busy = false,
    this.available,
  });

  final String current;
  final String status;
  final bool busy;
  final UpdateRelease? available;

  factory UpdateState.fromJson(Map<String, dynamic> json) => UpdateState(
        current: json['current'] as String? ?? '1.0.0',
        status: json['status'] as String? ?? '',
        busy: json['busy'] as bool? ?? false,
        available: json['available'] == null
            ? null
            : UpdateRelease.fromJson(json['available'] as Map<String, dynamic>),
      );
}

class SearchHit {
  const SearchHit({
    required this.id,
    required this.chat,
    required this.chatName,
    required this.senderName,
    required this.text,
    this.media,
    required this.ts,
    required this.fromMe,
  });

  final String id;
  final String chat;
  final String chatName;
  final String senderName;
  final String text;
  final String? media;
  final int ts;
  final bool fromMe;

  factory SearchHit.fromJson(Map<String, dynamic> json) => SearchHit(
        id: json['id'] as String? ?? '',
        chat: json['chat'] as String? ?? '',
        chatName: json['chat_name'] as String? ?? '',
        senderName: json['sender_name'] as String? ?? '',
        text: json['text'] as String? ?? '',
        media: json['media'] as String?,
        ts: (json['ts'] as num?)?.toInt() ?? 0,
        fromMe: json['from_me'] as bool? ?? false,
      );
}

class MediaStats {
  const MediaStats({
    required this.dir,
    required this.files,
    required this.totalBytes,
    required this.staleFiles,
    required this.staleBytes,
    required this.oldFiles,
    this.cleanedFiles,
    this.cleanedBytes,
  });

  final String dir;
  final int files;
  final int totalBytes;
  final int staleFiles;
  final int staleBytes;
  final int oldFiles;
  final int? cleanedFiles;
  final int? cleanedBytes;

  factory MediaStats.fromJson(Map<String, dynamic> json) => MediaStats(
        dir: json['dir'] as String? ?? '',
        files: (json['files'] as num?)?.toInt() ?? 0,
        totalBytes: (json['total_bytes'] as num?)?.toInt() ?? 0,
        staleFiles: (json['stale_files'] as num?)?.toInt() ?? 0,
        staleBytes: (json['stale_bytes'] as num?)?.toInt() ?? 0,
        oldFiles: (json['old_files'] as num?)?.toInt() ?? 0,
        cleanedFiles: (json['cleaned_files'] as num?)?.toInt(),
        cleanedBytes: (json['cleaned_bytes'] as num?)?.toInt(),
      );
}

class ExportResult {
  const ExportResult({required this.ok, this.path, this.error});

  final bool ok;
  final String? path;
  final String? error;

  factory ExportResult.fromJson(Map<String, dynamic> json) => ExportResult(
        ok: json['ok'] as bool? ?? false,
        path: json['path'] as String?,
        error: json['error'] as String?,
      );
}

class ClipboardImageResult {
  const ClipboardImageResult({this.path, this.error});

  final String? path;
  final String? error;

  factory ClipboardImageResult.fromJson(Map<String, dynamic> json) =>
      ClipboardImageResult(
        path: json['path'] as String?,
        error: json['error'] as String?,
      );
}

class GalleryLinkItem {
  const GalleryLinkItem({
    required this.id,
    required this.chat,
    required this.url,
    required this.text,
    required this.ts,
    this.fromMe = false,
  });

  final String id;
  final String chat;
  final String url;
  final String text;
  final int ts;
  final bool fromMe;

  factory GalleryLinkItem.fromJson(Map<String, dynamic> json) => GalleryLinkItem(
        id: json['id'] as String? ?? '',
        chat: json['chat'] as String? ?? '',
        url: json['url'] as String? ?? '',
        text: json['text'] as String? ?? '',
        ts: (json['ts'] as num?)?.toInt() ?? 0,
        fromMe: json['from_me'] as bool? ?? false,
      );
}

class ChatGallery {
  const ChatGallery({
    required this.chat,
    this.totalMessages = 0,
    this.syncing = false,
    this.exhausted = false,
    this.media = const [],
    this.docs = const [],
    this.links = const [],
  });

  final String chat;
  final int totalMessages;
  final bool syncing;
  final bool exhausted;
  final List<Msg> media;
  final List<Msg> docs;
  final List<GalleryLinkItem> links;

  factory ChatGallery.fromJson(Map<String, dynamic> json) => ChatGallery(
        chat: json['chat'] as String? ?? '',
        totalMessages: (json['total_messages'] as num?)?.toInt() ?? 0,
        syncing: json['syncing'] as bool? ?? false,
        exhausted: json['exhausted'] as bool? ?? false,
        media: (json['media'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(Msg.fromJson)
            .toList(),
        docs: (json['docs'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(Msg.fromJson)
            .toList(),
        links: (json['links'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(GalleryLinkItem.fromJson)
            .toList(),
      );
}

class SearchResultsBatch {
  const SearchResultsBatch({
    this.items = const [],
    this.totalHits = 0,
    this.scannedMessages = 0,
  });

  final List<SearchHit> items;
  final int totalHits;
  final int scannedMessages;
}

class ProfileResult {
  const ProfileResult({required this.kind, required this.ok, this.error});

  final String kind;
  final bool ok;
  final String? error;

  factory ProfileResult.fromJson(Map<String, dynamic> json) => ProfileResult(
        kind: json['kind'] as String? ?? 'picture',
        ok: json['ok'] as bool? ?? false,
        error: json['error'] as String?,
      );
}

class Snapshot {
  Snapshot({
    required this.connection,
    required this.detail,
    required this.selected,
    required this.chats,
    required this.messages,
    this.selectedTotalMessages = 0,
    this.historySyncing = const [],
    this.historyExhausted = const [],
    this.self,
    this.selfName,
    this.selfStatus,
    this.selfAvatar,
    this.avatarRev = 0,
    this.search = '',
    this.group,
    this.pinnedMessage,
    this.ephemeral,
    this.archived = const [],
    this.scheduled = const [],
    this.contacts = const {},
    this.contactDetails = const {},
    this.presence = const {},
    this.prefs = const Prefs(),
    this.call,
    this.audio,
    this.stickers = const [],
    this.update = const UpdateState(),
  });

  final String connection;
  final String? detail;
  final String? selected;
  final int selectedTotalMessages;
  final List<String> historySyncing;
  final List<String> historyExhausted;

  bool isHistorySyncing(String jid) => historySyncing.contains(jid);
  bool isHistoryExhausted(String jid) => historyExhausted.contains(jid);

  /// This account's own JID, needed to tell whether we are a group admin.
  final String? self;
  final String? selfName;
  final String? selfStatus;
  final String? selfAvatar;
  final int avatarRev;
  final String search;
  final List<ChatItem> chats;

  /// Details of the selected chat when it is a group.
  final GroupInfo? group;
  final PinnedMsg? pinnedMessage;
  final int? ephemeral;

  /// Archived chats: hidden from [chats] by the backend, shown in their own
  /// section so unarchiving stays possible.
  final List<ChatItem> archived;

  /// Queued messages the backend has not sent yet (or failed to send).
  final List<Scheduled> scheduled;
  final List<Msg> messages;

  /// JID → display name, so group bubbles can show who wrote what.
  final Map<String, String> contacts;

  /// Richer contact metadata (blocked, business, verifiedName, avatar).
  final Map<String, ContactInfo> contactDetails;

  /// JID → online state, only for contacts that have one.
  final Map<String, Presence> presence;

  final Prefs prefs;
  final CallInfo? call;
  final AudioState? audio;
  final List<String> stickers;
  final UpdateState update;

  factory Snapshot.fromJson(Map<String, dynamic> json) {
    final conn = json['connection'] as Map<String, dynamic>? ?? const {};
    final contactList = (json['contacts'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    return Snapshot(
      connection: conn['kind'] as String? ?? 'disconnected',
      detail: conn['detail']?.toString(),
      selected: json['selected'] as String?,
      selectedTotalMessages:
          (json['selected_total_messages'] as num?)?.toInt() ?? 0,
      historySyncing: (json['history_syncing'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toList(),
      historyExhausted:
          (json['history_exhausted'] as List<dynamic>? ?? const [])
              .whereType<String>()
              .toList(),
      self: json['self'] as String?,
      selfName: json['self_name'] as String?,
      selfStatus: json['self_status'] as String?,
      selfAvatar: json['self_avatar'] as String?,
      avatarRev: (json['avatar_rev'] as num?)?.toInt() ?? 0,
      search: json['search'] as String? ?? '',
      group: json['group'] == null
          ? null
          : GroupInfo.fromJson(json['group'] as Map<String, dynamic>),
      pinnedMessage: json['pinned_message'] == null
          ? null
          : PinnedMsg.fromJson(json['pinned_message'] as Map<String, dynamic>),
      ephemeral: (json['ephemeral'] as num?)?.toInt(),
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
        for (final c in contactList)
          c['jid'] as String: c['name'] as String? ?? '',
      },
      contactDetails: {
        for (final c in contactList)
          c['jid'] as String: ContactInfo.fromJson(c),
      },
      presence: {
        for (final p in json['presence'] as List<dynamic>? ?? const [])
          (p as Map<String, dynamic>)['jid'] as String: Presence.fromJson(p),
      },
      prefs: Prefs.fromJson(
        json['prefs'] as Map<String, dynamic>? ?? const {},
      ),
      call: json['call'] == null
          ? null
          : CallInfo.fromJson(json['call'] as Map<String, dynamic>),
      audio: json['audio'] == null
          ? null
          : AudioState.fromJson(json['audio'] as Map<String, dynamic>),
      stickers: (json['stickers'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toList(),
      update: json['update'] == null
          ? const UpdateState()
          : UpdateState.fromJson(json['update'] as Map<String, dynamic>),
    );
  }

  ChatItem? chat(String? jid) {
    if (jid == null) return null;
    for (final c in chats) {
      if (c.jid == jid) return c;
    }
    for (final c in archived) {
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
  final _searchResults = StreamController<List<SearchHit>>.broadcast();
  final _searchBatches = StreamController<SearchResultsBatch>.broadcast();
  final _chatGalleries = StreamController<ChatGallery>.broadcast();
  final _mediaStats = StreamController<MediaStats>.broadcast();
  final _exportResults = StreamController<ExportResult>.broadcast();
  final _clipboardImages = StreamController<ClipboardImageResult>.broadcast();
  final _windowActivations = StreamController<String?>.broadcast();
  final _profileResults = StreamController<ProfileResult>.broadcast();
  final _starredMessages = StreamController<List<SearchHit>>.broadcast();
  Timer? _retry;
  WebSocketChannel? _channel;
  bool _connecting = false;
  int _lastAvatarRev = -1;
  String? _lastSelfAvatar;

  Stream<Snapshot> get snapshots => _snapshots.stream;

  /// Emits true while the socket is open.
  Stream<bool> get link => _link.stream;

  Stream<List<SearchHit>> get searchResults => _searchResults.stream;
  Stream<SearchResultsBatch> get searchBatches => _searchBatches.stream;
  Stream<ChatGallery> get chatGalleries => _chatGalleries.stream;
  Stream<MediaStats> get mediaStats => _mediaStats.stream;
  Stream<ExportResult> get exportResults => _exportResults.stream;
  Stream<ClipboardImageResult> get clipboardImages => _clipboardImages.stream;
  Stream<String?> get windowActivations => _windowActivations.stream;
  Stream<ProfileResult> get profileResults => _profileResults.stream;
  Stream<List<SearchHit>> get starredMessages => _starredMessages.stream;

  void connect() {
    if (_connecting) return;
    _connecting = true;
    try {
      final channel = WebSocketChannel.connect(Uri.parse('ws://127.0.0.1:$port'));
      _channel = channel;
      unawaited(
        channel.ready.then(
          (_) {
            if (_channel == channel) _link.add(true);
          },
          onError: (_) {
            if (_channel == channel) _lost();
          },
        ),
      );
      channel.stream.listen(
        (frame) {
          final decoded = jsonDecode(frame as String);
          if (decoded is! Map<String, dynamic>) return;
          switch (decoded['type']) {
            case 'snapshot':
              final snap = Snapshot.fromJson(decoded);
              if (snap.avatarRev != _lastAvatarRev) {
                _lastAvatarRev = snap.avatarRev;
                _evictAvatarCaches(snap);
              }
              _lastSelfAvatar = snap.selfAvatar;
              _snapshots.add(snap);
            case 'search_results':
              final items = (decoded['items'] as List<dynamic>? ?? const [])
                  .whereType<Map<String, dynamic>>()
                  .map(SearchHit.fromJson)
                  .toList();
              _searchResults.add(items);
              _searchBatches.add(
                SearchResultsBatch(
                  items: items,
                  totalHits:
                      (decoded['total_hits'] as num?)?.toInt() ?? items.length,
                  scannedMessages:
                      (decoded['scanned_messages'] as num?)?.toInt() ?? 0,
                ),
              );
            case 'chat_gallery':
              _chatGalleries.add(ChatGallery.fromJson(decoded));
            case 'media_stats':
              _mediaStats.add(MediaStats.fromJson(decoded));
            case 'export_result':
              _exportResults.add(ExportResult.fromJson(decoded));
            case 'clipboard_image':
              _clipboardImages.add(ClipboardImageResult.fromJson(decoded));
            case 'activate_window':
              _windowActivations.add(decoded['chat'] as String?);
            case 'profile_result':
              _profileResults.add(ProfileResult.fromJson(decoded));
            case 'starred_messages':
              final items = (decoded['items'] as List<dynamic>? ?? const [])
                  .whereType<Map<String, dynamic>>()
                  .map(SearchHit.fromJson)
                  .toList();
              _starredMessages.add(items);
          }
        },
        onDone: () {
          if (_channel == channel) _lost();
        },
        onError: (_) {
          if (_channel == channel) _lost();
        },
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

  void reconnectBackend() => _send({'type': 'connect'});
  void disconnect() => _send({'type': 'disconnect'});
  void dismissSyncing() => _send({'type': 'dismiss_syncing'});
  void requestPairCode(String phone) =>
      _send({'type': 'request_pair_code', 'phone': phone});
  void cancelPairCode() => _send({'type': 'cancel_pair_code'});

  void select(String jid) => _send({'type': 'select', 'chat': jid});
  void startChat(String phoneOrJid) =>
      _send({'type': 'start_chat', 'phone': phoneOrJid});
  void refreshChats() => _send({'type': 'refresh_chats'});

  void saveDraft(String chat, String text) =>
      _send({'type': 'save_draft', 'chat': chat, 'text': text});

  void sendTyping(String chat, bool composing) =>
      _send({'type': 'typing', 'chat': chat, 'composing': composing});

  void sendText(
    String jid,
    String text, {
    String? reply,
    List<String> mentions = const [],
  }) =>
      _send({
        'type': 'send',
        'chat': jid,
        'text': text,
        'reply': ?reply,
        if (mentions.isNotEmpty) 'mentions': mentions,
      });

  void sendContact(String chat, String contactJid, {String? reply}) => _send({
        'type': 'send_contact',
        'chat': chat,
        'contact': contactJid,
        'reply': ?reply,
      });

  void search(String query) => _send({'type': 'search', 'q': query});

  void searchMessages({
    required String query,
    required String scope,
    required String sender,
    required String contentType,
    required String dateRange,
  }) =>
      _send({
        'type': 'search_messages',
        'q': query,
        'scope': scope,
        'sender': sender,
        'content_type': contentType,
        'date_range': dateRange,
      });

  void setPref(String key, Object? value) =>
      _send({'type': 'set_pref', 'key': key, 'value': value});

  void starMessage(String chat, String id, bool starred) =>
      _send({'type': 'star', 'chat': chat, 'id': id, 'starred': starred});
  void requestStarred({String? chat}) =>
      _send({'type': 'get_starred', 'chat': ?chat});

  void setPushName(String name) =>
      _send({'type': 'set_push_name', 'name': name});
  void setStatusText(String text) =>
      _send({'type': 'set_status_text', 'text': text});
  void setProfilePicture(String path) =>
      _send({'type': 'set_profile_picture', 'path': path});
  void removeProfilePicture() => _send({'type': 'remove_profile_picture'});

  void testNotification() => _send({'type': 'test_notification'});
  void setWindowFocused(bool focused) =>
      _send({'type': 'window_focus', 'focused': focused});

  void requestMediaStats() => _send({'type': 'media_stats'});
  void cleanMedia(String mode) => _send({'type': 'clean_media', 'mode': mode});
  void openMediaDir() => _send({'type': 'open_media_dir'});
  void checkUpdates() => _send({'type': 'check_updates'});
  void installUpdate() => _send({'type': 'install_update'});

  void edit(String chat, String id, String text) =>
      _send({'type': 'edit', 'chat': chat, 'id': id, 'text': text});

  void react(String chat, String id, String emoji) =>
      _send({'type': 'react', 'chat': chat, 'id': id, 'emoji': emoji});

  void deleteMessage(String chat, String id) =>
      _send({'type': 'delete', 'chat': chat, 'id': id});

  void download(String chat, String id) =>
      _send({'type': 'download', 'chat': chat, 'id': id});

  void markRead(String chat) => _send({'type': 'read', 'chat': chat});

  void more(String chat) => _send({'type': 'more', 'chat': chat});

  void jumpToMessage(String chat, String id) =>
      _send({'type': 'jump_to_message', 'chat': chat, 'id': id});

  void sendMedia(String chat, String path,
          {String? caption, String? replyTo, bool viewOnce = false}) =>
      _send({
        'type': 'send_media',
        'chat': chat,
        'path': path,
        if (caption != null && caption.isNotEmpty) 'caption': caption,
        'reply_to': ?replyTo,
        if (viewOnce) 'view_once': true,
      });

  void pasteClipboardImage() => _send({'type': 'paste_clipboard_image'});

  void recordStart() => _send({'type': 'record_start'});
  void recordStop(String chat) => _send({'type': 'record_stop', 'chat': chat});
  void recordCancel() => _send({'type': 'record_cancel'});

  void audioToggle(String id, String path) =>
      _send({'type': 'audio_toggle', 'id': id, 'path': path});
  void audioPause() => _send({'type': 'audio_pause'});
  void audioResume() => _send({'type': 'audio_resume'});
  void audioSeek(int ms) => _send({'type': 'audio_seek', 'ms': ms});

  void openFile(String path) => _send({'type': 'open_file', 'path': path});
  void showInFolder(String path) =>
      _send({'type': 'show_in_folder', 'path': path});

  void forward(String from, String to, List<String> ids) =>
      _send({'type': 'forward', 'from': from, 'to': to, 'ids': ids});

  void revoke(String chat, String id) =>
      _send({'type': 'revoke', 'chat': chat, 'id': id});

  void pinMessage(String chat, String id, {int? seconds}) => _send({
        'type': 'pin_message',
        'chat': chat,
        'id': id,
        'duration': ?seconds,
      });

  void openViewOnce(String chat, String id) =>
      _send({'type': 'view_once', 'chat': chat, 'id': id});

  void consumeViewOnce(String chat, String id) =>
      _send({'type': 'consume_view_once', 'chat': chat, 'id': id});

  void pinChat(String chat) => _send({'type': 'pin_chat', 'chat': chat});
  void unpinChat(String chat) => _send({'type': 'unpin_chat', 'chat': chat});

  void muteChat(String chat, {int? hours}) => _send({
        'type': 'mute_chat',
        'chat': chat,
        'hours': ?hours,
      });

  void unmuteChat(String chat) => _send({'type': 'unmute_chat', 'chat': chat});
  void archiveChat(String chat) => _send({'type': 'archive_chat', 'chat': chat});
  void unarchiveChat(String chat) =>
      _send({'type': 'unarchive_chat', 'chat': chat});
  void clearChat(String chat) => _send({'type': 'clear_chat', 'chat': chat});
  void deleteChat(String chat) => _send({'type': 'delete_chat', 'chat': chat});

  void saveContact(String jid, String name) =>
      _send({'type': 'save_contact', 'jid': jid, 'name': name});
  void blockContact(String jid) => _send({'type': 'block_contact', 'jid': jid});
  void unblockContact(String jid) =>
      _send({'type': 'unblock_contact', 'jid': jid});

  void createPoll(String chat, String question, List<String> options,
          {int selectable = 1}) =>
      _send({
        'type': 'create_poll',
        'chat': chat,
        'question': question,
        'options': options,
        'selectable': selectable,
      });

  void votePoll(String chat, String messageId, List<String> options) => _send({
        'type': 'vote_poll',
        'chat': chat,
        'id': messageId,
        'options': options,
      });

  void exportChat(String chat, String format, {String? dir}) => _send({
        'type': 'export_chat',
        'chat': chat,
        'format': format,
        'dir': ?dir,
      });

  void createGroup(String subject, List<String> participants) => _send({
        'type': 'create_group',
        'subject': subject,
        'participants': participants,
      });

  void joinGroup(String code) => _send({'type': 'join_group', 'code': code});

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
  void promoteParticipants(String chat, List<String> participants) => _send({
        'type': 'promote_participants',
        'chat': chat,
        'participants': participants,
      });
  void demoteParticipants(String chat, List<String> participants) => _send({
        'type': 'demote_participants',
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

  void setEphemeral(String chat, int seconds) =>
      _send({'type': 'ephemeral', 'chat': chat, 'seconds': seconds});
  void leaveGroup(String chat) => _send({'type': 'leave_group', 'chat': chat});

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

  void startCall(String peerJid, {bool isVideo = false}) =>
      _send({'type': 'start_call', 'peer': peerJid, 'video': isVideo});
  void acceptCall(String id) => _send({'type': 'accept_call', 'id': id});
  void rejectCall(String id) => _send({'type': 'reject_call', 'id': id});
  void endCall(String id) => _send({'type': 'end_call', 'id': id});
  void toggleCallMute() => _send({'type': 'toggle_call_mute'});
  void toggleCallVideo() => _send({'type': 'toggle_call_video'});

  void requestChatGallery(String chat) =>
      _send({'type': 'get_chat_gallery', 'chat': chat});
  void syncFullHistory({String? chat}) => _send({
        'type': 'sync_full_history',
        'chat': ?chat,
      });
  void cancelHistorySync() => _send({'type': 'cancel_history_sync'});

  void dispose() {
    _retry?.cancel();
    _snapshots.close();
    _link.close();
    _searchResults.close();
    _searchBatches.close();
    _chatGalleries.close();
    _mediaStats.close();
    _exportResults.close();
    _clipboardImages.close();
    _windowActivations.close();
    _profileResults.close();
    _starredMessages.close();
    _channel?.sink.close();
  }

  void _evictAvatarCaches(Snapshot snap) {
    final paths = <String>{
      if (_lastSelfAvatar != null && _lastSelfAvatar!.isNotEmpty)
        _lastSelfAvatar!,
      if (snap.selfAvatar != null && snap.selfAvatar!.isNotEmpty)
        snap.selfAvatar!,
      for (final c in snap.chats)
        if (c.avatar != null && c.avatar!.isNotEmpty) c.avatar!,
      for (final c in snap.contactDetails.values)
        if (c.avatar != null && c.avatar!.isNotEmpty) c.avatar!,
    };
    for (final p in paths) {
      try {
        FileImage(File(p)).evict();
      } catch (_) {}
    }
  }
}
