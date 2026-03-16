// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Session Sentinel — Native System Tray Entry Point
//
// This is the main entry point for the session-sentinel-tray binary.
// It provides KDE/Wayland system tray integration via the DBus
// StatusNotifierItem protocol, displaying real-time session health
// information from the ReScript monitoring core.
//
// Architecture:
//   CLI args → DBus connection → SNI registration → monitor loop
//                                                     ↓
//                                              signal handlers
//                                              watchdog thread
//                                              tray updates
//
// The binary is designed to run as a long-lived daemon, typically started
// by a systemd user service (Type=notify with watchdog).

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const dbus = @import("dbus.zig");
const tray = @import("tray.zig");
const icons = @import("icons.zig");
const watchdog = @import("watchdog.zig");

// ---------------------------------------------------------------------------
// Version and build metadata
// ---------------------------------------------------------------------------

/// Semantic version of the tray binary (keep in sync with project root).
pub const VERSION = "0.1.0";

/// Build-time metadata string for diagnostics.
pub const BUILD_INFO = "session-sentinel-tray " ++ VERSION ++ " (zig " ++ @import("builtin").zig_version_string ++ ")";

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

/// Runtime configuration parsed from CLI arguments and/or config file.
pub const Config = struct {
    /// Path to the JSON/TOML config file. Defaults to
    /// ~/.config/session-sentinel/config.json if not specified.
    config_path: ?[]const u8 = null,

    /// Run a single scan and exit (useful for cron / scripting).
    once: bool = false,

    /// Run as a background daemon (fork and detach from terminal).
    daemon: bool = false,

    /// Scan interval in seconds. Overridden by config file if present.
    scan_interval_s: u32 = 300,

    /// Enable verbose logging to stderr.
    verbose: bool = false,
};

/// Global mutable state protected by an atomic flag.
/// Only the main thread writes; signal handlers read.
var shutdown_requested = std.atomic.Value(bool).init(false);

/// Flag to request an immediate rescan (set by SIGUSR1 handler).
var rescan_requested = std.atomic.Value(bool).init(false);

/// Flag to request config reload (set by SIGHUP handler).
var reload_requested = std.atomic.Value(bool).init(false);

// ---------------------------------------------------------------------------
// Signal handlers
// ---------------------------------------------------------------------------

/// POSIX signal handler — sets atomic flags for the main loop to pick up.
/// Signal handlers must be async-signal-safe, so we only write to atomics.
fn signalHandler(sig: c_int) callconv(.C) void {
    switch (sig) {
        posix.SIG.HUP => {
            // SIGHUP: reload configuration without restarting.
            reload_requested.store(true, .release);
        },
        posix.SIG.TERM, posix.SIG.INT => {
            // SIGTERM / SIGINT: graceful shutdown.
            shutdown_requested.store(true, .release);
        },
        posix.SIG.USR1 => {
            // SIGUSR1: force an immediate rescan cycle.
            rescan_requested.store(true, .release);
        },
        else => {},
    }
}

/// Install POSIX signal handlers for SIGHUP, SIGTERM, SIGINT, SIGUSR1.
fn installSignalHandlers() !void {
    const handler: posix.Sigaction = .{
        .handler = .{ .handler = signalHandler },
        .mask = posix.empty_sigset,
        .flags = posix.SA.RESTART,
    };

    try posix.sigaction(posix.SIG.HUP, &handler, null);
    try posix.sigaction(posix.SIG.TERM, &handler, null);
    try posix.sigaction(posix.SIG.INT, &handler, null);
    try posix.sigaction(posix.SIG.USR1, &handler, null);
}

// ---------------------------------------------------------------------------
// CLI argument parsing
// ---------------------------------------------------------------------------

/// Parse command-line arguments into a Config struct.
/// Returns null if --help or --version was handled (caller should exit 0).
fn parseArgs(allocator: std.mem.Allocator) !?Config {
    var config = Config{};
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip argv[0] (program name).
    _ = args.next();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--config")) {
            config.config_path = args.next() orelse {
                std.log.err("--config requires a PATH argument", .{});
                return error.InvalidArgs;
            };
        } else if (std.mem.eql(u8, arg, "--once")) {
            config.once = true;
        } else if (std.mem.eql(u8, arg, "--daemon")) {
            config.daemon = true;
        } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            config.verbose = true;
        } else if (std.mem.eql(u8, arg, "--interval")) {
            const val_str = args.next() orelse {
                std.log.err("--interval requires a seconds value", .{});
                return error.InvalidArgs;
            };
            config.scan_interval_s = std.fmt.parseInt(u32, val_str, 10) catch {
                std.log.err("--interval value must be a positive integer", .{});
                return error.InvalidArgs;
            };
        } else if (std.mem.eql(u8, arg, "--version")) {
            const stdout = std.io.getStdOut().writer();
            try stdout.print("{s}\n", .{BUILD_INFO});
            return null;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            const stdout = std.io.getStdOut().writer();
            try stdout.writeAll(
                \\session-sentinel-tray — KDE/Wayland system tray for Session Sentinel
                \\
                \\Usage: session-sentinel-tray [OPTIONS]
                \\
                \\Options:
                \\  --config PATH   Path to config file (default: ~/.config/session-sentinel/config.json)
                \\  --once          Run a single scan cycle and exit
                \\  --daemon        Run as a background daemon
                \\  --interval N    Scan interval in seconds (default: 300)
                \\  --verbose, -v   Enable verbose logging
                \\  --version       Print version and exit
                \\  --help, -h      Show this help message
                \\
                \\Signals:
                \\  SIGHUP          Reload configuration
                \\  SIGUSR1         Force immediate rescan
                \\  SIGTERM/SIGINT  Graceful shutdown
                \\
                \\DBus interface: org.hyperpolymath.SessionSentinel1
                \\
            );
            return null;
        } else {
            std.log.err("Unknown argument: {s}", .{arg});
            return error.InvalidArgs;
        }
    }

    return config;
}

// ---------------------------------------------------------------------------
// Monitor loop
// ---------------------------------------------------------------------------

/// The core monitoring loop. Runs in its own thread when in daemon mode,
/// or on the main thread for --once mode.
///
/// Each iteration:
///   1. Queries the ReScript core for current health metrics (via DBus).
///   2. Classifies the health zone (green/yellow/red/purple).
///   3. Updates the tray icon, tooltip, and menu state.
///   4. Emits a HealthChanged signal if the zone transitioned.
///   5. Notifies the systemd watchdog (if active).
///   6. Sleeps for the configured interval (or exits if --once).
fn monitorLoop(
    config: Config,
    bus: *dbus.Connection,
    tray_state: *tray.TrayState,
    wd: *watchdog.Watchdog,
) void {
    std.log.info("Monitor loop started (interval={d}s, once={any})", .{
        config.scan_interval_s,
        config.once,
    });

    var previous_zone: tray.HealthZone = .green;

    while (!shutdown_requested.load(.acquire)) {
        // Check for config reload request.
        if (reload_requested.swap(false, .acq_rel)) {
            std.log.info("Reloading configuration (SIGHUP received)", .{});
            // Config reload is handled by the main thread; we just log here.
        }

        // Perform a scan cycle.
        const scan_result = performScan(bus, tray_state, wd);

        if (scan_result) |zone| {
            // Update tray visuals.
            tray_state.updateZone(zone);

            // Emit HealthChanged signal if zone transitioned.
            if (zone != previous_zone) {
                std.log.info("Health zone transition: {s} -> {s}", .{
                    @tagName(previous_zone),
                    @tagName(zone),
                });
                dbus.emitHealthChanged(bus, zone) catch |err| {
                    std.log.err("Failed to emit HealthChanged signal: {any}", .{err});
                };
                previous_zone = zone;
            }

            // Report success to watchdog.
            wd.reportScanSuccess();
        } else |err| {
            std.log.err("Scan cycle failed: {any}", .{err});
            wd.reportScanFailure();

            // Check if watchdog wants us to enter degraded mode.
            if (wd.shouldEnterDegraded()) {
                tray_state.updateZone(.purple);
                previous_zone = .purple;
            }
        }

        // Notify systemd watchdog (heartbeat).
        wd.notifyWatchdog();

        // Write heartbeat file for external health checks.
        wd.writeHeartbeat() catch |err| {
            std.log.warn("Failed to write heartbeat file: {any}", .{err});
        };

        // Exit after one cycle if --once mode.
        if (config.once) {
            std.log.info("--once mode: exiting after single scan", .{});
            break;
        }

        // Sleep for the scan interval, but wake early on rescan request or shutdown.
        const interval_ns: u64 = @as(u64, config.scan_interval_s) * std.time.ns_per_s;
        const check_interval_ns: u64 = 500 * std.time.ns_per_ms; // Check every 500ms
        var elapsed: u64 = 0;

        while (elapsed < interval_ns) {
            if (shutdown_requested.load(.acquire)) break;
            if (rescan_requested.swap(false, .acq_rel)) {
                std.log.info("Immediate rescan requested (SIGUSR1)", .{});
                break;
            }
            std.time.sleep(check_interval_ns);
            elapsed += check_interval_ns;
        }
    }

    std.log.info("Monitor loop exiting", .{});
}

/// Execute a single scan cycle by querying the monitoring core via DBus.
/// Returns the determined health zone, or an error if the scan failed.
fn performScan(
    bus: *dbus.Connection,
    tray_state: *tray.TrayState,
    wd: *watchdog.Watchdog,
) !tray.HealthZone {
    _ = wd;

    // Call GetHealth on the monitoring core via DBus.
    const health_json = try dbus.callGetHealth(bus);
    defer if (health_json) |json| {
        std.heap.c_allocator.free(json);
    };

    // Parse the health response to determine the zone.
    const zone = if (health_json) |json|
        tray.classifyHealthZone(json)
    else
        tray.HealthZone.yellow; // No response = degraded

    // Update tooltip with latest metrics.
    if (health_json) |json| {
        tray_state.updateTooltipFromJson(json);
    }

    return zone;
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn main() !void {
    // Use the general-purpose allocator for long-lived allocations.
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse CLI arguments.
    const maybe_config = try parseArgs(allocator);
    const config = maybe_config orelse return; // --help or --version handled

    // Set up logging level.
    if (config.verbose) {
        std.log.info("Verbose logging enabled", .{});
    }

    std.log.info("{s} starting", .{BUILD_INFO});

    // Install signal handlers before any threads are spawned.
    try installSignalHandlers();

    // Ensure the icon temp directory exists.
    try icons.ensureTempDir();
    defer icons.cleanupTempDir();

    // Initialize DBus connection to the session bus.
    var bus = try dbus.Connection.init();
    defer bus.deinit();

    // Request our well-known bus name.
    try bus.requestName(dbus.BUS_NAME);

    // Register DBus method handlers (GetHealth, ForceHeal, etc.).
    try dbus.registerMethodHandlers(&bus);

    std.log.info("DBus connection established: {s}", .{dbus.BUS_NAME});

    // Create tray state and register with StatusNotifierWatcher.
    var tray_state = try tray.TrayState.init(allocator, &bus);
    defer tray_state.deinit();

    std.log.info("StatusNotifierItem registered", .{});

    // Initialize watchdog (systemd + internal).
    var wd = watchdog.Watchdog.init();

    // Notify systemd that we are ready (sd_notify READY=1).
    wd.notifyReady();

    // Spawn the monitoring loop in a separate thread (unless --once).
    if (config.daemon or !config.once) {
        const monitor_thread = try std.Thread.spawn(.{}, monitorLoop, .{
            config,
            &bus,
            &tray_state,
            &wd,
        });

        // Main thread: process DBus messages (blocking dispatch loop).
        // This handles incoming method calls and signal delivery.
        while (!shutdown_requested.load(.acquire)) {
            bus.processMessages(100) catch |err| {
                std.log.err("DBus message processing error: {any}", .{err});
                std.time.sleep(100 * std.time.ns_per_ms);
            };

            // Handle flash timer for purple zone.
            tray_state.tickFlashTimer();
        }

        // Wait for monitor thread to finish.
        monitor_thread.join();
    } else {
        // --once mode: run a single scan on the main thread.
        monitorLoop(config, &bus, &tray_state, &wd);
    }

    // Notify systemd that we are stopping.
    wd.notifyStopping();

    std.log.info("Session Sentinel tray shutting down gracefully", .{});
}

// ---------------------------------------------------------------------------
// C FFI exports (for use from Idris2 / ReScript via Deno FFI)
// ---------------------------------------------------------------------------

/// Get the version string. Returned pointer is valid for the lifetime of the process.
export fn session_sentinel_tray_version() [*:0]const u8 {
    return VERSION;
}

/// Get the build info string. Returned pointer is valid for the lifetime of the process.
export fn session_sentinel_tray_build_info() [*:0]const u8 {
    return BUILD_INFO;
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "config defaults are sensible" {
    const config = Config{};
    try std.testing.expect(config.scan_interval_s == 300);
    try std.testing.expect(!config.once);
    try std.testing.expect(!config.daemon);
    try std.testing.expect(!config.verbose);
    try std.testing.expect(config.config_path == null);
}

test "version string is not empty" {
    try std.testing.expect(VERSION.len > 0);
    try std.testing.expect(std.mem.count(u8, VERSION, ".") >= 2);
}

test "build info contains version" {
    try std.testing.expect(std.mem.indexOf(u8, BUILD_INFO, VERSION) != null);
}
