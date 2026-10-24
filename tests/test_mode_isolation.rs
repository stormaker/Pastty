//! Reject unsafe test startup through the actual binary, before SQLite or AppKit.
use std::fs;
use std::process::Command;
use tempfile::tempdir;

fn command() -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_pastty"));
    command
        .env("PASTTY_SMOKE_TEST", "1")
        .env("PASTTY_STRESS_CYCLES", "1000");
    command
}

#[test]
fn missing_explicit_test_path_is_rejected_before_default_history_is_opened() {
    let output = command().env_remove("PASTTY_DATA_DIR").output().unwrap();
    assert!(!output.status.success());
    let error = String::from_utf8(output.stderr).unwrap();
    assert!(
        error.contains("explicit isolated data directory"),
        "{error}"
    );
}

#[test]
fn existing_history_is_never_opened_or_modified_by_test_startup() {
    let root = tempdir().unwrap();
    let database = root.path().join("history.sqlite");
    fs::write(&database, b"private history must remain untouched").unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(root.path(), fs::Permissions::from_mode(0o755)).unwrap();
    }
    let output = command()
        .env("PASTTY_DATA_DIR", root.path())
        .output()
        .unwrap();
    assert!(!output.status.success());
    let error = String::from_utf8(output.stderr).unwrap();
    assert!(
        error.contains("Test data directory must be empty"),
        "{error}"
    );
    assert_eq!(
        fs::read(database).unwrap(),
        b"private history must remain untouched"
    );
    assert_eq!(fs::read_dir(root.path()).unwrap().count(), 1);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            fs::metadata(root.path()).unwrap().permissions().mode() & 0o777,
            0o755
        );
    }
}

#[test]
fn invalid_stress_parameters_do_not_create_the_requested_directory() {
    let temporary = tempdir().unwrap();
    let requested = temporary.path().join("must-not-be-created");
    let output = command()
        .env("PASTTY_DATA_DIR", &requested)
        .env("PASTTY_STRESS_CYCLES", "10001")
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert!(String::from_utf8(output.stderr)
        .unwrap()
        .contains("between 1 and 10000"));
    assert!(!requested.exists());
}
