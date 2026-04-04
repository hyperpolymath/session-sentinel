// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// session-sentinel :: src/interface/ffi/src/verisimdb.zig
//
// VeriSimDB persistence client for health zone history and scan records.
//
// Persists session-sentinel health readings to VeriSimDB under the collection
// `session-sentinel:health` so that Hypatia rules can detect degradation
// trends across reboots and gitbot-fleet can act on Purple-zone breaches.
//
// ## Collection schema (session-sentinel:health)
//
// ```json
// {
//   "reading_id":    "ss:1740000000000:abc123",
//   "timestamp":     "2026-01-30T12:00:00Z",
//   "bytes_used":    524288000,
//   "health_zone":   "Yellow",
//   "trend":         "degrading",
//   "flash_check":   false,
//   "hostname":      "hydra"
// }
// ```
//
// ## Environment
//
// Set `VERISIMDB_URL` to override the default `http://localhost:8080`.
//
// ## Fail-open semantics
//
// VeriSimDB is best-effort. Health readings are logged locally first;
// VeriSimDB persistence is additional durable storage for cross-reboot
// analysis. If VeriSimDB is unreachable, `persistReading` returns an error
// and the caller continues with local-only storage.

const std = @import("std");

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const DEFAULT_URL  = "http://localhost:8080";
const COLLECTION   = "session-sentinel:health";

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// Health zones matching the Green/Yellow/Red/Purple classification in health.as.
pub const HealthZone = enum {
    Green,
    Yellow,
    Red,
    Purple,
};

/// Trend direction from health.as trend analysis.
pub const Trend = enum {
    improving,
    stable,
    degrading,
};

/// A single health reading for VeriSimDB persistence.
pub const HealthReading = struct {
    reading_id:  []const u8,
    timestamp:   []const u8,
    bytes_used:  u64,
    zone:        HealthZone,
    trend:       Trend,
    flash_check: bool,
    hostname:    []const u8,
};

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Persist a health reading to VeriSimDB (collection: session-sentinel:health).
///
/// Uses HTTP PUT to `/v1/session-sentinel:health/<reading_id>`.
/// Returns an error on connectivity failure — caller should log and continue.
pub fn persistReading(allocator: std.mem.Allocator, reading: HealthReading) !void {
    const base_url = std.posix.getenv("VERISIMDB_URL") orelse DEFAULT_URL;

    const url = try std.fmt.allocPrint(allocator, "{s}/v1/{s}/{s}", .{
        base_url, COLLECTION, reading.reading_id,
    });
    defer allocator.free(url);

    const zone_str = @tagName(reading.zone);
    const trend_str = @tagName(reading.trend);
    const flash_str = if (reading.flash_check) "true" else "false";

    const body = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "reading_id": "{s}",
        \\  "timestamp": "{s}",
        \\  "bytes_used": {d},
        \\  "health_zone": "{s}",
        \\  "trend": "{s}",
        \\  "flash_check": {s},
        \\  "hostname": "{s}"
        \\}}
    , .{
        reading.reading_id,
        reading.timestamp,
        reading.bytes_used,
        zone_str,
        trend_str,
        flash_str,
        reading.hostname,
    });
    defer allocator.free(body);

    try httpPut(allocator, url, body);
}

/// Generate a stable reading ID from hostname and timestamp milliseconds.
///
/// Format: `ss:<ts_ms>:<first_8_of_hostname_sha256_hex>`
pub fn makeReadingId(allocator: std.mem.Allocator, hostname: []const u8, ts_ms: u64) ![]u8 {
    var hash_buf: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(hostname, &hash_buf, .{});
    const hex = try std.fmt.allocPrint(allocator, "{}", .{std.fmt.fmtSliceHexLower(hash_buf[0..4])});
    defer allocator.free(hex);
    return std.fmt.allocPrint(allocator, "ss:{d}:{s}", .{ ts_ms, hex });
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn httpPut(allocator: std.mem.Allocator, url: []const u8, body: []const u8) !void {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(url);

    var header_buf: [4096]u8 = undefined;
    var req = try client.open(.PUT, uri, .{
        .server_header_buffer = &header_buf,
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "application/json" },
        },
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = body.len };
    try req.send();
    try req.writeAll(body);
    try req.finish();
    try req.wait();

    const status = req.response.status;
    if (@intFromEnum(status) < 200 or @intFromEnum(status) >= 300) {
        return error.VeriSimDbHttpError;
    }
}
