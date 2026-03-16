// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Session Sentinel — Dynamic SVG Icon Generation
//
// Generates SVG icons at runtime for the system tray, reflecting the current
// health zone. Icons are written to /tmp/session-sentinel/ so the
// StatusNotifierItem can reference them by file path.
//
// Icon design:
//   All zones use a shield shape as the base, consistent with security-oriented
//   system tray conventions. The fill colour and overlay symbol change per zone:
//
//     Green  — green shield with a checkmark (all clear)
//     Yellow — amber shield with an exclamation mark (warning)
//     Red    — red shield with an X (critical)
//     Purple — purple shield with a pulse line (degraded / system fault)
//
// Two sizes are generated:
//   22x22 — tray icon (StatusNotifierItem IconPixmap)
//   48x48 — tooltip icon (shown in hover popup)
//
// The SVG files are named deterministically so the tray host can cache them
// and we can atomically swap by overwriting.

const std = @import("std");
const fs = std.fs;
const posix = std.posix;

const tray = @import("tray.zig");

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Directory where generated icons are stored.
pub const ICON_DIR = "/tmp/session-sentinel";

/// File names for tray-size icons (22x22).
const ICON_TRAY_FILENAME = "tray-icon.svg";

/// File names for tooltip-size icons (48x48).
const ICON_TOOLTIP_FILENAME = "tooltip-icon.svg";

/// Blank icon filename (used for purple zone flash-off state).
const ICON_BLANK_FILENAME = "blank-icon.svg";

// ---------------------------------------------------------------------------
// Colour palette
// ---------------------------------------------------------------------------

/// Fill colours for each health zone.
const ZoneColours = struct {
    /// Primary shield fill colour.
    fill: []const u8,
    /// Darker stroke colour for the shield border.
    stroke: []const u8,
    /// Colour for the overlay symbol (checkmark, exclamation, etc.).
    symbol: []const u8,
};

/// Get the colour palette for a given health zone.
fn coloursForZone(zone: tray.HealthZone) ZoneColours {
    return switch (zone) {
        .green => .{
            .fill = "#4CAF50",
            .stroke = "#2E7D32",
            .symbol = "#FFFFFF",
        },
        .yellow => .{
            .fill = "#FFC107",
            .stroke = "#F57F17",
            .symbol = "#000000",
        },
        .red => .{
            .fill = "#F44336",
            .stroke = "#B71C1C",
            .symbol = "#FFFFFF",
        },
        .purple => .{
            .fill = "#9C27B0",
            .stroke = "#6A1B9A",
            .symbol = "#FFFFFF",
        },
    };
}

// ---------------------------------------------------------------------------
// SVG templates
// ---------------------------------------------------------------------------

/// Generate the shield path for a given viewport size.
///
/// The shield is a classic heraldic shape: pointed bottom, curved top shoulders.
/// All coordinates are relative to the viewport size for clean scaling.
fn shieldPath(size: u32) []const u8 {
    return switch (size) {
        22 => "M11 1 C6 1 2 3 2 7 L2 13 C2 17 11 21 11 21 C11 21 20 17 20 13 L20 7 C20 3 16 1 11 1 Z",
        48 => "M24 2 C13 2 4 6 4 15 L4 28 C4 37 24 46 24 46 C24 46 44 37 44 28 L44 15 C44 6 35 2 24 2 Z",
        else => "M11 1 C6 1 2 3 2 7 L2 13 C2 17 11 21 11 21 C11 21 20 17 20 13 L20 7 C20 3 16 1 11 1 Z",
    };
}

/// Generate a checkmark symbol path (green zone).
fn checkmarkPath(size: u32) []const u8 {
    return switch (size) {
        22 => "M7 11 L10 14 L15 8",
        48 => "M15 24 L22 31 L33 17",
        else => "M7 11 L10 14 L15 8",
    };
}

/// Generate an exclamation mark symbol path (yellow zone).
fn exclamationPath(size: u32) []const u8 {
    return switch (size) {
        22 => "M11 6 L11 13 M11 15 L11 16",
        48 => "M24 12 L24 30 M24 34 L24 36",
        else => "M11 6 L11 13 M11 15 L11 16",
    };
}

/// Generate an X symbol path (red zone).
fn xMarkPath(size: u32) []const u8 {
    return switch (size) {
        22 => "M7 7 L15 15 M15 7 L7 15",
        48 => "M16 16 L32 32 M32 16 L16 32",
        else => "M7 7 L15 15 M15 7 L7 15",
    };
}

/// Generate a pulse/heartbeat symbol path (purple zone).
fn pulsePath(size: u32) []const u8 {
    return switch (size) {
        22 => "M4 11 L8 11 L9 7 L11 15 L13 9 L14 11 L18 11",
        48 => "M8 24 L16 24 L19 14 L24 34 L29 18 L31 24 L40 24",
        else => "M4 11 L8 11 L9 7 L11 15 L13 9 L14 11 L18 11",
    };
}

// ---------------------------------------------------------------------------
// SVG generation
// ---------------------------------------------------------------------------

/// Generate a complete SVG icon string for a given health zone and size.
///
/// The returned buffer is stack-allocated and valid until the caller is done
/// writing it to disk. The caller must not store the pointer long-term.
pub fn generateIcon(zone: tray.HealthZone, size: u32) ![2048]u8 {
    const colours = coloursForZone(zone);
    const shield = shieldPath(size);

    const symbol_path = switch (zone) {
        .green => checkmarkPath(size),
        .yellow => exclamationPath(size),
        .red => xMarkPath(size),
        .purple => pulsePath(size),
    };

    // Stroke width scales with icon size.
    const stroke_width: []const u8 = if (size >= 48) "3" else "2";

    // For the exclamation mark, we use round linecap for the dot.
    const linecap: []const u8 = if (zone == .yellow) "round" else "round";

    // Purple zone gets an animation element for the pulse.
    const animation: []const u8 = if (zone == .purple)
        \\<animate attributeName="opacity" values="1;0.4;1" dur="1.5s" repeatCount="indefinite"/>
    else
        "";

    var buf: [2048]u8 = undefined;
    const written = std.fmt.bufPrint(&buf,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<svg xmlns="http://www.w3.org/2000/svg" width="{d}" height="{d}" viewBox="0 0 {d} {d}">
        \\  <title>Session Sentinel — {s}</title>
        \\  <path d="{s}" fill="{s}" stroke="{s}" stroke-width="1"/>
        \\  <path d="{s}" fill="none" stroke="{s}" stroke-width="{s}" stroke-linecap="{s}"/>
        \\  {s}
        \\</svg>
        \\
    , .{
        size,
        size,
        size,
        size,
        @tagName(zone),
        shield,
        colours.fill,
        colours.stroke,
        symbol_path,
        colours.symbol,
        stroke_width,
        linecap,
        animation,
    }) catch {
        return error.IconBufferOverflow;
    };

    // Zero the rest of the buffer so we can find the end.
    @memset(buf[written.len..], 0);

    return buf;
}

/// Generate a blank (transparent) SVG icon for the flash-off state.
pub fn generateBlankIcon() [512]u8 {
    var buf: [512]u8 = undefined;
    const content =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<svg xmlns="http://www.w3.org/2000/svg" width="22" height="22" viewBox="0 0 22 22">
        \\  <title>Session Sentinel — blank</title>
        \\  <rect width="22" height="22" fill="none" opacity="0"/>
        \\</svg>
        \\
    ;

    @memcpy(buf[0..content.len], content);
    @memset(buf[content.len..], 0);

    return buf;
}

// ---------------------------------------------------------------------------
// File operations
// ---------------------------------------------------------------------------

/// Ensure the icon temp directory exists.
///
/// Creates /tmp/session-sentinel/ with 0o700 permissions. Safe to call
/// multiple times (idempotent).
pub fn ensureTempDir() !void {
    fs.makeDirAbsolute(ICON_DIR) catch |err| {
        if (err != error.PathAlreadyExists) {
            std.log.err("Failed to create icon directory {s}: {any}", .{ ICON_DIR, err });
            return err;
        }
    };

    std.log.info("Icon directory ready: {s}", .{ICON_DIR});
}

/// Write the appropriate icon files for a given health zone.
///
/// Generates both the 22x22 tray icon and the 48x48 tooltip icon,
/// writing them atomically to the temp directory.
pub fn writeIconForZone(zone: tray.HealthZone) !void {
    // Generate and write tray-size icon (22x22).
    const tray_svg = try generateIcon(zone, 22);
    try writeIconFile(ICON_TRAY_FILENAME, &tray_svg);

    // Generate and write tooltip-size icon (48x48).
    const tooltip_svg = try generateIcon(zone, 48);
    try writeIconFile(ICON_TOOLTIP_FILENAME, &tooltip_svg);
}

/// Write the blank icon (for purple zone flash-off).
pub fn writeBlankIcon() !void {
    const blank_svg = generateBlankIcon();
    try writeIconFile(ICON_TRAY_FILENAME, &blank_svg);
}

/// Write an SVG buffer to a named file in the icon directory.
///
/// Uses write-to-temp-then-rename for atomic updates, so the tray host
/// never reads a partially-written file.
fn writeIconFile(filename: []const u8, svg_data: []const u8) !void {
    // Find the actual content length (buffer is zero-padded).
    const content_len = std.mem.indexOfScalar(u8, svg_data, 0) orelse svg_data.len;
    if (content_len == 0) return error.EmptyIcon;

    // Build the full path.
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ ICON_DIR, filename }) catch {
        return error.PathTooLong;
    };

    // Build a temp path for atomic write.
    var tmp_path_buf: [256]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_path_buf, "{s}/.{s}.tmp", .{ ICON_DIR, filename }) catch {
        return error.PathTooLong;
    };

    // Write to the temp file.
    const tmp_file = fs.createFileAbsolute(tmp_path, .{ .truncate = true }) catch |err| {
        std.log.err("Failed to create temp icon file {s}: {any}", .{ tmp_path, err });
        return err;
    };
    defer tmp_file.close();

    tmp_file.writeAll(svg_data[0..content_len]) catch |err| {
        std.log.err("Failed to write icon data to {s}: {any}", .{ tmp_path, err });
        return err;
    };

    // Atomically rename temp file to final path.
    fs.renameAbsolute(tmp_path, path) catch |err| {
        std.log.err("Failed to rename {s} -> {s}: {any}", .{ tmp_path, path, err });
        return err;
    };
}

/// Remove all generated icon files and the temp directory.
///
/// Called during graceful shutdown to avoid leaving stale files.
pub fn cleanupTempDir() void {
    // Delete known icon files (ignore errors — best effort).
    const filenames = [_][]const u8{
        ICON_TRAY_FILENAME,
        ICON_TOOLTIP_FILENAME,
        ICON_BLANK_FILENAME,
    };

    for (filenames) |name| {
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ ICON_DIR, name }) catch continue;
        fs.deleteFileAbsolute(path) catch {};
    }

    // Also clean up any temp files left from interrupted writes.
    const tmp_names = [_][]const u8{
        ".tray-icon.svg.tmp",
        ".tooltip-icon.svg.tmp",
        ".blank-icon.svg.tmp",
    };

    for (tmp_names) |name| {
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ ICON_DIR, name }) catch continue;
        fs.deleteFileAbsolute(path) catch {};
    }

    // Remove the directory itself (will fail if non-empty, which is fine).
    fs.deleteDirAbsolute(ICON_DIR) catch {};

    std.log.info("Icon directory cleaned up", .{});
}

/// Get the full path to the current tray icon file.
///
/// Returns a stack-allocated path string. The caller must use it before
/// the stack frame returns.
pub fn trayIconPath() [256]u8 {
    var buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ ICON_DIR, ICON_TRAY_FILENAME }) catch {
        @memcpy(buf[0..ICON_DIR.len], ICON_DIR);
        buf[ICON_DIR.len] = '/';
        @memcpy(buf[ICON_DIR.len + 1 ..][0..ICON_TRAY_FILENAME.len], ICON_TRAY_FILENAME);
        buf[ICON_DIR.len + 1 + ICON_TRAY_FILENAME.len] = 0;
        return buf;
    };
    _ = path;
    return buf;
}

/// Get the full path to the current tooltip icon file.
pub fn tooltipIconPath() [256]u8 {
    var buf: [256]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{s}/{s}", .{ ICON_DIR, ICON_TOOLTIP_FILENAME }) catch {
        @memset(&buf, 0);
        return buf;
    };
    return buf;
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "generateIcon — green zone produces valid SVG" {
    const svg = try generateIcon(.green, 22);
    const content = std.mem.sliceTo(&svg, 0);
    try std.testing.expect(std.mem.startsWith(u8, content, "<?xml"));
    try std.testing.expect(std.mem.indexOf(u8, content, "#4CAF50") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "green") != null);
}

test "generateIcon — yellow zone produces valid SVG" {
    const svg = try generateIcon(.yellow, 22);
    const content = std.mem.sliceTo(&svg, 0);
    try std.testing.expect(std.mem.indexOf(u8, content, "#FFC107") != null);
}

test "generateIcon — red zone produces valid SVG" {
    const svg = try generateIcon(.red, 22);
    const content = std.mem.sliceTo(&svg, 0);
    try std.testing.expect(std.mem.indexOf(u8, content, "#F44336") != null);
}

test "generateIcon — purple zone includes animation" {
    const svg = try generateIcon(.purple, 22);
    const content = std.mem.sliceTo(&svg, 0);
    try std.testing.expect(std.mem.indexOf(u8, content, "#9C27B0") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "animate") != null);
}

test "generateIcon — 48x48 size produces valid SVG" {
    const svg = try generateIcon(.green, 48);
    const content = std.mem.sliceTo(&svg, 0);
    try std.testing.expect(std.mem.indexOf(u8, content, "width=\"48\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "height=\"48\"") != null);
}

test "generateBlankIcon — produces transparent SVG" {
    const svg = generateBlankIcon();
    const content = std.mem.sliceTo(&svg, 0);
    try std.testing.expect(std.mem.startsWith(u8, content, "<?xml"));
    try std.testing.expect(std.mem.indexOf(u8, content, "opacity=\"0\"") != null);
}

test "coloursForZone — all zones return non-empty colours" {
    const zones = [_]tray.HealthZone{ .green, .yellow, .red, .purple };
    for (zones) |zone| {
        const colours = coloursForZone(zone);
        try std.testing.expect(colours.fill.len > 0);
        try std.testing.expect(colours.stroke.len > 0);
        try std.testing.expect(colours.symbol.len > 0);
    }
}

test "ICON_DIR is an absolute path" {
    try std.testing.expect(ICON_DIR[0] == '/');
}
