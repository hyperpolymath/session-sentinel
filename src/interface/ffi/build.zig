// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Session Sentinel FFI — Zig Build Configuration (Zig 0.15+)
//
// Builds the native system tray binary (session-sentinel-tray) which provides
// KDE/Wayland StatusNotifierItem integration via DBus. Links against libdbus-1
// for session bus communication with the desktop environment.
//
// Targets: Linux x86_64 (primary), with cross-compilation support via Zig.
//
// Build steps:
//   zig build              — build the tray binary
//   zig build test         — run unit tests (no DBus required)
//   zig build test-integration — run integration tests (DBus session bus required)
//   zig build install      — install to ~/.local/bin/
//
// Dependencies:
//   - libdbus-1 (system library, typically from dbus-devel / libdbus-1-dev)
//   - libsystemd (for sd_notify watchdog integration)

const std = @import("std");

/// Build configuration for session-sentinel-tray.
///
/// This produces a single native executable that implements the DBus
/// StatusNotifierItem protocol for KDE/Wayland system tray integration.
/// The binary communicates with the monitoring core via DBus IPC.
pub fn build(b: *std.Build) void {
    // -------------------------------------------------------------------------
    // Target and optimisation
    // -------------------------------------------------------------------------

    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    // -------------------------------------------------------------------------
    // Shared module for main source (reused across exe, libs, tests)
    // -------------------------------------------------------------------------

    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .pic = true,
    });
    main_mod.linkSystemLibrary("dbus-1", .{});
    main_mod.linkSystemLibrary("libsystemd", .{});

    // -------------------------------------------------------------------------
    // Main executable: session-sentinel-tray
    // -------------------------------------------------------------------------

    const exe = b.addExecutable(.{
        .name = "session-sentinel-tray",
        .root_module = main_mod,
    });

    b.installArtifact(exe);

    // -------------------------------------------------------------------------
    // Shared library (for FFI consumers — Idris2, ReScript via Deno FFI)
    // -------------------------------------------------------------------------

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lib_mod.linkSystemLibrary("dbus-1", .{});
    lib_mod.linkSystemLibrary("libsystemd", .{});

    const lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "session_sentinel_tray",
        .root_module = lib_mod,
        .version = .{ .major = 0, .minor = 1, .patch = 0 },
    });

    b.installArtifact(lib);

    // -------------------------------------------------------------------------
    // Unit tests (no DBus session bus required)
    // -------------------------------------------------------------------------

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.linkSystemLibrary("dbus-1", .{});
    test_mod.linkSystemLibrary("systemd", .{});

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests (no DBus required)");
    test_step.dependOn(&run_unit_tests.step);

    // -------------------------------------------------------------------------
    // Integration tests (require DBus session bus)
    // -------------------------------------------------------------------------

    const integ_mod = b.createModule(.{
        .root_source_file = b.path("test/integration_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    integ_mod.linkSystemLibrary("dbus-1", .{});
    integ_mod.linkSystemLibrary("systemd", .{});

    const integration_tests = b.addTest(.{
        .root_module = integ_mod,
    });

    const run_integration_tests = b.addRunArtifact(integration_tests);

    const integration_test_step = b.step("test-integration", "Run integration tests (DBus session bus required)");
    integration_test_step.dependOn(&run_integration_tests.step);

    // -------------------------------------------------------------------------
    // Install to ~/.local/bin/ (user-local install)
    // -------------------------------------------------------------------------

    const home = std.posix.getenv("HOME") orelse "/home/hyper";
    const local_bin = std.fmt.allocPrint(b.allocator, "{s}/.local/bin", .{home}) catch @panic("OOM");

    const install_step = b.step("install-local", "Install session-sentinel-tray to ~/.local/bin/");
    const copy_cmd = b.addSystemCommand(&.{
        "cp",
        "-f",
    });
    copy_cmd.addArtifactArg(exe);
    copy_cmd.addArg(local_bin);
    install_step.dependOn(&copy_cmd.step);
}
