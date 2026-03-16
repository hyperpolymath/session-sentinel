// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Session Sentinel — Integration Tests
//
// These tests verify the FFI modules work together correctly. They exercise:
//   - Icon generation for each health zone
//   - Health zone classification from JSON
//   - DBus message formatting (without a live bus)
//   - Watchdog state transitions and escalation
//   - Config loading defaults
//
// Tests that require a live DBus session bus are gated behind a runtime check
// and will be skipped gracefully if no bus is available (e.g. in CI containers).
//
// Run with: zig build test-integration

const std = @import("std");
const testing = std.testing;
const fs = std.fs;

// Import the modules under test.
const tray = @import("../src/tray.zig");
const icons = @import("../src/icons.zig");
const watchdog = @import("../src/watchdog.zig");
const dbus = @import("../src/dbus.zig");
const main = @import("../src/main.zig");

// ===========================================================================
// Icon Generation Tests
// ===========================================================================

test "integration: generate icon for green zone (22x22)" {
    const svg = try icons.generateIcon(.green, 22);
    const content = std.mem.sliceTo(&svg, 0);

    // Must be valid XML/SVG.
    try testing.expect(std.mem.startsWith(u8, content, "<?xml"));
    try testing.expect(std.mem.indexOf(u8, content, "<svg") != null);
    try testing.expect(std.mem.indexOf(u8, content, "</svg>") != null);

    // Must use the correct green colour.
    try testing.expect(std.mem.indexOf(u8, content, "#4CAF50") != null);

    // Must contain the shield path.
    try testing.expect(std.mem.indexOf(u8, content, "<path") != null);

    // Must have correct dimensions.
    try testing.expect(std.mem.indexOf(u8, content, "width=\"22\"") != null);
    try testing.expect(std.mem.indexOf(u8, content, "height=\"22\"") != null);
}

test "integration: generate icon for yellow zone (22x22)" {
    const svg = try icons.generateIcon(.yellow, 22);
    const content = std.mem.sliceTo(&svg, 0);

    try testing.expect(std.mem.indexOf(u8, content, "#FFC107") != null);
    try testing.expect(std.mem.indexOf(u8, content, "</svg>") != null);
}

test "integration: generate icon for red zone (22x22)" {
    const svg = try icons.generateIcon(.red, 22);
    const content = std.mem.sliceTo(&svg, 0);

    try testing.expect(std.mem.indexOf(u8, content, "#F44336") != null);
    try testing.expect(std.mem.indexOf(u8, content, "</svg>") != null);
}

test "integration: generate icon for purple zone (22x22)" {
    const svg = try icons.generateIcon(.purple, 22);
    const content = std.mem.sliceTo(&svg, 0);

    try testing.expect(std.mem.indexOf(u8, content, "#9C27B0") != null);
    // Purple zone must include animation for the pulse effect.
    try testing.expect(std.mem.indexOf(u8, content, "animate") != null);
    try testing.expect(std.mem.indexOf(u8, content, "repeatCount") != null);
}

test "integration: generate icon at tooltip size (48x48)" {
    const svg = try icons.generateIcon(.green, 48);
    const content = std.mem.sliceTo(&svg, 0);

    try testing.expect(std.mem.indexOf(u8, content, "width=\"48\"") != null);
    try testing.expect(std.mem.indexOf(u8, content, "height=\"48\"") != null);
    try testing.expect(std.mem.indexOf(u8, content, "viewBox=\"0 0 48 48\"") != null);
}

test "integration: blank icon is transparent" {
    const svg = icons.generateBlankIcon();
    const content = std.mem.sliceTo(&svg, 0);

    try testing.expect(std.mem.startsWith(u8, content, "<?xml"));
    try testing.expect(std.mem.indexOf(u8, content, "opacity=\"0\"") != null);
    try testing.expect(std.mem.indexOf(u8, content, "fill=\"none\"") != null);
}

test "integration: all four zone icons are distinct" {
    const green = try icons.generateIcon(.green, 22);
    const yellow = try icons.generateIcon(.yellow, 22);
    const red = try icons.generateIcon(.red, 22);
    const purple = try icons.generateIcon(.purple, 22);

    const green_s = std.mem.sliceTo(&green, 0);
    const yellow_s = std.mem.sliceTo(&yellow, 0);
    const red_s = std.mem.sliceTo(&red, 0);
    const purple_s = std.mem.sliceTo(&purple, 0);

    // Each zone's icon must be different from the others.
    try testing.expect(!std.mem.eql(u8, green_s, yellow_s));
    try testing.expect(!std.mem.eql(u8, green_s, red_s));
    try testing.expect(!std.mem.eql(u8, green_s, purple_s));
    try testing.expect(!std.mem.eql(u8, yellow_s, red_s));
    try testing.expect(!std.mem.eql(u8, yellow_s, purple_s));
    try testing.expect(!std.mem.eql(u8, red_s, purple_s));
}

// ===========================================================================
// Health Zone Classification Tests
// ===========================================================================

test "integration: classify health zone from JSON — green" {
    const json = "{\"zone\":\"green\",\"totalSize\":\"42 MB\",\"providerCount\":2,\"trend\":\"stable\"}";
    try testing.expectEqual(tray.HealthZone.green, tray.classifyHealthZone(json));
}

test "integration: classify health zone from JSON — yellow" {
    const json = "{\"zone\":\"yellow\",\"totalSize\":\"850 MB\",\"providerCount\":5,\"trend\":\"increasing\"}";
    try testing.expectEqual(tray.HealthZone.yellow, tray.classifyHealthZone(json));
}

test "integration: classify health zone from JSON — red" {
    const json = "{\"zone\":\"red\",\"totalSize\":\"4.2 GB\",\"providerCount\":7,\"trend\":\"increasing\"}";
    try testing.expectEqual(tray.HealthZone.red, tray.classifyHealthZone(json));
}

test "integration: classify health zone from JSON — purple" {
    const json = "{\"zone\":\"purple\",\"totalSize\":\"unknown\",\"providerCount\":0,\"trend\":\"unknown\"}";
    try testing.expectEqual(tray.HealthZone.purple, tray.classifyHealthZone(json));
}

test "integration: classify health zone — missing zone field defaults to yellow" {
    const json = "{\"totalSize\":\"100 MB\"}";
    try testing.expectEqual(tray.HealthZone.yellow, tray.classifyHealthZone(json));
}

test "integration: classify health zone — unknown zone value defaults to yellow" {
    const json = "{\"zone\":\"chartreuse\"}";
    try testing.expectEqual(tray.HealthZone.yellow, tray.classifyHealthZone(json));
}

test "integration: classify health zone — empty JSON defaults to yellow" {
    try testing.expectEqual(tray.HealthZone.yellow, tray.classifyHealthZone("{}"));
}

test "integration: icon name mapping matches XDG conventions" {
    // These icon names must exist in standard freedesktop icon themes.
    try testing.expectEqualStrings("security-high", tray.iconNameForZone(.green));
    try testing.expectEqualStrings("security-medium", tray.iconNameForZone(.yellow));
    try testing.expectEqualStrings("security-low", tray.iconNameForZone(.red));
    try testing.expectEqualStrings("security-low", tray.iconNameForZone(.purple));
}

// ===========================================================================
// DBus Message Formatting Tests
// ===========================================================================

test "integration: DBus bus name is valid format" {
    // DBus bus names must contain at least one dot and start with a letter.
    const name = dbus.BUS_NAME;
    try testing.expect(std.mem.indexOf(u8, name, ".") != null);
    try testing.expect(name.len > 0);
    try testing.expect(std.ascii.isAlphabetic(name[0]));
}

test "integration: DBus object path starts with slash" {
    const path = dbus.OBJECT_PATH;
    try testing.expect(path.len > 0);
    try testing.expect(path[0] == '/');
}

test "integration: DBus interface name is versioned" {
    const iface = dbus.INTERFACE;
    // Interface should end with a version number.
    try testing.expect(iface.len > 0);
    const last_char = iface[iface.len - 1];
    try testing.expect(std.ascii.isDigit(last_char));
}

test "integration: DBus constants are consistent" {
    // The object path should reflect the bus name structure.
    // org.hyperpolymath.SessionSentinel → /org/hyperpolymath/SessionSentinel
    try testing.expect(std.mem.indexOf(u8, dbus.OBJECT_PATH, "hyperpolymath") != null);
    try testing.expect(std.mem.indexOf(u8, dbus.OBJECT_PATH, "SessionSentinel") != null);
    try testing.expect(std.mem.indexOf(u8, dbus.BUS_NAME, "hyperpolymath") != null);
}

// ===========================================================================
// Watchdog State Transition Tests
// ===========================================================================

test "integration: watchdog escalation ladder — full sequence" {
    var wd = watchdog.Watchdog{};
    wd.systemd_watchdog_active = false;

    // Start healthy.
    try testing.expectEqual(watchdog.RecoveryAction.none, wd.recommendedAction());

    // 1 failure → warn_and_retry.
    wd.reportScanFailure();
    try testing.expectEqual(watchdog.RecoveryAction.warn_and_retry, wd.recommendedAction());

    // 2 failures → still warn_and_retry.
    wd.reportScanFailure();
    try testing.expectEqual(watchdog.RecoveryAction.warn_and_retry, wd.recommendedAction());

    // 3 failures → enter_degraded.
    wd.reportScanFailure();
    try testing.expectEqual(watchdog.RecoveryAction.enter_degraded, wd.recommendedAction());
    try testing.expect(wd.shouldEnterDegraded());

    // 4 failures → still enter_degraded.
    wd.reportScanFailure();
    try testing.expectEqual(watchdog.RecoveryAction.enter_degraded, wd.recommendedAction());

    // 5 failures → restart_scan.
    wd.reportScanFailure();
    try testing.expectEqual(watchdog.RecoveryAction.restart_scan, wd.recommendedAction());

    // 6-9 failures → still restart_scan.
    for (0..4) |_| {
        wd.reportScanFailure();
    }
    try testing.expectEqual(watchdog.RecoveryAction.restart_scan, wd.recommendedAction());

    // 10 failures → restart_service.
    wd.reportScanFailure();
    try testing.expectEqual(watchdog.RecoveryAction.restart_service, wd.recommendedAction());
}

test "integration: watchdog recovery after degraded" {
    var wd = watchdog.Watchdog{};
    wd.systemd_watchdog_active = false;

    // Push into degraded.
    for (0..4) |_| {
        wd.reportScanFailure();
    }
    try testing.expect(wd.shouldEnterDegraded());

    // A single success should clear the consecutive failure counter.
    wd.reportScanSuccess();
    try testing.expect(!wd.shouldEnterDegraded());
    try testing.expectEqual(watchdog.RecoveryAction.none, wd.recommendedAction());

    // But total failures are preserved.
    try testing.expectEqual(@as(u64, 4), wd.total_failures);
    try testing.expectEqual(@as(u64, 1), wd.total_successes);
}

test "integration: watchdog healing rate tracks correctly" {
    var wd = watchdog.Watchdog{};
    wd.systemd_watchdog_active = false;

    // No attempts = 100%.
    try testing.expectEqual(@as(u32, 100), wd.healingSuccessRate());

    // 3 successes, 1 failure = 75%.
    wd.reportHealingResult(true);
    wd.reportHealingResult(true);
    wd.reportHealingResult(true);
    wd.reportHealingResult(false);
    try testing.expectEqual(@as(u32, 75), wd.healingSuccessRate());

    // 3 successes, 2 failures = 60%.
    wd.reportHealingResult(false);
    try testing.expectEqual(@as(u32, 60), wd.healingSuccessRate());
}

test "integration: watchdog diagnostics JSON contains all fields" {
    var wd = watchdog.Watchdog{};
    wd.systemd_watchdog_active = false;

    wd.reportScanSuccess();
    wd.reportScanFailure();

    const json_buf = wd.diagnosticsJson();
    const json = std.mem.sliceTo(&json_buf, 0);

    // All expected fields must be present.
    const required_fields = [_][]const u8{
        "consecutive_failures",
        "total_failures",
        "total_successes",
        "healing_attempts",
        "healing_successes",
        "healing_rate_pct",
        "systemd_watchdog",
        "recommended_action",
    };

    for (required_fields) |field| {
        try testing.expect(std.mem.indexOf(u8, json, field) != null);
    }
}

// ===========================================================================
// Config Loading Tests
// ===========================================================================

test "integration: default config has sensible values" {
    const config = main.Config{};

    // Default interval is 5 minutes.
    try testing.expectEqual(@as(u32, 300), config.scan_interval_s);

    // Not in one-shot or daemon mode by default.
    try testing.expect(!config.once);
    try testing.expect(!config.daemon);
    try testing.expect(!config.verbose);

    // No config path by default (uses XDG default).
    try testing.expect(config.config_path == null);
}

test "integration: version string is semantic versioning" {
    const ver = main.VERSION;

    // Must contain at least two dots (X.Y.Z).
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, ver, "."));

    // Each component must be a number.
    var iter = std.mem.splitSequence(u8, ver, ".");
    while (iter.next()) |component| {
        _ = std.fmt.parseInt(u32, component, 10) catch {
            try testing.expect(false); // Component is not a number.
        };
    }
}

test "integration: build info contains program name and version" {
    const info = main.BUILD_INFO;

    try testing.expect(std.mem.indexOf(u8, info, "session-sentinel-tray") != null);
    try testing.expect(std.mem.indexOf(u8, info, main.VERSION) != null);
}

// ===========================================================================
// Cross-Module Consistency Tests
// ===========================================================================

test "integration: icon colours differ across all zones" {
    // Ensure the icon generation and zone colours are consistent.
    const zones = [_]tray.HealthZone{ .green, .yellow, .red, .purple };
    var svgs: [4][]const u8 = undefined;
    var buffers: [4][2048]u8 = undefined;

    for (zones, 0..) |zone, i| {
        buffers[i] = try icons.generateIcon(zone, 22);
        svgs[i] = std.mem.sliceTo(&buffers[i], 0);
    }

    // Every pair must be distinct.
    for (0..4) |i| {
        for (i + 1..4) |j| {
            try testing.expect(!std.mem.eql(u8, svgs[i], svgs[j]));
        }
    }
}

test "integration: heartbeat path is writable location" {
    // /tmp should always be writable.
    try testing.expect(std.mem.startsWith(u8, watchdog.HEARTBEAT_PATH, "/tmp/"));
}

test "integration: icon directory path is in /tmp" {
    try testing.expect(std.mem.startsWith(u8, icons.ICON_DIR, "/tmp/"));
}

test "integration: menu labels count matches menu actions" {
    // There must be exactly one label per MenuAction variant.
    const action_count = @typeInfo(tray.MenuAction).@"enum".fields.len;
    try testing.expectEqual(action_count, tray.MENU_LABELS.len);
}
