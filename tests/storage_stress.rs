//! Explicit storage stress checks. These tests never access the system clipboard.
//! Run with: cargo test --test storage_stress -- --ignored --nocapture
use pastty::store::{Store, MAX_IMAGE_BYTES, MAX_ITEMS, MAX_TEXT_BYTES};
use std::collections::{HashSet, VecDeque};
use std::fs;
use std::path::Path;
use std::time::Instant;
use tempfile::tempdir;

const TEXT_UTI: &str = "public.utf8-plain-text";
const PNG_UTI: &str = "public.png";
const BYTE_BUDGET: u64 = 256 * 1024 * 1024;
const PNG: &[u8] = include_bytes!("../assets/Pastty-1024.png");

#[derive(Debug, Default)]
struct Objects {
    payloads: usize,
    thumbnails: usize,
    bytes: u64,
}

fn objects(root: &Path) -> Objects {
    let mut result = Objects::default();
    for entry in fs::read_dir(root.join("objects")).expect("private object directory") {
        let entry = entry.expect("object entry");
        let metadata = entry.metadata().expect("object metadata");
        assert!(metadata.is_file(), "unexpected object type");
        match entry.path().extension().and_then(|value| value.to_str()) {
            Some("data") => result.payloads += 1,
            Some("png") => result.thumbnails += 1,
            _ => panic!("uncommitted temporary or unexpected object left behind"),
        }
        result.bytes += metadata.len();
    }
    assert!(
        result.payloads <= MAX_ITEMS,
        "payload count exceeds history cap"
    );
    assert!(
        result.thumbnails <= MAX_ITEMS,
        "thumbnail count exceeds history cap"
    );
    assert!(
        result.bytes <= BYTE_BUDGET,
        "committed objects exceed byte budget"
    );
    result
}

fn text(token: u32) -> String {
    format!("文字压力测试 🦀 {token:05}")
}

fn snapshot(store: &Store) -> Vec<(i64, String, String, Option<String>, i64)> {
    store
        .list()
        .expect("list metadata")
        .into_iter()
        .map(|row| {
            (
                row.id,
                row.kind,
                row.preview,
                row.thumbnail_path,
                row.created_at,
            )
        })
        .collect()
}

#[test]
#[ignore = "explicit 10,000-capture disk/SQLite storage stress test"]
fn ten_thousand_text_captures_preserve_mru_and_bounded_files() {
    let started = Instant::now();
    let root = tempdir().expect("isolated test storage");
    let mut store = Store::open(root.path()).expect("open test store");
    let mut expected = VecDeque::<u32>::new();
    let mut first_id = None;
    let mut duplicate_captures = 0usize;
    let mut peak_files = 0usize;
    let mut peak_bytes = 0u64;

    for index in 0..10_000u32 {
        let token = if index % 4 == 0 {
            (index / 4) % 37
        } else {
            10_000 + index
        };
        if let Some(position) = expected.iter().position(|value| *value == token) {
            expected.remove(position);
            duplicate_captures += 1;
        }
        expected.push_front(token);
        expected.truncate(MAX_ITEMS);
        let value = text(token);
        assert!(store
            .capture(value.as_bytes(), TEXT_UTI, None)
            .expect("capture text"));

        let rows = store.list().expect("list after each capture");
        assert_eq!(rows.len(), expected.len());
        assert!(rows.len() <= MAX_ITEMS);
        assert_eq!(rows[0].preview, value, "newest capture not first");
        assert!(rows
            .iter()
            .all(|row| row.kind == "text" && row.thumbnail_path.is_none()));
        // Each accepted text has this fixed byte length. This checks the per-round
        // live-payload budget independently of the Store's internal accounting.
        assert!((rows.len() * value.len()) as u64 <= BYTE_BUDGET);
        // Index 0 belongs to the repeatedly copied hot set. Index 1 is a
        // unique item and must eventually lose both its row and payload.
        if index == 1 {
            first_id = Some(rows[0].id);
        }
        if (index + 1) % 1000 == 0 {
            let actual: Vec<_> = rows.iter().map(|row| row.preview.as_str()).collect();
            let oracle: Vec<_> = expected.iter().map(|token| text(*token)).collect();
            assert_eq!(
                actual,
                oracle.iter().map(String::as_str).collect::<Vec<_>>()
            );
            assert_eq!(
                rows.iter().map(|row| row.id).collect::<HashSet<_>>().len(),
                rows.len()
            );
            let files = objects(root.path());
            assert_eq!(files.payloads, rows.len());
            assert_eq!(files.thumbnails, 0);
            assert_eq!(files.bytes, (rows.len() * value.len()) as u64);
            peak_files = peak_files.max(files.payloads);
            peak_bytes = peak_bytes.max(files.bytes);
            println!(
                "text checkpoint captures={} rows={} files={} bytes={} elapsed={:.2}s",
                index + 1,
                rows.len(),
                files.payloads,
                files.bytes,
                started.elapsed().as_secs_f64()
            );
        }
    }

    assert!(
        duplicate_captures > 100,
        "workload did not exercise live-entry deduplication"
    );
    assert!(store
        .load(first_id.expect("first id"))
        .expect("load evicted id")
        .is_none());
    let rows = store.list().expect("final text list");
    let newest = rows[0].id;
    assert_eq!(
        store
            .load(newest)
            .expect("load latest")
            .expect("latest retained")
            .0,
        text(*expected.front().unwrap()).as_bytes()
    );
    let before_rejection = snapshot(&store);
    assert!(!store
        .capture(&vec![b'x'; MAX_TEXT_BYTES + 1], TEXT_UTI, None)
        .expect("reject oversized text"));
    assert_eq!(snapshot(&store), before_rejection);
    drop(store);
    let reopened = Store::open(root.path()).expect("reopen stress store");
    assert_eq!(snapshot(&reopened), before_rejection);
    let files = objects(root.path());
    assert_eq!(files.payloads, MAX_ITEMS);
    println!("TEXT_STRESS_OK captures=10000 live_duplicates={} rows={} peak_checkpoint_files={} peak_checkpoint_bytes={} elapsed={:.2}s", duplicate_captures, files.payloads, peak_files, peak_bytes, started.elapsed().as_secs_f64());
}

// A real project PNG is followed by deterministic trailing bytes to produce
// distinct payloads and controlled file sizes. This exercises exact-byte Store
// persistence and quota handling; it is not an ImageIO/PNG decoder acceptance test.
fn image_payload(index: u64, padded_size: usize) -> Vec<u8> {
    let mut bytes = Vec::with_capacity(padded_size.max(PNG.len()) + 8);
    bytes.extend_from_slice(PNG);
    bytes.resize(padded_size.max(PNG.len()), 0);
    bytes.extend_from_slice(&index.to_le_bytes());
    bytes
}

#[test]
#[ignore = "explicit 960-image capture, eviction and 256 MiB quota stress test"]
fn image_capture_count_and_byte_evictions_remove_original_files() {
    let started = Instant::now();
    let root = tempdir().expect("isolated image store");
    let mut store = Store::open(root.path()).expect("open test store");
    let mut first_id = None;
    let mut first_paths = HashSet::new();
    let mut peak_files = 0usize;
    let mut peak_bytes = 0u64;

    for index in 0..640u64 {
        let bytes = image_payload(index, PNG.len());
        assert!(store
            .capture(&bytes, PNG_UTI, Some(PNG))
            .expect("capture image"));
        let rows = store.list().expect("image list");
        assert_eq!(rows.len(), ((index + 1) as usize).min(MAX_ITEMS));
        assert!(rows
            .iter()
            .all(|row| row.kind == "image" && row.thumbnail_path.is_some()));
        let files = objects(root.path());
        assert_eq!(files.payloads, rows.len());
        assert_eq!(files.thumbnails, rows.len());
        assert_eq!(
            files.bytes,
            rows.len() as u64 * (bytes.len() + PNG.len()) as u64
        );
        peak_files = peak_files.max(files.payloads + files.thumbnails);
        peak_bytes = peak_bytes.max(files.bytes);
        if index == 0 {
            first_id = Some(rows[0].id);
            first_paths = fs::read_dir(root.path().join("objects"))
                .unwrap()
                .map(|entry| entry.unwrap().path())
                .collect();
        }
        if index == 639 {
            assert_eq!(store.load(rows[0].id).unwrap().unwrap().0, bytes);
        }
        if (index + 1) % 160 == 0 {
            println!(
                "image count checkpoint captures={} rows={} objects={} bytes={} elapsed={:.2}s",
                index + 1,
                rows.len(),
                files.payloads + files.thumbnails,
                files.bytes,
                started.elapsed().as_secs_f64()
            );
        }
    }
    assert!(store.load(first_id.unwrap()).unwrap().is_none());
    assert!(
        first_paths.iter().all(|path| !path.exists()),
        "evicted first image/thumbnail still occupies disk"
    );

    let mut byte_eviction_observed = false;
    for index in 640..960u64 {
        let bytes = image_payload(index, 1024 * 1024);
        assert!(store
            .capture(&bytes, PNG_UTI, Some(PNG))
            .expect("capture quota image"));
        let rows = store.list().expect("quota image list");
        let files = objects(root.path());
        assert_eq!(files.payloads, rows.len());
        assert_eq!(files.thumbnails, rows.len());
        assert!(rows.len() <= MAX_ITEMS);
        peak_files = peak_files.max(files.payloads + files.thumbnails);
        peak_bytes = peak_bytes.max(files.bytes);
        if rows.len() < MAX_ITEMS {
            byte_eviction_observed = true;
        }
        if index % 80 == 79 {
            assert_eq!(store.load(rows[0].id).unwrap().unwrap().0, bytes);
            println!(
                "image quota checkpoint captures={} rows={} objects={} bytes={} elapsed={:.2}s",
                index + 1,
                rows.len(),
                files.payloads + files.thumbnails,
                files.bytes,
                started.elapsed().as_secs_f64()
            );
        }
    }
    assert!(
        byte_eviction_observed,
        "workload did not reach the byte quota"
    );
    let before_rejection = snapshot(&store);
    let bytes_before = objects(root.path()).bytes;
    let oversized = image_payload(9999, MAX_IMAGE_BYTES + 1);
    assert!(!store
        .capture(&oversized, PNG_UTI, Some(PNG))
        .expect("reject oversized image"));
    assert_eq!(snapshot(&store), before_rejection);
    assert_eq!(objects(root.path()).bytes, bytes_before);
    drop(oversized);
    drop(store);
    let reopened = Store::open(root.path()).expect("reopen image stress store");
    assert_eq!(snapshot(&reopened), before_rejection);
    let files = objects(root.path());
    assert_eq!(files.bytes, bytes_before);
    assert_eq!(files.payloads, before_rejection.len());
    println!("IMAGE_STRESS_OK captures=960 rows={} objects={} peak_objects={} bytes={} peak_bytes={} elapsed={:.2}s", files.payloads, files.payloads + files.thumbnails, peak_files, files.bytes, peak_bytes, started.elapsed().as_secs_f64());
}
