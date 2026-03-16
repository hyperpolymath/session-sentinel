// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

// =============================================================================
// session-sentinel :: src/core/healer.as
// =============================================================================
// Self-healing engine for AI session storage.
//
// The healer receives the current health zone and config, then determines
// and executes a set of corrective actions.  Aggressiveness scales with
// zone severity:
//
//   Green  — no action.
//   Yellow — prune orphans and empty directories only.
//   Red    — also prune stale conversations and subagents.
//   Purple — aggressive: prune everything older than 1 day.
//
// Safety invariants:
//   - NEVER delete data belonging to a running AI session.
//   - NEVER delete model files unless the provider config allows auto_heal.
//   - Every action is logged to the diagnostics subsystem before execution.
//   - Dry-run mode is supported for testing.
// =============================================================================

module SessionSentinel.Core.Healer

use SessionSentinel.Core.Config.{AIProviderConfig, SentinelConfig}
use SessionSentinel.Core.Health.{HealthZone, Green, Yellow, Red, Purple}
use SessionSentinel.Core.Scanner.{ProviderSnapshot, Timestamp, WorktreeInfo}
use SessionSentinel.Core.Diagnostics.{DiagnosticLog, log_info, log_warning, log_critical}

// ---------------------------------------------------------------------------
// Effects
// ---------------------------------------------------------------------------

/// Filesystem effect — deletion, directory listing, stat.
effect FS {
    fn remove_dir_all(path: String) -> Result[Unit, IOError];
    fn remove_file(path: String)    -> Result[Unit, IOError];
    fn list_dir(path: String)       -> Result[Vec[DirEntry], IOError];
    fn is_dir(path: String)         -> Bool;
    fn is_empty_dir(path: String)   -> Bool;
    fn file_mtime(path: String)     -> Result[Timestamp, IOError];
    fn dir_size_bytes(path: String) -> Result[Nat, IOError];
}

/// Process effect — check for running AI processes.
effect Process {
    /// Return a list of PIDs whose command line matches the given pattern.
    /// Used to avoid deleting data for active sessions.
    fn find_pids(pattern: String) -> Vec[Nat];

    /// Check whether a specific file or directory is open by any process.
    fn is_path_in_use(path: String) -> Bool;
}

/// Clock effect — current time for age calculations.
effect Clock {
    fn now() -> Timestamp;
}

// ---------------------------------------------------------------------------
// Heal actions
// ---------------------------------------------------------------------------

/// The discrete actions the healer can take.
///
/// Each variant carries enough context to execute and to log.
type HealAction =
    /// Remove subagent directories that have no JSONL output (orphans).
    | PruneOrphans

    /// Remove conversation directories older than N days.
    | PruneStaleConversations Nat

    /// Remove subagent working directories older than N days.
    | PruneStaleSubagents Nat

    /// Remove empty directories left behind after other pruning.
    | RemoveEmptyDirs

    /// Prune git worktrees whose main repo no longer references them.
    | PruneWorktrees

/// Human-readable description of a heal action for logging.
total fn describe_action(action: ref HealAction) -> String {
    match action {
        PruneOrphans                => "Prune orphaned subagent directories",
        PruneStaleConversations(d)  => format!("Prune conversations older than {} days", d),
        PruneStaleSubagents(d)      => format!("Prune subagent dirs older than {} days", d),
        RemoveEmptyDirs             => "Remove empty directories",
        PruneWorktrees              => "Prune orphaned git worktrees"
    }
}

// ---------------------------------------------------------------------------
// Heal result
// ---------------------------------------------------------------------------

/// Outcome of a healing run.
///
/// Returned to the monitor loop so it can update the diagnostic log and
/// determine whether to re-scan immediately.
type HealResult = {
    /// Total bytes freed across all actions.
    bytes_freed: Nat,

    /// Actions that were successfully executed.
    actions_taken: Vec[HealAction],

    /// Actions that failed, with their error messages.
    errors: Vec[(HealAction, String)],

    /// Whether all planned actions succeeded.
    fully_successful: Bool,

    /// Wall-clock duration of the healing run in milliseconds.
    duration_ms: Nat
}

/// Construct an empty (no-op) heal result.
total fn empty_result() -> HealResult {
    {
        bytes_freed:      0,
        actions_taken:    vec![],
        errors:           vec![],
        fully_successful: true,
        duration_ms:      0
    }
}

// ---------------------------------------------------------------------------
// Active session detection
// ---------------------------------------------------------------------------

/// Patterns to search for in the process list, by provider name.
///
/// If any of these patterns match a running process, we consider that
/// provider's session active and skip deletion for paths in use.
total fn process_patterns(provider_name: ref String) -> Vec[String] {
    match provider_name.as_str() {
        "Claude"     => vec!["claude", "claude-code"],
        "Copilot"    => vec!["github-copilot", "copilot-agent"],
        "Ollama"     => vec!["ollama serve", "ollama run"],
        "LM Studio"  => vec!["lms", "lm-studio"],
        "Continue"   => vec!["continue"],
        "Cursor"     => vec!["cursor"],
        "Aider"      => vec!["aider"],
        _            => vec![]
    }
}

/// Check whether any active session exists for the given provider.
///
/// Returns `true` if at least one matching process is running.
fn is_provider_active(provider_name: ref String) -> Bool / Process {
    let patterns = process_patterns(provider_name);
    patterns.iter().any(|p| !Process.find_pids(p.clone()).is_empty())
}

/// Check whether a specific path is safe to delete.
///
/// Returns `false` if any process has the path (or a child) open.
fn is_safe_to_delete(path: ref String) -> Bool / Process {
    !Process.is_path_in_use(path.clone())
}

// ---------------------------------------------------------------------------
// Individual healing operations
// ---------------------------------------------------------------------------

/// Prune orphaned subagent directories for a single provider.
///
/// An orphaned subagent is a directory matching the subagent naming
/// convention (`cw_*` or containing `.task.json`) that has no `.jsonl`
/// output.
fn prune_orphans_for(provider: ref AIProviderConfig)
    -> Result[Nat, String] / FS + Process
{
    let mut freed: Nat = 0;

    for base_path in provider.storage_paths.iter() {
        let projects = FS.list_dir(format!("{}/projects", base_path)).unwrap_or(vec![]);

        for project in projects.iter() {
            if !FS.is_dir(project.path.clone()) { continue };

            let conversations = FS.list_dir(project.path.clone()).unwrap_or(vec![]);

            for conv in conversations.iter() {
                if !FS.is_dir(conv.path.clone()) { continue };

                let entries = FS.list_dir(conv.path.clone()).unwrap_or(vec![]);

                for entry in entries.iter() {
                    if !entry.is_dir { continue };
                    if !entry.name.starts_with("cw_") { continue };

                    // Check orphan condition: no .jsonl files inside.
                    let subfiles = FS.list_dir(entry.path.clone()).unwrap_or(vec![]);
                    let has_jsonl = subfiles.iter().any(|f| f.name.ends_with(".jsonl"));

                    if !has_jsonl && is_safe_to_delete(ref entry.path) {
                        let size = FS.dir_size_bytes(entry.path.clone()).unwrap_or(0);
                        match FS.remove_dir_all(entry.path.clone()) {
                            Ok(())  => { freed = freed + size },
                            Err(e)  => return Err(format!(
                                "Failed to remove orphan {}: {}", entry.path, e
                            ))
                        }
                    }
                }
            }
        }
    };

    Ok(freed)
}

/// Prune directories older than `max_age_days` under the provider's storage.
///
/// Operates on conversation-level directories (one level below projects).
/// Skips paths that are in use by an active process.
fn prune_stale_dirs(
    provider:     ref AIProviderConfig,
    max_age_days: Nat,
    subagent_only: Bool
) -> Result[Nat, String] / FS + Clock + Process {
    let now = Clock.now();
    let max_age_secs: Nat = max_age_days * 86400;
    let mut freed: Nat = 0;

    for base_path in provider.storage_paths.iter() {
        let projects = FS.list_dir(format!("{}/projects", base_path)).unwrap_or(vec![]);

        for project in projects.iter() {
            if !FS.is_dir(project.path.clone()) { continue };

            let conversations = FS.list_dir(project.path.clone()).unwrap_or(vec![]);

            for conv in conversations.iter() {
                if !FS.is_dir(conv.path.clone()) { continue };

                if subagent_only {
                    // Only delete subagent dirs within the conversation.
                    let entries = FS.list_dir(conv.path.clone()).unwrap_or(vec![]);
                    for entry in entries.iter() {
                        if !entry.is_dir || !entry.name.starts_with("cw_") { continue };

                        let mtime = FS.file_mtime(entry.path.clone()).unwrap_or(now);
                        let age = if now > mtime { now - mtime } else { 0 };

                        if age > max_age_secs && is_safe_to_delete(ref entry.path) {
                            let size = FS.dir_size_bytes(entry.path.clone()).unwrap_or(0);
                            match FS.remove_dir_all(entry.path.clone()) {
                                Ok(())  => { freed = freed + size },
                                Err(_)  => continue
                            }
                        }
                    }
                } else {
                    // Delete the entire conversation directory if stale.
                    let mtime = FS.file_mtime(conv.path.clone()).unwrap_or(now);
                    let age = if now > mtime { now - mtime } else { 0 };

                    if age > max_age_secs && is_safe_to_delete(ref conv.path) {
                        let size = FS.dir_size_bytes(conv.path.clone()).unwrap_or(0);
                        match FS.remove_dir_all(conv.path.clone()) {
                            Ok(())  => { freed = freed + size },
                            Err(_)  => continue
                        }
                    }
                }
            }
        }
    };

    Ok(freed)
}

/// Remove empty directories under the provider's storage paths.
///
/// Walks bottom-up so that nested empty dirs are removed in a single
/// pass.
fn remove_empty_dirs_for(provider: ref AIProviderConfig) -> Result[Nat, String] / FS {
    let mut removed: Nat = 0;

    for base_path in provider.storage_paths.iter() {
        removed = removed + remove_empty_dirs_recursive(ref base_path)?;
    };

    Ok(removed)
}

/// Recursively remove empty directories, bottom-up.
///
/// Returns the number of directories removed.
fn remove_empty_dirs_recursive(path: ref String) -> Result[Nat, String] / FS {
    let entries = FS.list_dir(path.clone()).unwrap_or(vec![]);
    let mut removed: Nat = 0;

    // Recurse into subdirectories first (bottom-up).
    for entry in entries.iter() {
        if entry.is_dir {
            removed = removed + remove_empty_dirs_recursive(ref entry.path)?;
        }
    };

    // After recursion, check if this dir is now empty.
    if FS.is_empty_dir(path.clone()) {
        match FS.remove_dir_all(path.clone()) {
            Ok(())  => { removed = removed + 1 },
            Err(e)  => return Err(format!("Failed to remove empty dir {}: {}", path, e))
        }
    };

    Ok(removed)
}

/// Prune orphaned git worktrees from the provider's snapshot.
///
/// Only removes worktrees already identified as orphaned by the scanner.
fn prune_orphan_worktrees(snapshot: ref ProviderSnapshot)
    -> Result[Nat, String] / FS + Process
{
    let mut freed: Nat = 0;

    for wt in snapshot.worktrees.iter() {
        if !wt.is_orphaned { continue };

        if is_safe_to_delete(ref wt.worktree_path) {
            let size = FS.dir_size_bytes(wt.worktree_path.clone()).unwrap_or(0);
            match FS.remove_dir_all(wt.worktree_path.clone()) {
                Ok(())  => { freed = freed + size },
                Err(e)  => return Err(format!(
                    "Failed to prune worktree {}: {}", wt.worktree_path, e
                ))
            }
        }
    };

    Ok(freed)
}

// ---------------------------------------------------------------------------
// Action plan generation
// ---------------------------------------------------------------------------

/// Determine which actions to take based on the current health zone and
/// the provider's configuration.
///
/// Aggressiveness increases with zone severity:
///   Green  -> []                    (no action)
///   Yellow -> [PruneOrphans, RemoveEmptyDirs]
///   Red    -> Yellow actions + [PruneStaleSubagents(stale_days), PruneStaleConversations(stale_days)]
///   Purple -> Red actions but with max_age = 1 day (aggressive)
total fn plan_actions(
    zone:     ref HealthZone,
    provider: ref AIProviderConfig
) -> Vec[HealAction] {
    match zone {
        Green => vec![],

        Yellow => vec![
            PruneOrphans,
            RemoveEmptyDirs
        ],

        Red => vec![
            PruneOrphans,
            PruneStaleSubagents(provider.stale_days),
            PruneStaleConversations(provider.stale_days),
            PruneWorktrees,
            RemoveEmptyDirs
        ],

        Purple => vec![
            PruneOrphans,
            PruneStaleSubagents(1),           // aggressive: 1 day
            PruneStaleConversations(1),       // aggressive: 1 day
            PruneWorktrees,
            RemoveEmptyDirs
        ]
    }
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Execute the self-healing engine for all configured providers.
///
/// This is the main entry point called by the monitor loop.  It:
///   1. Checks that self-healing is enabled in the config.
///   2. For each provider with `auto_heal = true`, plans and executes
///      the appropriate actions for the current zone.
///   3. Skips providers with active sessions (running processes).
///   4. Logs every action to the diagnostic log.
///   5. Returns a composite `HealResult`.
///
/// If `dry_run` is true, actions are planned and logged but not executed.
fn auto_heal(
    zone:      ref HealthZone,
    config:    ref SentinelConfig,
    snapshots: ref Vec[ProviderSnapshot],
    diag_log:  mut ref DiagnosticLog,
    dry_run:   Bool
) -> HealResult / FS + Process + Clock {
    // Short-circuit if healing is disabled or zone is healthy.
    if !config.enable_self_healing {
        log_info(diag_log, "Healing", "Self-healing is disabled in config");
        return empty_result()
    };

    match zone {
        Green => {
            log_info(diag_log, "Healing", "Zone is Green — no healing needed");
            return empty_result()
        },
        _ => ()
    };

    let start = Clock.now();
    let mut total_freed: Nat              = 0;
    let mut all_actions: Vec[HealAction]  = vec![];
    let mut all_errors:  Vec[(HealAction, String)] = vec![];

    for (idx, provider) in config.providers.iter().enumerate() {
        // Skip providers that opted out of auto-healing.
        if !provider.auto_heal {
            log_info(diag_log, "Healing",
                format!("Skipping {} — auto_heal is disabled", provider.name));
            continue
        };

        // Skip providers with active sessions.
        if is_provider_active(ref provider.name) {
            log_warning(diag_log, "Healing",
                format!("Skipping {} — active session detected", provider.name));
            continue
        };

        let actions = plan_actions(zone, ref provider);

        for action in actions.iter() {
            log_info(diag_log, "Healing",
                format!("[{}] {}{}", provider.name, describe_action(ref action),
                        if dry_run { " (DRY RUN)" } else { "" }));

            if dry_run {
                all_actions.push(action.clone());
                continue
            };

            // Find the matching snapshot for this provider (needed for worktree info).
            let snapshot = snapshots.iter().find(|s| s.provider_name == provider.name);

            let result = match action {
                PruneOrphans =>
                    prune_orphans_for(ref provider),

                PruneStaleConversations(days) =>
                    prune_stale_dirs(ref provider, days, false).map(|f| f),

                PruneStaleSubagents(days) =>
                    prune_stale_dirs(ref provider, days, true).map(|f| f),

                RemoveEmptyDirs =>
                    remove_empty_dirs_for(ref provider).map(|_| 0),

                PruneWorktrees => match snapshot {
                    Some(s) => prune_orphan_worktrees(ref s),
                    None    => Ok(0)
                }
            };

            match result {
                Ok(freed) => {
                    total_freed = total_freed + freed;
                    all_actions.push(action.clone());
                    if freed > 0 {
                        log_info(diag_log, "Healing",
                            format!("[{}] {} freed {} bytes",
                                    provider.name, describe_action(ref action), freed));
                    }
                },
                Err(msg) => {
                    log_warning(diag_log, "Healing",
                        format!("[{}] {} failed: {}",
                                provider.name, describe_action(ref action), msg));
                    all_errors.push((action.clone(), msg));
                }
            }
        }
    };

    let end = Clock.now();
    let duration = if end > start { (end - start) * 1000 } else { 0 };

    let result = {
        bytes_freed:      total_freed,
        actions_taken:    all_actions,
        errors:           all_errors.clone(),
        fully_successful: all_errors.is_empty(),
        duration_ms:      duration
    };

    if total_freed > 0 {
        log_info(diag_log, "Healing",
            format!("Healing complete: freed {} bytes in {} ms ({} errors)",
                    total_freed, duration, all_errors.len()));
    };

    result
}
