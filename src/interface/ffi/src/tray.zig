// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Session Sentinel — KDE StatusNotifierItem (SNI) Implementation
//
// Implements the freedesktop / KDE StatusNotifierItem protocol for displaying
// session health information in the Wayland/KDE system tray. This replaces
// the legacy XEmbed tray protocol with the modern DBus-based approach that
// KDE Plasma and other Wayland compositors use.
//
// Protocol references:
//   - https://www.freedesktop.org/wiki/Specifications/StatusNotifierItem/
//   - org.kde.StatusNotifierWatcher (registration)
//   - org.kde.StatusNotifierItem (per-item interface)
//
// Health zone mapping:
//   Green  — all clear, session data within safe limits
//   Yellow — approaching configured thresholds, attention advised
//   Red    — thresholds exceeded, action recommended
//   Purple — system degraded / scan failures, flashing icon

const std = @import("std");

const dbus = @import("dbus.zig");
const icons = @import("icons.zig");

// ---------------------------------------------------------------------------
// Health zone classification
// ---------------------------------------------------------------------------

/// Health zone derived from monitoring metrics.
/// Determines the tray icon, tooltip text, and urgency level.
pub const HealthZone = enum(u8) {
    /// All clear — session data within safe limits.
    green,

    /// Warning — approaching configured thresholds.
    yellow,

    /// Critical — thresholds exceeded, action recommended.
    red,

    /// Degraded — monitoring subsystem itself is unhealthy (flashing icon).
    purple,
};

/// SNI category: we are a system service monitor.
const SNI_CATEGORY = "SystemServices";

/// SNI unique identifier.
const SNI_ID = "session-sentinel";

/// DBus interface name for StatusNotifierItem.
const SNI_INTERFACE = "org.kde.StatusNotifierItem";

/// DBus interface name for StatusNotifierWatcher (registration target).
const SNI_WATCHER_INTERFACE = "org.kde.StatusNotifierWatcher";

/// DBus bus name for the watcher.
const SNI_WATCHER_BUS_NAME = "org.kde.StatusNotifierWatcher";

/// DBus object path for the watcher.
const SNI_WATCHER_PATH = "/StatusNotifierWatcher";

/// DBus object path for our item.
const SNI_ITEM_PATH = "/StatusNotifierItem";

// ---------------------------------------------------------------------------
// Context menu item identifiers
// ---------------------------------------------------------------------------

/// Identifiers for context menu actions, used in DBus method dispatch.
pub const MenuAction = enum(u32) {
    /// Trigger an immediate scan cycle (SIGUSR1 equivalent).
    force_scan = 0,

    /// Open the PanLL monitoring panel.
    open_panel = 1,

    /// Open the configuration file / settings UI.
    configure = 2,

    /// Run the healing subsystem on detected issues.
    run_healing = 3,

    /// Display diagnostic information (log tail, counters).
    view_diagnostics = 4,

    /// Graceful shutdown.
    quit = 5,
};

/// Human-readable labels for context menu items.
pub const MENU_LABELS = [_][]const u8{
    "Force Scan",
    "Open Panel",
    "Configure...",
    "Run Healing",
    "View Diagnostics",
    "Quit",
};

// ---------------------------------------------------------------------------
// TrayState
// ---------------------------------------------------------------------------

/// Mutable state for the system tray icon.
///
/// This struct owns the current zone, tooltip text, flash timer state,
/// and handles communication with the StatusNotifierWatcher. It is
/// accessed from both the main thread (DBus dispatch) and the monitor
/// thread, so zone updates use atomic operations.
pub const TrayState = struct {
    /// Allocator used for tooltip string allocations.
    allocator: std.mem.Allocator,

    /// Reference to the shared DBus connection.
    bus: *dbus.Connection,

    /// Current health zone (atomically updated by the monitor thread).
    current_zone: std.atomic.Value(HealthZone) = std.atomic.Value(HealthZone).init(.green),

    /// Whether the icon is currently visible (toggled for purple flash).
    flash_visible: bool = true,

    /// Monotonic timestamp (ns) of the last flash toggle.
    last_flash_toggle_ns: i128 = 0,

    /// Flash interval in nanoseconds (500ms).
    flash_interval_ns: i128 = 500 * std.time.ns_per_ms,

    /// Current tooltip text. Protected by the allocator (main thread only).
    tooltip_text: []const u8 = "Session Sentinel: initialising...",

    /// Whether we have successfully registered with the SNI watcher.
    registered: bool = false,

    /// Initialise tray state and register with the StatusNotifierWatcher.
    ///
    /// This sends a RegisterStatusNotifierItem call to the watcher so that
    /// KDE Plasma (or another SNI host) picks up our icon.
    pub fn init(allocator: std.mem.Allocator, bus: *dbus.Connection) !TrayState {
        var state = TrayState{
            .allocator = allocator,
            .bus = bus,
        };

        // Generate initial icon for green zone.
        try icons.writeIconForZone(.green);

        // Register with the StatusNotifierWatcher.
        state.registered = registerWithWatcher(bus) catch |err| blk: {
            std.log.warn("SNI watcher registration failed (tray may not be visible): {any}", .{err});
            break :blk false;
        };

        if (state.registered) {
            std.log.info("Registered with StatusNotifierWatcher", .{});
        }

        return state;
    }

    /// Release resources held by the tray state.
    pub fn deinit(self: *TrayState) void {
        // If we allocated a dynamic tooltip, free it.
        if (!std.mem.eql(u8, self.tooltip_text, "Session Sentinel: initialising...")) {
            self.allocator.free(self.tooltip_text);
        }

        self.* = undefined;
    }

    /// Update the health zone and refresh the tray icon accordingly.
    ///
    /// Called from the monitor thread. The zone write is atomic; icon
    /// regeneration is fire-and-forget (errors are logged, not propagated).
    pub fn updateZone(self: *TrayState, zone: HealthZone) void {
        const previous = self.current_zone.swap(zone, .acq_rel);

        if (previous != zone) {
            // Regenerate the SVG icon for the new zone.
            icons.writeIconForZone(zone) catch |err| {
                std.log.err("Failed to write icon for zone {s}: {any}", .{
                    @tagName(zone),
                    err,
                });
            };

            // Emit NewIcon signal so the tray host picks up the change.
            emitNewIcon(self.bus) catch |err| {
                std.log.err("Failed to emit NewIcon signal: {any}", .{err});
            };

            // Emit NewToolTip signal.
            emitNewToolTip(self.bus) catch |err| {
                std.log.err("Failed to emit NewToolTip signal: {any}", .{err});
            };

            // Reset flash state when leaving/entering purple.
            if (zone == .purple) {
                self.flash_visible = true;
                self.last_flash_toggle_ns = std.time.nanoTimestamp();
            }
        }
    }

    /// Update the tooltip text from a JSON health response.
    ///
    /// Expected JSON shape (subset):
    /// ```json
    /// {
    ///   "zone": "green",
    ///   "totalSize": "142 MB",
    ///   "providerCount": 3,
    ///   "trend": "stable"
    /// }
    /// ```
    pub fn updateTooltipFromJson(self: *TrayState, json: []const u8) void {
        // Simple extraction — we avoid pulling in a full JSON parser to keep
        // the binary small. The monitoring core sends well-formed JSON.
        const zone_str = extractJsonString(json, "zone") orelse "unknown";
        const total_size = extractJsonString(json, "totalSize") orelse "unknown";
        const trend = extractJsonString(json, "trend") orelse "unknown";
        const provider_count = extractJsonString(json, "providerCount") orelse "?";

        const new_tooltip = std.fmt.allocPrint(
            self.allocator,
            "Session Sentinel: {s}\n{s} across {s} AI tools\nTrend: {s}",
            .{ zone_str, total_size, provider_count, trend },
        ) catch {
            std.log.err("Failed to allocate tooltip text", .{});
            return;
        };

        // Free the previous tooltip if it was dynamically allocated.
        if (!std.mem.eql(u8, self.tooltip_text, "Session Sentinel: initialising...")) {
            self.allocator.free(self.tooltip_text);
        }

        self.tooltip_text = new_tooltip;
    }

    /// Tick the flash timer for purple zone.
    ///
    /// Call this from the main DBus dispatch loop. When in purple zone,
    /// toggles the icon visibility every 500ms to create a flashing effect
    /// that draws the user's attention to the degraded state.
    pub fn tickFlashTimer(self: *TrayState) void {
        const zone = self.current_zone.load(.acquire);
        if (zone != .purple) return;

        const now = std.time.nanoTimestamp();
        const elapsed = now - self.last_flash_toggle_ns;

        if (elapsed >= self.flash_interval_ns) {
            self.flash_visible = !self.flash_visible;
            self.last_flash_toggle_ns = now;

            // Write either the purple icon or a blank icon.
            if (self.flash_visible) {
                icons.writeIconForZone(.purple) catch {};
            } else {
                icons.writeBlankIcon() catch {};
            }

            // Notify the tray host of the icon change.
            emitNewIcon(self.bus) catch {};
        }
    }

    /// Get the XDG icon name for the current zone (fallback when custom
    /// SVG icons are not supported by the tray host).
    pub fn currentIconName(self: *const TrayState) []const u8 {
        return iconNameForZone(self.current_zone.load(.acquire));
    }

    /// Get the SNI Status string for the current zone.
    pub fn currentStatus(self: *const TrayState) []const u8 {
        return switch (self.current_zone.load(.acquire)) {
            .green => "Active",
            .yellow => "Active",
            .red => "NeedsAttention",
            .purple => "NeedsAttention",
        };
    }
};

// ---------------------------------------------------------------------------
// Health zone classification from JSON
// ---------------------------------------------------------------------------

/// Classify a health zone from a JSON response string.
///
/// Looks for a "zone" field and maps its value to a HealthZone enum variant.
/// Falls back to .yellow if the zone string is unrecognised.
pub fn classifyHealthZone(json: []const u8) HealthZone {
    const zone_str = extractJsonString(json, "zone") orelse return .yellow;

    if (std.mem.eql(u8, zone_str, "green")) return .green;
    if (std.mem.eql(u8, zone_str, "yellow")) return .yellow;
    if (std.mem.eql(u8, zone_str, "red")) return .red;
    if (std.mem.eql(u8, zone_str, "purple")) return .purple;

    return .yellow;
}

/// Map a health zone to an XDG icon name.
///
/// These are standard freedesktop icon names that KDE Plasma and GNOME
/// ship by default in their icon themes.
pub fn iconNameForZone(zone: HealthZone) []const u8 {
    return switch (zone) {
        .green => "security-high",
        .yellow => "security-medium",
        .red => "security-low",
        .purple => "security-low",
    };
}

// ---------------------------------------------------------------------------
// SNI DBus interactions
// ---------------------------------------------------------------------------

/// Register this process as a StatusNotifierItem with the KDE watcher.
///
/// Sends: org.kde.StatusNotifierWatcher.RegisterStatusNotifierItem(bus_name)
fn registerWithWatcher(bus: *dbus.Connection) !bool {
    const msg = try dbus.newMethodCall(
        SNI_WATCHER_BUS_NAME,
        SNI_WATCHER_PATH,
        SNI_WATCHER_INTERFACE,
        "RegisterStatusNotifierItem",
    );
    defer dbus.messageUnref(msg);

    // The argument is our unique bus name (e.g. ":1.42").
    const bus_name = bus.getUniqueName() orelse return error.NoBusName;
    try dbus.appendStringArg(msg, bus_name);

    // Send and wait for reply (with 2 second timeout).
    _ = try bus.sendWithReply(msg, 2000);

    return true;
}

/// Emit the NewIcon signal on our StatusNotifierItem object path.
///
/// This tells the tray host to re-read our icon.
fn emitNewIcon(bus: *dbus.Connection) !void {
    try dbus.emitSignal(
        bus,
        SNI_ITEM_PATH,
        SNI_INTERFACE,
        "NewIcon",
    );
}

/// Emit the NewToolTip signal on our StatusNotifierItem object path.
///
/// This tells the tray host to re-read our tooltip.
fn emitNewToolTip(bus: *dbus.Connection) !void {
    try dbus.emitSignal(
        bus,
        SNI_ITEM_PATH,
        SNI_INTERFACE,
        "NewToolTip",
    );
}

// ---------------------------------------------------------------------------
// Minimal JSON string extraction (no allocations)
// ---------------------------------------------------------------------------

/// Extract a string value from a JSON object by key name.
///
/// This is a deliberately simple scanner — it finds `"key":"value"` or
/// `"key": "value"` patterns without a full JSON parser. Sufficient for
/// the well-formed JSON the monitoring core produces.
///
/// Returns a slice into the input JSON, or null if the key was not found.
fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    // Build the search pattern: "key"
    var search_buf: [256]u8 = undefined;
    const search_len = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{key}) catch return null;
    const search = search_buf[0..search_len.len];

    // Find the key in the JSON.
    const key_pos = std.mem.indexOf(u8, json, search) orelse return null;
    const after_key = key_pos + search.len;

    // Skip whitespace and colon.
    var pos = after_key;
    while (pos < json.len and (json[pos] == ' ' or json[pos] == ':' or json[pos] == '\t')) {
        pos += 1;
    }

    if (pos >= json.len) return null;

    // Check if value is a quoted string.
    if (json[pos] == '"') {
        pos += 1; // skip opening quote
        const end = std.mem.indexOfPos(u8, json, pos, "\"") orelse return null;
        return json[pos..end];
    }

    // Value is unquoted (number, boolean) — scan to next comma/brace/bracket.
    const start = pos;
    while (pos < json.len and json[pos] != ',' and json[pos] != '}' and json[pos] != ']') {
        pos += 1;
    }

    // Trim trailing whitespace.
    var end = pos;
    while (end > start and (json[end - 1] == ' ' or json[end - 1] == '\t' or json[end - 1] == '\n')) {
        end -= 1;
    }

    return if (end > start) json[start..end] else null;
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "classifyHealthZone — known zones" {
    try std.testing.expectEqual(HealthZone.green, classifyHealthZone("{\"zone\":\"green\"}"));
    try std.testing.expectEqual(HealthZone.yellow, classifyHealthZone("{\"zone\":\"yellow\"}"));
    try std.testing.expectEqual(HealthZone.red, classifyHealthZone("{\"zone\":\"red\"}"));
    try std.testing.expectEqual(HealthZone.purple, classifyHealthZone("{\"zone\":\"purple\"}"));
}

test "classifyHealthZone — unknown zone falls back to yellow" {
    try std.testing.expectEqual(HealthZone.yellow, classifyHealthZone("{\"zone\":\"magenta\"}"));
}

test "classifyHealthZone — missing zone field falls back to yellow" {
    try std.testing.expectEqual(HealthZone.yellow, classifyHealthZone("{\"status\":\"ok\"}"));
}

test "iconNameForZone mapping" {
    try std.testing.expectEqualStrings("security-high", iconNameForZone(.green));
    try std.testing.expectEqualStrings("security-medium", iconNameForZone(.yellow));
    try std.testing.expectEqualStrings("security-low", iconNameForZone(.red));
    try std.testing.expectEqualStrings("security-low", iconNameForZone(.purple));
}

test "extractJsonString — quoted value" {
    const json = "{\"zone\":\"green\",\"totalSize\":\"142 MB\"}";
    try std.testing.expectEqualStrings("green", extractJsonString(json, "zone").?);
    try std.testing.expectEqualStrings("142 MB", extractJsonString(json, "totalSize").?);
}

test "extractJsonString — unquoted number" {
    const json = "{\"providerCount\":3}";
    try std.testing.expectEqualStrings("3", extractJsonString(json, "providerCount").?);
}

test "extractJsonString — missing key" {
    const json = "{\"zone\":\"green\"}";
    try std.testing.expect(extractJsonString(json, "missing") == null);
}

test "MENU_LABELS count matches MenuAction variants" {
    // Ensure we have a label for every menu action.
    try std.testing.expectEqual(@as(usize, 6), MENU_LABELS.len);
}
