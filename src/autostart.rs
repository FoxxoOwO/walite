const REG_KEY_PATH: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";
const REG_APP_NAME: &str = "WaLite";

/// Check if Warust is configured to start with Windows.
pub fn is_autostart_enabled() -> bool {
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        use std::process::Command;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        // Query HKCU\Software\Microsoft\Windows\CurrentVersion\Run /v WaLite
        let output = Command::new("reg")
            .args(["query", &format!(r"HKCU\{}", REG_KEY_PATH), "/v", REG_APP_NAME])
            .creation_flags(CREATE_NO_WINDOW)
            .output();

        if let Ok(out) = output {
            out.status.success()
        } else {
            false
        }
    }
    #[cfg(not(target_os = "windows"))]
    {
        false
    }
}

/// Prefer launching `warust_gui.exe --tray` when bundled next to `warust.exe`
/// (or built under `gui/build/windows/x64/runner/Release/`), falling back to
/// the current executable.
#[cfg(target_os = "windows")]
fn autostart_executable() -> anyhow::Result<std::path::PathBuf> {
    let current_exe = std::env::current_exe()?;
    if let Some(dir) = current_exe.parent() {
        let sibling = dir.join("warust_gui.exe");
        if sibling.is_file() {
            return Ok(sibling);
        }
        // When running from target/release or target/debug in the repo:
        if let Some(repo_root) = dir.parent().and_then(|p| p.parent()) {
            let release_gui = repo_root.join(r"gui\build\windows\x64\runner\Release\warust_gui.exe");
            if release_gui.is_file() {
                return Ok(release_gui);
            }
        }
    }
    Ok(current_exe)
}

/// Enable or disable starting WaLite with Windows.
pub fn set_autostart_enabled(enabled: bool) -> anyhow::Result<()> {
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        use std::process::Command;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;

        if enabled {
            let exe = autostart_executable()?;
            let exe_str = exe.to_string_lossy().to_string();
            // Run with --tray flag so it starts in background/tray
            let reg_value = format!("\"{}\" --tray", exe_str);

            let status = Command::new("reg")
                .args([
                    "add",
                    &format!(r"HKCU\{}", REG_KEY_PATH),
                    "/v",
                    REG_APP_NAME,
                    "/t",
                    "REG_SZ",
                    "/d",
                    &reg_value,
                    "/f",
                ])
                .creation_flags(CREATE_NO_WINDOW)
                .status()?;

            if !status.success() {
                anyhow::bail!("Failed to add registry entry for autostart");
            }
        } else {
            // Delete the registry value if it exists
            let status = Command::new("reg")
                .args([
                    "delete",
                    &format!(r"HKCU\{}", REG_KEY_PATH),
                    "/v",
                    REG_APP_NAME,
                    "/f",
                ])
                .creation_flags(CREATE_NO_WINDOW)
                .status()?;

            // Error 1 from reg delete simply means it didn't exist, which is fine
            let _ = status;
        }
        // Clean up legacy Warust autostart entry if present.
        let _ = Command::new("reg")
            .args([
                "delete",
                &format!(r"HKCU\{}", REG_KEY_PATH),
                "/v",
                "Warust",
                "/f",
            ])
            .creation_flags(CREATE_NO_WINDOW)
            .status();

        Ok(())
    }
    #[cfg(not(target_os = "windows"))]
    {
        let _ = enabled;
        Ok(())
    }
}
