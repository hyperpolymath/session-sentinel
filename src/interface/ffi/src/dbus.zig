// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Session Sentinel — DBus Abstraction Layer
//
// Provides a safe Zig wrapper around libdbus-1 for session bus communication.
// This module handles:
//   - Connection lifecycle (connect, request name, disconnect)
//   - Message construction and dispatch (method calls, signals)
//   - Method handler registration for our org.hyperpolymath.SessionSentinel1 interface
//   - Error handling with retry logic for transient bus failures
//
// DBus topology:
//   Bus name:    org.hyperpolymath.SessionSentinel
//   Object path: /org/hyperpolymath/SessionSentinel
//   Interface:   org.hyperpolymath.SessionSentinel1
//
// Exposed methods:
//   GetHealth()           → s (JSON string with zone, metrics)
//   ForceHeal()           → s (JSON string with healing result)
//   GetDiagnostics()      → s (JSON string with diagnostic counters)
//   GetHistory(n: u32)    → s (JSON array of last N scan results)
//   TuneThreshold(k,v)    → b (success boolean)
//
// Emitted signals:
//   HealthChanged(zone: s, metrics_json: s)
//   HealingCompleted(result_json: s)

const std = @import("std");

const tray = @import("tray.zig");

// ---------------------------------------------------------------------------
// DBus well-known names
// ---------------------------------------------------------------------------

/// Our well-known bus name on the session bus.
pub const BUS_NAME = "org.hyperpolymath.SessionSentinel";

/// DBus object path where we expose our interface.
pub const OBJECT_PATH = "/org/hyperpolymath/SessionSentinel";

/// DBus interface name (versioned to allow future evolution).
pub const INTERFACE = "org.hyperpolymath.SessionSentinel1";

/// Maximum number of retry attempts for transient DBus errors.
const MAX_RETRIES: u32 = 3;

/// Delay between retries in nanoseconds (100ms).
const RETRY_DELAY_NS: u64 = 100 * std.time.ns_per_ms;

// ---------------------------------------------------------------------------
// libdbus-1 C bindings (linked via build.zig)
// ---------------------------------------------------------------------------

/// Opaque C types from libdbus-1.
const DBusConnection = opaque {};
const DBusMessage = opaque {};
const DBusPendingCall = opaque {};

/// DBus error structure (C layout).
const DBusError = extern struct {
    name: ?[*:0]const u8 = null,
    message: ?[*:0]const u8 = null,
    dummy1: c_uint = 0,
    dummy2: c_uint = 0,
    dummy3: c_uint = 0,
    dummy4: c_uint = 0,
    dummy5: c_uint = 0,
    padding1: ?*anyopaque = null,
};

/// DBus bus types.
const DBUS_BUS_SESSION: c_int = 0;
const DBUS_BUS_SYSTEM: c_int = 1;

/// Name request flags.
const DBUS_NAME_FLAG_REPLACE_EXISTING: c_uint = 0x2;
const DBUS_NAME_FLAG_DO_NOT_QUEUE: c_uint = 0x4;

/// Name request results.
const DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER: c_int = 1;

/// Message types.
const DBUS_MESSAGE_TYPE_METHOD_CALL: c_int = 1;
const DBUS_MESSAGE_TYPE_SIGNAL: c_int = 4;

// libdbus-1 function declarations (extern C ABI).
extern "dbus-1" fn dbus_error_init(error: *DBusError) void;
extern "dbus-1" fn dbus_error_free(error: *DBusError) void;
extern "dbus-1" fn dbus_error_is_set(error: *const DBusError) c_int;

extern "dbus-1" fn dbus_bus_get(bus_type: c_int, error: *DBusError) ?*DBusConnection;
extern "dbus-1" fn dbus_bus_request_name(
    conn: *DBusConnection,
    name: [*:0]const u8,
    flags: c_uint,
    error: *DBusError,
) c_int;
extern "dbus-1" fn dbus_bus_get_unique_name(conn: *DBusConnection) ?[*:0]const u8;

extern "dbus-1" fn dbus_connection_unref(conn: *DBusConnection) void;
extern "dbus-1" fn dbus_connection_read_write_dispatch(
    conn: *DBusConnection,
    timeout_ms: c_int,
) c_int;
extern "dbus-1" fn dbus_connection_send(
    conn: *DBusConnection,
    message: *DBusMessage,
    serial: ?*u32,
) c_int;
extern "dbus-1" fn dbus_connection_send_with_reply_and_block(
    conn: *DBusConnection,
    message: *DBusMessage,
    timeout_ms: c_int,
    error: *DBusError,
) ?*DBusMessage;
extern "dbus-1" fn dbus_connection_add_filter(
    conn: *DBusConnection,
    function: *const fn (?*DBusConnection, ?*DBusMessage, ?*anyopaque) callconv(.C) c_int,
    user_data: ?*anyopaque,
    free_data_function: ?*const fn (?*anyopaque) callconv(.C) void,
) c_int;

extern "dbus-1" fn dbus_message_new_method_call(
    destination: ?[*:0]const u8,
    path: [*:0]const u8,
    iface: ?[*:0]const u8,
    method: [*:0]const u8,
) ?*DBusMessage;
extern "dbus-1" fn dbus_message_new_signal(
    path: [*:0]const u8,
    iface: [*:0]const u8,
    name: [*:0]const u8,
) ?*DBusMessage;
extern "dbus-1" fn dbus_message_new_method_return(message: *DBusMessage) ?*DBusMessage;
extern "dbus-1" fn dbus_message_unref(message: *DBusMessage) void;

extern "dbus-1" fn dbus_message_append_args(
    message: *DBusMessage,
    first_arg_type: c_int,
    ...,
) c_int;
extern "dbus-1" fn dbus_message_get_args(
    message: *DBusMessage,
    error: *DBusError,
    first_arg_type: c_int,
    ...,
) c_int;

extern "dbus-1" fn dbus_message_is_method_call(
    message: *DBusMessage,
    iface: [*:0]const u8,
    method: [*:0]const u8,
) c_int;
extern "dbus-1" fn dbus_message_get_interface(message: *DBusMessage) ?[*:0]const u8;
extern "dbus-1" fn dbus_message_get_member(message: *DBusMessage) ?[*:0]const u8;
extern "dbus-1" fn dbus_message_get_type(message: *DBusMessage) c_int;

// DBus type constants for dbus_message_append_args.
const DBUS_TYPE_STRING: c_int = 's';
const DBUS_TYPE_UINT32: c_int = 'u';
const DBUS_TYPE_BOOLEAN: c_int = 'b';
const DBUS_TYPE_INVALID: c_int = 0;

// Filter return values.
const DBUS_HANDLER_RESULT_HANDLED: c_int = 0;
const DBUS_HANDLER_RESULT_NOT_YET_HANDLED: c_int = 1;

// ---------------------------------------------------------------------------
// Connection wrapper
// ---------------------------------------------------------------------------

/// Safe wrapper around a libdbus-1 session bus connection.
///
/// Manages the connection lifecycle and provides typed helpers for
/// sending messages, emitting signals, and dispatching incoming calls.
pub const Connection = struct {
    /// Raw libdbus-1 connection pointer. Non-null after successful init.
    raw: *DBusConnection,

    /// Whether we own the well-known bus name.
    name_owned: bool = false,

    /// Connect to the DBus session bus.
    ///
    /// This opens a connection to the user's session bus (typically managed
    /// by dbus-daemon or dbus-broker). Returns an error if the session bus
    /// is not available (e.g. running outside a desktop session).
    pub fn init() !Connection {
        var err: DBusError = .{};
        dbus_error_init(&err);
        defer dbus_error_free(&err);

        const raw = dbus_bus_get(DBUS_BUS_SESSION, &err) orelse {
            if (dbus_error_is_set(&err) != 0) {
                if (err.message) |msg| {
                    std.log.err("DBus session bus connection failed: {s}", .{std.mem.span(msg)});
                }
            }
            return error.DBusConnectionFailed;
        };

        std.log.info("Connected to DBus session bus", .{});
        return Connection{ .raw = raw };
    }

    /// Disconnect from the session bus and release resources.
    pub fn deinit(self: *Connection) void {
        dbus_connection_unref(self.raw);
        self.* = undefined;
    }

    /// Request our well-known bus name (org.hyperpolymath.SessionSentinel).
    ///
    /// If another instance already owns the name, this will fail rather than
    /// queue — we want exactly one tray icon per session.
    pub fn requestName(self: *Connection, name: [*:0]const u8) !void {
        var err: DBusError = .{};
        dbus_error_init(&err);
        defer dbus_error_free(&err);

        const result = dbus_bus_request_name(
            self.raw,
            name,
            DBUS_NAME_FLAG_DO_NOT_QUEUE | DBUS_NAME_FLAG_REPLACE_EXISTING,
            &err,
        );

        if (dbus_error_is_set(&err) != 0) {
            if (err.message) |msg| {
                std.log.err("Failed to request bus name '{s}': {s}", .{
                    std.mem.span(name),
                    std.mem.span(msg),
                });
            }
            return error.DBusNameRequestFailed;
        }

        if (result != DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER) {
            std.log.err("Another instance already owns bus name '{s}'", .{std.mem.span(name)});
            return error.DBusNameAlreadyOwned;
        }

        self.name_owned = true;
        std.log.info("Acquired bus name: {s}", .{std.mem.span(name)});
    }

    /// Get our unique bus name (e.g. ":1.42").
    pub fn getUniqueName(self: *const Connection) ?[]const u8 {
        const raw_name = dbus_bus_get_unique_name(@constCast(self.raw)) orelse return null;
        return std.mem.span(raw_name);
    }

    /// Process pending DBus messages with a timeout.
    ///
    /// This calls dbus_connection_read_write_dispatch which:
    ///   1. Reads any pending data from the bus socket.
    ///   2. Dispatches incoming messages to registered handlers.
    ///   3. Writes any outgoing messages queued for sending.
    ///
    /// The timeout_ms parameter controls how long to block waiting
    /// for data (0 = non-blocking, -1 = block indefinitely).
    pub fn processMessages(self: *Connection, timeout_ms: i32) !void {
        const result = dbus_connection_read_write_dispatch(self.raw, @intCast(timeout_ms));
        if (result == 0) {
            // Connection has been disconnected.
            return error.DBusDisconnected;
        }
    }

    /// Send a message and wait for a reply (blocking).
    ///
    /// Used for method calls where we need the return value (e.g.
    /// calling GetHealth on the monitoring core).
    pub fn sendWithReply(self: *Connection, msg: *DBusMessage, timeout_ms: i32) !?*DBusMessage {
        var err: DBusError = .{};
        dbus_error_init(&err);
        defer dbus_error_free(&err);

        const reply = dbus_connection_send_with_reply_and_block(
            self.raw,
            msg,
            @intCast(timeout_ms),
            &err,
        );

        if (dbus_error_is_set(&err) != 0) {
            if (err.message) |emsg| {
                std.log.warn("DBus method call failed: {s}", .{std.mem.span(emsg)});
            }
            return error.DBusMethodCallFailed;
        }

        return reply;
    }

    /// Send a message without waiting for a reply (fire-and-forget).
    ///
    /// Used for signals and notifications where we don't need confirmation.
    pub fn send(self: *Connection, msg: *DBusMessage) !void {
        const result = dbus_connection_send(self.raw, msg, null);
        if (result == 0) {
            return error.DBusSendFailed;
        }
    }
};

// ---------------------------------------------------------------------------
// Message construction helpers
// ---------------------------------------------------------------------------

/// Create a new DBus method call message.
///
/// Parameters match the DBus addressing model:
///   - destination: bus name of the target service
///   - path: object path on the target
///   - iface: interface containing the method
///   - method: method name to invoke
pub fn newMethodCall(
    destination: [*:0]const u8,
    path: [*:0]const u8,
    iface: [*:0]const u8,
    method: [*:0]const u8,
) !*DBusMessage {
    return dbus_message_new_method_call(destination, path, iface, method) orelse {
        return error.DBusMessageCreationFailed;
    };
}

/// Append a string argument to a DBus message.
pub fn appendStringArg(msg: *DBusMessage, value: []const u8) !void {
    // libdbus expects a null-terminated string; we need to ensure it.
    // For slices that are already sentinel-terminated, this is a no-op.
    var buf: [4096]u8 = undefined;
    if (value.len >= buf.len) return error.StringTooLong;

    @memcpy(buf[0..value.len], value);
    buf[value.len] = 0;

    const ptr: [*:0]const u8 = buf[0..value.len :0];
    const arg_ptr: *const [*:0]const u8 = &ptr;

    const result = dbus_message_append_args(
        msg,
        DBUS_TYPE_STRING,
        @as(*const anyopaque, @ptrCast(arg_ptr)),
        DBUS_TYPE_INVALID,
    );

    if (result == 0) {
        return error.DBusAppendArgFailed;
    }
}

/// Unreference (free) a DBus message.
pub fn messageUnref(msg: *DBusMessage) void {
    dbus_message_unref(msg);
}

// ---------------------------------------------------------------------------
// Signal emission
// ---------------------------------------------------------------------------

/// Emit a DBus signal on the given path and interface.
///
/// This is the no-argument form used for SNI property change signals
/// (NewIcon, NewToolTip, NewStatus, etc.).
pub fn emitSignal(
    bus: *Connection,
    path: [*:0]const u8,
    iface: [*:0]const u8,
    name: [*:0]const u8,
) !void {
    const msg = dbus_message_new_signal(path, iface, name) orelse {
        return error.DBusSignalCreationFailed;
    };
    defer dbus_message_unref(msg);

    try bus.send(msg);
}

/// Emit a HealthChanged signal with zone and metrics JSON.
///
/// Signal signature: HealthChanged(s zone, s metrics_json)
/// Emitted on: org.hyperpolymath.SessionSentinel1
pub fn emitHealthChanged(bus: *Connection, zone: tray.HealthZone) !void {
    const msg = dbus_message_new_signal(
        OBJECT_PATH,
        INTERFACE,
        "HealthChanged",
    ) orelse {
        return error.DBusSignalCreationFailed;
    };
    defer dbus_message_unref(msg);

    const zone_str = @tagName(zone);
    try appendStringArg(msg, zone_str);

    try bus.send(msg);
}

/// Emit a HealingCompleted signal with a JSON result.
///
/// Signal signature: HealingCompleted(s result_json)
/// Emitted on: org.hyperpolymath.SessionSentinel1
pub fn emitHealingCompleted(bus: *Connection, result_json: []const u8) !void {
    const msg = dbus_message_new_signal(
        OBJECT_PATH,
        INTERFACE,
        "HealingCompleted",
    ) orelse {
        return error.DBusSignalCreationFailed;
    };
    defer dbus_message_unref(msg);

    try appendStringArg(msg, result_json);

    try bus.send(msg);
}

// ---------------------------------------------------------------------------
// Method call helpers (outgoing)
// ---------------------------------------------------------------------------

/// Call GetHealth on the monitoring core via DBus.
///
/// This sends a method call to our own bus name (the ReScript monitoring
/// core registers on the same bus name from a separate process, or we
/// read local state). Returns the JSON response string, or null if the
/// call failed.
///
/// Caller owns the returned slice and must free it with the c_allocator.
pub fn callGetHealth(bus: *Connection) !?[]const u8 {
    var last_err: anyerror = error.DBusMethodCallFailed;

    for (0..MAX_RETRIES) |attempt| {
        const msg = dbus_message_new_method_call(
            BUS_NAME,
            OBJECT_PATH,
            INTERFACE,
            "GetHealth",
        ) orelse {
            return error.DBusMessageCreationFailed;
        };
        defer dbus_message_unref(msg);

        const reply = bus.sendWithReply(msg, 2000) catch |err| {
            last_err = err;
            if (attempt < MAX_RETRIES - 1) {
                std.log.warn("GetHealth attempt {d} failed, retrying...", .{attempt + 1});
                std.time.sleep(RETRY_DELAY_NS);
                continue;
            }
            return last_err;
        };

        if (reply) |r| {
            defer dbus_message_unref(r);

            // Extract the string argument from the reply.
            var err_dbus: DBusError = .{};
            dbus_error_init(&err_dbus);
            defer dbus_error_free(&err_dbus);

            var result_ptr: ?[*:0]const u8 = null;
            const ok = dbus_message_get_args(
                r,
                &err_dbus,
                DBUS_TYPE_STRING,
                &result_ptr,
                DBUS_TYPE_INVALID,
            );

            if (ok != 0) {
                if (result_ptr) |ptr| {
                    const span = std.mem.span(ptr);
                    // Copy the string since the message will be freed.
                    const copy = std.heap.c_allocator.alloc(u8, span.len) catch {
                        return error.OutOfMemory;
                    };
                    @memcpy(copy, span);
                    return copy;
                }
            }
        }

        return null;
    }

    return last_err;
}

// ---------------------------------------------------------------------------
// Method handler registration (incoming calls)
// ---------------------------------------------------------------------------

/// Register a DBus message filter that handles incoming method calls
/// on our interface.
///
/// The filter function inspects each incoming message and dispatches
/// to the appropriate handler based on the method name.
pub fn registerMethodHandlers(bus: *Connection) !void {
    const result = dbus_connection_add_filter(
        bus.raw,
        methodFilter,
        null,
        null,
    );

    if (result == 0) {
        return error.DBusFilterRegistrationFailed;
    }

    std.log.info("DBus method handlers registered on {s}", .{INTERFACE});
}

/// DBus message filter callback (C ABI).
///
/// Inspects each incoming message. If it's a method call on our interface,
/// dispatches to the appropriate handler and sends a reply. Otherwise,
/// passes the message through to the next filter.
fn methodFilter(
    conn: ?*DBusConnection,
    msg: ?*DBusMessage,
    _: ?*anyopaque,
) callconv(.C) c_int {
    const message = msg orelse return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    const connection = conn orelse return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;

    // Only handle method calls.
    if (dbus_message_get_type(message) != DBUS_MESSAGE_TYPE_METHOD_CALL) {
        return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    }

    // Check if this is for our interface.
    const iface = dbus_message_get_interface(message) orelse return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    const iface_str = std.mem.span(iface);

    if (!std.mem.eql(u8, iface_str, INTERFACE)) {
        return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    }

    const member = dbus_message_get_member(message) orelse return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    const method = std.mem.span(member);

    // Dispatch to the appropriate handler.
    const response_json: []const u8 = if (std.mem.eql(u8, method, "GetHealth"))
        handleGetHealth()
    else if (std.mem.eql(u8, method, "ForceHeal"))
        handleForceHeal()
    else if (std.mem.eql(u8, method, "GetDiagnostics"))
        handleGetDiagnostics()
    else if (std.mem.eql(u8, method, "GetHistory"))
        handleGetHistory()
    else if (std.mem.eql(u8, method, "TuneThreshold"))
        handleTuneThreshold()
    else
        return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;

    // Build and send a method return with the JSON response.
    const reply = dbus_message_new_method_return(message) orelse {
        return DBUS_HANDLER_RESULT_HANDLED;
    };
    defer dbus_message_unref(reply);

    // Append the response string.
    // We need a null-terminated copy for libdbus.
    var buf: [4096]u8 = undefined;
    if (response_json.len < buf.len) {
        @memcpy(buf[0..response_json.len], response_json);
        buf[response_json.len] = 0;

        const ptr: [*:0]const u8 = buf[0..response_json.len :0];
        const arg_ptr: *const [*:0]const u8 = &ptr;

        _ = dbus_message_append_args(
            reply,
            DBUS_TYPE_STRING,
            @as(*const anyopaque, @ptrCast(arg_ptr)),
            DBUS_TYPE_INVALID,
        );
    }

    _ = dbus_connection_send(connection, reply, null);

    return DBUS_HANDLER_RESULT_HANDLED;
}

// ---------------------------------------------------------------------------
// Method handlers (stub implementations)
// ---------------------------------------------------------------------------

/// Handle GetHealth method call.
///
/// Returns a JSON string with the current health zone and metrics.
/// In the full implementation, this reads from the ReScript monitoring core's
/// shared state. The stub returns a placeholder.
fn handleGetHealth() []const u8 {
    return "{\"zone\":\"green\",\"totalSize\":\"0 B\",\"providerCount\":0,\"trend\":\"stable\"}";
}

/// Handle ForceHeal method call.
///
/// Triggers the healing subsystem and returns the result as JSON.
fn handleForceHeal() []const u8 {
    return "{\"status\":\"ok\",\"actions\":[],\"message\":\"No issues to heal\"}";
}

/// Handle GetDiagnostics method call.
///
/// Returns diagnostic counters and system state as JSON.
fn handleGetDiagnostics() []const u8 {
    return "{\"uptime_s\":0,\"scan_count\":0,\"failure_count\":0,\"last_scan\":null}";
}

/// Handle GetHistory method call.
///
/// Returns the last N scan results as a JSON array.
fn handleGetHistory() []const u8 {
    return "[]";
}

/// Handle TuneThreshold method call.
///
/// Adjusts a named threshold value. Returns success/failure.
fn handleTuneThreshold() []const u8 {
    return "{\"success\":false,\"message\":\"Not yet implemented\"}";
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "bus name constants are well-formed" {
    // DBus bus names must start with a letter and contain dots.
    try std.testing.expect(std.mem.startsWith(u8, BUS_NAME, "org."));
    try std.testing.expect(std.mem.indexOf(u8, OBJECT_PATH, "/org/") != null);
    try std.testing.expect(std.mem.endsWith(u8, INTERFACE, "1"));
}

test "handler stubs return valid JSON" {
    // Verify each stub returns something that looks like JSON.
    const health = handleGetHealth();
    try std.testing.expect(health.len > 2);
    try std.testing.expect(health[0] == '{');

    const heal = handleForceHeal();
    try std.testing.expect(heal[0] == '{');

    const diag = handleGetDiagnostics();
    try std.testing.expect(diag[0] == '{');

    const history = handleGetHistory();
    try std.testing.expect(history[0] == '[');

    const threshold = handleTuneThreshold();
    try std.testing.expect(threshold[0] == '{');
}

test "MAX_RETRIES is reasonable" {
    try std.testing.expect(MAX_RETRIES >= 1);
    try std.testing.expect(MAX_RETRIES <= 10);
}
