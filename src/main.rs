use fs2::FileExt;
use std::fs::OpenOptions;

fn main() {
    if let Err(error) = run() {
        eprintln!("Pastty: {error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let root = pastty::data_directory()?;
    pastty::prepare_directory(&root)?;
    let mut options = OpenOptions::new();
    options.create(true).read(true).write(true).truncate(false);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let lock = options
        .open(root.join("instance.lock"))
        .map_err(|_| "Cannot open application lock")?;
    if lock.try_lock_exclusive().is_err() {
        #[cfg(target_os = "macos")]
        unsafe {
            pastty_reopen_existing();
        }
        return Ok(());
    }
    pastty::initialize(&root)?;
    #[cfg(target_os = "macos")]
    let result = unsafe { pastty_run() };
    #[cfg(not(target_os = "macos"))]
    let result = {
        eprintln!("Pastty requires macOS 14 or later.");
        1
    };
    let _ = FileExt::unlock(&lock);
    if result == 0 {
        Ok(())
    } else {
        Err("Native application failed to start".into())
    }
}

#[cfg(target_os = "macos")]
extern "C" {
    fn pastty_run() -> i32;
    fn pastty_reopen_existing();
}
