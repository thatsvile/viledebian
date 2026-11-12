//! `vile --update` — refresh ~/.local/bin viledesktop binaries from upstream.
//!
//! Mode comes from config `update_mode`:
//! - `binaries`: shallow-clone the dots repo and install `dist/<arch>/` when newer
//! - `source`: shallow-clone and `cargo build --release` from `viledesktop/`

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{bail, Context, Result};
use vile_protocol::{load_config, UpdateMode};

const REPO_URL: &str = "https://github.com/thatsvile/viledebian.git";
const REPO_BRANCH: &str = "main";
const BINS: &[&str] = &[
    "vile",
    "viledaemon",
    "vilebar",
    "vilecolors",
    "vilewall",
    "vileshot",
    "vilefox",
];

pub fn run() -> Result<()> {
    let cfg = load_config().context("loading ~/.config/vile/config.json")?;
    match cfg.update_mode {
        UpdateMode::Binaries => update_binaries(),
        UpdateMode::Source => update_source(),
    }
}

fn cache_root() -> PathBuf {
    std::env::var_os("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".cache")))
        .unwrap_or_else(|| PathBuf::from(".cache"))
        .join("vile")
        .join("src")
}

fn stamp_path() -> PathBuf {
    cache_root().join("viledesktop.installed")
}

fn dots_checkout() -> PathBuf {
    cache_root().join("vile-dots")
}

fn local_bin_dir() -> PathBuf {
    std::env::var_os("HOME")
        .map(|h| PathBuf::from(h).join(".local").join("bin"))
        .unwrap_or_else(|| PathBuf::from(".local/bin"))
}

fn host_arch() -> Result<&'static str> {
    match std::env::consts::ARCH {
        "x86_64" => Ok("x86_64"),
        "aarch64" => Ok("aarch64"),
        other => bail!("unsupported architecture for vile --update: {other}"),
    }
}

fn read_stamp() -> Option<String> {
    fs::read_to_string(stamp_path())
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

fn write_stamp(version: &str) -> Result<()> {
    let root = cache_root();
    fs::create_dir_all(&root).with_context(|| format!("creating {}", root.display()))?;
    fs::write(stamp_path(), format!("{version}\n"))
        .with_context(|| format!("writing {}", stamp_path().display()))
}

fn ensure_repo(dir: &Path) -> Result<()> {
    fs::create_dir_all(dir.parent().unwrap_or(Path::new(".")))
        .with_context(|| format!("creating {}", dir.display()))?;

    let status = if dir.join(".git").is_dir() {
        run_git(dir, &["remote", "set-url", "origin", REPO_URL])?;
        run_git(
            dir,
            &["fetch", "--quiet", "--depth", "1", "origin", REPO_BRANCH],
        )?;
        run_git(dir, &["checkout", "-q", "-B", REPO_BRANCH, "FETCH_HEAD"])?;
        run_git(dir, &["reset", "--quiet", "--hard", "FETCH_HEAD"])
    } else {
        if dir.exists() {
            fs::remove_dir_all(dir)
                .with_context(|| format!("removing stale {}", dir.display()))?;
        }
        let parent = dir.parent().unwrap_or(Path::new("."));
        Command::new("git")
            .current_dir(parent)
            .args([
                "clone",
                "--quiet",
                "--depth",
                "1",
                "--branch",
                REPO_BRANCH,
                REPO_URL,
                dir.file_name()
                    .and_then(|s| s.to_str())
                    .unwrap_or("vile-dots"),
            ])
            .env("GIT_CONFIG_COUNT", "1")
            .env("GIT_CONFIG_KEY_0", "advice.detachedHead")
            .env("GIT_CONFIG_VALUE_0", "false")
            .status()
            .context("running git clone")
            .and_then(|s| {
                if s.success() {
                    Ok(())
                } else {
                    bail!("git clone failed with {s}");
                }
            })
    };
    status
}

fn run_git(dir: &Path, args: &[&str]) -> Result<()> {
    let status = Command::new("git")
        .current_dir(dir)
        .args(args)
        .env("GIT_CONFIG_COUNT", "1")
        .env("GIT_CONFIG_KEY_0", "advice.detachedHead")
        .env("GIT_CONFIG_VALUE_0", "false")
        .status()
        .with_context(|| format!("running git {}", args.join(" ")))?;
    if !status.success() {
        bail!("git {} failed with {status}", args.join(" "));
    }
    Ok(())
}

fn git_stdout(dir: &Path, args: &[&str]) -> Result<String> {
    let out = Command::new("git")
        .current_dir(dir)
        .args(args)
        .output()
        .with_context(|| format!("running git {}", args.join(" ")))?;
    if !out.status.success() {
        bail!(
            "git {} failed: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr)
        );
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

fn install_bins_from(src_dir: &Path) -> Result<()> {
    let dest_dir = local_bin_dir();
    fs::create_dir_all(&dest_dir).with_context(|| format!("creating {}", dest_dir.display()))?;
    for bin in BINS {
        let src = src_dir.join(bin);
        if !src.is_file() {
            bail!("missing binary {}", src.display());
        }
        let dest = dest_dir.join(bin);
        // Unlink first so a running binary does not block the overwrite.
        let _ = fs::remove_file(&dest);
        fs::copy(&src, &dest).with_context(|| {
            format!("copying {} -> {}", src.display(), dest.display())
        })?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = fs::metadata(&dest)?.permissions();
            perms.set_mode(0o755);
            fs::set_permissions(&dest, perms)?;
        }
    }
    let vilefox = dest_dir.join("vilefox");
    if vilefox.is_file() {
        let _ = Command::new(&vilefox).arg("install").status();
    }
    Ok(())
}

fn update_binaries() -> Result<()> {
    let checkout = dots_checkout();
    println!("Fetching {REPO_URL} ({REPO_BRANCH})...");
    ensure_repo(&checkout)?;

    let arch = host_arch()?;
    let dist = checkout.join("dist").join(arch);
    let version_path = dist.join("VERSION");
    if !version_path.is_file() {
        bail!(
            "no bundled binaries for {arch} at {} — set \"update_mode\": \"source\" in config.json or run pack-dist.sh upstream",
            dist.display()
        );
    }
    let remote = fs::read_to_string(&version_path)
        .with_context(|| format!("reading {}", version_path.display()))?
        .trim()
        .to_string();
    if remote.is_empty() {
        bail!("empty VERSION in {}", dist.display());
    }

    let installed = read_stamp();
    let vile_bin = local_bin_dir().join("vile");
    if vile_bin.is_file() && installed.as_deref() == Some(remote.as_str()) {
        println!("viledesktop: already up to date ({remote}).");
        return Ok(());
    }

    match &installed {
        Some(cur) => println!("viledesktop: {cur} -> {remote} (binaries)"),
        None => println!("viledesktop: installing {remote} (binaries)..."),
    }

    for bin in BINS {
        if !dist.join(bin).is_file() {
            bail!("incomplete dist bundle: missing {}", dist.join(bin).display());
        }
    }
    install_bins_from(&dist)?;
    write_stamp(&remote)?;
    println!("viledesktop updated ({remote}).");
    Ok(())
}

fn resolve_cargo() -> Result<PathBuf> {
    if let Ok(path) = which("cargo") {
        return Ok(path);
    }
    if let Ok(home) = std::env::var("HOME") {
        let candidate = PathBuf::from(home).join(".cargo").join("bin").join("cargo");
        if candidate.is_file() {
            return Ok(candidate);
        }
    }
    bail!("cargo not found; install rustup or set \"update_mode\": \"binaries\"");
}

fn which(bin: &str) -> Result<PathBuf> {
    let out = Command::new("sh")
        .args(["-c", &format!("command -v {bin}")])
        .output()
        .context("resolving command on PATH")?;
    if !out.status.success() {
        bail!("{bin} not on PATH");
    }
    let path = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if path.is_empty() {
        bail!("{bin} not on PATH");
    }
    Ok(PathBuf::from(path))
}

fn update_source() -> Result<()> {
    let checkout = dots_checkout();
    println!("Fetching {REPO_URL} ({REPO_BRANCH})...");
    ensure_repo(&checkout)?;

    let desktop = checkout.join("viledesktop");
    if !desktop.join("Cargo.toml").is_file() {
        bail!("viledesktop sources missing at {}", desktop.display());
    }

    let remote = git_stdout(&checkout, &["rev-parse", "--short=12", "HEAD:viledesktop"])?;
    let installed = read_stamp();
    let vile_bin = local_bin_dir().join("vile");
    if vile_bin.is_file() && installed.as_deref() == Some(remote.as_str()) {
        println!("viledesktop: already up to date ({remote}).");
        return Ok(());
    }

    match &installed {
        Some(cur) => println!("viledesktop: {cur} -> {remote} (source)"),
        None => println!("viledesktop: building {remote}..."),
    }

    let cargo = resolve_cargo()?;

    let status = Command::new(&cargo)
        .current_dir(&desktop)
        .args(["build", "--release", "--workspace"])
        .status()
        .context("running cargo build --release")?;
    if !status.success() {
        bail!("cargo build failed with {status}");
    }

    install_bins_from(&desktop.join("target").join("release"))?;
    write_stamp(&remote)?;
    println!("viledesktop updated ({remote}).");
    Ok(())
}
