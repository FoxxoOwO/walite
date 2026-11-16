//! Minimal vCard 3.0 reader/writer — the format WhatsApp puts in `ContactMessage`.

use serde::{Deserialize, Serialize};

/// Parsed contact entry from a shared WhatsApp vCard (`ContactMessage` /
/// `ContactsArrayMessage`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ContactCard {
    pub name: String,
    pub phone: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub waid: Option<String>,
}

/// Unescapes a vCard 3.0 text value (`\;`, `\,`, `\n`, `\\`).
fn unescape(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    let mut chars = value.chars();
    while let Some(c) = chars.next() {
        if c == '\\' {
            match chars.next() {
                Some('n' | 'N') => out.push('\n'),
                Some(other) => out.push(other),
                None => break,
            }
        } else {
            out.push(c);
        }
    }
    out
}

/// Parses a single vCard 3.0 payload (`FN`, optional `N` fallback, and `TEL`/`waid`).
pub fn parse_vcard(raw: &str, display_name_hint: Option<&str>) -> Option<ContactCard> {
    // Unfold RFC 2425 continuation lines ("\r\n " or "\n ").
    let unfolded = raw
        .replace("\r\n ", "")
        .replace("\r\n\t", "")
        .replace("\n ", "")
        .replace("\n\t", "");

    let mut fn_name: Option<String> = None;
    let mut n_name: Option<String> = None;
    let mut phone: Option<String> = None;
    let mut waid: Option<String> = None;

    for line in unfolded.lines() {
        let trimmed = line.trim();
        let Some((left, val)) = trimmed.split_once(':') else {
            continue;
        };
        let mut parts = left.split(';');
        let prop = parts.next().unwrap_or_default().to_ascii_uppercase();
        let clean_val = unescape(val.trim());

        match prop.as_str() {
            "FN" if fn_name.is_none() && !clean_val.is_empty() => {
                fn_name = Some(clean_val);
            }
            "N" if n_name.is_none() && !clean_val.is_empty() => {
                let joined: Vec<&str> = clean_val
                    .split(';')
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .collect();
                if !joined.is_empty() {
                    n_name = Some(joined.join(" "));
                }
            }
            "TEL" => {
                for param in parts {
                    if let Some((k, v)) = param.split_once('=') {
                        if k.trim().eq_ignore_ascii_case("waid") {
                            let digits: String =
                                v.trim().chars().filter(|c| c.is_ascii_digit()).collect();
                            if !digits.is_empty() && waid.is_none() {
                                waid = Some(digits);
                            }
                        }
                    }
                }
                if phone.is_none() && !clean_val.is_empty() {
                    phone = Some(clean_val);
                }
            }
            _ => {}
        }
    }

    let name = fn_name
        .or(n_name)
        .or_else(|| display_name_hint.map(|s| s.trim().to_string()).filter(|s| !s.is_empty()))
        .unwrap_or_default();
    let phone_val = phone
        .or_else(|| waid.as_ref().map(|w| format!("+{w}")))
        .unwrap_or_default();

    if name.is_empty() && phone_val.is_empty() {
        return None;
    }
    Some(ContactCard {
        name: if name.is_empty() { phone_val.clone() } else { name },
        phone: phone_val,
        waid,
    })
}

/// Escapes a value for a vCard 3.0 text field.
fn escape(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for c in value.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            ';' => out.push_str("\\;"),
            ',' => out.push_str("\\,"),
            '\n' => out.push_str("\\n"),
            '\r' => {}
            _ => out.push(c),
        }
    }
    out
}

/// Phone digits of a JID: `420123456789:12@s.whatsapp.net` → `420123456789`.
pub fn jid_digits(jid: &str) -> String {
    jid.split('@')
        .next()
        .unwrap_or_default()
        .split(':')
        .next()
        .unwrap_or_default()
        .chars()
        .filter(|c| c.is_ascii_digit())
        .collect()
}

/// A vCard WhatsApp and other clients understand for `phone`.
///
/// `waid` is what links the card back to a WhatsApp account; the human value is
/// the international number.
pub fn build_vcard(display_name: &str, phone: &str) -> String {
    let digits: String = phone.chars().filter(|c| c.is_ascii_digit()).collect();
    format!(
        "BEGIN:VCARD\nVERSION:3.0\nFN:{name}\nTEL;type=CELL;type=VOICE;waid={digits}:+{digits}\nEND:VCARD",
        name = escape(display_name),
        digits = digits
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn card_carries_name_waid_and_international_number() {
        let card = build_vcard("Petr Novák", "420602123456");
        assert!(card.starts_with("BEGIN:VCARD\nVERSION:3.0\n"));
        assert!(card.contains("FN:Petr Novák\n"));
        assert!(card.contains("waid=420602123456:+420602123456"));
        assert!(card.ends_with("END:VCARD"));
    }

    #[test]
    fn separators_in_a_name_are_escaped() {
        // Semicolon and comma are field separators in vCard 3.0.
        assert_eq!(escape("Novák; Petr, ml."), "Novák\\; Petr\\, ml.");
        assert_eq!(escape("line\nbreak"), "line\\nbreak");
    }

    #[test]
    fn jid_digits_drop_server_and_device() {
        assert_eq!(jid_digits("420602123456:12@s.whatsapp.net"), "420602123456");
        assert_eq!(jid_digits("420602123456@s.whatsapp.net"), "420602123456");
        assert_eq!(jid_digits("123@lid"), "123");
        assert_eq!(jid_digits(""), "");
    }

    #[test]
    fn parse_vcard_extracts_name_phone_and_waid() {
        let card = build_vcard("Petr; Novák", "420602123456");
        let parsed = parse_vcard(&card, None).unwrap();
        assert_eq!(parsed.name, "Petr; Novák");
        assert_eq!(parsed.phone, "+420602123456");
        assert_eq!(parsed.waid.as_deref(), Some("420602123456"));
    }

    #[test]
    fn parse_vcard_uses_display_hint_when_fn_missing() {
        let raw = "BEGIN:VCARD\nVERSION:3.0\nTEL;type=CELL:+420777888999\nEND:VCARD";
        let parsed = parse_vcard(raw, Some("Eva Malá")).unwrap();
        assert_eq!(parsed.name, "Eva Malá");
        assert_eq!(parsed.phone, "+420777888999");
        assert_eq!(parsed.waid, None);
    }
}
