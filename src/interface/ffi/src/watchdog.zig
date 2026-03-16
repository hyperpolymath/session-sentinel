// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Session Sentinel — Watchdog and Fault Tolerance
//
// Provides two layers of health monitoring:
//
//   1. SystemdWatchdog — sd_notify integration for systemd Type=notify services.
//      Sends READY=1 on startup, WATCHDOG=1 heartbeats at the configured interval,
//      and STOPPING=1 on graceful shutdown. If heartbeats stop, systemd will
//      restart the service according to the unit's Restart= policy.
//
//   2. SelfWatchdog — internal health tracking for the monitoring subsystem itself.
//      Tracks consecutive scan failures, healing success rates, and stuck thread
//      detection. Implements an escalating recovery strategy:
//
//        1 failure  → log warning, retry immediately
//        3 failures → enter degraded mode (purple tray icon)
//        5 failures → restart scan subsystem
//        10 failures → log critical, attempt full service restart via systemd
//
// External health check:
//   A heartbeat timestamp is written to /tmp/session-sentinel.heartbeat on each
//   successful watchdog tick. External monitors (cron, another service) can read
//   this file and consider the service unhealthy if the timestamp is stale by
//   more than 2x the scan interval.

const std = @import("std");
const fs = std.fs;
const posix = std.posix;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Path for the external heartbeat file.
pub const HEARTBEAT_PATH = "/tmp/session-sentinel.heartbeat";

/// Number of consecutive failures before entering degraded mode.
const DEGRADED_THRESHOLD: u32 = 3;

/// Number of consecutive failures before attempting scan subsystem restart.
const RESTART_SCAN_THRESHOLD: u32 = 5;

/// Number of consecutive failures before attempting full service restart.
const CRITICAL_THRESHOLD: u32 = 10;

// ---------------------------------------------------------------------------
// libsystemd bindings (linked via build.zig)
// ---------------------------------------------------------------------------

/// sd_notify from libsystemd (sends status to the systemd service manager).
///
/// Parameters:
///   unset_environment — if non-zero, unset $NOTIFY_SOCKET after sending
///   state — newline-delimited key=value pairs (e.g. "READY=1\nSTATUS=Running")
///
/// Returns:
///   > 0 if the notification was sent
///   0 if $NOTIFY_SOCKET is not set (not running under systemd)
///   < 0 on error (negated errno)
extern "systemd" fn sd_notify(unset_environment: c_int, state: [*:0]const u8) c_int;

/// sd_watchdog_enabled from libsystemd.
///
/// Returns the watchdog interval in microseconds if enabled, 0 if disabled.
extern "systemd" fn sd_watchdog_enabled(unset_environment: c_int, usec: *u64) c_int;

// ---------------------------------------------------------------------------
// Recovery action
// ---------------------------------------------------------------------------

/// Actions the watchdog can recommend based on failure count.
pub const RecoveryAction = enum {
    /// No action needed — system is healthy.
    none,

    /// Log a warning and retry the scan immediately.
    warn_and_retry,

    /// Enter degraded mode — show purple tray icon.
    enter_degraded,

    /// Restart the scan subsystem (reset internal state, re-init providers).
    restart_scan,

    /// Critical failure — attempt full service restart via systemd.
    restart_service,
};

// ---------------------------------------------------------------------------
// Watchdog
// ---------------------------------------------------------------------------

/// Combined systemd and self-watchdog state.
///
/// This struct is designed to be stack-allocated and owned by the main
/// function. It is accessed from both the main thread and the monitor
/// thread, but the failure counters are only incremented from the monitor
/// thread (single-writer), so we use relaxed atomics for visibility.
pub const Watchdog = struct {
    /// Consecutive scan failures (reset to 0 on success).
    consecutive_failures: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// Total lifetime scan failures (monotonically increasing).
    total_failures: u64 = 0,

    /// Total lifetime successful scans.
    total_successes: u64 = 0,

    /// Total healing attempts.
    healing_attempts: u64 = 0,

    /// Total successful healing operations.
    healing_successes: u64 = 0,

    /// Whether systemd watchdog is active (determined at startup).
    systemd_watchdog_active: bool = false,

    /// Systemd watchdog interval in nanoseconds (0 if not active).
    systemd_watchdog_interval_ns: u64 = 0,

    /// Monotonic timestamp of the last successful scan (nanoseconds).
    last_success_ns: i128 = 0,

    /// Maximum allowed duration for a single scan before it's considered stuck.
    /// Defaults to 60 seconds.
    stuck_threshold_ns: i128 = 60 * std.time.ns_per_s,

    /// Initialise the watchdog, probing for systemd watchdog configuration.
    ///
    /// If running under systemd with WatchdogSec= configured, the watchdog
    /// interval is read from sd_watchdog_enabled(). We send heartbeats at
    /// half the configured interval to provide margin.
    pub fn init() Watchdog {
        var wd = Watchdog{};

        // Probe for systemd watchdog.
        var usec: u64 = 0;
        const result = sd_watchdog_enabled(0, &usec);

        if (result > 0 and usec > 0) {
            wd.systemd_watchdog_active = true;
            // Convert microseconds to nanoseconds. We'll heartbeat at half interval.
            wd.systemd_watchdog_interval_ns = usec * 1000;
            std.log.info("Systemd watchdog active (interval={d}us)", .{usec});
        } else {
            std.log.info("Systemd watchdog not active (standalone mode)", .{});
        }

        wd.last_success_ns = std.time.nanoTimestamp();

        return wd;
    }

    // -----------------------------------------------------------------------
    // Systemd notifications
    // -----------------------------------------------------------------------

    /// Notify systemd that the service is ready (READY=1).
    ///
    /// Call this once, after all initialisation is complete (DBus connected,
    /// tray registered, monitor thread spawned).
    pub fn notifyReady(self: *const Watchdog) void {
        _ = self;
        const result = sd_notify(0, "READY=1\nSTATUS=Session Sentinel monitoring active");
        if (result > 0) {
            std.log.info("Sent sd_notify READY=1", .{});
        }
    }

    /// Notify systemd that the service is stopping (STOPPING=1).
    ///
    /// Call this at the beginning of the shutdown sequence, before
    /// releasing resources.
    pub fn notifyStopping(self: *const Watchdog) void {
        _ = self;
        const result = sd_notify(0, "STOPPING=1\nSTATUS=Shutting down");
        if (result > 0) {
            std.log.info("Sent sd_notify STOPPING=1", .{});
        }
    }

    /// Send a watchdog heartbeat to systemd (WATCHDOG=1).
    ///
    /// Also sends a STATUS= update with the current failure count.
    /// Call this from the monitor loop after each scan cycle.
    pub fn notifyWatchdog(self: *const Watchdog) void {
        if (!self.systemd_watchdog_active) return;

        // Build status string with current metrics.
        var buf: [256]u8 = undefined;
        const failures = self.consecutive_failures.load(.acquire);

        const status = if (failures == 0)
            std.fmt.bufPrint(&buf, "WATCHDOG=1\nSTATUS=Healthy ({d} scans)", .{self.total_successes}) catch "WATCHDOG=1"
        else
            std.fmt.bufPrint(&buf, "WATCHDOG=1\nSTATUS=Degraded ({d} consecutive failures)", .{failures}) catch "WATCHDOG=1";

        // Ensure null-termination for the C API.
        var notify_buf: [256]u8 = undefined;
        if (status.len < notify_buf.len) {
            @memcpy(notify_buf[0..status.len], status);
            notify_buf[status.len] = 0;
            _ = sd_notify(0, notify_buf[0..status.len :0]);
        }
    }

    // -----------------------------------------------------------------------
    // Scan result tracking
    // -----------------------------------------------------------------------

    /// Record a successful scan cycle.
    ///
    /// Resets the consecutive failure counter and updates success metrics.
    pub fn reportScanSuccess(self: *Watchdog) void {
        self.consecutive_failures.store(0, .release);
        self.total_successes += 1;
        self.last_success_ns = std.time.nanoTimestamp();
    }

    /// Record a failed scan cycle.
    ///
    /// Increments the consecutive failure counter and total failure count.
    pub fn reportScanFailure(self: *Watchdog) void {
        _ = self.consecutive_failures.fetchAdd(1, .acq_rel);
        self.total_failures += 1;
    }

    /// Record a healing attempt and its outcome.
    pub fn reportHealingResult(self: *Watchdog, success: bool) void {
        self.healing_attempts += 1;
        if (success) {
            self.healing_successes += 1;
        }
    }

    // -----------------------------------------------------------------------
    // Recovery decision logic
    // -----------------------------------------------------------------------

    /// Determine the appropriate recovery action based on current failure state.
    ///
    /// The escalation ladder:
    ///   0 failures → none (healthy)
    ///   1-2 failures → warn and retry
    ///   3-4 failures → enter degraded mode (purple icon)
    ///   5-9 failures → restart scan subsystem
    ///   10+ failures → critical, restart entire service
    pub fn recommendedAction(self: *const Watchdog) RecoveryAction {
        const failures = self.consecutive_failures.load(.acquire);

        if (failures == 0) return .none;
        if (failures < DEGRADED_THRESHOLD) return .warn_and_retry;
        if (failures < RESTART_SCAN_THRESHOLD) return .enter_degraded;
        if (failures < CRITICAL_THRESHOLD) return .restart_scan;
        return .restart_service;
    }

    /// Check if we should enter degraded mode (purple tray icon).
    ///
    /// Returns true if consecutive failures >= DEGRADED_THRESHOLD.
    pub fn shouldEnterDegraded(self: *const Watchdog) bool {
        return self.consecutive_failures.load(.acquire) >= DEGRADED_THRESHOLD;
    }

    /// Check if the scan thread appears to be stuck.
    ///
    /// A scan is considered stuck if no success has been recorded for
    /// longer than the stuck threshold (default 60 seconds).
    pub fn isScanStuck(self: *const Watchdog) bool {
        const now = std.time.nanoTimestamp();
        const elapsed = now - self.last_success_ns;
        return elapsed > self.stuck_threshold_ns;
    }

    /// Get the healing success rate as a percentage (0–100).
    ///
    /// Returns 100 if no healing has been attempted (no data = no failures).
    pub fn healingSuccessRate(self: *const Watchdog) u32 {
        if (self.healing_attempts == 0) return 100;
        return @intCast((self.healing_successes * 100) / self.healing_attempts);
    }

    // -----------------------------------------------------------------------
    // External heartbeat file
    // -----------------------------------------------------------------------

    /// Write the current timestamp to the heartbeat file.
    ///
    /// External monitors can read this file and compare the timestamp
    /// against the current time. If the heartbeat is stale by more than
    /// 2x the scan interval, the service should be considered unhealthy.
    ///
    /// Format: Unix timestamp in seconds, followed by a newline.
    pub fn writeHeartbeat(self: *const Watchdog) !void {
        _ = self;

        const now = std.time.timestamp();

        var buf: [32]u8 = undefined;
        const content = std.fmt.bufPrint(&buf, "{d}\n", .{now}) catch {
            return error.HeartbeatFormatError;
        };

        // Write atomically via temp file.
        const tmp_path = HEARTBEAT_PATH ++ ".tmp";

        const file = fs.createFileAbsolute(tmp_path, .{ .truncate = true }) catch |err| {
            return err;
        };
        defer file.close();

        file.writeAll(content) catch |err| {
            return err;
        };

        fs.renameAbsolute(tmp_path, HEARTBEAT_PATH) catch |err| {
            return err;
        };
    }

    /// Read the heartbeat file and determine if the service is healthy.
    ///
    /// Returns true if the heartbeat timestamp is within the acceptable
    /// staleness window (2x the given interval in seconds).
    ///
    /// This is a static function — it can be called from external health
    /// check scripts without needing a Watchdog instance.
    pub fn checkHeartbeat(max_staleness_s: i64) bool {
        const file = fs.openFileAbsolute(HEARTBEAT_PATH, .{}) catch return false;
        defer file.close();

        var buf: [32]u8 = undefined;
        const bytes_read = file.readAll(&buf) catch return false;
        if (bytes_read == 0) return false;

        // Parse the timestamp (strip trailing newline).
        const content = std.mem.trimRight(u8, buf[0..bytes_read], "\n\r ");
        const heartbeat_ts = std.fmt.parseInt(i64, content, 10) catch return false;

        const now = std.time.timestamp();
        const elapsed = now - heartbeat_ts;

        return elapsed <= max_staleness_s;
    }

    // -----------------------------------------------------------------------
    // Diagnostics
    // -----------------------------------------------------------------------

    /// Get a diagnostic summary as a JSON string.
    ///
    /// The returned buffer is stack-allocated. Caller must copy if needed
    /// beyond the current scope.
    pub fn diagnosticsJson(self: *const Watchdog) [512]u8 {
        var buf: [512]u8 = undefined;
        const content = std.fmt.bufPrint(&buf,
            \\{{"consecutive_failures":{d},"total_failures":{d},"total_successes":{d},"healing_attempts":{d},"healing_successes":{d},"healing_rate_pct":{d},"systemd_watchdog":{s},"recommended_action":"{s}"}}
        , .{
            self.consecutive_failures.load(.acquire),
            self.total_failures,
            self.total_successes,
            self.healing_attempts,
            self.healing_successes,
            self.healingSuccessRate(),
            if (self.systemd_watchdog_active) "true" else "false",
            @tagName(self.recommendedAction()),
        }) catch {
            @memset(&buf, 0);
            return buf;
        };

        @memset(buf[content.len..], 0);
        return buf;
    }
};

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "Watchdog — initial state is healthy" {
    var wd = Watchdog{};
    wd.systemd_watchdog_active = false; // Don't probe systemd in tests.

    try std.testing.expectEqual(RecoveryAction.none, wd.recommendedAction());
    try std.testing.expect(!wd.shouldEnterDegraded());
    try std.testing.expectEqual(@as(u32, 100), wd.healingSuccessRate());
}

test "Watchdog — single failure triggers warn_and_retry" {
    var wd = Watchdog{};
    wd.systemd_watchdog_active = false;

    wd.reportScanFailure();
    try std.testing.expectEqual(RecoveryAction.warn_and_retry, wd.recommendedAction());
    try std.testing.expect(!wd.shouldEnterDegraded());
}

test "Watchdog — 3 failures triggers enter_degraded" {
    var wd = Watchdog{};
    wd.systemd_watchdog_active = false;

    wd.reportScanFailure();
    wd.reportScanFailure();
    wd.reportScanFailure();

    try std.testing.expectEqual(RecoveryAction.enter_degraded, wd.recommendedAction());
    try std.testing.expect(wd.shouldEnterDegraded());
}

test "Watchdog — 5 failures triggers restart_scan" {
    var wd = Watchdog{};
    wd.systemd_watchdog_active = false;

    for (0..5) |_| {
        wd.reportScanFailure();
    }

    try std.testing.expectEqual(RecoveryAction.restart_scan, wd.recommendedAction());
}

test "Watchdog — 10 failures triggers restart_service" {
    var wd = Watchdog{};
    wd.systemd_watchdog_active = false;

    for (0..10) |_| {
        wd.reportScanFailure();
    }

    try std.testing.expectEqual(RecoveryAction.restart_service, wd.recommendedAction());
}

test "Watchdog — success resets failure counter" {
    var wd = Watchdog{};
    wd.systemd_watchdog_active = false;

    wd.reportScanFailure();
    wd.reportScanFailure();
    wd.reportScanFailure();
    try std.testing.expect(wd.shouldEnterDegraded());

    wd.reportScanSuccess();
    try std.testing.expectEqual(RecoveryAction.none, wd.recommendedAction());
    try std.testing.expect(!wd.shouldEnterDegraded());
}

test "Watchdog — healing success rate calculation" {
    var wd = Watchdog{};
    wd.systemd_watchdog_active = false;

    // 100% when no attempts made.
    try std.testing.expectEqual(@as(u32, 100), wd.healingSuccessRate());

    // 100% with all successes.
    wd.reportHealingResult(true);
    wd.reportHealingResult(true);
    try std.testing.expectEqual(@as(u32, 100), wd.healingSuccessRate());

    // 66% with 2 successes and 1 failure.
    wd.reportHealingResult(false);
    try std.testing.expectEqual(@as(u32, 66), wd.healingSuccessRate());
}

test "Watchdog — diagnostics JSON is well-formed" {
    var wd = Watchdog{};
    wd.systemd_watchdog_active = false;

    const json_buf = wd.diagnosticsJson();
    const json = std.mem.sliceTo(&json_buf, 0);

    try std.testing.expect(json.len > 0);
    try std.testing.expect(json[0] == '{');
    try std.testing.expect(std.mem.indexOf(u8, json, "consecutive_failures") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "recommended_action") != null);
}

test "Watchdog — total counters accumulate correctly" {
    var wd = Watchdog{};
    wd.systemd_watchdog_active = false;

    wd.reportScanSuccess();
    wd.reportScanSuccess();
    wd.reportScanFailure();
    wd.reportScanSuccess();

    try std.testing.expectEqual(@as(u64, 3), wd.total_successes);
    try std.testing.expectEqual(@as(u64, 1), wd.total_failures);
    // Consecutive failures reset by the last success.
    try std.testing.expectEqual(@as(u32, 0), wd.consecutive_failures.load(.acquire));
}

test "HEARTBEAT_PATH is absolute" {
    try std.testing.expect(HEARTBEAT_PATH[0] == '/');
}

test "thresholds are in ascending order" {
    try std.testing.expect(DEGRADED_THRESHOLD < RESTART_SCAN_THRESHOLD);
    try std.testing.expect(RESTART_SCAN_THRESHOLD < CRITICAL_THRESHOLD);
}
