//! Small C ABI between the Rust history store and native AppKit shell.
//! Buffers have one owner: native callers release them through the matching free function.
pub mod store;

use std::ffi::{c_char, CStr, CString};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use store::Store;

static STORE: OnceLock<Mutex<Store>> = OnceLock::new();
const MAX_INPUT: usize = 16 * 1024 * 1024;
const MAX_THUMBNAIL: usize = 256 * 1024;

/// Validate opt-in test flags before any application data is opened.
pub fn validate_test_mode(
    smoke: Option<&str>,
    cycles: Option<&str>,
    explicit_data_dir: bool,
) -> Result<bool, String> {
    if smoke.is_none() && cycles.is_none() {
        return Ok(false);
    }
    if smoke != Some("1") || !explicit_data_dir {
        return Err(
            "Test mode requires PASTTY_SMOKE_TEST=1 and an explicit isolated data directory".into(),
        );
    }
    if let Some(value) = cycles {
        if value.is_empty()
            || !value.bytes().all(|byte| byte.is_ascii_digit())
            || !value
                .parse::<u32>()
                .is_ok_and(|number| (1..=10000).contains(&number))
        {
            return Err("Stress cycle count must be between 1 and 10000".into());
        }
    }
    Ok(true)
}

/// Read-only preflight: test runs must use an existing empty private directory.
pub fn validate_test_directory(path: &Path, home: &Path) -> Result<(), String> {
    if !path.is_absolute() {
        return Err("Test data directory must be absolute".into());
    }
    let metadata =
        std::fs::symlink_metadata(path).map_err(|_| "Create a fresh empty test directory first")?;
    if !metadata.is_dir() || metadata.file_type().is_symlink() {
        return Err("Test data directory must be a directory, not a symlink".into());
    }
    let canonical = std::fs::canonicalize(path).map_err(|_| "Cannot resolve test directory")?;
    let production = home.join("Library/Application Support/Pastty");
    let production = std::fs::canonicalize(&production).unwrap_or(production);
    if canonical.starts_with(production) {
        return Err("Test mode cannot use the application history directory".into());
    }
    if std::fs::read_dir(&canonical)
        .map_err(|_| "Cannot inspect test directory")?
        .next()
        .is_some()
    {
        return Err("Test data directory must be empty; existing history is never opened".into());
    }
    Ok(())
}

pub fn data_directory() -> Result<PathBuf, String> {
    if let Some(root) = std::env::var_os("PASTTY_DATA_DIR") {
        let root = PathBuf::from(root);
        if !root.is_absolute() {
            return Err("PASTTY_DATA_DIR must be absolute".into());
        }
        return Ok(root);
    }
    let home = std::env::var_os("HOME").ok_or("Cannot determine user home directory")?;
    Ok(PathBuf::from(home).join("Library/Application Support/Pastty"))
}

pub fn prepare_directory(path: &Path) -> Result<(), String> {
    if std::fs::symlink_metadata(path).is_ok_and(|metadata| metadata.file_type().is_symlink()) {
        return Err("Application data directory must not be a symlink".into());
    }
    std::fs::create_dir_all(path).map_err(|_| "Cannot create application data directory")?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))
            .map_err(|_| "Cannot protect application data directory")?;
    }
    Ok(())
}

pub fn initialize(path: &Path) -> Result<(), String> {
    prepare_directory(path)?;
    STORE
        .set(Mutex::new(Store::open(path)?))
        .map_err(|_| "Store already initialized".into())
}

fn with_store<T>(action: impl FnOnce(&mut Store) -> Result<T, String>) -> Result<T, String> {
    let mut store = STORE
        .get()
        .ok_or("Store unavailable")?
        .lock()
        .map_err(|_| "Store unavailable")?;
    action(&mut store)
}

fn string_result(value: String) -> *mut c_char {
    CString::new(value)
        .map(CString::into_raw)
        .unwrap_or(std::ptr::null_mut())
}

/// # Safety
/// Pointer must address a valid NUL-terminated UTF-8 string for the duration of the call.
unsafe fn input_string<'a>(value: *const c_char) -> Option<&'a str> {
    if value.is_null() {
        None
    } else {
        CStr::from_ptr(value).to_str().ok()
    }
}

#[no_mangle]
pub extern "C" fn pastty_list() -> *mut c_char {
    match with_store(|store| {
        serde_json::to_string(&store.list()?).map_err(|_| "Cannot encode history".into())
    }) {
        Ok(value) => string_result(value),
        Err(_) => std::ptr::null_mut(),
    }
}

/// # Safety
/// The nonnull pointer must have been returned by this library, and freed only once.
#[no_mangle]
pub unsafe extern "C" fn pastty_free_string(value: *mut c_char) {
    if !value.is_null() {
        drop(CString::from_raw(value));
    }
}

/// # Safety
/// Nonnull buffers must cover their lengths; uti must be a valid C string.
#[no_mangle]
pub unsafe extern "C" fn pastty_capture(
    data: *const u8,
    len: usize,
    uti: *const c_char,
    thumbnail: *const u8,
    thumbnail_len: usize,
) -> i32 {
    if data.is_null()
        || len == 0
        || len > MAX_INPUT
        || thumbnail_len > MAX_THUMBNAIL
        || (thumbnail.is_null() && thumbnail_len != 0)
    {
        return 1;
    }
    let Some(uti) = input_string(uti) else {
        return 1;
    };
    let data = std::slice::from_raw_parts(data, len);
    let thumbnail = if thumbnail_len == 0 {
        None
    } else {
        Some(std::slice::from_raw_parts(thumbnail, thumbnail_len))
    };
    match with_store(|store| store.capture(data, uti, thumbnail)) {
        Ok(true) => 0,
        Ok(false) => 1,
        Err(_) => -1,
    }
}

/// # Safety
/// Output pointers must be writable. Free successful output with the matching library functions.
#[no_mangle]
pub unsafe extern "C" fn pastty_load(
    id: i64,
    data: *mut *mut u8,
    len: *mut usize,
    uti: *mut *mut c_char,
) -> i32 {
    if data.is_null() || len.is_null() || uti.is_null() {
        return -1;
    }
    *data = std::ptr::null_mut();
    *len = 0;
    *uti = std::ptr::null_mut();
    match with_store(|store| store.load(id)) {
        Ok(Some((bytes, kind))) => {
            let kind = string_result(kind);
            if kind.is_null() {
                return -1;
            }
            let bytes = bytes.into_boxed_slice();
            *len = bytes.len();
            *data = Box::into_raw(bytes) as *mut u8;
            *uti = kind;
            0
        }
        Ok(None) => 1,
        Err(_) => -1,
    }
}

/// # Safety
/// Data and length must match a successful pastty_load output, freed exactly once.
#[no_mangle]
pub unsafe extern "C" fn pastty_free_data(data: *mut u8, len: usize) {
    if !data.is_null() {
        drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(data, len)));
    }
}

/// # Safety
/// Key must be a valid C string.
#[no_mangle]
pub unsafe extern "C" fn pastty_get_bool(key: *const c_char, fallback: i32) -> i32 {
    let Some(key) = input_string(key) else {
        return fallback;
    };
    with_store(|store| store.get_bool(key, fallback != 0))
        .map(i32::from)
        .unwrap_or(fallback)
}

/// # Safety
/// Key must be a valid C string.
#[no_mangle]
pub unsafe extern "C" fn pastty_set_bool(key: *const c_char, value: i32) -> i32 {
    let Some(key) = input_string(key) else {
        return -1;
    };
    if !matches!(key, "show_icon") {
        return -1;
    }
    with_store(|store| store.set_bool(key, value != 0))
        .map(|_| 0)
        .unwrap_or(-1)
}

#[no_mangle]
pub extern "C" fn pastty_get_hotkey() -> *mut c_char {
    let (keycode, modifiers) = with_store(|store| store.get_hotkey()).unwrap_or((9, 2048));
    string_result(serde_json::json!({"keycode":keycode,"modifiers":modifiers}).to_string())
}

pub fn valid_hotkey(keycode: u32, modifiers: u32) -> bool {
    const ALLOWED: u32 = 256 | 512 | 2048 | 4096;
    keycode <= 127
        && modifiers & !ALLOWED == 0
        && modifiers & (256 | 2048 | 4096) != 0
        && !(keycode == 9 && modifiers == 256)
}

#[no_mangle]
pub extern "C" fn pastty_set_hotkey(keycode: u32, modifiers: u32) -> i32 {
    if !valid_hotkey(keycode, modifiers) {
        return -1;
    }
    with_store(|store| store.set_hotkey(keycode, modifiers))
        .map(|_| 0)
        .unwrap_or(-1)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn smoke_configuration_requires_explicit_isolation_and_exact_flag() {
        assert!(validate_test_mode(None, None, false).is_ok());
        assert!(validate_test_mode(Some("1"), None, true).unwrap());
        assert!(validate_test_mode(Some("1"), Some("1000"), true).unwrap());
        for (smoke, cycles, explicit) in [
            (Some("0"), None, true),
            (Some("1"), None, false),
            (None, Some("1000"), true),
            (Some("1"), Some("0"), true),
            (Some("1"), Some("10001"), true),
            (Some("1"), Some("+1"), true),
            (Some("1"), Some(""), true),
        ] {
            assert!(validate_test_mode(smoke, cycles, explicit).is_err());
        }
    }

    #[test]
    fn test_directory_guard_is_read_only_and_rejects_real_history() {
        let temporary = tempfile::tempdir().unwrap();
        let home = temporary.path().join("home");
        let production = home.join("Library/Application Support/Pastty");
        std::fs::create_dir_all(&production).unwrap();
        let original = production.join("history.sqlite");
        std::fs::write(&original, b"untouched user data").unwrap();
        assert!(validate_test_directory(&production, &home).is_err());
        assert_eq!(std::fs::read(&original).unwrap(), b"untouched user data");
        assert_eq!(std::fs::read_dir(&production).unwrap().count(), 1);
        let child = production.join("empty");
        std::fs::create_dir(&child).unwrap();
        assert!(validate_test_directory(&child, &home).is_err());
        let isolated = temporary.path().join("isolated");
        std::fs::create_dir(&isolated).unwrap();
        assert!(validate_test_directory(&isolated, &home).is_ok());
        assert!(validate_test_directory(&temporary.path().join("missing"), &home).is_err());
        std::fs::write(isolated.join("existing"), b"keep").unwrap();
        assert!(validate_test_directory(&isolated, &home).is_err());
        assert_eq!(std::fs::read(isolated.join("existing")).unwrap(), b"keep");
    }

    #[test]
    #[cfg(unix)]
    fn test_directory_guard_rejects_symlink_alias() {
        let temporary = tempfile::tempdir().unwrap();
        let actual = temporary.path().join("actual");
        std::fs::create_dir(&actual).unwrap();
        let alias = temporary.path().join("alias");
        std::os::unix::fs::symlink(&actual, &alias).unwrap();
        assert!(validate_test_directory(&alias, temporary.path()).is_err());
        assert_eq!(std::fs::read_dir(actual).unwrap().count(), 0);
    }
    #[test]
    #[cfg(unix)]
    fn directory_setup_rejects_symlink_without_changing_target_permissions() {
        use std::os::unix::fs::{symlink, PermissionsExt};
        let temporary = tempfile::tempdir().unwrap();
        let target = temporary.path().join("target");
        std::fs::create_dir(&target).unwrap();
        std::fs::set_permissions(&target, std::fs::Permissions::from_mode(0o755)).unwrap();
        let link = temporary.path().join("alias");
        symlink(&target, &link).unwrap();
        assert!(prepare_directory(&link).is_err());
        assert_eq!(
            std::fs::metadata(&target).unwrap().permissions().mode() & 0o777,
            0o755
        );
    }
    #[test]
    fn reserves_system_paste_and_rejects_invalid_hotkeys() {
        assert!(valid_hotkey(9, 2048));
        assert!(!valid_hotkey(9, 256));
        assert!(!valid_hotkey(9, 0));
        assert!(!valid_hotkey(9, 512));
        assert!(!valid_hotkey(128, 2048));
        assert!(!valid_hotkey(9, u32::MAX));
    }
    #[test]
    fn ffi_rejects_invalid_buffer_contracts_before_reading() {
        unsafe {
            assert_eq!(
                pastty_capture(std::ptr::null(), 1, std::ptr::null(), std::ptr::null(), 0),
                1
            );
            assert_eq!(
                pastty_load(
                    1,
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    std::ptr::null_mut()
                ),
                -1
            );
            assert_eq!(pastty_set_bool(std::ptr::null(), 1), -1);
        }
    }
}
