//! Message Search engine with multi-criteria filtering

use chrono::{Local, Utc};
use whatsapp_rust::wacore_binary::Jid;
use crate::state::{AppState, Message};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum SearchScope {
    #[default]
    CurrentChat,
    AllChats,
}

impl SearchScope {
    pub fn label(&self) -> &'static str {
        match self {
            Self::CurrentChat => "📌 This chat",
            Self::AllChats => "🌐 All chats",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum SearchSender {
    #[default]
    All,
    SentByMe,
    Received,
}

impl SearchSender {
    pub fn label(&self) -> &'static str {
        match self {
            Self::All => "👥 All senders",
            Self::SentByMe => "↗ Sent by me",
            Self::Received => "↙ Received",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum SearchContentType {
    #[default]
    All,
    TextOnly,
    MediaOnly,
    LinksOnly,
    PollsOnly,
    WithReactionsOnly,
    StarredOnly,
}

impl SearchContentType {
    pub fn label(&self) -> &'static str {
        match self {
            Self::All => "📄 All content",
            Self::TextOnly => "💬 Text only",
            Self::MediaOnly => "📷 Media only",
            Self::LinksOnly => "🔗 Links only",
            Self::PollsOnly => "📊 Polls only",
            Self::WithReactionsOnly => "😀 With reactions",
            Self::StarredOnly => "⭐ Starred only",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum SearchDateRange {
    #[default]
    AllTime,
    Today,
    Last7Days,
    Last30Days,
}

impl SearchDateRange {
    pub fn label(&self) -> &'static str {
        match self {
            Self::AllTime => "⏱ All time",
            Self::Today => "📅 Today",
            Self::Last7Days => "📅 Last 7 days",
            Self::Last30Days => "📅 Last 30 days",
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct MessageSearchFilter {
    pub query: String,
    pub scope: SearchScope,
    pub sender: SearchSender,
    pub content_type: SearchContentType,
    pub date_range: SearchDateRange,
}

impl MessageSearchFilter {
    pub fn is_empty(&self) -> bool {
        self.query.trim().is_empty()
            && self.sender == SearchSender::All
            && self.content_type == SearchContentType::All
            && self.date_range == SearchDateRange::AllTime
    }

    pub fn reset_filters(&mut self) {
        self.sender = SearchSender::All;
        self.content_type = SearchContentType::All;
        self.date_range = SearchDateRange::AllTime;
    }
}

#[derive(Debug, Clone)]
pub struct SearchResultItem {
    pub message: Message,
    pub chat_name: String,
    pub sender_name: String,
}

fn contains_ascii_ci(haystack: &str, needle: &[u8]) -> bool {
    haystack
        .as_bytes()
        .windows(needle.len())
        .any(|w| w.eq_ignore_ascii_case(needle))
}

/// Search across stored messages according to active filters
pub fn search_messages(
    state: &AppState,
    filter: &MessageSearchFilter,
) -> Vec<SearchResultItem> {
    if filter.is_empty() {
        return Vec::new();
    }

    let query_lower = filter.query.trim().to_lowercase();
    let now = Utc::now();
    let today_local = Local::now().date_naive();
    let mut results = Vec::new();

    // Determine target chats to scan
    let target_chats: Vec<(&Jid, &[Message])> = match filter.scope {
        SearchScope::CurrentChat => {
            if let Some(ref selected) = state.selected_chat {
                state
                    .get_chat_messages(selected)
                    .map(|msgs| vec![(selected, msgs.as_slice())])
                    .unwrap_or_default()
            } else {
                state
                    .messages
                    .iter()
                    .map(|(j, m)| (j, m.as_slice()))
                    .collect()
            }
        }
        SearchScope::AllChats => state
            .messages
            .iter()
            .map(|(j, m)| (j, m.as_slice()))
            .collect(),
    };

    for (chat_jid, msgs) in target_chats {
        let canon = state.canonical_jid(chat_jid);
        let chat_name = state
            .chats
            .get(&canon)
            .or_else(|| state.chats.get(chat_jid))
            .map(|c| c.name.clone())
            .unwrap_or_else(|| crate::util::format_jid(&canon));

        for msg in msgs {
            // Filter 1: Sender (Sent vs Received)
            match filter.sender {
                SearchSender::All => {}
                SearchSender::SentByMe if !msg.from_me => continue,
                SearchSender::Received if msg.from_me => continue,
                _ => {}
            }

            // Filter 2: Content Type
            match filter.content_type {
                SearchContentType::All => {}
                SearchContentType::TextOnly => {
                    if msg.media_type.is_some() {
                        continue;
                    }
                }
                SearchContentType::MediaOnly => {
                    if msg.media_type.is_none() {
                        continue;
                    }
                }
                SearchContentType::LinksOnly => {
                    let has_link = |s: &str| {
                        contains_ascii_ci(s, b"http://") || contains_ascii_ci(s, b"https://")
                    };
                    if !has_link(&msg.text)
                        && !msg.media_caption.as_deref().is_some_and(has_link)
                    {
                        continue;
                    }
                }
                SearchContentType::PollsOnly => {
                    if msg.poll.is_none() {
                        continue;
                    }
                }
                SearchContentType::WithReactionsOnly => {
                    if msg.reactions.is_empty() {
                        continue;
                    }
                }
                SearchContentType::StarredOnly => {
                    if !msg.starred {
                        continue;
                    }
                }
            }

            // Filter 3: Date Range
            match filter.date_range {
                SearchDateRange::AllTime => {}
                SearchDateRange::Today => {
                    if msg.timestamp.with_timezone(&Local).date_naive() != today_local {
                        continue;
                    }
                }
                SearchDateRange::Last7Days => {
                    if (now - msg.timestamp).num_days() > 7 {
                        continue;
                    }
                }
                SearchDateRange::Last30Days => {
                    if (now - msg.timestamp).num_days() > 30 {
                        continue;
                    }
                }
            }

            // Filter 4: Text Query match (body, caption, filename, poll, or shared contacts)
            if !query_lower.is_empty() {
                let in_text = msg.text.to_lowercase().contains(&query_lower);
                let in_caption = msg.media_caption.as_deref().map_or(false, |c| c.to_lowercase().contains(&query_lower));
                let in_filename = msg
                    .media_path
                    .as_deref()
                    .and_then(|p| std::path::Path::new(p).file_name())
                    .and_then(|n| n.to_str())
                    .map_or(false, |n| n.to_lowercase().contains(&query_lower));
                let in_poll = msg.poll.as_ref().map_or(false, |p| {
                    p.question.to_lowercase().contains(&query_lower)
                        || p.options.iter().any(|o| o.to_lowercase().contains(&query_lower))
                });
                let in_contacts = msg.contacts.iter().any(|c| {
                    c.name.to_lowercase().contains(&query_lower)
                        || c.phone.to_lowercase().contains(&query_lower)
                });
                if !in_text && !in_caption && !in_filename && !in_poll && !in_contacts {
                    continue;
                }
            }

            let sender_name = if msg.from_me {
                "You".to_string()
            } else {
                state.resolve_display_name(&msg.sender_jid)
                    .unwrap_or_else(|| crate::util::format_jid(&msg.sender_jid))
            };

            results.push(SearchResultItem {
                message: msg.clone(),
                chat_name: chat_name.clone(),
                sender_name,
            });
        }
    }

    // Sort newest first
    results.sort_by(|a, b| b.message.timestamp.cmp(&a.message.timestamp));
    results
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::MessageStatus;

    #[test]
    fn test_search_messages_filter_query_and_sender() {
        let mut state = AppState::new();
        let chat_jid: Jid = "420737526533@s.whatsapp.net".parse().unwrap();
        let my_jid: Jid = "420123456789@s.whatsapp.net".parse().unwrap();

        state.get_or_create_chat(chat_jid.clone(), "Eva".to_string(), false);
        state.selected_chat = Some(chat_jid.clone());

        let msg1 = Message::new_text(
            "1".to_string(),
            chat_jid.clone(),
            chat_jid.clone(),
            "Ahoj, jak se daří v práci?".to_string(),
            Utc::now(),
            false,
            MessageStatus::Read,
            None,
            None,
        );
        let msg2 = Message::new_text(
            "2".to_string(),
            chat_jid.clone(),
            my_jid.clone(),
            "Skvěle! Posílám odkaz https://rust-lang.org".to_string(),
            Utc::now(),
            true,
            MessageStatus::Sent,
            None,
            None,
        );

        state.add_message(msg1);
        state.add_message(msg2);

        // Test 1: Query match
        let mut filter = MessageSearchFilter::default();
        filter.query = "práci".to_string();
        let res = search_messages(&state, &filter);
        assert_eq!(res.len(), 1);
        assert_eq!(res[0].message.id, "1");

        // Test 2: Filter sender SentByMe
        filter.query.clear();
        filter.sender = SearchSender::SentByMe;
        let res = search_messages(&state, &filter);
        assert_eq!(res.len(), 1);
        assert_eq!(res[0].message.id, "2");

        // Test 3: Filter links only
        filter.sender = SearchSender::All;
        filter.content_type = SearchContentType::LinksOnly;
        let res = search_messages(&state, &filter);
        assert_eq!(res.len(), 1);
        assert_eq!(res[0].message.id, "2");
    }

    #[test]
    fn test_search_filters_polls_reactions_and_starred() {
        let mut state = AppState::new();
        let chat_jid: Jid = "420737526533@s.whatsapp.net".parse().unwrap();
        state.get_or_create_chat(chat_jid.clone(), "Eva".to_string(), false);

        let mut poll_msg = Message::new_text(
            "P1".to_string(),
            chat_jid.clone(),
            chat_jid.clone(),
            "Kam na oběd?".to_string(),
            Utc::now(),
            false,
            MessageStatus::Read,
            None,
            None,
        );
        poll_msg.poll = Some(crate::state::PollData {
            question: "Kam na oběd?".to_string(),
            options: vec!["Ramen".to_string(), "Pizza".to_string()],
            selectable_count: 1,
            ..Default::default()
        });

        let mut react_msg = Message::new_text(
            "R1".to_string(),
            chat_jid.clone(),
            chat_jid.clone(),
            "Super nápad!".to_string(),
            Utc::now(),
            false,
            MessageStatus::Read,
            None,
            None,
        );
        react_msg.reactions.push(crate::state::Reaction {
            emoji: "👍".to_string(),
            sender: chat_jid.clone(),
        });
        react_msg.starred = true;

        state.add_message(poll_msg);
        state.add_message(react_msg);

        let polls = search_messages(
            &state,
            &MessageSearchFilter {
                content_type: SearchContentType::PollsOnly,
                ..Default::default()
            },
        );
        assert_eq!(polls.len(), 1);
        assert_eq!(polls[0].message.id, "P1");

        let reacted = search_messages(
            &state,
            &MessageSearchFilter {
                content_type: SearchContentType::WithReactionsOnly,
                ..Default::default()
            },
        );
        assert_eq!(reacted.len(), 1);
        assert_eq!(reacted[0].message.id, "R1");

        let starred = search_messages(
            &state,
            &MessageSearchFilter {
                content_type: SearchContentType::StarredOnly,
                ..Default::default()
            },
        );
        assert_eq!(starred.len(), 1);
        assert_eq!(starred[0].message.id, "R1");
    }

    #[test]
    fn search_resolves_canonical_current_chat_and_matches_uppercase_links() {
        let mut state = AppState::new();
        let lid: Jid = "999888777@lid".parse().unwrap();
        let pn: Jid = "420737526533@s.whatsapp.net".parse().unwrap();
        state.lid_to_pn.insert(lid.clone(), pn.clone());
        state.get_or_create_chat(pn.clone(), "Eva".to_string(), false);
        state.selected_chat = Some(lid);

        let msg = Message::new_text(
            "UPPER_LINK".to_string(),
            pn.clone(),
            pn.clone(),
            "Mrkni na HTTPS://Example.COM/path".to_string(),
            Utc::now(),
            false,
            MessageStatus::Read,
            None,
            None,
        );
        state.add_message(msg);

        let filter = MessageSearchFilter {
            scope: SearchScope::CurrentChat,
            content_type: SearchContentType::LinksOnly,
            ..Default::default()
        };
        let res = search_messages(&state, &filter);
        assert_eq!(res.len(), 1);
        assert_eq!(res[0].message.id, "UPPER_LINK");
    }
}
