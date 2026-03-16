// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

// =============================================================================
// session-sentinel :: src/core/config.as
// =============================================================================
// Configuration system for the multi-AI session health monitor.
//
// Defines per-provider storage configuration, global sentinel thresholds,
// and serialisation to/from the TOML config file at
// ~/.config/session-sentinel/config.toml.
//
// The config is intentionally kept in a single TOML file so that both the
// daemon and the PanLL panel can read it without IPC.
// =============================================================================

module SessionSentinel.Core.Config

// ---------------------------------------------------------------------------
// Effects
// ---------------------------------------------------------------------------

/// IO effect — filesystem reads, writes, env-var lookups.
effect IO {
    fn read_file(path: String)  -> Result[String, IOError];
    fn write_file(path: String, contents: String) -> Result[Unit, IOError];
    fn env_var(name: String)    -> Option[String];
    fn path_exists(path: String) -> Bool;
    fn create_dir_all(path: String) -> Result[Unit, IOError];
}

// ---------------------------------------------------------------------------
// Error types
// ---------------------------------------------------------------------------

/// Errors that can occur while loading or saving configuration.
type ConfigError =
    | FileNotFound      String          // path that was expected
    | ParseError        String          // TOML parse failure detail
    | SerialiseError    String          // could not write TOML
    | PermissionDenied  String          // path we could not access
    | IOFault           IOError         // pass-through from IO effect

// ---------------------------------------------------------------------------
// Core configuration types
// ---------------------------------------------------------------------------

/// Per-AI-provider storage configuration.
///
/// Each provider has one or more directories that session-sentinel watches.
/// `stale_days` controls when conversations / caches are considered prunable.
/// `scan_interval_override` lets a heavy provider (e.g. Ollama models) be
/// scanned less frequently than the global cadence.
type AIProviderConfig = {
    /// Human-readable provider name, e.g. "Claude", "Ollama".
    name: String,

    /// Absolute paths to the directories that hold this provider's data.
    /// Multiple paths allow for XDG overrides or split storage.
    storage_paths: Vec[String],

    /// Number of days after which a conversation / cache entry is "stale".
    /// Used by the healer to decide what to prune.
    stale_days: Nat,

    /// Per-provider scan interval in seconds.  When `None`, the global
    /// `scan_interval_secs` from `SentinelConfig` is used.
    scan_interval_override: Option[Nat],

    /// Whether the healer is allowed to touch this provider's files.
    /// Set to `false` for providers whose data you never want pruned
    /// (e.g. manually-curated Ollama models).
    auto_heal: Bool
}

/// Size thresholds that partition storage into health zones.
///
/// All values are in **bytes**.  The zones are:
///   Green  :  total <= green_max
///   Yellow :  green_max < total <= yellow_max
///   Red    :  yellow_max < total <= red_max
///   Purple :  total > red_max
type SizeThresholds = {
    /// Upper bound (inclusive) for the Green zone.  Default: 200 MB.
    green_max: Nat,

    /// Upper bound (inclusive) for the Yellow zone.  Default: 500 MB.
    yellow_max: Nat,

    /// Upper bound (inclusive) for the Red zone.  Default: 800 MB.
    /// Anything above this is Purple (critical).
    red_max: Nat
}

/// Top-level sentinel configuration.
///
/// Loaded once at startup and reloaded on SIGHUP.  The canonical location
/// is `~/.config/session-sentinel/config.toml`.
type SentinelConfig = {
    /// Registered AI providers to monitor.
    providers: Vec[AIProviderConfig],

    /// Byte thresholds for health zone classification.
    thresholds: SizeThresholds,

    /// Default scan interval in seconds.  Individual providers may override.
    scan_interval_secs: Nat,

    /// Master switch for the self-healing engine.
    enable_self_healing: Bool,

    /// Master switch for the diagnostics subsystem.
    enable_diagnostics: Bool,

    /// Path to the persistent log file (diagnostic entries are also written
    /// here so they survive daemon restarts).
    log_path: String,

    /// Unix-domain socket path for the PanLL panel to connect to.
    /// The monitor pushes JSON frames down this socket on every scan cycle.
    panel_socket_path: String
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Canonical config file location, relative to $HOME.
let CONFIG_REL_PATH: String = ".config/session-sentinel/config.toml"

/// 200 MB in bytes — default Green ceiling.
let DEFAULT_GREEN_MAX: Nat = 209_715_200

/// 500 MB in bytes — default Yellow ceiling.
let DEFAULT_YELLOW_MAX: Nat = 524_288_000

/// 800 MB in bytes — default Red ceiling.  Above this is Purple.
let DEFAULT_RED_MAX: Nat = 838_860_800

/// Default scan cadence: every 60 seconds.
let DEFAULT_SCAN_INTERVAL: Nat = 60

/// Default log file location, relative to $HOME.
let DEFAULT_LOG_REL: String = ".local/share/session-sentinel/sentinel.log"

/// Default PanLL socket location.
let DEFAULT_SOCKET_REL: String = ".local/share/session-sentinel/panel.sock"

// ---------------------------------------------------------------------------
// Default provider configurations
// ---------------------------------------------------------------------------

/// Claude Code — conversations live under ~/.claude/ as project dirs
/// containing JSONL transcripts and subagent working directories.
/// Stale after 7 days by default; auto-heal enabled.
total fn default_claude_provider() -> AIProviderConfig {
    {
        name: "Claude",
        storage_paths: vec!["~/.claude/"],
        stale_days: 7,
        scan_interval_override: None,
        auto_heal: true
    }
}

/// GitHub Copilot — caches live under the XDG config directory.
/// Stale after 14 days; auto-heal enabled.
total fn default_copilot_provider() -> AIProviderConfig {
    {
        name: "Copilot",
        storage_paths: vec!["~/.config/github-copilot/"],
        stale_days: 14,
        scan_interval_override: None,
        auto_heal: true
    }
}

/// Ollama — model blobs under ~/.ollama/models/.
/// Models are large and intentionally kept; stale threshold is 30 days
/// and auto-heal is OFF by default (user must opt in to model pruning).
total fn default_ollama_provider() -> AIProviderConfig {
    {
        name: "Ollama",
        storage_paths: vec!["~/.ollama/"],
        stale_days: 30,
        scan_interval_override: Some(300),   // scan every 5 min — models change rarely
        auto_heal: false
    }
}

/// LM Studio — model cache under ~/.cache/lm-studio/.
/// Similar profile to Ollama: large, infrequent changes.
total fn default_lmstudio_provider() -> AIProviderConfig {
    {
        name: "LM Studio",
        storage_paths: vec!["~/.cache/lm-studio/"],
        stale_days: 30,
        scan_interval_override: Some(300),
        auto_heal: false
    }
}

/// All built-in provider defaults collected in registration order.
total fn builtin_providers() -> Vec[AIProviderConfig] {
    vec![
        default_claude_provider(),
        default_copilot_provider(),
        default_ollama_provider(),
        default_lmstudio_provider()
    ]
}

// ---------------------------------------------------------------------------
// Default sentinel configuration
// ---------------------------------------------------------------------------

/// Constructs a fully-populated `SentinelConfig` with sane defaults.
///
/// `home` is the value of `$HOME` — passed explicitly so this function
/// remains pure (the IO effect is only needed in `load_config`).
total fn default_config(home: ref String) -> SentinelConfig {
    {
        providers: builtin_providers(),
        thresholds: {
            green_max:  DEFAULT_GREEN_MAX,
            yellow_max: DEFAULT_YELLOW_MAX,
            red_max:    DEFAULT_RED_MAX
        },
        scan_interval_secs: DEFAULT_SCAN_INTERVAL,
        enable_self_healing: true,
        enable_diagnostics:  true,
        log_path:            format!("{}/{}", home, DEFAULT_LOG_REL),
        panel_socket_path:   format!("{}/{}", home, DEFAULT_SOCKET_REL)
    }
}

// ---------------------------------------------------------------------------
// Path resolution
// ---------------------------------------------------------------------------

/// Expand a leading `~` in a path to the user's home directory.
///
/// Returns the path unchanged when it does not start with `~/` or `~`.
total fn expand_tilde(path: ref String, home: ref String) -> String {
    match path {
        p if p.starts_with("~/") => format!("{}{}", home, p.slice(1, p.len())),
        "~"                      => home.clone(),
        _                        => path.clone()
    }
}

/// Resolve the absolute path to the config file.
///
/// Checks `$SESSION_SENTINEL_CONFIG` first; falls back to
/// `$XDG_CONFIG_HOME/session-sentinel/config.toml`, then
/// `~/.config/session-sentinel/config.toml`.
fn resolve_config_path() -> String / IO {
    match IO.env_var("SESSION_SENTINEL_CONFIG") {
        Some(p) => p,
        None    => {
            let home = IO.env_var("HOME").unwrap_or("/root");
            let xdg  = IO.env_var("XDG_CONFIG_HOME")
                         .unwrap_or(format!("{}/.config", home));
            format!("{}/session-sentinel/config.toml", xdg)
        }
    }
}

// ---------------------------------------------------------------------------
// TOML serialisation helpers  (simplified — real impl delegates to a
// TOML library via FFI; here we show the logical structure)
// ---------------------------------------------------------------------------

/// Serialise a `SentinelConfig` to a TOML string.
///
/// Provider entries appear as `[[providers]]` array-of-tables.
/// Thresholds appear under `[thresholds]`.
total fn serialise_config(cfg: ref SentinelConfig) -> String {
    let mut out = String.new();

    // -- Global scalars --
    out.push_line(format!("scan_interval_secs = {}", cfg.scan_interval_secs));
    out.push_line(format!("enable_self_healing = {}", cfg.enable_self_healing));
    out.push_line(format!("enable_diagnostics = {}", cfg.enable_diagnostics));
    out.push_line(format!("log_path = \"{}\"", cfg.log_path));
    out.push_line(format!("panel_socket_path = \"{}\"", cfg.panel_socket_path));
    out.push_line("");

    // -- Thresholds --
    out.push_line("[thresholds]");
    out.push_line(format!("green_max = {}", cfg.thresholds.green_max));
    out.push_line(format!("yellow_max = {}", cfg.thresholds.yellow_max));
    out.push_line(format!("red_max = {}", cfg.thresholds.red_max));
    out.push_line("");

    // -- Providers --
    for provider in cfg.providers.iter() {
        out.push_line("[[providers]]");
        out.push_line(format!("name = \"{}\"", provider.name));
        out.push_line(format!("storage_paths = {:?}", provider.storage_paths));
        out.push_line(format!("stale_days = {}", provider.stale_days));
        match provider.scan_interval_override {
            Some(n) => out.push_line(format!("scan_interval_override = {}", n)),
            None    => ()
        };
        out.push_line(format!("auto_heal = {}", provider.auto_heal));
        out.push_line("");
    };

    out
}

/// Parse a TOML string into a `SentinelConfig`.
///
/// Missing keys are filled from `default_config`.  Unknown keys are
/// silently ignored (forward-compatible).
fn parse_config(toml_str: ref String, home: ref String) -> Result[SentinelConfig, ConfigError] {
    // NOTE: real implementation delegates to a TOML parser via Zig FFI.
    // This stub shows the expected signature and error handling.
    let defaults = default_config(home);

    match toml::parse(toml_str) {
        Ok(table) => {
            let thresholds = match table.get("thresholds") {
                Some(t) => {
                    green_max:  t.get_nat("green_max").unwrap_or(defaults.thresholds.green_max),
                    yellow_max: t.get_nat("yellow_max").unwrap_or(defaults.thresholds.yellow_max),
                    red_max:    t.get_nat("red_max").unwrap_or(defaults.thresholds.red_max)
                },
                None => defaults.thresholds
            };

            let providers = match table.get_array("providers") {
                Some(arr) => arr.iter().map(|entry| {
                    {
                        name:                   entry.get_str("name").unwrap_or("Unknown"),
                        storage_paths:          entry.get_str_array("storage_paths").unwrap_or(vec![]),
                        stale_days:             entry.get_nat("stale_days").unwrap_or(7),
                        scan_interval_override: entry.get_nat_opt("scan_interval_override"),
                        auto_heal:              entry.get_bool("auto_heal").unwrap_or(true)
                    }
                }).collect(),
                None => defaults.providers
            };

            Ok({
                providers:           providers,
                thresholds:          thresholds,
                scan_interval_secs:  table.get_nat("scan_interval_secs").unwrap_or(defaults.scan_interval_secs),
                enable_self_healing: table.get_bool("enable_self_healing").unwrap_or(defaults.enable_self_healing),
                enable_diagnostics:  table.get_bool("enable_diagnostics").unwrap_or(defaults.enable_diagnostics),
                log_path:            table.get_str("log_path").unwrap_or(defaults.log_path),
                panel_socket_path:   table.get_str("panel_socket_path").unwrap_or(defaults.panel_socket_path)
            })
        },
        Err(e) => Err(ParseError(format!("TOML parse failure: {}", e)))
    }
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Load configuration from disk.
///
/// Resolution order:
///   1. `$SESSION_SENTINEL_CONFIG` (explicit override)
///   2. `$XDG_CONFIG_HOME/session-sentinel/config.toml`
///   3. `~/.config/session-sentinel/config.toml`
///
/// If the file does not exist, a default config is written and returned.
/// If the file exists but cannot be parsed, a `ConfigError` is returned.
fn load_config() -> Result[SentinelConfig, ConfigError] / IO {
    let home = IO.env_var("HOME").unwrap_or("/root");
    let path = resolve_config_path();

    if IO.path_exists(ref path) {
        match IO.read_file(ref path) {
            Ok(contents) => parse_config(ref contents, ref home),
            Err(e)       => Err(IOFault(e))
        }
    } else {
        // First run — write defaults and return them.
        let cfg = default_config(ref home);
        match save_config(ref cfg) {
            Ok(())  => Ok(cfg),
            Err(e)  => Err(e)
        }
    }
}

/// Persist a `SentinelConfig` to disk.
///
/// Creates parent directories if they do not exist.  The file is written
/// atomically (write-to-temp then rename) to avoid partial reads by the
/// PanLL panel.
fn save_config(cfg: ref SentinelConfig) -> Result[Unit, ConfigError] / IO {
    let path = resolve_config_path();
    let dir  = path.parent_dir();

    // Ensure the config directory exists.
    match IO.create_dir_all(ref dir) {
        Ok(())  => (),
        Err(e)  => return Err(PermissionDenied(format!("Cannot create {}: {}", dir, e)))
    };

    let toml_str = serialise_config(cfg);

    // Atomic write: temp file then rename.
    let tmp_path = format!("{}.tmp", path);
    match IO.write_file(ref tmp_path, ref toml_str) {
        Ok(()) => {
            match IO.rename(ref tmp_path, ref path) {
                Ok(())  => Ok(()),
                Err(e)  => Err(IOFault(e))
            }
        },
        Err(e) => Err(IOFault(e))
    }
}

/// Expand all tilde-prefixed storage paths in every provider config.
///
/// Called once after loading, so the rest of the system works with
/// absolute paths only.
fn resolve_all_paths(cfg: own SentinelConfig) -> SentinelConfig / IO {
    let home = IO.env_var("HOME").unwrap_or("/root");

    let resolved_providers = cfg.providers.iter().map(|p| {
        {
            ..p,
            storage_paths: p.storage_paths.iter()
                            .map(|sp| expand_tilde(ref sp, ref home))
                            .collect()
        }
    }).collect();

    {
        ..cfg,
        providers: resolved_providers,
        log_path:          expand_tilde(ref cfg.log_path, ref home),
        panel_socket_path: expand_tilde(ref cfg.panel_socket_path, ref home)
    }
}
