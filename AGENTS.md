# Pastty development

Work in `/Volumes/Docs/IO/Pastty`. This is the authoritative working directory.

## Scope and sources

Read `docs/技术选型研究.md` before implementation or architecture changes. It defines the minimal product and resource budgets. Read `docs/发布与开源.md` before build, signing, CI, release, or distribution work. `docs/REA逆向分析.md` supplies reference evidence, not a proven diagnosis of Maccy's memory use.

Implement local text/image clipboard history, normal system Cmd+V, configurable history hotkey (default Option+V), mouse/arrow selection and Enter paste, and Esc dismissal. Settings contain exactly menu-bar icon visibility, history hotkey, and login launch. Reopening the app exposes settings when its icon is hidden; only one process owns clipboard observation and hotkeys.

The implementation uses Rust + a thin Objective-C/AppKit C ABI bridge + SQLite, with image files and bounded thumbnail caches. Rust owns history/configuration; `native/` owns UI and macOS APIs. Keep raw clipboard contents out of logs. Preserve original image quality for paste and explicitly bound storage, decoding, queues and cache bytes. Source language alone is not evidence of low memory.

## Delivery

This is an MIT open-source application intended for GitHub Releases and downloadable DMG installation. The repository contains project-owned source and public documentation. `research/` contains local third-party artifacts and evidence and is excluded from Git; retain attribution for any source actually reused.

Use focused validation for storage and paste state transitions, real-app checks for focus/hotkeys/images, and Release-mode measurements for resource claims. Distinguish compiled, locally exercised, signed, notarized, and tested on another machine. Keep the current delivery state in README honest.

Preserve unrelated changes and assign distinct file ownership if agents are used. Keep signing credentials in Keychain or CI secrets. Create the remote and publish assets only when that step is requested. Confirm the final bundle identifier before assigning signing identities and public releases.
