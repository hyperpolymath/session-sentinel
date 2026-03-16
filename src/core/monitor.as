// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

// =============================================================================
// session-sentinel :: src/core/monitor.as
// =============================================================================
// Main monitoring loop.
//
// Ties together configuration, scanning, health classification, self-healing,
// diagnostics, and the PanLL panel socket into a single event loop.
//
// Lifecycle:
//   1. Load config, resolve paths.
//   2. Initial scan and classification.
//   3. Set tray icon, open panel socket.
//   4. Enter loop: scan → classify → heal → update tray → push panel → sleep.
//
// Signal handling:
//   SIGHUP  — reload configuration from disk.
//   SIGTERM — graceful shutdown (close socket, flush log, exit 0).
//   SIGUSR1 — force an immediate scan (skip sleep).
//
// Fault tolerance:
//   If a scan throws, the error is logged and a degraded counter incremented.
//   After 3 consecutive failures the monitor enters Failed state, changes the
//   tray icon to flashing purple, and logs a critical diagnostic.
// =============================================================================

module SessionSentinel.Core.Monitor

use SessionSentinel.Core.Config.{
    SentinelConfig, load_config, resolve_all_paths
}
use SessionSentinel.Core.Scanner.{
    ProviderSnapshot, scan_all, aggregate_bytes, Timestamp
}
use SessionSentinel.Core.Health.{
    HealthZone, HealthReading, HealthSummary,
    classify, analyse_trend, build_summary, flash_check,
    detect_transition, zone_label,
    Green, Yellow, Red, Purple
}
use SessionSentinel.Core.Healer.{
    auto_heal, HealResult
}
use SessionSentinel.Core.Diagnostics.{
    DiagnosticLog, DiagnosticEntry, Watchdog,
    new_log, new_watchdog, watchdog_ping,
    run_diagnostics,
    log_info, log_warning, log_critical
}

// ---------------------------------------------------------------------------
// Effects
// ---------------------------------------------------------------------------

/// State effect — threaded monitor state through the loop.
effect State[S] {
    fn get() -> S;
    fn put(s: S) -> Unit;
    fn modify(f: fn(S) -> S) -> Unit;
}

/// IO effect — filesystem, network, sleep.
effect IO {
    fn sleep_secs(n: Nat) -> Unit;
    fn read_file(path: String) -> Result[String, IOError];
    fn write_file(path: String, contents: String) -> Result[Unit, IOError];
    fn env_var(name: String) -> Option[String];
    fn path_exists(path: String) -> Bool;
    fn create_dir_all(path: String) -> Result[Unit, IOError];
}

/// Filesystem effect — delegated to scanner and healer.
effect FS {
    fn list_dir(path: String)       -> Result[Vec[DirEntry], IOError];
    fn dir_size_bytes(path: String) -> Result[Nat, IOError];
    fn file_size(path: String)      -> Result[Nat, IOError];
    fn file_mtime(path: String)     -> Result[Timestamp, IOError];
    fn is_dir(path: String)         -> Bool;
    fn is_file(path: String)        -> Bool;
    fn is_symlink(path: String)     -> Bool;
    fn is_empty_dir(path: String)   -> Bool;
    fn read_to_string(path: String) -> Result[String, IOError];
    fn remove_dir_all(path: String) -> Result[Unit, IOError];
    fn remove_file(path: String)    -> Result[Unit, IOError];
    fn statvfs(path: String)        -> Result[FsStats, IOError];
    fn append_file(path: String, line: String) -> Result[Unit, IOError];
}

/// Process effect.
effect Process {
    fn find_pids(pattern: String) -> Vec[Nat];
    fn is_path_in_use(path: String) -> Bool;
    fn process_age_secs(pid: Nat) -> Result[Nat, IOError];
}

/// System effect — memory info.
effect System {
    fn total_memory_bytes() -> Nat;
    fn available_memory_bytes() -> Nat;
    fn total_swap_bytes() -> Nat;
    fn used_swap_bytes() -> Nat;
}

/// Clock effect.
effect Clock {
    fn now() -> Timestamp;
}

/// Signal effect — POSIX signal reception.
effect Signal {
    /// Check for a pending signal.  Non-blocking; returns `None` if no
    /// signal is queued.
    fn poll_signal() -> Option[PosixSignal];
}

/// Tray icon effect — update the system tray icon.
effect Tray {
    fn set_icon(colour: String, tooltip: String) -> Unit;
    fn set_flashing(enabled: Bool) -> Unit;
}

/// Panel socket effect — push JSON frames to the PanLL panel.
effect Panel {
    fn open_socket(path: String) -> Result[Unit, IOError];
    fn close_socket() -> Unit;
    fn push_frame(json: String) -> Result[Unit, IOError];
    fn is_connected() -> Bool;
}

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// POSIX signals the monitor handles.
type PosixSignal =
    | SIGHUP        // reload config
    | SIGTERM       // graceful shutdown
    | SIGUSR1       // force immediate scan

/// The monitor's run state.
type RunState =
    /// Normal operation — scanning and healing on schedule.
    | Running
    /// Degraded — scan failures have occurred but not yet critical.
    | Degraded Nat      // consecutive failure count
    /// Failed — 3+ consecutive failures; tray is flashing purple.
    | Failed
    /// Shutting down — received SIGTERM, draining and exiting.
    | ShuttingDown

/// Complete monitor state threaded through the main loop.
///
/// This is the `S` in `State[MonitorState]`.
type MonitorState = {
    /// Current configuration (reloaded on SIGHUP).
    config: SentinelConfig,

    /// Current health zone (updated every scan cycle).
    current_zone: HealthZone,

    /// Timestamp of the last successful scan.
    last_scan_time: Option[Timestamp],

    /// Ring buffer of historical readings (last 100).
    trend_history: Vec[HealthReading],

    /// Diagnostic log (ring buffer of last 1000 entries).
    diagnostic_log: DiagnosticLog,

    /// Watchdog tracking scan liveness.
    watchdog: Watchdog,

    /// Current run state.
    run_state: RunState,

    /// Most recent snapshots from the last scan.
    last_snapshots: Vec[ProviderSnapshot],

    /// Bytes healed in the current hour (reset every 3600 seconds).
    heal_bytes_this_hour: Nat,

    /// Timestamp of the last hourly reset for heal tracking.
    heal_hour_start: Timestamp
}

/// Maximum number of historical readings to retain for trend analysis.
let MAX_TREND_HISTORY: Nat = 100

/// Number of consecutive scan failures before entering Failed state.
let MAX_CONSECUTIVE_FAILURES: Nat = 3

// ---------------------------------------------------------------------------
// Initialisation
// ---------------------------------------------------------------------------

/// Initialise the monitor: load config, perform initial scan, set up tray
/// and panel socket.
///
/// Returns the initial `MonitorState` or an error if critical setup fails.
fn initialise()
    -> Result[MonitorState, String]
    / IO + FS + Clock + Process + System + Tray + Panel
{
    let now = Clock.now();

    // Load and resolve config.
    let raw_config = match load_config() {
        Ok(c)  => c,
        Err(e) => return Err(format!("Failed to load config: {:?}", e))
    };
    let config = resolve_all_paths(raw_config);

    // Create diagnostic log.
    let mut diag_log = new_log(config.log_path.clone());
    log_info(mut ref diag_log, "Health",
        "session-sentinel starting up");

    // Create watchdog.
    let watchdog = new_watchdog(config.scan_interval_secs);

    // Initial scan.
    let (snapshots, scan_errors) = scan_all(ref config);

    for (name, err) in scan_errors.iter() {
        log_warning(mut ref diag_log, "Storage",
            format!("Initial scan failed for {}: {}", name, err));
    };

    let total_bytes = aggregate_bytes(ref snapshots);
    let zone = classify(total_bytes, ref config.thresholds);

    log_info(mut ref diag_log, "Health",
        format!("Initial zone: {} ({} bytes across {} providers)",
                zone_label(ref zone), total_bytes, snapshots.len()));

    // Set tray icon.
    Tray.set_icon(Health.zone_colour(ref zone),
        format!("session-sentinel: {}", zone_label(ref zone)));
    Tray.set_flashing(false);

    // Open panel socket.
    match Panel.open_socket(config.panel_socket_path.clone()) {
        Ok(())  => log_info(mut ref diag_log, "Health",
            format!("Panel socket opened at {}", config.panel_socket_path)),
        Err(e)  => log_warning(mut ref diag_log, "Error",
            format!("Failed to open panel socket: {} (panel will be unavailable)", e))
    };

    // Build initial state.
    let initial_reading = {
        timestamp:   now,
        total_bytes: total_bytes,
        zone:        zone.clone()
    };

    Ok({
        config:              config,
        current_zone:        zone,
        last_scan_time:      Some(now),
        trend_history:       vec![initial_reading],
        diagnostic_log:      diag_log,
        watchdog:            watchdog,
        run_state:           Running,
        last_snapshots:      snapshots,
        heal_bytes_this_hour: 0,
        heal_hour_start:     now
    })
}

// ---------------------------------------------------------------------------
// Signal handling
// ---------------------------------------------------------------------------

/// Process any pending signal.
///
/// - SIGHUP:  reload config from disk.
/// - SIGTERM: begin graceful shutdown.
/// - SIGUSR1: set a flag to skip the sleep and scan immediately.
///
/// Returns `true` if a forced scan should happen (SIGUSR1).
fn handle_signals(state: mut ref MonitorState)
    -> Bool
    / Signal + IO + FS + Clock
{
    match Signal.poll_signal() {
        None => false,

        Some(SIGHUP) => {
            log_info(mut ref state.diagnostic_log, "Health",
                "Received SIGHUP — reloading configuration");

            match load_config() {
                Ok(raw) => {
                    let resolved = resolve_all_paths(raw);
                    state.config = resolved;
                    log_info(mut ref state.diagnostic_log, "Health",
                        "Configuration reloaded successfully");
                },
                Err(e) => {
                    log_warning(mut ref state.diagnostic_log, "Error",
                        format!("Config reload failed: {:?}. Keeping previous config.", e));
                }
            };
            false
        },

        Some(SIGTERM) => {
            log_info(mut ref state.diagnostic_log, "Health",
                "Received SIGTERM — initiating graceful shutdown");
            state.run_state = ShuttingDown;
            false
        },

        Some(SIGUSR1) => {
            log_info(mut ref state.diagnostic_log, "Health",
                "Received SIGUSR1 — forcing immediate scan");
            true
        }
    }
}

// ---------------------------------------------------------------------------
// Single scan cycle
// ---------------------------------------------------------------------------

/// Execute one scan-classify-heal-update cycle.
///
/// This is the body of the main loop, extracted for clarity and testability.
fn run_cycle(state: mut ref MonitorState)
    -> Unit
    / IO + FS + Clock + Process + System + Tray + Panel
{
    let now = Clock.now();

    // Reset hourly heal counter if an hour has passed.
    if now - state.heal_hour_start >= 3600 {
        state.heal_bytes_this_hour = 0;
        state.heal_hour_start = now;
    };

    // ---- Scan ----
    let scan_result = scan_all(ref state.config);

    match scan_result {
        (snapshots, errors) if !snapshots.is_empty() => {
            // At least some providers scanned successfully.
            for (name, err) in errors.iter() {
                log_warning(mut ref state.diagnostic_log, "Storage",
                    format!("Scan failed for {}: {}", name, err));
            };

            let total_bytes = aggregate_bytes(ref snapshots);
            let previous_zone = state.current_zone.clone();
            let zone = classify(total_bytes, ref state.config.thresholds);

            // Record reading in trend history.
            let reading = {
                timestamp:   now,
                total_bytes: total_bytes,
                zone:        zone.clone()
            };
            state.trend_history.push(reading);
            if state.trend_history.len() > MAX_TREND_HISTORY {
                state.trend_history.remove(0);
            };

            // Build health summary.
            let summary = build_summary(
                ref snapshots,
                ref state.trend_history,
                ref previous_zone,
                ref state.config.thresholds,
                state.config.scan_interval_secs,
                now
            );

            // Log zone transitions.
            match summary.transition {
                Some((old, new_zone)) => {
                    let msg = format!("Zone transition: {} -> {}",
                                      zone_label(ref old), zone_label(ref new_zone));
                    if Health.is_escalation(ref old, ref new_zone) {
                        log_warning(mut ref state.diagnostic_log, "Health", msg);
                    } else {
                        log_info(mut ref state.diagnostic_log, "Health", msg);
                    }
                },
                None => ()
            };

            // ---- Heal ----
            let heal_result = auto_heal(
                ref zone,
                ref state.config,
                ref snapshots,
                mut ref state.diagnostic_log,
                false   // not dry-run
            );
            state.heal_bytes_this_hour = state.heal_bytes_this_hour + heal_result.bytes_freed;

            // ---- Update tray ----
            Tray.set_icon(Health.zone_colour(ref zone),
                format!("session-sentinel: {} | {} bytes | {} providers",
                        zone_label(ref zone), total_bytes, snapshots.len()));
            Tray.set_flashing(summary.should_flash);

            // ---- Push panel frame ----
            if Panel.is_connected() {
                let frame = serialise_summary_json(ref summary, ref snapshots);
                match Panel.push_frame(frame) {
                    Ok(())  => (),
                    Err(e)  => log_warning(mut ref state.diagnostic_log, "Error",
                        format!("Failed to push panel frame: {}", e))
                }
            };

            // ---- Update state ----
            state.current_zone   = zone;
            state.last_scan_time = Some(now);
            state.last_snapshots = snapshots;
            watchdog_ping(mut ref state.watchdog, now);

            // Reset degraded counter on success.
            state.run_state = Running;
        },

        (_, errors) => {
            // All providers failed.
            for (name, err) in errors.iter() {
                log_warning(mut ref state.diagnostic_log, "Storage",
                    format!("Scan failed for {}: {}", name, err));
            };

            // Increment degraded counter.
            state.run_state = match state.run_state {
                Running       => Degraded(1),
                Degraded(n)   => {
                    if n + 1 >= MAX_CONSECUTIVE_FAILURES {
                        log_critical(mut ref state.diagnostic_log, "Health",
                            format!("Entering Failed state after {} consecutive scan failures",
                                    n + 1));
                        Tray.set_icon(Health.zone_colour(ref Purple),
                            "session-sentinel: FAILED — scan errors");
                        Tray.set_flashing(true);
                        Failed
                    } else {
                        Degraded(n + 1)
                    }
                },
                Failed        => Failed,
                ShuttingDown  => ShuttingDown
            };
        }
    }
}

// ---------------------------------------------------------------------------
// Main loop
// ---------------------------------------------------------------------------

/// The main monitoring loop.
///
/// Runs indefinitely until SIGTERM is received or an unrecoverable error
/// occurs.  Each iteration:
///   1. Check for signals (SIGHUP, SIGTERM, SIGUSR1).
///   2. Run a scan-classify-heal-update cycle.
///   3. Optionally run full diagnostics (every 10th cycle).
///   4. Sleep for the configured interval.
fn run_monitor()
    -> Unit
    / IO + FS + Clock + Process + System + Signal + Tray + Panel + State[MonitorState]
{
    let mut cycle_count: Nat = 0;

    loop {
        let state = State.get();

        // Exit if shutting down.
        match state.run_state {
            ShuttingDown => {
                log_info(mut ref state.diagnostic_log, "Health",
                    "Shutdown complete — closing sockets and exiting");
                Panel.close_socket();
                State.put(state);
                break
            },
            _ => ()
        };

        // Check signals.
        let force_scan = handle_signals(mut ref state);
        State.put(state);

        // Run scan cycle.
        let mut state = State.get();
        run_cycle(mut ref state);
        cycle_count = cycle_count + 1;
        State.put(state);

        // Run full diagnostics every 10 cycles (or ~10 minutes at
        // default 60s interval).
        if cycle_count % 10 == 0 {
            let mut state = State.get();
            if state.config.enable_diagnostics {
                let _ = run_diagnostics(
                    mut ref state.diagnostic_log,
                    mut ref state.watchdog,
                    ref state.trend_history,
                    state.heal_bytes_this_hour
                );
            };
            State.put(state);
        };

        // Sleep (skip if SIGUSR1 forced an immediate scan).
        if !force_scan {
            let state = State.get();
            IO.sleep_secs(state.config.scan_interval_secs);
        }
    }
}

// ---------------------------------------------------------------------------
// JSON serialisation for the PanLL panel
// ---------------------------------------------------------------------------

/// Serialise a `HealthSummary` and provider snapshots to a JSON string
/// for transmission over the panel socket.
///
/// The PanLL panel expects a single JSON object per frame, terminated
/// by a newline.
total fn serialise_summary_json(
    summary:   ref HealthSummary,
    snapshots: ref Vec[ProviderSnapshot]
) -> String {
    let mut json = String.new();
    json.push('{');

    // Top-level fields.
    json.push_str(format!("\"zone\":\"{}\",", zone_label(ref summary.zone)));
    json.push_str(format!("\"total_bytes\":{},", summary.total_bytes));
    json.push_str(format!("\"should_flash\":{},", summary.should_flash));
    json.push_str(format!("\"timestamp\":{},", summary.timestamp));

    // Trend.
    let trend_dir = match summary.trend.direction {
        Health.Improving => "improving",
        Health.Stable    => "stable",
        Health.Degrading => "degrading"
    };
    json.push_str(format!("\"trend\":{{\"direction\":\"{}\",\"growth_rate_bps\":{},\"sample_count\":{}}},",
        trend_dir, summary.trend.growth_rate_bps, summary.trend.sample_count));

    // Provider snapshots.
    json.push_str("\"providers\":[");
    for (i, snap) in snapshots.iter().enumerate() {
        if i > 0 { json.push(',') };
        json.push_str(format!(
            "{{\"name\":\"{}\",\"total_bytes\":{},\"file_count\":{},\
              \"conversation_count\":{},\"subagent_count\":{},\"orphan_count\":{}}}",
            snap.provider_name, snap.total_bytes, snap.file_count,
            snap.conversation_count, snap.subagent_count, snap.orphan_count
        ));
    };
    json.push_str("]");

    // Transition.
    match summary.transition {
        Some((old, new_zone)) => {
            json.push_str(format!(",\"transition\":{{\"from\":\"{}\",\"to\":\"{}\"}}",
                zone_label(ref old), zone_label(ref new_zone)));
        },
        None => ()
    };

    json.push('}');
    json
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

/// Top-level entry point for the monitor daemon.
///
/// Initialises state and hands off to `run_monitor`.  If initialisation
/// fails, logs the error to stderr and exits with code 1.
fn main() -> Unit / IO + FS + Clock + Process + System + Signal + Tray + Panel {
    match initialise() {
        Ok(initial_state) => {
            // Run the monitor with the initial state threaded through
            // the State effect.
            with State[MonitorState] = initial_state {
                run_monitor()
            }
        },
        Err(msg) => {
            eprintln(format!("session-sentinel: fatal: {}", msg));
            exit(1)
        }
    }
}
