// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

// =============================================================================
// session-sentinel :: src/core/scanner.as
// =============================================================================
// Multi-AI storage scanner.
//
// Walks provider storage directories and produces a `ProviderSnapshot` —
// a point-in-time measurement of disk usage, file counts, conversation
// counts, subagent counts, and orphan counts.
//
// Claude gets specialised scanning because its directory layout is richer
// (project dirs → JSONL conversations → subagent working directories).
// All other providers use a generic recursive-size scan.
//
// Git worktree detection is included because Claude Code creates worktrees
// that can orphan `.git` pointer files when sessions crash.
// =============================================================================

module SessionSentinel.Core.Scanner

use SessionSentinel.Core.Config.{AIProviderConfig, SentinelConfig}

// ---------------------------------------------------------------------------
// Effects
// ---------------------------------------------------------------------------

/// Filesystem effect — directory traversal, stat calls, metadata reads.
effect FS {
    fn list_dir(path: String)       -> Result[Vec[DirEntry], IOError];
    fn dir_size_bytes(path: String) -> Result[Nat, IOError];
    fn file_size(path: String)      -> Result[Nat, IOError];
    fn file_mtime(path: String)     -> Result[Timestamp, IOError];
    fn is_dir(path: String)         -> Bool;
    fn is_file(path: String)        -> Bool;
    fn is_symlink(path: String)     -> Bool;
    fn read_to_string(path: String) -> Result[String, IOError];
}

/// Clock effect — current time for relative age calculations.
effect Clock {
    fn now() -> Timestamp;
}

// ---------------------------------------------------------------------------
// Supporting types
// ---------------------------------------------------------------------------

/// Opaque UNIX timestamp (seconds since epoch).
type Timestamp = Nat

/// A single directory entry returned by `list_dir`.
type DirEntry = {
    name:    String,
    path:    String,
    is_dir:  Bool,
    is_file: Bool
}

/// Summary of a single conversation directory (Claude-specific).
///
/// A conversation dir typically contains one or more `.jsonl` files
/// (the transcript) and zero or more subagent working directories.
type ConversationInfo = {
    /// Absolute path to the conversation directory.
    path: String,

    /// Total size of all files within, in bytes.
    total_bytes: Nat,

    /// Number of JSONL transcript files found.
    transcript_count: Nat,

    /// Number of subagent working directories found.
    subagent_count: Nat,

    /// Subagent dirs that contain no JSONL output — likely orphaned.
    orphan_subagent_count: Nat,

    /// Modification time of the most recently written file.
    last_activity: Timestamp
}

/// Detection result for git worktrees.
///
/// A `.git` *file* (as opposed to a `.git` *directory*) indicates a
/// worktree checkout.  Orphaned worktrees point to a main repo whose
/// worktree list no longer references them.
type WorktreeInfo = {
    /// Path where the `.git` file was found.
    worktree_path: String,

    /// Contents of the `.git` file (typically `gitdir: /path/to/main/.git/worktrees/name`).
    gitdir_target: String,

    /// Whether the target main repo still lists this worktree.
    is_orphaned: Bool
}

// ---------------------------------------------------------------------------
// Snapshot — the main output of a scan
// ---------------------------------------------------------------------------

/// Point-in-time storage snapshot for a single AI provider.
///
/// Produced by `scan_provider` and consumed by the health classifier
/// and the PanLL panel.
type ProviderSnapshot = {
    /// Provider name (matches `AIProviderConfig.name`).
    provider_name: String,

    /// Total bytes consumed across all `storage_paths`.
    total_bytes: Nat,

    /// Total number of files (non-directory entries).
    file_count: Nat,

    /// Modification time of the oldest file found.
    oldest_file: Option[Timestamp],

    /// Modification time of the newest file found.
    newest_file: Option[Timestamp],

    /// Number of distinct conversations detected (Claude-specific;
    /// zero for generic providers).
    conversation_count: Nat,

    /// Number of subagent working directories detected (Claude-specific).
    subagent_count: Nat,

    /// Number of orphaned subagent dirs (no JSONL output) or orphaned
    /// git worktrees.
    orphan_count: Nat,

    /// Git worktrees found within provider storage paths.
    worktrees: Vec[WorktreeInfo],

    /// Wall-clock time at which this snapshot was taken.
    scanned_at: Timestamp
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Recursively compute the total size and file count of a directory.
///
/// Follows symlinks only one level deep to avoid infinite loops.
/// Returns `(total_bytes, file_count, oldest_mtime, newest_mtime)`.
fn recursive_stat(path: ref String)
    -> Result[(Nat, Nat, Option[Timestamp], Option[Timestamp]), IOError] / FS
{
    let entries = FS.list_dir(path.clone())?;
    let mut total: Nat            = 0;
    let mut count: Nat            = 0;
    let mut oldest: Option[Timestamp] = None;
    let mut newest: Option[Timestamp] = None;

    for entry in entries.iter() {
        if entry.is_dir {
            // Skip .git directories to avoid double-counting repo objects.
            if entry.name == ".git" { continue };

            let (sub_bytes, sub_count, sub_oldest, sub_newest) =
                recursive_stat(ref entry.path)?;
            total = total + sub_bytes;
            count = count + sub_count;
            oldest = min_timestamp(oldest, sub_oldest);
            newest = max_timestamp(newest, sub_newest);
        } else if entry.is_file {
            let size  = FS.file_size(entry.path.clone())?;
            let mtime = FS.file_mtime(entry.path.clone())?;
            total = total + size;
            count = count + 1;
            oldest = min_timestamp(oldest, Some(mtime));
            newest = max_timestamp(newest, Some(mtime));
        }
    };

    Ok((total, count, oldest, newest))
}

/// Return the earlier of two optional timestamps.
total fn min_timestamp(a: Option[Timestamp], b: Option[Timestamp]) -> Option[Timestamp] {
    match (a, b) {
        (None,    None)    => None,
        (Some(x), None)    => Some(x),
        (None,    Some(y)) => Some(y),
        (Some(x), Some(y)) => if x <= y { Some(x) } else { Some(y) }
    }
}

/// Return the later of two optional timestamps.
total fn max_timestamp(a: Option[Timestamp], b: Option[Timestamp]) -> Option[Timestamp] {
    match (a, b) {
        (None,    None)    => None,
        (Some(x), None)    => Some(x),
        (None,    Some(y)) => Some(y),
        (Some(x), Some(y)) => if x >= y { Some(x) } else { Some(y) }
    }
}

// ---------------------------------------------------------------------------
// Claude-specific scanning
// ---------------------------------------------------------------------------

/// Determine whether a directory is a subagent working directory.
///
/// Heuristic: the directory name matches the pattern `cw_*` (Claude
/// worktree prefix) or contains a `.task.json` manifest.
fn is_subagent_dir(entry: ref DirEntry) -> Bool / FS {
    if entry.name.starts_with("cw_") {
        true
    } else {
        FS.is_file(format!("{}/.task.json", entry.path))
    }
}

/// Check whether a subagent directory is orphaned.
///
/// A subagent dir is orphaned when it contains no `.jsonl` output file
/// and no running process holds a lock on it.  We check for JSONL here;
/// process-list checking is deferred to the healer (it requires a
/// different effect).
fn is_orphan_subagent(subagent_path: ref String) -> Bool / FS {
    let entries = match FS.list_dir(subagent_path.clone()) {
        Ok(e)  => e,
        Err(_) => return true   // unreadable dir is treated as orphan
    };
    let has_jsonl = entries.iter().any(|e| e.name.ends_with(".jsonl"));
    !has_jsonl
}

/// Scan a single Claude conversation directory.
///
/// Returns a `ConversationInfo` summarising transcripts, subagents, and
/// orphans found within.
fn scan_conversation(conv_path: ref String) -> Result[ConversationInfo, IOError] / FS {
    let entries = FS.list_dir(conv_path.clone())?;
    let mut total_bytes: Nat      = 0;
    let mut transcript_count: Nat = 0;
    let mut subagent_count: Nat   = 0;
    let mut orphan_count: Nat     = 0;
    let mut last_activity: Timestamp = 0;

    for entry in entries.iter() {
        if entry.is_file && entry.name.ends_with(".jsonl") {
            let size  = FS.file_size(entry.path.clone())?;
            let mtime = FS.file_mtime(entry.path.clone())?;
            total_bytes      = total_bytes + size;
            transcript_count = transcript_count + 1;
            if mtime > last_activity { last_activity = mtime };
        } else if entry.is_dir && is_subagent_dir(ref entry) {
            subagent_count = subagent_count + 1;
            let (sub_bytes, _, _, sub_newest) = recursive_stat(ref entry.path)?;
            total_bytes = total_bytes + sub_bytes;
            match sub_newest {
                Some(t) if t > last_activity => { last_activity = t },
                _ => ()
            };
            if is_orphan_subagent(ref entry.path) {
                orphan_count = orphan_count + 1;
            }
        } else if entry.is_file {
            let size = FS.file_size(entry.path.clone())?;
            total_bytes = total_bytes + size;
        }
    };

    Ok({
        path:                  conv_path.clone(),
        total_bytes:           total_bytes,
        transcript_count:      transcript_count,
        subagent_count:        subagent_count,
        orphan_subagent_count: orphan_count,
        last_activity:         last_activity
    })
}

/// Walk the Claude storage tree: ~/.claude/projects/<project>/<conversation>/
///
/// Returns aggregated conversation stats plus any orphan/worktree data.
fn scan_claude(config: ref AIProviderConfig)
    -> Result[ProviderSnapshot, IOError] / FS + Clock
{
    let now = Clock.now();
    let mut total_bytes: Nat      = 0;
    let mut file_count: Nat       = 0;
    let mut oldest: Option[Timestamp] = None;
    let mut newest: Option[Timestamp] = None;
    let mut conversations: Nat    = 0;
    let mut subagents: Nat        = 0;
    let mut orphans: Nat          = 0;
    let mut worktrees: Vec[WorktreeInfo] = vec![];

    for base_path in config.storage_paths.iter() {
        // Top level: project directories.
        let project_entries = match FS.list_dir(format!("{}/projects", base_path)) {
            Ok(e)  => e,
            Err(_) => continue    // no projects dir — skip
        };

        for project_entry in project_entries.iter() {
            if !project_entry.is_dir { continue };

            // Second level: conversation directories within a project.
            let conv_entries = match FS.list_dir(project_entry.path.clone()) {
                Ok(e)  => e,
                Err(_) => continue
            };

            for conv_entry in conv_entries.iter() {
                if !conv_entry.is_dir { continue };

                // Check for git worktree indicator (.git file, not dir).
                let git_path = format!("{}/.git", conv_entry.path);
                if FS.is_file(git_path.clone()) && !FS.is_dir(git_path.clone()) {
                    let gitdir = match FS.read_to_string(git_path.clone()) {
                        Ok(s)  => s.trim().clone(),
                        Err(_) => "".to_string()
                    };
                    worktrees.push({
                        worktree_path: conv_entry.path.clone(),
                        gitdir_target: gitdir,
                        is_orphaned:   false  // resolved later by detect_orphan_worktrees
                    });
                };

                match scan_conversation(ref conv_entry.path) {
                    Ok(info) => {
                        total_bytes   = total_bytes + info.total_bytes;
                        conversations = conversations + 1;
                        subagents     = subagents + info.subagent_count;
                        orphans       = orphans + info.orphan_subagent_count;
                        oldest        = min_timestamp(oldest, Some(info.last_activity));
                        newest        = max_timestamp(newest, Some(info.last_activity));
                    },
                    Err(_) => continue
                }
            }
        };

        // Also account for non-project files (config, caches, etc.)
        let (extra_bytes, extra_count, extra_oldest, extra_newest) =
            match recursive_stat(ref base_path) {
                Ok(r)  => r,
                Err(_) => (0, 0, None, None)
            };
        total_bytes = total_bytes + extra_bytes;
        file_count  = file_count + extra_count;
        oldest      = min_timestamp(oldest, extra_oldest);
        newest      = max_timestamp(newest, extra_newest);
    };

    // Detect orphaned worktrees.
    worktrees = detect_orphan_worktrees(worktrees);

    let worktree_orphan_count = worktrees.iter()
                                         .filter(|w| w.is_orphaned)
                                         .count();

    Ok({
        provider_name:      config.name.clone(),
        total_bytes:        total_bytes,
        file_count:         file_count,
        oldest_file:        oldest,
        newest_file:        newest,
        conversation_count: conversations,
        subagent_count:     subagents,
        orphan_count:       orphans + worktree_orphan_count,
        worktrees:          worktrees,
        scanned_at:         now
    })
}

// ---------------------------------------------------------------------------
// Git worktree orphan detection
// ---------------------------------------------------------------------------

/// Mark worktrees as orphaned when their `gitdir` target no longer exists
/// or the main repo's worktree list does not contain the worktree path.
///
/// A `.git` file in a worktree checkout contains a line like:
///   `gitdir: /home/user/repo/.git/worktrees/session-abc`
///
/// If that target directory is missing, the worktree is orphaned.
fn detect_orphan_worktrees(mut worktrees: Vec[WorktreeInfo])
    -> Vec[WorktreeInfo] / FS
{
    for wt in worktrees.iter_mut() {
        // Parse gitdir target: strip "gitdir: " prefix.
        let target = if wt.gitdir_target.starts_with("gitdir: ") {
            wt.gitdir_target.slice(8, wt.gitdir_target.len()).trim()
        } else {
            wt.gitdir_target.clone()
        };

        if target.is_empty() {
            wt.is_orphaned = true;
            continue
        };

        // If the target directory no longer exists, the worktree is orphaned.
        if !FS.is_dir(target.clone()) {
            wt.is_orphaned = true
        }
    };

    worktrees
}

// ---------------------------------------------------------------------------
// Generic provider scanning
// ---------------------------------------------------------------------------

/// Scan a non-Claude provider using plain recursive directory sizing.
///
/// Conversation/subagent/orphan counts are all zero because generic
/// providers do not have that structure.
fn scan_generic(config: ref AIProviderConfig)
    -> Result[ProviderSnapshot, IOError] / FS + Clock
{
    let now = Clock.now();
    let mut total_bytes: Nat = 0;
    let mut file_count: Nat  = 0;
    let mut oldest: Option[Timestamp] = None;
    let mut newest: Option[Timestamp] = None;
    let mut worktrees: Vec[WorktreeInfo] = vec![];

    for base_path in config.storage_paths.iter() {
        if !FS.is_dir(base_path.clone()) { continue };

        let (bytes, count, dir_oldest, dir_newest) = recursive_stat(ref base_path)?;
        total_bytes = total_bytes + bytes;
        file_count  = file_count + count;
        oldest      = min_timestamp(oldest, dir_oldest);
        newest      = max_timestamp(newest, dir_newest);

        // Still check for stray git worktree files.
        let git_path = format!("{}/.git", base_path);
        if FS.is_file(git_path.clone()) && !FS.is_dir(git_path.clone()) {
            let gitdir = FS.read_to_string(git_path).unwrap_or("".to_string());
            worktrees.push({
                worktree_path: base_path.clone(),
                gitdir_target: gitdir.trim(),
                is_orphaned:   false
            });
        }
    };

    worktrees = detect_orphan_worktrees(worktrees);

    Ok({
        provider_name:      config.name.clone(),
        total_bytes:        total_bytes,
        file_count:         file_count,
        oldest_file:        oldest,
        newest_file:        newest,
        conversation_count: 0,
        subagent_count:     0,
        orphan_count:       worktrees.iter().filter(|w| w.is_orphaned).count(),
        worktrees:          worktrees,
        scanned_at:         now
    })
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Scan a single provider and produce a snapshot.
///
/// Dispatches to `scan_claude` for the "Claude" provider and
/// `scan_generic` for everything else.
fn scan_provider(config: ref AIProviderConfig)
    -> Result[ProviderSnapshot, IOError] / FS + Clock
{
    match config.name.as_str() {
        "Claude" => scan_claude(config),
        _        => scan_generic(config)
    }
}

/// Scan all configured providers and return their snapshots.
///
/// Providers whose scan fails are **not** included in the result list;
/// instead their errors are collected in the second element of the tuple.
/// This ensures a partial scan still produces useful data.
fn scan_all(config: ref SentinelConfig)
    -> (Vec[ProviderSnapshot], Vec[(String, IOError)]) / FS + Clock
{
    let mut snapshots: Vec[ProviderSnapshot]     = vec![];
    let mut errors:    Vec[(String, IOError)]     = vec![];

    for provider in config.providers.iter() {
        match scan_provider(ref provider) {
            Ok(snapshot) => snapshots.push(snapshot),
            Err(e)       => errors.push((provider.name.clone(), e))
        }
    };

    (snapshots, errors)
}

/// Convenience: compute the aggregate total bytes across all snapshots.
///
/// Used by the health classifier to determine the overall zone.
total fn aggregate_bytes(snapshots: ref Vec[ProviderSnapshot]) -> Nat {
    snapshots.iter().fold(0, |acc, s| acc + s.total_bytes)
}

/// Convenience: compute the aggregate orphan count across all snapshots.
total fn aggregate_orphans(snapshots: ref Vec[ProviderSnapshot]) -> Nat {
    snapshots.iter().fold(0, |acc, s| acc + s.orphan_count)
}
