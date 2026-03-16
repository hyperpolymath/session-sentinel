// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Session Sentinel FFI — Zig Build Configuration
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
//   zig build docs         — generate documentation
//
// Dependencies:
//   - libdbus-1 (system library, typically from dbus-devel / libdbus-1-dev)
//   - sd-daemon (optional, for systemd watchdog integration)

const std = @import("std");

/// Build configuration for session-sentinel-tray.
///
/// This produces a single native executable that implements the DBus
/// StatusNotifierItem protocol for KDE/Wayland system tray integration.
/// The binary communicates with the ReScript monitoring core via DBus IPC.
pub fn build(b: *std.Build) void {
    // -------------------------------------------------------------------------
    // Target and optimisation
    // -------------------------------------------------------------------------

    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_arch = .x86_64,
            .os_tag = .linux,
        },
    });

    const optimize = b.standardOptimizeOption(.{});

    // -------------------------------------------------------------------------
    // Main executable: session-sentinel-tray
    // -------------------------------------------------------------------------

    const exe = b.addExecutable(.{
        .name = "session-sentinel-tray",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Link libdbus-1 (system library for DBus communication)
    exe.linkSystemLibrary("dbus-1");

    // Link libsystemd for sd_notify watchdog integration (optional at runtime)
    exe.linkSystemLibrary("systemd");

    // Link libc (required for libdbus-1 interop)
    exe.linkLibC();

    // Install the executable
    b.installArtifact(exe);

    // -------------------------------------------------------------------------
    // Shared library (for FFI consumers — Idris2, ReScript via Deno FFI)
    // -------------------------------------------------------------------------

    const lib = b.addSharedLibrary(.{
        .name = "session_sentinel_tray",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    lib.version = .{ .major = 0, .minor = 1, .patch = 0 };
    lib.linkSystemLibrary("dbus-1");
    lib.linkSystemLibrary("systemd");
    lib.linkLibC();

    b.installArtifact(lib);

    // -------------------------------------------------------------------------
    // Static library
    // -------------------------------------------------------------------------

    const lib_static = b.addStaticLibrary(.{
        .name = "session_sentinel_tray",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    lib_static.linkSystemLibrary("dbus-1");
    lib_static.linkSystemLibrary("systemd");
    lib_static.linkLibC();

    b.installArtifact(lib_static);

    // -------------------------------------------------------------------------
    // Unit tests (no DBus session bus required)
    // -------------------------------------------------------------------------

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    unit_tests.linkSystemLibrary("dbus-1");
    unit_tests.linkSystemLibrary("systemd");
    unit_tests.linkLibC();

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests (no DBus required)");
    test_step.dependOn(&run_unit_tests.step);

    // -------------------------------------------------------------------------
    // Integration tests (require DBus session bus)
    // -------------------------------------------------------------------------

    const integration_tests = b.addTest(.{
        .root_source_file = b.path("test/integration_test.zig"),
        .target = target,
        .optimize = optimize,
    });

    integration_tests.linkSystemLibrary("dbus-1");
    integration_tests.linkSystemLibrary("systemd");
    integration_tests.linkLibC();

    const run_integration_tests = b.addRunArtifact(integration_tests);

    const integration_test_step = b.step("test-integration", "Run integration tests (DBus session bus required)");
    integration_test_step.dependOn(&run_integration_tests.step);

    // -------------------------------------------------------------------------
    // Install to ~/.local/bin/ (user-local install)
    // -------------------------------------------------------------------------

    const install_local = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = "" } },
    });

    const home = std.posix.getenv("HOME") orelse "/home/hyper";
    const local_bin = std.fmt.allocPrint(b.allocator, "{s}/.local/bin", .{home}) catch @panic("OOM");

    const install_step = b.step("install-local", "Install session-sentinel-tray to ~/.local/bin/");
    const copy_cmd = b.addSystemCommand(&.{
        "cp",
        "-f",
    });
    copy_cmd.addArtifactArg(exe);
    copy_cmd.addArg(local_bin);
    copy_cmd.step.dependOn(&install_local.step);
    install_step.dependOn(&copy_cmd.step);

    // -------------------------------------------------------------------------
    // Documentation generation
    // -------------------------------------------------------------------------

    const docs = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .Debug,
    });

    docs.linkSystemLibrary("dbus-1");
    docs.linkSystemLibrary("systemd");
    docs.linkLibC();

    const docs_step = b.step("docs", "Generate documentation from source");
    docs_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = docs.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    }).step);
}
