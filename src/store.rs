use rusqlite::{params, Connection};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

pub const MAX_ITEMS: usize = 500;
pub const MAX_IMAGE_BYTES: usize = 16 * 1024 * 1024;
pub const MAX_TEXT_BYTES: usize = 1024 * 1024;
const MAX_THUMBNAIL_BYTES: usize = 256 * 1024;
const MAX_BYTES: i64 = 256 * 1024 * 1024;
const MAX_AGE_SECONDS: i64 = 30 * 24 * 60 * 60;
static TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);
type Result<T> = std::result::Result<T, String>;

#[derive(Debug, Serialize)]
pub struct HistoryRow {
    pub id: i64,
    pub kind: String,
    pub preview: String,
    pub thumbnail_path: Option<String>,
    pub created_at: i64,
}

pub struct Store {
    conn: Connection,
    objects: PathBuf,
    max_bytes: i64,
    capture_disabled: bool,
}

impl Store {
    pub fn open(root: &Path) -> Result<Self> {
        private_directory(root)?;
        let root = fs::canonicalize(root).map_err(error)?;
        let objects = root.join("objects");
        private_directory(&objects)?;
        let database = root.join("history.sqlite");
        reject_symlink(&database)?;
        let conn = Connection::open(&database).map_err(error)?;
        conn.busy_timeout(Duration::from_secs(2)).map_err(error)?;
        conn.execute_batch(
            "PRAGMA journal_mode=WAL;
             PRAGMA synchronous=NORMAL;
             PRAGMA cache_size=-1024;
             PRAGMA wal_autocheckpoint=128;
             PRAGMA journal_size_limit=1048576;
             CREATE TABLE IF NOT EXISTS history (
                 id INTEGER PRIMARY KEY AUTOINCREMENT,
                 digest TEXT NOT NULL UNIQUE CHECK(length(digest)=64),
                 kind TEXT NOT NULL CHECK(kind IN ('text','image')),
                 uti TEXT NOT NULL CHECK(uti IN ('public.utf8-plain-text','public.png','public.tiff')),
                 preview TEXT NOT NULL,
                 object_name TEXT NOT NULL,
                 thumbnail_name TEXT,
                 bytes INTEGER NOT NULL CHECK(bytes>0),
                 thumbnail_bytes INTEGER NOT NULL DEFAULT 0 CHECK(thumbnail_bytes>=0),
                 created_at INTEGER NOT NULL,
                 recency INTEGER NOT NULL
             );
             CREATE INDEX IF NOT EXISTS history_recency ON history(recency DESC);
             CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);",
        ).map_err(error)?;
        for name in ["history.sqlite", "history.sqlite-wal", "history.sqlite-shm"] {
            let path = root.join(name);
            if path.exists() {
                private_file(&path)?;
            }
        }
        let mut store = Self {
            conn,
            objects,
            max_bytes: MAX_BYTES,
            capture_disabled: false,
        };
        store.recover()?;
        Ok(store)
    }

    /// Store a supported, bounded snapshot. Rejected content is left on the system clipboard.
    pub fn capture(&mut self, data: &[u8], uti: &str, thumbnail: Option<&[u8]>) -> Result<bool> {
        if self.capture_disabled {
            return Err(
                "Capture disabled after a storage cleanup failure; restart to recover".into(),
            );
        }
        let uti = if uti == "NSStringPboardType" {
            "public.utf8-plain-text"
        } else {
            uti
        };
        if data.is_empty() {
            return Ok(false);
        }
        let (kind, preview) = match uti {
            "public.utf8-plain-text" if data.len() <= MAX_TEXT_BYTES => {
                let Ok(text) = std::str::from_utf8(data) else {
                    return Ok(false);
                };
                ("text", text.chars().take(200).collect::<String>())
            }
            "public.png"
                if data.len() <= MAX_IMAGE_BYTES && data.starts_with(b"\x89PNG\r\n\x1a\n") =>
            {
                ("image", "图片 · PNG".into())
            }
            "public.tiff"
                if data.len() <= MAX_IMAGE_BYTES
                    && (data.starts_with(b"II\x2a\0") || data.starts_with(b"MM\0\x2a")) =>
            {
                ("image", "图片 · TIFF".into())
            }
            _ => return Ok(false),
        };
        let thumbnail = thumbnail
            .filter(|t| kind == "image" && !t.is_empty() && t.len() <= MAX_THUMBNAIL_BYTES);
        let mut hasher = Sha256::new();
        hasher.update(uti.as_bytes());
        hasher.update([0]);
        hasher.update(data);
        let digest = format!("{:x}", hasher.finalize());
        let object_name = format!("{digest}.data");
        // Thumbnail files are immutable too: a failed replacement must not alter
        // the image already referenced by the committed database row.
        let thumbnail_name = thumbnail.map(|bytes| {
            let mut hasher = Sha256::new();
            hasher.update(digest.as_bytes());
            hasher.update(bytes);
            format!("{:x}.png", hasher.finalize())
        });
        use rusqlite::OptionalExtension;
        let previous_thumbnail: Option<String> = self
            .conn
            .query_row(
                "SELECT thumbnail_name FROM history WHERE digest=?1",
                [&digest],
                |row| row.get::<_, Option<String>>(0),
            )
            .optional()
            .map_err(error)?
            .flatten();
        // Establish ownership before writing. A failing database therefore stops
        // subsequent attempts before they can add more untracked payloads.
        let mut rollback_files = Vec::new();
        for name in std::iter::once(&object_name).chain(thumbnail_name.iter()) {
            let referenced: bool = self.conn.query_row(
                "SELECT EXISTS(SELECT 1 FROM history WHERE object_name=?1 OR thumbnail_name=?1)",
                [name], |row| row.get(0),
            ).map_err(error)?;
            if !referenced {
                rollback_files.push(name.clone());
            }
        }
        let committed = (|| -> Result<Vec<String>> {
            atomic_private_write(&self.objects.join(&object_name), data)?;
            if let (Some(name), Some(bytes)) = (&thumbnail_name, thumbnail) {
                atomic_private_write(&self.objects.join(name), bytes)?;
            }
            let now = now();
            let transaction = self.conn.transaction().map_err(error)?;
            let recency: i64 = transaction
                .query_row("SELECT COALESCE(MAX(recency),0)+1 FROM history", [], |r| {
                    r.get(0)
                })
                .map_err(error)?;
            transaction.execute(
                "INSERT INTO history(digest,kind,uti,preview,object_name,thumbnail_name,bytes,thumbnail_bytes,created_at,recency)
                 VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)
                 ON CONFLICT(digest) DO UPDATE SET created_at=excluded.created_at,recency=excluded.recency,
                   thumbnail_name=COALESCE(excluded.thumbnail_name,history.thumbnail_name),
                   thumbnail_bytes=CASE WHEN excluded.thumbnail_name IS NULL THEN history.thumbnail_bytes ELSE excluded.thumbnail_bytes END",
                params![digest,kind,uti,preview,object_name,thumbnail_name,data.len() as i64,thumbnail.map_or(0, |t| t.len()) as i64,now,recency],
            ).map_err(error)?;
            let mut removed = evict(&transaction, now, self.max_bytes)?;
            transaction.commit().map_err(error)?;
            if thumbnail_name.is_some() && previous_thumbnail != thumbnail_name {
                if let Some(name) = previous_thumbnail {
                    removed.push(name);
                }
            }
            Ok(removed)
        })();
        let removed = match committed {
            Ok(removed) => removed,
            Err(failure) => {
                if self.remove_objects(rollback_files).is_err() {
                    // Fail closed rather than accepting unbounded future writes
                    // when this process cannot remove its own uncommitted files.
                    self.capture_disabled = true;
                    return Err(
                        "Capture failed and cleanup was unavailable; restart to recover".into(),
                    );
                }
                return Err(failure);
            }
        };
        if let Err(failure) = self.remove_objects(removed) {
            self.capture_disabled = true;
            return Err(failure);
        }
        Ok(true)
    }

    pub fn list(&self) -> Result<Vec<HistoryRow>> {
        let transaction = self.conn.unchecked_transaction().map_err(error)?;
        let removed = evict(&transaction, now(), self.max_bytes)?;
        transaction.commit().map_err(error)?;
        self.remove_objects(removed)?;
        let mut statement = self.conn.prepare("SELECT id,kind,preview,thumbnail_name,created_at FROM history ORDER BY recency DESC LIMIT 500").map_err(error)?;
        let records = statement
            .query_map([], |row| {
                let thumb: Option<String> = row.get(3)?;
                Ok(HistoryRow {
                    id: row.get(0)?,
                    kind: row.get(1)?,
                    preview: row.get(2)?,
                    thumbnail_path: thumb
                        .filter(|s| valid_object_name(s))
                        .map(|name| self.objects.join(name).to_string_lossy().into_owned()),
                    created_at: row.get(4)?,
                })
            })
            .map_err(error)?;
        records
            .collect::<std::result::Result<Vec<_>, _>>()
            .map_err(error)
    }

    pub fn load(&self, id: i64) -> Result<Option<(Vec<u8>, String)>> {
        use rusqlite::OptionalExtension;
        let record: Option<(String, String, i64)> = self
            .conn
            .query_row(
                "SELECT object_name,uti,bytes FROM history WHERE id=?1 AND created_at>=?2",
                params![id, now() - MAX_AGE_SECONDS],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .optional()
            .map_err(error)?;
        let Some((name, uti, declared_size)) = record else {
            return Ok(None);
        };
        if !valid_object_name(&name) || !(1..=MAX_IMAGE_BYTES as i64).contains(&declared_size) {
            return Err("Invalid stored object".into());
        }
        let path = self.objects.join(name);
        reject_symlink(&path)?;
        let metadata = fs::metadata(&path).map_err(error)?;
        if !metadata.is_file() || metadata.len() != declared_size as u64 {
            return Err("Stored object size mismatch".into());
        }
        let bytes = fs::read(path).map_err(error)?;
        Ok(Some((bytes, uti)))
    }

    pub fn get_bool(&self, key: &str, default: bool) -> Result<bool> {
        Ok(self
            .setting(key)?
            .map(|value| value == "true")
            .unwrap_or(default))
    }

    pub fn set_bool(&self, key: &str, value: bool) -> Result<()> {
        validate_key(key)?;
        self.conn.execute("INSERT INTO settings(key,value) VALUES(?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value", params![key,if value {"true"} else {"false"}]).map_err(error)?;
        Ok(())
    }

    pub fn get_hotkey(&self) -> Result<(u32, u32)> {
        let key = self
            .setting("hotkey_keycode")?
            .and_then(|s| s.parse().ok())
            .unwrap_or(9);
        let mods = self
            .setting("hotkey_modifiers")?
            .and_then(|s| s.parse().ok())
            .unwrap_or(2048);
        Ok((key, mods))
    }

    pub fn set_hotkey(&self, keycode: u32, modifiers: u32) -> Result<()> {
        const ALLOWED_MODIFIERS: u32 = 256 | 512 | 2048 | 4096;
        if keycode > 127
            || modifiers & !ALLOWED_MODIFIERS != 0
            || modifiers & (256 | 2048 | 4096) == 0
            || (keycode == 9 && modifiers == 256)
        {
            return Err("Invalid or reserved hotkey".into());
        }
        let transaction = self.conn.unchecked_transaction().map_err(error)?;
        for (key, value) in [("hotkey_keycode", keycode), ("hotkey_modifiers", modifiers)] {
            transaction.execute("INSERT INTO settings(key,value) VALUES(?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value", params![key,value.to_string()]).map_err(error)?;
        }
        transaction.commit().map_err(error)
    }

    fn setting(&self, key: &str) -> Result<Option<String>> {
        use rusqlite::OptionalExtension;
        validate_key(key)?;
        self.conn
            .query_row("SELECT value FROM settings WHERE key=?1", [key], |r| {
                r.get(0)
            })
            .optional()
            .map_err(error)
    }

    #[cfg(test)]
    fn total_bytes(&self) -> Result<i64> {
        self.conn
            .query_row(
                "SELECT COALESCE(SUM(bytes+thumbnail_bytes),0) FROM history",
                [],
                |r| r.get(0),
            )
            .map_err(error)
    }

    fn recover(&mut self) -> Result<()> {
        let records = {
            let mut statement = self
                .conn
                .prepare("SELECT id,object_name,thumbnail_name,bytes FROM history")
                .map_err(error)?;
            let rows = statement
                .query_map([], |r| {
                    Ok((
                        r.get::<_, i64>(0)?,
                        r.get::<_, String>(1)?,
                        r.get::<_, Option<String>>(2)?,
                        r.get::<_, i64>(3)?,
                    ))
                })
                .map_err(error)?
                .collect::<std::result::Result<Vec<_>, _>>()
                .map_err(error)?;
            rows
        };
        let transaction = self.conn.transaction().map_err(error)?;
        for (id, name, thumb, size) in records {
            let path = self.objects.join(&name);
            let exists = valid_object_name(&name)
                && fs::symlink_metadata(&path).is_ok_and(|m| {
                    m.is_file() && !m.file_type().is_symlink() && m.len() == size as u64
                });
            if !exists {
                transaction
                    .execute("DELETE FROM history WHERE id=?1", [id])
                    .map_err(error)?;
            } else if let Some(thumb) = thumb {
                let path = self.objects.join(&thumb);
                let metadata = fs::symlink_metadata(path).ok().filter(|m| {
                    valid_object_name(&thumb)
                        && m.is_file()
                        && !m.file_type().is_symlink()
                        && m.len() > 0
                        && m.len() <= MAX_THUMBNAIL_BYTES as u64
                });
                if let Some(metadata) = metadata {
                    transaction.execute("UPDATE history SET thumbnail_bytes=?1 WHERE id=?2 AND thumbnail_bytes<>?1",params![metadata.len() as i64,id]).map_err(error)?;
                } else {
                    transaction
                        .execute(
                            "UPDATE history SET thumbnail_name=NULL,thumbnail_bytes=0 WHERE id=?1",
                            [id],
                        )
                        .map_err(error)?;
                }
            }
        }
        evict(&transaction, now(), self.max_bytes)?;
        transaction.commit().map_err(error)?;
        let mut keep = HashSet::new();
        let mut statement = self
            .conn
            .prepare("SELECT object_name,thumbnail_name FROM history")
            .map_err(error)?;
        let names = statement
            .query_map([], |r| {
                Ok((r.get::<_, String>(0)?, r.get::<_, Option<String>>(1)?))
            })
            .map_err(error)?;
        for row in names {
            let (name, thumb) = row.map_err(error)?;
            keep.insert(name);
            if let Some(name) = thumb {
                keep.insert(name);
            }
        }
        for entry in fs::read_dir(&self.objects).map_err(error)? {
            let entry = entry.map_err(error)?;
            if !keep.contains(&entry.file_name().to_string_lossy().into_owned()) {
                let kind = entry.file_type().map_err(error)?;
                if kind.is_file() || kind.is_symlink() {
                    fs::remove_file(entry.path()).map_err(error)?;
                }
            } else {
                private_file(&entry.path())?;
            }
        }
        Ok(())
    }

    fn remove_objects(&self, objects: Vec<String>) -> Result<()> {
        for name in objects {
            if !valid_object_name(&name) {
                continue;
            }
            match fs::remove_file(self.objects.join(name)) {
                Ok(()) => (),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => (),
                Err(e) => return Err(error(e)),
            }
        }
        Ok(())
    }
}

fn evict(
    transaction: &rusqlite::Transaction<'_>,
    timestamp: i64,
    max_bytes: i64,
) -> Result<Vec<String>> {
    let records = {
        let mut statement=transaction.prepare("SELECT id,object_name,thumbnail_name,bytes+thumbnail_bytes,created_at FROM history ORDER BY recency DESC").map_err(error)?;
        let rows = statement
            .query_map([], |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, Option<String>>(2)?,
                    r.get::<_, i64>(3)?,
                    r.get::<_, i64>(4)?,
                ))
            })
            .map_err(error)?
            .collect::<std::result::Result<Vec<_>, _>>()
            .map_err(error)?;
        rows
    };
    let mut count = 0usize;
    let mut total = 0i64;
    let mut removed = Vec::new();
    for (id, name, thumb, bytes, created_at) in records {
        if created_at < timestamp - MAX_AGE_SECONDS
            || count >= MAX_ITEMS
            || total.saturating_add(bytes) > max_bytes
        {
            transaction
                .execute("DELETE FROM history WHERE id=?1", [id])
                .map_err(error)?;
            removed.push(name);
            if let Some(name) = thumb {
                removed.push(name);
            }
        } else {
            count += 1;
            total += bytes;
        }
    }
    Ok(removed)
}

fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}
fn error(e: impl std::fmt::Display) -> String {
    e.to_string()
}
fn validate_key(key: &str) -> Result<()> {
    if key.is_empty()
        || key.len() > 64
        || !key.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')
    {
        Err("Invalid setting key".into())
    } else {
        Ok(())
    }
}
fn valid_object_name(name: &str) -> bool {
    let Some((hash, ext)) = name.rsplit_once('.') else {
        return false;
    };
    hash.len() == 64 && hash.bytes().all(|b| b.is_ascii_hexdigit()) && matches!(ext, "data" | "png")
}
fn reject_symlink(path: &Path) -> Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() => {
            Err("Symlinks are not allowed in private storage".into())
        }
        Ok(_) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(error(e)),
    }
}
fn private_directory(path: &Path) -> Result<()> {
    reject_symlink(path)?;
    fs::create_dir_all(path).map_err(error)?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o700)).map_err(error)
}
fn private_file(path: &Path) -> Result<()> {
    reject_symlink(path)?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600)).map_err(error)
}
fn atomic_private_write(path: &Path, bytes: &[u8]) -> Result<()> {
    reject_symlink(path)?;
    if path
        .extension()
        .is_some_and(|extension| extension == "data")
        && path.exists()
    {
        return Ok(());
    }
    let sequence = TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    let temporary = path.with_extension(format!("{}.{}.tmp", std::process::id(), sequence));
    let result = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&temporary)
            .map_err(error)?;
        file.write_all(bytes).map_err(error)?;
        file.sync_all().map_err(error)?;
        fs::rename(&temporary, path).map_err(error)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    const TEXT: &str = "public.utf8-plain-text";
    const PNG: &[u8] = b"\x89PNG\r\n\x1a\noriginal image payload";

    #[test]
    fn text_and_original_image_survive_reopen() {
        let root = tempdir().unwrap();
        let mut store = Store::open(root.path()).unwrap();
        assert!(store
            .capture("你好 clipboard".as_bytes(), TEXT, None)
            .unwrap());
        assert!(store
            .capture(PNG, "public.png", Some(b"thumbnail"))
            .unwrap());
        let rows = store.list().unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].kind, "image");
        assert!(rows[0].thumbnail_path.is_some());
        let image_id = rows[0].id;
        drop(store);
        let store = Store::open(root.path()).unwrap();
        let (bytes, uti) = store.load(image_id).unwrap().unwrap();
        assert_eq!(bytes, PNG);
        assert_eq!(uti, "public.png");
        assert_eq!(store.list().unwrap()[1].preview, "你好 clipboard");
    }

    #[test]
    fn duplicate_is_promoted_without_growing_count_or_bytes() {
        let root = tempdir().unwrap();
        let mut store = Store::open(root.path()).unwrap();
        store.capture(b"first", TEXT, None).unwrap();
        store.capture(b"second", TEXT, None).unwrap();
        store.capture(b"first", TEXT, None).unwrap();
        let rows = store.list().unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].preview, "first");
        assert_eq!(store.total_bytes().unwrap(), 11);
    }

    #[test]
    fn empty_unsupported_invalid_and_oversized_data_are_skipped() {
        let root = tempdir().unwrap();
        let mut store = Store::open(root.path()).unwrap();
        for (data, uti) in [
            (&b""[..], TEXT),
            (&b"abc"[..], "public.html"),
            (&[0xff][..], TEXT),
            (&b"not png"[..], "public.png"),
        ] {
            assert!(!store.capture(data, uti, None).unwrap());
        }
        assert!(!store
            .capture(&vec![b'a'; MAX_TEXT_BYTES + 1], TEXT, None)
            .unwrap());
        let mut image = vec![0; MAX_IMAGE_BYTES + 1];
        image[..8].copy_from_slice(&PNG[..8]);
        assert!(!store.capture(&image, "public.png", None).unwrap());
        assert!(store.list().unwrap().is_empty());
    }

    #[test]
    fn count_limit_evicts_oldest_files() {
        let root = tempdir().unwrap();
        let mut store = Store::open(root.path()).unwrap();
        for i in 0..=MAX_ITEMS {
            store
                .capture(format!("item {i}").as_bytes(), TEXT, None)
                .unwrap();
        }
        let rows = store.list().unwrap();
        assert_eq!(rows.len(), MAX_ITEMS);
        assert!(!rows.iter().any(|r| r.preview == "item 0"));
        assert_eq!(
            std::fs::read_dir(root.path().join("objects"))
                .unwrap()
                .count(),
            MAX_ITEMS
        );
    }

    #[test]
    fn byte_budget_and_age_are_enforced_transactionally() {
        let root = tempdir().unwrap();
        let mut store = Store::open(root.path()).unwrap();
        store.max_bytes = 8;
        store.capture(b"12345", TEXT, None).unwrap();
        store.capture(b"67890", TEXT, None).unwrap();
        assert_eq!(store.list().unwrap().len(), 1);
        assert_eq!(store.total_bytes().unwrap(), 5);
        store
            .conn
            .execute("UPDATE history SET created_at = 1", [])
            .unwrap();
        store.capture(b"new", TEXT, None).unwrap();
        assert_eq!(store.list().unwrap().len(), 1);
        assert_eq!(store.list().unwrap()[0].preview, "new");
    }

    #[test]
    fn restart_removes_orphans_and_missing_payload_rows() {
        let root = tempdir().unwrap();
        let mut store = Store::open(root.path()).unwrap();
        store.capture(b"one", TEXT, None).unwrap();
        let id = store.list().unwrap()[0].id;
        let object: String = store
            .conn
            .query_row("SELECT object_name FROM history WHERE id=?1", [id], |r| {
                r.get(0)
            })
            .unwrap();
        std::fs::remove_file(root.path().join("objects").join(object)).unwrap();
        std::fs::write(root.path().join("objects/orphan.data"), b"orphan").unwrap();
        drop(store);
        let store = Store::open(root.path()).unwrap();
        assert!(store.list().unwrap().is_empty());
        assert_eq!(
            std::fs::read_dir(root.path().join("objects"))
                .unwrap()
                .count(),
            0
        );
    }

    #[test]
    fn configuration_persists_and_preview_does_not_split_unicode() {
        let root = tempdir().unwrap();
        let mut store = Store::open(root.path()).unwrap();
        assert_eq!(store.get_hotkey().unwrap(), (9, 2048));
        assert!(store.get_bool("show_icon", true).unwrap());
        store.set_bool("show_icon", false).unwrap();
        store.set_hotkey(8, 768).unwrap();
        store
            .capture("🦀".repeat(300).as_bytes(), TEXT, None)
            .unwrap();
        drop(store);
        let store = Store::open(root.path()).unwrap();
        assert!(!store.get_bool("show_icon", true).unwrap());
        assert_eq!(store.get_hotkey().unwrap(), (8, 768));
        assert_eq!(store.list().unwrap()[0].preview.chars().count(), 200);
    }

    #[test]
    fn payload_permissions_and_paths_are_private() {
        use std::os::unix::fs::PermissionsExt;
        let root = tempdir().unwrap();
        let mut store = Store::open(root.path()).unwrap();
        store.capture(b"secret", TEXT, None).unwrap();
        let file = std::fs::read_dir(root.path().join("objects"))
            .unwrap()
            .next()
            .unwrap()
            .unwrap()
            .path();
        assert_eq!(
            std::fs::metadata(file).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(
            std::fs::metadata(root.path()).unwrap().permissions().mode() & 0o777,
            0o700
        );
    }
    #[test]
    fn image_thumbnail_bytes_count_toward_budget_and_oversized_thumbs_are_ignored() {
        let root = tempdir().unwrap();
        let mut store = Store::open(root.path()).unwrap();
        store.max_bytes = PNG.len() as i64 + 9;
        store.capture(b"old", TEXT, None).unwrap();
        store
            .capture(PNG, "public.png", Some(b"thumbnail"))
            .unwrap();
        assert_eq!(store.list().unwrap().len(), 1);
        assert_eq!(store.total_bytes().unwrap(), PNG.len() as i64 + 9);
        store.capture(PNG, "public.png", Some(b"new")).unwrap();
        assert_eq!(store.total_bytes().unwrap(), PNG.len() as i64 + 3);
        let thumb = store.list().unwrap()[0].thumbnail_path.clone().unwrap();
        assert_eq!(std::fs::read(thumb).unwrap(), b"new");
        let mut second = PNG.to_vec();
        second.push(1);
        assert!(store
            .capture(
                &second,
                "public.png",
                Some(&vec![0; MAX_THUMBNAIL_BYTES + 1])
            )
            .unwrap());
        assert!(store.list().unwrap()[0].thumbnail_path.is_none());
    }

    #[test]
    fn symlink_root_is_rejected_without_modifying_target() {
        let root = tempdir().unwrap();
        let outside = root.path().join("outside");
        std::fs::create_dir(&outside).unwrap();
        std::fs::write(outside.join("keep"), b"unrelated").unwrap();
        let link = root.path().join("link");
        std::os::unix::fs::symlink(&outside, &link).unwrap();
        assert!(Store::open(&link).is_err());
        assert_eq!(std::fs::read(outside.join("keep")).unwrap(), b"unrelated");
        assert!(!outside.join("history.sqlite").exists());
    }

    #[test]
    fn invalid_hotkey_is_rejected_and_previous_configuration_remains() {
        let root = tempdir().unwrap();
        let store = Store::open(root.path()).unwrap();
        for (key, modifiers) in [(9, 256), (9, 0), (9, 512), (128, 2048), (9, 1)] {
            assert!(store.set_hotkey(key, modifiers).is_err());
        }
        assert_eq!(store.get_hotkey().unwrap(), (9, 2048));
    }

    #[test]
    fn restart_reconciles_thumbnail_file_bytes_after_interrupted_update() {
        let root = tempdir().unwrap();
        let mut store = Store::open(root.path()).unwrap();
        store
            .capture(PNG, "public.png", Some(b"thumbnail"))
            .unwrap();
        store
            .conn
            .execute("UPDATE history SET thumbnail_bytes=1", [])
            .unwrap();
        drop(store);
        let store = Store::open(root.path()).unwrap();
        assert_eq!(store.total_bytes().unwrap(), PNG.len() as i64 + 9);
    }
    #[test]
    fn failed_database_writes_do_not_accumulate_unreferenced_payloads() {
        let root = tempdir().unwrap();
        let mut store = Store::open(root.path()).unwrap();
        store.conn.execute_batch("CREATE TRIGGER fail_insert BEFORE INSERT ON history BEGIN SELECT RAISE(FAIL, 'injected insert failure'); END;").unwrap();
        for i in 0..5 {
            let mut image = PNG.to_vec();
            image.push(i);
            assert!(store
                .capture(&image, "public.png", Some(b"thumbnail"))
                .is_err());
            assert_eq!(
                std::fs::read_dir(root.path().join("objects"))
                    .unwrap()
                    .count(),
                0
            );
        }
        assert_eq!(store.total_bytes().unwrap(), 0);
    }

    #[test]
    fn failed_duplicate_write_preserves_existing_payload_and_thumbnail() {
        let root = tempdir().unwrap();
        let mut store = Store::open(root.path()).unwrap();
        store
            .capture(PNG, "public.png", Some(b"original thumbnail"))
            .unwrap();
        let before = store.list().unwrap();
        let id = before[0].id;
        let thumbnail = before[0].thumbnail_path.clone().unwrap();
        let accounted_bytes = store.total_bytes().unwrap();
        store.conn.execute_batch("CREATE TRIGGER fail_insert BEFORE INSERT ON history BEGIN SELECT RAISE(FAIL, 'injected insert failure'); END;").unwrap();
        assert!(store
            .capture(PNG, "public.png", Some(b"replacement thumbnail"))
            .is_err());
        assert_eq!(store.load(id).unwrap().unwrap().0, PNG);
        assert_eq!(std::fs::read(thumbnail).unwrap(), b"original thumbnail");
        assert_eq!(store.total_bytes().unwrap(), accounted_bytes);
        assert_eq!(
            std::fs::read_dir(root.path().join("objects"))
                .unwrap()
                .count(),
            2
        );
    }
}
