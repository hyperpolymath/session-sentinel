// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

// =============================================================================
// session-sentinel :: src/core/diagnostics.as
// =============================================================================
// Self-diagnostics system.
//
// Provides a bounded ring buffer of diagnostic entries, a watchdog that
// alerts when scans stop running, and a full system health check that
// examines disk space, memory pressure, orphan processes, storage growth
// rates, and healer effectiveness.
//
// The diagnostics subsystem is designed to answer the meta-question:
// "Is session-sentinel itself healthy?"
// =============================================================================

module SessionSentinel.Core.Diagnostics

use SessionSentinel.Core.Scanner.{Timestamp}
use SessionSentinel.Core.Health.{HealthZone, HealthReading, TrendDirection, Degrading}

// ---------------------------------------------------------------------------
// Effects
// ---------------------------------------------------------------------------

/// Filesystem effect — stat calls for disk space checks.
effect FS {
    fn statvfs(path: String) -> Result[FsStats, IOError];
    fn path_exists(path: String) -> Bool;
    fn append_file(path: String, line: String) -> Result[Unit, IOError];
    fn create_dir_all(path: String) -> Result[Unit, IOError];
}

/// Process effect — check for orphan AI processes.
effect Process {
    fn find_pids(pattern: String) -> Vec[Nat];
    fn process_age_secs(pid: Nat) -> Result[Nat, IOError];
}

/// System effect — memory and swap information.
effect System {
    fn total_memory_bytes() -> Nat;
    fn available_memory_bytes() -> Nat;
    fn total_swap_bytes() -> Nat;
    fn used_swap_bytes() -> Nat;
}

/// Clock effect — timestamps.
effect Clock {
    fn now() -> Timestamp;
}

// ---------------------------------------------------------------------------
// Supporting types
// ---------------------------------------------------------------------------

/// Filesystem statistics returned by statvfs(2).
type FsStats = {
    /// Total capacity of the filesystem in bytes.
    total_bytes: Nat,

    /// Available bytes (to non-root users).
    available_bytes: Nat,

    /// Used bytes (total - available).
    used_bytes: Nat,

    /// Mount point path.
    mount_point: String
}

// ---------------------------------------------------------------------------
// Diagnostic entry
// ---------------------------------------------------------------------------

/// Category of a diagnostic entry.
///
/// Used for filtering in the PanLL panel and for routing notifications.
type DiagnosticCategory =
    /// Disk/storage-related observations.
    | Storage
    /// Process lifecycle observations (orphan detection, active sessions).
    | ProcessCat
    /// Health zone transitions and classifications.
    | Health
    /// Self-healing actions and their outcomes.
    | Healing
    /// Errors in session-sentinel's own operation.
    | Error

/// Severity level of a diagnostic entry.
///
/// Determines log colouring, notification urgency, and retention priority.
type Severity =
    /// Informational — normal operation.
    | Info
    /// Warning — something unusual that may need attention.
    | Warning
    /// Critical — action required; sentinel may be degraded.
    | Critical

/// A single diagnostic entry.
///
/// Immutable once created.  Stored in the ring buffer and optionally
/// persisted to the log file.
type DiagnosticEntry = {
    /// When this entry was created (UNIX seconds).
    timestamp: Timestamp,

    /// Which subsystem generated this entry.
    category: DiagnosticCategory,

    /// Human-readable diagnostic message.
    message: String,

    /// How severe this entry is.
    severity: Severity
}

/// Format a diagnostic entry as a single log line.
///
/// Format: `[TIMESTAMP] [SEVERITY] [CATEGORY] message`
total fn format_entry(entry: ref DiagnosticEntry) -> String {
    let sev = match entry.severity {
        Info     => "INFO",
        Warning  => "WARN",
        Critical => "CRIT"
    };
    let cat = match entry.category {
        Storage    => "STORAGE",
        ProcessCat => "PROCESS",
        Health     => "HEALTH",
        Healing    => "HEALING",
        Error      => "ERROR"
    };
    format!("[{}] [{}] [{}] {}", entry.timestamp, sev, cat, entry.message)
}

// ---------------------------------------------------------------------------
// Ring buffer
// ---------------------------------------------------------------------------

/// Maximum number of entries retained in memory.
///
/// 1000 entries at ~200 bytes each is ~200 KB — negligible.
let MAX_ENTRIES: Nat = 1000

/// Bounded ring buffer of diagnostic entries.
///
/// When the buffer is full, the oldest entry is evicted.  The buffer
/// supports O(1) append and O(n) iteration in chronological order.
type DiagnosticLog = {
    /// The underlying storage.  Indices wrap modulo `MAX_ENTRIES`.
    entries: Vec[DiagnosticEntry],

    /// Index of the next write position.
    write_pos: Nat,

    /// Number of entries currently stored (max `MAX_ENTRIES`).
    count: Nat,

    /// Path to the persistent log file (entries are also appended here).
    log_file_path: String
}

/// Create a new empty diagnostic log.
total fn new_log(log_file_path: String) -> DiagnosticLog {
    {
        entries:       Vec.with_capacity(MAX_ENTRIES),
        write_pos:     0,
        count:         0,
        log_file_path: log_file_path
    }
}

/// Append a diagnostic entry to the ring buffer and optionally persist it.
///
/// If the buffer is full, the oldest entry is overwritten.
fn push_entry(log: mut ref DiagnosticLog, entry: DiagnosticEntry) -> Unit / FS {
    // Persist to file (best-effort — do not fail if disk is full).
    let line = format_entry(ref entry);
    let dir = log.log_file_path.parent_dir();
    let _ = FS.create_dir_all(dir);
    let _ = FS.append_file(log.log_file_path.clone(), format!("{}\n", line));

    // Append to ring buffer.
    if log.count < MAX_ENTRIES {
        log.entries.push(entry);
        log.count = log.count + 1;
    } else {
        log.entries[log.write_pos] = entry;
    };
    log.write_pos = (log.write_pos + 1) % MAX_ENTRIES;
}

/// Iterate entries in chronological order (oldest first).
total fn iter_entries(log: ref DiagnosticLog) -> Vec[ref DiagnosticEntry] {
    if log.count < MAX_ENTRIES {
        log.entries.iter().collect()
    } else {
        // Ring buffer has wrapped: read from write_pos to end, then 0 to write_pos.
        let mut result: Vec[ref DiagnosticEntry] = vec![];
        for i in log.write_pos..MAX_ENTRIES {
            result.push(ref log.entries[i]);
        };
        for i in 0..log.write_pos {
            result.push(ref log.entries[i]);
        };
        result
    }
}

/// Return the most recent N entries (newest first).
total fn recent_entries(log: ref DiagnosticLog, n: Nat) -> Vec[ref DiagnosticEntry] {
    let all = iter_entries(log);
    let start = if all.len() > n { all.len() - n } else { 0 };
    all.slice(start, all.len()).rev().collect()
}

/// Count entries matching a severity level.
total fn count_by_severity(log: ref DiagnosticLog, sev: ref Severity) -> Nat {
    iter_entries(log).iter().filter(|e| e.severity == sev).count()
}

// ---------------------------------------------------------------------------
// Convenience logging functions
// ---------------------------------------------------------------------------

/// Log an informational entry.
fn log_info(log: mut ref DiagnosticLog, category: &str, message: String) -> Unit / FS + Clock {
    let ts = Clock.now();
    let cat = parse_category(category);
    push_entry(log, {
        timestamp: ts,
        category:  cat,
        message:   message,
        severity:  Info
    })
}

/// Log a warning entry.
fn log_warning(log: mut ref DiagnosticLog, category: &str, message: String) -> Unit / FS + Clock {
    let ts = Clock.now();
    let cat = parse_category(category);
    push_entry(log, {
        timestamp: ts,
        category:  cat,
        message:   message,
        severity:  Warning
    })
}

/// Log a critical entry.
fn log_critical(log: mut ref DiagnosticLog, category: &str, message: String) -> Unit / FS + Clock {
    let ts = Clock.now();
    let cat = parse_category(category);
    push_entry(log, {
        timestamp: ts,
        category:  cat,
        message:   message,
        severity:  Critical
    })
}

/// Map a category string to the DiagnosticCategory enum.
total fn parse_category(cat: &str) -> DiagnosticCategory {
    match cat {
        "Storage"  => Storage,
        "Process"  => ProcessCat,
        "Health"   => Health,
        "Healing"  => Healing,
        _          => Error
    }
}

// ---------------------------------------------------------------------------
// Watchdog
// ---------------------------------------------------------------------------

/// Watchdog state — tracks the last successful scan to detect hangs.
///
/// If more than `2 * expected_interval_secs` have elapsed since the last
/// successful scan, the watchdog fires a critical diagnostic.
type Watchdog = {
    /// Timestamp of the last successful scan completion.
    last_successful_scan: Option[Timestamp],

    /// Expected interval between scans (from config).
    expected_interval_secs: Nat,

    /// Number of consecutive watchdog alerts fired (reset on successful scan).
    consecutive_alerts: Nat
}

/// Create a new watchdog with no scan history.
total fn new_watchdog(expected_interval: Nat) -> Watchdog {
    {
        last_successful_scan:  None,
        expected_interval_secs: expected_interval,
        consecutive_alerts:    0
    }
}

/// Record a successful scan, resetting the watchdog timer.
total fn watchdog_ping(wd: mut ref Watchdog, now: Timestamp) -> Unit {
    wd.last_successful_scan = Some(now);
    wd.consecutive_alerts   = 0;
}

/// Check the watchdog and fire an alert if the scan is overdue.
///
/// Returns `true` if an alert was fired.
fn watchdog_check(
    wd:       mut ref Watchdog,
    diag_log: mut ref DiagnosticLog
) -> Bool / Clock + FS {
    let now = Clock.now();
    let deadline = wd.expected_interval_secs * 2;

    match wd.last_successful_scan {
        None => {
            // No scan has ever completed.  Fire alert only after the
            // first expected interval has passed (give startup time).
            false
        },
        Some(last) => {
            let elapsed = if now > last { now - last } else { 0 };

            if elapsed > deadline {
                wd.consecutive_alerts = wd.consecutive_alerts + 1;
                log_critical(diag_log, "Health",
                    format!("Watchdog: no successful scan in {} seconds (expected every {}s). \
                             Consecutive alerts: {}",
                            elapsed, wd.expected_interval_secs, wd.consecutive_alerts));
                true
            } else {
                false
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Full system diagnostics
// ---------------------------------------------------------------------------

/// Mount points to check for disk space.
///
/// We check the home filesystem and any mount holding AI storage.
let CRITICAL_MOUNTS: Vec[String] = vec!["/", "/home", "/mnt/eclipse"]

/// Memory pressure threshold: warn when available memory is below 10%
/// of total.
let MEMORY_WARN_PERCENT: Nat = 10

/// Swap usage threshold: warn when swap usage exceeds 50% of total.
let SWAP_WARN_PERCENT: Nat = 50

/// Disk space threshold: warn when a filesystem is more than 90% full.
let DISK_WARN_PERCENT: Nat = 90

/// Process age threshold: an AI process running longer than 24 hours
/// without corresponding session data is flagged as potentially orphaned.
let ORPHAN_PROCESS_AGE_SECS: Nat = 86400

/// Run a complete self-diagnostic check.
///
/// Examines:
///   1. Disk space on critical mount points.
///   2. Memory and swap pressure.
///   3. Orphan AI processes (running but no active session data).
///   4. Storage growth rate (from trend analysis).
///   5. Healer effectiveness (are we keeping up with growth?).
///   6. Watchdog status (has scanning stalled?).
///
/// Returns a list of new diagnostic entries generated by this check.
fn run_diagnostics(
    diag_log:   mut ref DiagnosticLog,
    watchdog:   mut ref Watchdog,
    readings:   ref Vec[HealthReading],
    heal_bytes_last_hour: Nat
) -> Vec[DiagnosticEntry] / FS + Process + System + Clock {
    let now = Clock.now();
    let mut new_entries: Vec[DiagnosticEntry] = vec![];

    // ---- 1. Disk space checks ----
    for mount in CRITICAL_MOUNTS.iter() {
        if !FS.path_exists(mount.clone()) { continue };

        match FS.statvfs(mount.clone()) {
            Ok(stats) => {
                let used_percent = if stats.total_bytes > 0 {
                    (stats.used_bytes * 100) / stats.total_bytes
                } else {
                    0
                };

                if used_percent >= DISK_WARN_PERCENT {
                    let entry = {
                        timestamp: now,
                        category:  Storage,
                        message:   format!(
                            "Disk usage on {} is {}% ({} of {} bytes available)",
                            mount, used_percent,
                            stats.available_bytes, stats.total_bytes
                        ),
                        severity: if used_percent >= 95 { Critical } else { Warning }
                    };
                    push_entry(diag_log, entry.clone());
                    new_entries.push(entry);
                } else {
                    let entry = {
                        timestamp: now,
                        category:  Storage,
                        message:   format!("Disk {} OK: {}% used", mount, used_percent),
                        severity:  Info
                    };
                    push_entry(diag_log, entry.clone());
                    new_entries.push(entry);
                }
            },
            Err(e) => {
                let entry = {
                    timestamp: now,
                    category:  Error,
                    message:   format!("Failed to stat filesystem {}: {}", mount, e),
                    severity:  Warning
                };
                push_entry(diag_log, entry.clone());
                new_entries.push(entry);
            }
        }
    };

    // ---- 2. Memory and swap pressure ----
    let total_mem = System.total_memory_bytes();
    let avail_mem = System.available_memory_bytes();

    if total_mem > 0 {
        let avail_percent = (avail_mem * 100) / total_mem;

        if avail_percent < MEMORY_WARN_PERCENT {
            let entry = {
                timestamp: now,
                category:  ProcessCat,
                message:   format!(
                    "Low memory: only {}% available ({} of {} bytes)",
                    avail_percent, avail_mem, total_mem
                ),
                severity: Critical
            };
            push_entry(diag_log, entry.clone());
            new_entries.push(entry);
        }
    };

    let total_swap = System.total_swap_bytes();
    let used_swap  = System.used_swap_bytes();

    if total_swap > 0 {
        let swap_percent = (used_swap * 100) / total_swap;

        if swap_percent > SWAP_WARN_PERCENT {
            let entry = {
                timestamp: now,
                category:  ProcessCat,
                message:   format!(
                    "High swap usage: {}% ({} of {} bytes)",
                    swap_percent, used_swap, total_swap
                ),
                severity: Warning
            };
            push_entry(diag_log, entry.clone());
            new_entries.push(entry);
        }
    };

    // ---- 3. Orphan AI processes ----
    let ai_patterns = vec![
        "claude", "claude-code",
        "copilot-agent", "github-copilot",
        "ollama", "lm-studio", "lms",
        "cursor", "continue", "aider"
    ];

    for pattern in ai_patterns.iter() {
        let pids = Process.find_pids(pattern.clone());

        for pid in pids.iter() {
            match Process.process_age_secs(pid) {
                Ok(age) if age > ORPHAN_PROCESS_AGE_SECS => {
                    let entry = {
                        timestamp: now,
                        category:  ProcessCat,
                        message:   format!(
                            "Potentially orphaned process: PID {} matching '{}' \
                             has been running for {} seconds ({:.1} hours)",
                            pid, pattern, age, (age as Float) / 3600.0
                        ),
                        severity: Warning
                    };
                    push_entry(diag_log, entry.clone());
                    new_entries.push(entry);
                },
                _ => ()
            }
        }
    };

    // ---- 4. Storage growth rate ----
    if readings.len() >= 2 {
        let latest  = readings.last().unwrap();
        let earliest = readings.first().unwrap();
        let time_span = if latest.timestamp > earliest.timestamp {
            latest.timestamp - earliest.timestamp
        } else {
            1  // avoid division by zero
        };

        let byte_delta: Int = (latest.total_bytes as Int) - (earliest.total_bytes as Int);
        let bytes_per_hour: Int = (byte_delta * 3600) / (time_span as Int);

        if bytes_per_hour > 50_000_000 {  // > 50 MB/hr growth
            let entry = {
                timestamp: now,
                category:  Storage,
                message:   format!(
                    "Rapid storage growth: ~{} bytes/hour over last {} readings",
                    bytes_per_hour, readings.len()
                ),
                severity: Warning
            };
            push_entry(diag_log, entry.clone());
            new_entries.push(entry);
        }
    };

    // ---- 5. Healer effectiveness ----
    // Compare bytes healed in the last hour against growth rate.
    if readings.len() >= 2 {
        let latest   = readings.last().unwrap();
        let earliest = readings.first().unwrap();
        let time_span = if latest.timestamp > earliest.timestamp {
            latest.timestamp - earliest.timestamp
        } else {
            1
        };
        let byte_delta: Int = (latest.total_bytes as Int) - (earliest.total_bytes as Int);
        let growth_per_hour: Int = (byte_delta * 3600) / (time_span as Int);

        if growth_per_hour > 0 && (heal_bytes_last_hour as Int) < growth_per_hour {
            let entry = {
                timestamp: now,
                category:  Healing,
                message:   format!(
                    "Healer is not keeping up: growth ~{} bytes/hr but only {} bytes healed/hr",
                    growth_per_hour, heal_bytes_last_hour
                ),
                severity: Warning
            };
            push_entry(diag_log, entry.clone());
            new_entries.push(entry);
        }
    };

    // ---- 6. Watchdog check ----
    let _ = watchdog_check(watchdog, diag_log);

    new_entries
}
