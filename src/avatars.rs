//! Profile picture cache: downloaded JPEGs live in `%APPDATA%/warust/avatars`,
//! decoded textures are cached per egui context.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, SystemTime};

use parking_lot::Mutex;
use whatsapp_rust::wacore_binary::Jid;
use whatsapp_rust::Client;

use crate::state::SharedState;

/// Bumped whenever a new picture is written so UI textures get reloaded.
static AVATAR_REV: AtomicU64 = AtomicU64::new(1);
const REFRESH_AFTER: Duration = Duration::from_secs(24 * 3600);

fn dir() -> PathBuf {
    dirs::data_dir()
        .unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")))
        .join("warust")
        .join("avatars")
}

fn key(jid: &Jid) -> String {
    jid.to_string()
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '_' })
        .collect()
}

fn image_path(jid: &Jid) -> PathBuf {
    dir().join(format!("{}.jpg", key(jid)))
}

/// Current avatar cache revision; incremented whenever a new photo lands on disk.
pub fn revision() -> u64 {
    AVATAR_REV.load(Ordering::Relaxed)
}

/// Local path to a cached profile picture JPEG for `jid`, if present on disk.
pub fn cached_path(jid: &Jid) -> Option<String> {
    let path = image_path(jid);
    path.is_file().then(|| path.to_string_lossy().into_owned())
}

/// Write a newly uploaded JPEG into the avatar cache and bump `AVATAR_REV`.
pub fn save_cached_jpeg(jid: &Jid, jpeg_bytes: &[u8]) -> anyhow::Result<()> {
    let _ = std::fs::create_dir_all(dir());
    let img = image_path(jid);
    let none = none_path(jid);
    std::fs::write(&img, jpeg_bytes)?;
    let _ = std::fs::remove_file(&none);
    AVATAR_REV.fetch_add(1, Ordering::Relaxed);
    Ok(())
}

/// Remove a cached profile picture for `jid` and mark it absent so it isn't re-fetched immediately.
pub fn remove_cached(jid: &Jid) {
    let _ = std::fs::create_dir_all(dir());
    let _ = std::fs::remove_file(image_path(jid));
    let _ = std::fs::write(none_path(jid), b"");
    AVATAR_REV.fetch_add(1, Ordering::Relaxed);
}

/// Load any supported image from `path`, center-crop to a square, resize to
/// 640×640, and encode as RGB JPEG suitable for WhatsApp profile pictures.
pub fn prepare_profile_jpeg(path: &std::path::Path) -> anyhow::Result<Vec<u8>> {
    use anyhow::Context;
    use image::codecs::jpeg::JpegEncoder;
    use image::imageops::FilterType;

    let raw = std::fs::read(path)
        .with_context(|| format!("Nepodařilo se přečíst obrázek {}", path.display()))?;
    let mut img = image::load_from_memory(&raw)
        .context("Nepodporovaný nebo poškozený formát obrázku")?;
    let (w, h) = (img.width(), img.height());
    let side = w.min(h);
    if w != h {
        let x = (w - side) / 2;
        let y = (h - side) / 2;
        img = img.crop_imm(x, y, side, side);
    }
    let resized = img.resize_exact(640, 640, FilterType::Lanczos3).to_rgb8();
    let mut out = Vec::new();
    let mut enc = JpegEncoder::new_with_quality(&mut out, 90);
    enc.encode_image(&resized)?;
    Ok(out)
}

fn none_path(jid: &Jid) -> PathBuf {
    dir().join(format!("{}.none", key(jid)))
}

fn is_fresh(path: &PathBuf) -> bool {
    std::fs::metadata(path)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| SystemTime::now().duration_since(t).ok())
        .map_or(false, |age| age < REFRESH_AFTER)
}

/// Download (if missing/stale or `force`) the profile picture of one chat.
pub async fn fetch_avatar(client: &Arc<Client>, jid: &Jid, force: bool) {
    let img = image_path(jid);
    let none = none_path(jid);
    if !force && (is_fresh(&img) || is_fresh(&none)) {
        return;
    }
    let _ = std::fs::create_dir_all(dir());
    match client.contacts().get_profile_picture(jid, true).await {
        Ok(Some(pic)) => {
            let url = pic.url.clone();
            let bytes = tokio::task::spawn_blocking(move || -> anyhow::Result<Vec<u8>> {
                let mut resp = ureq::get(&url).call()?;
                Ok(resp.body_mut().read_to_vec()?)
            })
            .await;
            match bytes {
                Ok(Ok(b)) if !b.is_empty() => {
                    if std::fs::write(&img, b).is_ok() {
                        let _ = std::fs::remove_file(&none);
                        AVATAR_REV.fetch_add(1, Ordering::Relaxed);
                    }
                }
                Ok(Err(e)) => tracing::debug!("Avatar download failed for {}: {}", jid, e),
                _ => {}
            }
        }
        Ok(None) => {
            let had_img = img.exists();
            if had_img {
                let _ = std::fs::remove_file(&img);
                AVATAR_REV.fetch_add(1, Ordering::Relaxed);
            }
            let _ = std::fs::write(&none, b"");
        }
        Err(e) => tracing::debug!("Profile picture query failed for {}: {}", jid, e),
    }
}

/// Sync pictures of all chats, one at a time to stay polite to the server.
pub async fn sync_all_avatars(client: &Arc<Client>, state: &SharedState, force: bool) {
    let jids: Vec<Jid> = {
        let s = state.read();
        let mut chats: Vec<_> = s.chats.values().collect();
        chats.sort_by(|a, b| b.last_activity.cmp(&a.last_activity));
        chats.into_iter().map(|c| c.jid.clone()).collect()
    };
    tracing::info!("Syncing profile pictures for {} chats", jids.len());
    for jid in jids {
        fetch_avatar(client, &jid, force).await;
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    tracing::info!("Profile picture sync finished");
}

type Cache = Arc<Mutex<HashMap<Jid, (u64, Option<egui::TextureHandle>)>>>;

/// Returns the decoded texture for a chat's picture, if one is cached on disk.
pub fn texture(ctx: &egui::Context, jid: &Jid) -> Option<egui::TextureHandle> {
    let id = egui::Id::unique("warust_avatar_cache");
    let cache: Cache = ctx.data_mut(|d| d.get_temp::<Cache>(id)).unwrap_or_else(|| {
        let c: Cache = Arc::new(Mutex::new(HashMap::new()));
        ctx.data_mut(|d| d.insert_temp(id, c.clone()));
        c
    });
    let rev = AVATAR_REV.load(Ordering::Relaxed);
    let mut map = cache.lock();
    if let Some((r, tex)) = map.get(jid) {
        if *r == rev {
            return tex.clone();
        }
    }
    let tex = std::fs::read(image_path(jid))
        .ok()
        .and_then(|b| image::load_from_memory(&b).ok())
        .map(|img| {
            let rgba = img.to_rgba8();
            let size = [rgba.width() as usize, rgba.height() as usize];
            let ci = egui::ColorImage::from_rgba_unmultiplied(size, rgba.as_raw());
            ctx.load_texture(format!("avatar-{}", key(jid)), ci, egui::TextureOptions::LINEAR)
        });
    map.insert(jid.clone(), (rev, tex.clone()));
    tex
}

/// Paint a circular picture into `rect`.
pub fn paint_circle(ui: &egui::Ui, tex: &egui::TextureHandle, rect: egui::Rect) {
    egui::Image::new(egui::load::SizedTexture::new(tex.id(), rect.size()))
        .corner_radius(rect.width() / 2.0)
        .paint_at(ui, rect);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prepare_profile_jpeg_crops_and_resizes_to_640_square() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("wide.png");
        let img = image::RgbImage::from_fn(200, 100, |x, _| {
            if x < 50 || x >= 150 {
                image::Rgb([0, 0, 0])
            } else {
                image::Rgb([37, 211, 102])
            }
        });
        img.save(&src).unwrap();

        let jpeg = prepare_profile_jpeg(&src).unwrap();
        let decoded = image::load_from_memory(&jpeg).unwrap();
        assert_eq!((decoded.width(), decoded.height()), (640, 640));
    }
}
