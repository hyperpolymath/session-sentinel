// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

// =============================================================================
// session-sentinel :: src/core/providers.as
// =============================================================================
// AI provider detection and registration.
//
// Scans the filesystem for known AI tool directories and builds a list of
// detected providers.  Each provider has a well-known storage layout:
//
//   Claude        ~/.claude/projects/*/       JSONL conversations + subagent dirs
//   Copilot       ~/.config/github-copilot/   cache + settings
//   Ollama        ~/.ollama/models/            model blobs (multi-GB)
//   LM Studio     ~/.cache/lm-studio/          models + inference cache
//   Continue.dev  ~/.continue/                 sessions + index
//   Cursor        ~/.cursor/                   extensions + cache
//   Aider         ~/.aider/                    conversation cache
//
// The provider registry is extensible: users can add custom providers via
// the config file, and this module merges them with the built-in set.
// =============================================================================

module SessionSentinel.Core.Providers

use SessionSentinel.Core.Config.{AIProviderConfig}

// ---------------------------------------------------------------------------
// Effects
// ---------------------------------------------------------------------------

/// Filesystem effect — directory existence checks and listing.
effect FS {
    fn is_dir(path: String)  -> Bool;
    fn is_file(path: String) -> Bool;
    fn list_dir(path: String) -> Result[Vec[DirEntry], IOError];
}

/// IO effect — environment variable lookups and process execution.
effect IO {
    fn env_var(name: String) -> Option[String];
}

// ---------------------------------------------------------------------------
// Supporting types
// ---------------------------------------------------------------------------

/// Directory entry (minimal — only what detection needs).
type DirEntry = {
    name:    String,
    path:    String,
    is_dir:  Bool,
    is_file: Bool
}

/// Determines how storage is scanned for a given AI tool.
///
/// Claude has structured conversation data (JSONL + subagent dirs);
/// Ollama has large model blobs with a weight factor; most other tools
/// just have opaque cache directories.
type ProviderType =
    /// JSONL conversations, subagent dirs, orphan detection.
    | ClaudeProvider
    /// Large model blobs — weight factor applied to avoid false alarms.
    | OllamaProvider
    /// Flat directory size scan.
    | GenericProvider
    /// User-defined via config file.
    | CustomProvider

/// Describes a known AI provider's storage layout.
///
/// Used as the template for detection: if any of the `detection_paths`
/// exist on disk, the provider is considered present and a corresponding
/// `AIProviderConfig` is generated.
type ProviderTemplate = {
    /// Human-readable name.
    name: String,

    /// Provider scanning strategy.
    provider_type: ProviderType,

    /// Paths to check for existence (relative to $HOME).
    /// If ANY of these exist, the provider is detected.
    detection_paths: Vec[String],

    /// Paths to monitor for storage (relative to $HOME).
    /// These become `AIProviderConfig.storage_paths` after expansion.
    storage_paths: Vec[String],

    /// Default stale-days threshold for this provider.
    default_stale_days: Nat,

    /// Optional per-provider scan interval override (seconds).
    default_scan_interval: Option[Nat],

    /// Whether auto-heal should be enabled by default.
    default_auto_heal: Bool,

    /// Storage contribution weight (1.0 = full, 0.1 = mostly ignored).
    /// Ollama models score low because large files are intentional.
    weight: Float,

    /// Brief description of what this provider stores.
    description: String
}

// ---------------------------------------------------------------------------
// Built-in provider templates
// ---------------------------------------------------------------------------

/// Claude Code — the primary target of session-sentinel.
///
/// Storage layout:
///   ~/.claude/
///   ├── projects/
///   │   ├── <project-hash>/
///   │   │   ├── <conversation-id>/
///   │   │   │   ├── transcript.jsonl
///   │   │   │   ├── cw_<subagent>/       # subagent working dir
///   │   │   │   └── ...
///   │   │   └── ...
///   │   └── ...
///   ├── settings.json
///   └── credentials.json
total fn claude_template() -> ProviderTemplate {
    {
        name:                  "Claude",
        provider_type:         ClaudeProvider,
        detection_paths:       vec![".claude/", ".claude/projects/"],
        storage_paths:         vec![".claude/"],
        default_stale_days:    7,
        default_scan_interval: None,
        default_auto_heal:     true,
        weight:                1.0,
        description:           "Claude Code conversations, subagent working directories, and session metadata"
    }
}

/// GitHub Copilot — caches and settings.
///
/// Storage layout:
///   ~/.config/github-copilot/
///   ├── versions.json
///   ├── hosts.json
///   └── apps/    (cached completions, telemetry)
total fn copilot_template() -> ProviderTemplate {
    {
        name:                  "Copilot",
        provider_type:         GenericProvider,
        detection_paths:       vec![".config/github-copilot/"],
        storage_paths:         vec![".config/github-copilot/"],
        default_stale_days:    14,
        default_scan_interval: None,
        default_auto_heal:     true,
        weight:                1.0,
        description:           "GitHub Copilot configuration cache and completion telemetry"
    }
}

/// Ollama — local LLM model server.
///
/// Storage layout:
///   ~/.ollama/
///   ├── models/
///   │   ├── manifests/       (model metadata)
///   │   └── blobs/           (model weights — multi-GB each)
///   ├── history              (REPL history)
///   └── logs/
///
/// Models are intentionally large and rarely stale; auto-heal is off
/// by default to prevent accidental model deletion.  Weight is 0.1
/// so that multi-GB model blobs do not dominate the health score.
total fn ollama_template() -> ProviderTemplate {
    {
        name:                  "Ollama",
        provider_type:         OllamaProvider,
        detection_paths:       vec![".ollama/", ".ollama/models/"],
        storage_paths:         vec![".ollama/"],
        default_stale_days:    30,
        default_scan_interval: Some(300),   // every 5 minutes — models change rarely
        default_auto_heal:     false,
        weight:                0.1,
        description:           "Ollama model blobs, manifests, and inference logs"
    }
}

/// LM Studio — GUI-based local LLM runner.
///
/// Storage layout:
///   ~/.cache/lm-studio/
///   ├── models/              (downloaded model files)
///   ├── user-data/           (preferences, conversation history)
///   └── tmp/                 (inference scratch space)
total fn lmstudio_template() -> ProviderTemplate {
    {
        name:                  "LM Studio",
        provider_type:         GenericProvider,
        detection_paths:       vec![".cache/lm-studio/"],
        storage_paths:         vec![".cache/lm-studio/"],
        default_stale_days:    30,
        default_scan_interval: Some(300),
        default_auto_heal:     false,
        weight:                0.5,
        description:           "LM Studio model cache, user data, and inference scratch files"
    }
}

/// Continue.dev — open-source AI coding assistant.
///
/// Storage layout:
///   ~/.continue/
///   ├── sessions/            (conversation transcripts)
///   ├── index/               (codebase index for retrieval)
///   ├── dev_data/            (telemetry and diagnostics)
///   └── config.json
total fn continue_template() -> ProviderTemplate {
    {
        name:                  "Continue",
        provider_type:         GenericProvider,
        detection_paths:       vec![".continue/"],
        storage_paths:         vec![".continue/"],
        default_stale_days:    14,
        default_scan_interval: None,
        default_auto_heal:     true,
        weight:                1.0,
        description:           "Continue.dev session transcripts, codebase index, and dev telemetry"
    }
}

/// Cursor — AI-native code editor.
///
/// Storage layout:
///   ~/.cursor/
///   ├── extensions/          (installed extensions)
///   ├── User/                (settings, keybindings)
///   ├── Cache/               (extension caches, completions)
///   └── logs/
total fn cursor_template() -> ProviderTemplate {
    {
        name:                  "Cursor",
        provider_type:         GenericProvider,
        detection_paths:       vec![".cursor/"],
        storage_paths:         vec![".cursor/"],
        default_stale_days:    14,
        default_scan_interval: None,
        default_auto_heal:     true,
        weight:                1.0,
        description:           "Cursor editor extensions, caches, completion history, and logs"
    }
}

/// Aider — terminal-based AI pair programmer.
///
/// Storage layout:
///   ~/.aider/
///   ├── cache/               (LLM response cache)
///   ├── tags/                (ctags index)
///   └── history.md           (conversation log)
///
/// Also stores per-repo `.aider*` files, but those are outside $HOME
/// and tracked as part of the git repo — not monitored here.
total fn aider_template() -> ProviderTemplate {
    {
        name:                  "Aider",
        provider_type:         GenericProvider,
        detection_paths:       vec![".aider/"],
        storage_paths:         vec![".aider/"],
        default_stale_days:    7,
        default_scan_interval: None,
        default_auto_heal:     true,
        weight:                1.0,
        description:           "Aider LLM response cache, ctags index, and conversation history"
    }
}

/// All built-in provider templates, in detection priority order.
total fn all_templates() -> Vec[ProviderTemplate] {
    vec![
        claude_template(),
        copilot_template(),
        ollama_template(),
        lmstudio_template(),
        continue_template(),
        cursor_template(),
        aider_template()
    ]
}

// ---------------------------------------------------------------------------
// Detection
// ---------------------------------------------------------------------------

/// Expand a path relative to $HOME into an absolute path.
///
/// If `$HOME` is not set, falls back to `/root`.
fn expand_home_relative(rel_path: ref String) -> String / IO {
    let home = IO.env_var("HOME").unwrap_or("/root");
    format!("{}/{}", home, rel_path)
}

/// Check whether a provider template matches the current filesystem.
///
/// Returns `true` if ANY of the template's `detection_paths` exist
/// as directories on disk.
fn is_provider_present(template: ref ProviderTemplate) -> Bool / FS + IO {
    template.detection_paths.iter().any(|rel| {
        let abs_path = expand_home_relative(ref rel);
        FS.is_dir(abs_path)
    })
}

/// Convert a `ProviderTemplate` into an `AIProviderConfig`.
///
/// Expands relative paths to absolute and applies the template's defaults.
fn template_to_config(template: ref ProviderTemplate) -> AIProviderConfig / IO {
    let expanded_paths = template.storage_paths.iter()
        .map(|rel| expand_home_relative(ref rel))
        .collect();

    {
        name:                   template.name.clone(),
        storage_paths:          expanded_paths,
        stale_days:             template.default_stale_days,
        scan_interval_override: template.default_scan_interval,
        auto_heal:              template.default_auto_heal
    }
}

/// Auto-detect which AI tools are installed by checking for their
/// storage directories.
///
/// Returns a list of `AIProviderConfig` for each detected provider.
/// Providers that are not installed are silently excluded.
///
/// This is the primary entry point for automatic provider discovery,
/// called during initial config generation (first run) and when the
/// user requests a re-detect via the PanLL panel.
fn detect_providers() -> Vec[AIProviderConfig] / FS + IO {
    let templates = all_templates();
    let mut detected: Vec[AIProviderConfig] = vec![];

    for template in templates.iter() {
        if is_provider_present(ref template) {
            let config = template_to_config(ref template);
            detected.push(config);
        }
    };

    detected
}

// ---------------------------------------------------------------------------
// Custom provider registration
// ---------------------------------------------------------------------------

/// Registered provider — combines a known provider template with runtime
/// config overrides (e.g. custom stale days or additional paths).
type RegisteredProvider = {
    /// The underlying template (or a synthetic one for custom providers).
    template: ProviderTemplate,

    /// Override stale-days threshold from user config.
    override_stale: Option[Nat],

    /// Additional paths to monitor beyond the template defaults.
    extra_paths: Vec[String],

    /// Whether this provider is enabled for scanning.
    enabled: Bool
}

/// Create a RegisteredProvider from a ProviderTemplate with default settings.
total fn register_default(template: ProviderTemplate) -> RegisteredProvider {
    {
        template:       template,
        override_stale: None,
        extra_paths:    vec![],
        enabled:        true
    }
}

/// Register a fully custom provider from user config.
///
/// Validates that the given path exists and is a directory.  Returns
/// an `AIProviderConfig` with conservative defaults (14-day stale,
/// auto-heal on) that the user can customise in the config file.
fn register_custom_provider(
    name: String,
    storage_path: String,
    stale_days: Option[Nat],
    auto_heal: Option[Bool]
) -> Result[AIProviderConfig, String] / FS {
    if !FS.is_dir(storage_path.clone()) {
        return Err(format!(
            "Cannot register provider '{}': path '{}' does not exist or is not a directory",
            name, storage_path
        ))
    };

    Ok({
        name:                   name,
        storage_paths:          vec![storage_path],
        stale_days:             stale_days.unwrap_or(14),
        scan_interval_override: None,
        auto_heal:              auto_heal.unwrap_or(true)
    })
}

/// Register a custom provider by building a synthetic template.
///
/// Used for providers added via the config file that are not in the
/// built-in registry.
fn register_custom_template(
    name: String,
    paths: Vec[String],
    stale_days: Nat,
    weight: Float
) -> RegisteredProvider {
    {
        template: {
            name:                  name.clone(),
            provider_type:         CustomProvider,
            detection_paths:       paths.clone(),
            storage_paths:         paths,
            default_stale_days:    stale_days,
            default_scan_interval: None,
            default_auto_heal:     true,
            weight:                weight,
            description:           format!("Custom AI provider: {}", name)
        },
        override_stale: None,
        extra_paths:    vec![],
        enabled:        true
    }
}

// ---------------------------------------------------------------------------
// Merging detected and configured providers
// ---------------------------------------------------------------------------

/// Merge auto-detected providers with those already in the config.
///
/// Rules:
///   - If a detected provider already exists in `existing` (by name),
///     the existing config is kept (user customisations are preserved).
///   - If a detected provider is new, it is appended.
///   - If an existing provider is no longer detected, it is kept anyway
///     (the user may have a custom path or the tool may be temporarily
///     uninstalled).
///
/// Returns the merged list.
total fn merge_providers(
    existing: ref Vec[AIProviderConfig],
    detected: ref Vec[AIProviderConfig]
) -> Vec[AIProviderConfig] {
    let mut merged: Vec[AIProviderConfig] = existing.clone();
    let existing_names: Vec[String] = existing.iter()
        .map(|p| p.name.clone())
        .collect();

    for det in detected.iter() {
        if !existing_names.contains(ref det.name) {
            merged.push(det.clone());
        }
    };

    merged
}

// ---------------------------------------------------------------------------
// Provider information queries
// ---------------------------------------------------------------------------

/// Look up a provider config by name.
///
/// Returns `None` if no provider with that name is registered.
total fn find_provider(
    providers: ref Vec[AIProviderConfig],
    name: ref String
) -> Option[ref AIProviderConfig] {
    providers.iter().find(|p| p.name == name)
}

/// Return the names of all registered providers.
total fn provider_names(providers: ref Vec[AIProviderConfig]) -> Vec[String] {
    providers.iter().map(|p| p.name.clone()).collect()
}

/// Check whether a specific provider supports detailed scanning
/// (conversations, subagents, orphan detection).
///
/// Currently only Claude has a structured enough layout for this.
/// Other providers get generic directory-size scanning.
total fn supports_detailed_scan(provider_name: ref String) -> Bool {
    match provider_name.as_str() {
        "Claude" => true,
        _        => false
    }
}

/// Return the detection paths for a known provider (by name).
///
/// Returns an empty list for unknown provider names.
/// Useful for the diagnostics panel to show which paths were checked.
total fn detection_paths_for(provider_name: ref String) -> Vec[String] {
    let templates = all_templates();
    match templates.iter().find(|t| t.name == provider_name) {
        Some(t) => t.detection_paths.clone(),
        None    => vec![]
    }
}

/// Return the human-readable description for a known provider.
///
/// Returns a generic fallback for custom/unknown providers.
total fn provider_description(provider_name: ref String) -> String {
    let templates = all_templates();
    match templates.iter().find(|t| t.name == provider_name) {
        Some(t) => t.description.clone(),
        None    => format!("Custom AI provider: {}", provider_name)
    }
}

/// Get the effective stale threshold for a registered provider,
/// preferring the override if set, falling back to the template default.
total fn effective_stale(provider: ref RegisteredProvider) -> Nat {
    match provider.override_stale {
        Some(days) => days,
        None       => provider.template.default_stale_days
    }
}

/// Get all paths to scan for a registered provider, combining
/// the template paths with any extra paths from config.
total fn all_scan_paths(provider: ref RegisteredProvider) -> Vec[String] {
    let mut paths = provider.template.storage_paths.clone();
    for extra in provider.extra_paths.iter() {
        paths.push(extra.clone());
    };
    paths
}

// ---------------------------------------------------------------------------
// Process detection
// ---------------------------------------------------------------------------

/// Map provider names to process names to check in the process list.
///
/// Used by the healer to avoid cleaning up data for active sessions.
total fn process_patterns(provider_name: ref String) -> Vec[String] {
    match provider_name.as_str() {
        "Claude"     => vec!["claude", "claude-code"],
        "Copilot"    => vec!["copilot", "copilot-agent", "github-copilot"],
        "Ollama"     => vec!["ollama serve", "ollama run", "ollama"],
        "LM Studio"  => vec!["lms", "lm-studio"],
        "Continue"   => vec!["continue"],
        "Cursor"     => vec!["cursor"],
        "Aider"      => vec!["aider"],
        _            => vec![]
    }
}
