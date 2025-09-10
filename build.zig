const std = @import("std");
const assert = std.debug.assert;
const Build = std.Build;
const fs = std.fs;
const mem = std.mem;

const Scanner = @import("wayland").Scanner;

/// While a waylock release is in development, this string should contain the version in
/// development with the "-dev" suffix.
/// When a release is tagged, the "-dev" suffix should be removed for the commit that gets tagged.
/// Directly after the tagged commit, the version should be bumped and the "-dev" suffix added.
const version = "1.4.0-dev";

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const strip = b.option(bool, "strip", "Omit debug information") orelse false;
    const pie = b.option(bool, "pie", "Build a Position Independent Executable") orelse false;

    const man_pages = b.option(
        bool,
        "man-pages",
        "Set to true to build man pages. Requires scdoc. Defaults to true if scdoc is found.",
    ) orelse scdoc_found: {
        _ = b.findProgram(&.{"scdoc"}, &.{}) catch |err| switch (err) {
            error.FileNotFound => break :scdoc_found false,
            else => return err,
        };
        break :scdoc_found true;
    };

    if (man_pages) {
        // Workaround for https://github.com/ziglang/zig/issues/16369
        // Even passing a buffer to std.Build.Step.Run appears to be racy and occasionally deadlocks.
        const scdoc = b.addSystemCommand(&.{ "sh", "-c", "scdoc < doc/waylock.1.scd" });
        // This makes the caching work for the Workaround, and the extra argument is ignored by /bin/sh.
        scdoc.addFileArg(b.path("doc/waylock.1.scd"));

        const stdout = scdoc.captureStdOut();
        b.getInstallStep().dependOn(&b.addInstallFile(stdout, "share/man/man1/waylock.1").step);
    }

    const install_prefix = try std.fs.path.resolve(b.allocator, &.{b.install_prefix});
    if (mem.eql(u8, install_prefix, "/usr")) {
        b.installFile("pam.d/waylock", "../etc/pam.d/waylock");
    } else {
        b.installFile("pam.d/waylock", "etc/pam.d/waylock");
    }

    const full_version = blk: {
        if (mem.endsWith(u8, version, "-dev")) {
            var ret: u8 = undefined;

            const git_describe_long = b.runAllowFail(
                &.{ "git", "-C", b.build_root.path orelse ".", "describe", "--long" },
                &ret,
                .Inherit,
            ) catch break :blk version;

            var it = mem.splitScalar(u8, mem.trim(u8, git_describe_long, &std.ascii.whitespace), '-');
            _ = it.next().?; // previous tag
            const commit_count = it.next().?;
            const commit_hash = it.next().?;
            assert(it.next() == null);
            assert(commit_hash[0] == 'g');

            // Follow semantic versioning, e.g. 0.2.0-dev.42+d1cf95b
            break :blk b.fmt(version ++ ".{s}+{s}", .{ commit_count, commit_hash[1..] });
        } else {
            break :blk version;
        }
    };

    const options = b.addOptions();
    options.addOption([]const u8, "version", full_version);

    const scanner = Scanner.create(b, .{});
    scanner.addSystemProtocol("staging/ext-session-lock/ext-session-lock-v1.xml");
    scanner.addSystemProtocol("staging/single-pixel-buffer/single-pixel-buffer-v1.xml");
    scanner.addSystemProtocol("stable/viewporter/viewporter.xml");

    scanner.generate("wl_compositor", 4);
    scanner.generate("wl_output", 3);
    scanner.generate("wl_seat", 5);
    scanner.generate("ext_session_lock_manager_v1", 1);
    scanner.generate("wp_viewporter", 1);
    scanner.generate("wp_single_pixel_buffer_manager_v1", 1);

    const wayland = b.createModule(.{ .root_source_file = scanner.result });
    const xkbcommon = b.dependency("xkbcommon", .{}).module("xkbcommon");

    const waylock = b.addExecutable(.{
        .name = "waylock",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    waylock.root_module.addOptions("build_options", options);

    waylock.linkLibC();
    waylock.linkSystemLibrary("pam");

    waylock.root_module.addImport("wayland", wayland);
    waylock.linkSystemLibrary("wayland-client");

    waylock.root_module.addImport("xkbcommon", xkbcommon);
    waylock.linkSystemLibrary("xkbcommon");

    waylock.root_module.strip = strip;
    waylock.pie = pie;

    b.installArtifact(waylock);
}
