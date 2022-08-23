const std = @import("std");
const assert = std.debug.assert;
const zbs = std.build;
const fs = std.fs;
const mem = std.mem;

const ScanProtocolsStep = @import("deps/zig-wayland/build.zig").ScanProtocolsStep;

/// While a waylock release is in development, this string should contain the version in
/// development with the "-dev" suffix.
/// When a release is tagged, the "-dev" suffix should be removed for the commit that gets tagged.
/// Directly after the tagged commit, the version should be bumped and the "-dev" suffix added.
const version = "0.4.1";

pub fn build(b: *zbs.Builder) !void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const strip = b.option(bool, "strip", "Omit debug information") orelse false;
    const pie = b.option(bool, "pie", "Build a Position Independent Executable") orelse false;

    const man_pages = b.option(
        bool,
        "man-pages",
        "Set to true to build man pages. Requires scdoc. Defaults to true if scdoc is found.",
    ) orelse scdoc_found: {
        _ = b.findProgram(&[_][]const u8{"scdoc"}, &[_][]const u8{}) catch |err| switch (err) {
            error.FileNotFound => break :scdoc_found false,
            else => return err,
        };
        break :scdoc_found true;
    };

    if (man_pages) {
        const scdoc_step = try ScdocStep.create(b);
        try scdoc_step.install();
    }

    const install_prefix = try std.fs.path.resolve(b.allocator, &[_][]const u8{b.install_prefix});
    if (std.mem.eql(u8, install_prefix, "/usr")) {
        b.installFile("pam.d/waylock", "../etc/pam.d/waylock");
    } else {
        b.installFile("pam.d/waylock", "etc/pam.d/waylock");
    }

    const full_version = blk: {
        if (mem.endsWith(u8, version, "-dev")) {
            var ret: u8 = undefined;

            const git_describe_long = b.execAllowFail(
                &[_][]const u8{ "git", "-C", b.build_root, "describe", "--long" },
                &ret,
                .Inherit,
            ) catch break :blk version;

            var it = mem.split(u8, mem.trim(u8, git_describe_long, &std.ascii.spaces), "-");
            _ = it.next().?; // previous tag
            const commit_count = it.next().?;
            const commit_hash = it.next().?;
            assert(it.next() == null);
            assert(commit_hash[0] == 'g');

            // Follow semantic versioning, e.g. 0.2.0-dev.42+d1cf95b
            break :blk try std.fmt.allocPrintZ(b.allocator, version ++ ".{s}+{s}", .{
                commit_count,
                commit_hash[1..],
            });
        } else {
            break :blk version;
        }
    };

    const options = b.addOptions();
    options.addOption([]const u8, "version", full_version);

    const scanner = ScanProtocolsStep.create(b);
    scanner.addSystemProtocol("staging/ext-session-lock/ext-session-lock-v1.xml");
    scanner.addSystemProtocol("stable/viewporter/viewporter.xml");

    scanner.generate("wl_compositor", 4);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_output", 3);
    scanner.generate("wl_seat", 5);
    scanner.generate("ext_session_lock_manager_v1", 1);
    scanner.generate("wp_viewporter", 1);

    const waylock = b.addExecutable("waylock", "src/main.zig");
    waylock.setTarget(target);
    waylock.setBuildMode(mode);
    waylock.addOptions("build_options", options);

    waylock.addPackage(.{
        .name = "wayland",
        .path = .{ .generated = &scanner.result },
    });
    waylock.step.dependOn(&scanner.step);
    waylock.addPackagePath("xkbcommon", "deps/zig-xkbcommon/src/xkbcommon.zig");
    waylock.linkLibC();
    waylock.linkSystemLibrary("wayland-client");
    waylock.linkSystemLibrary("xkbcommon");
    waylock.linkSystemLibrary("pam");

    scanner.addCSource(waylock);

    waylock.strip = strip;
    waylock.pie = pie;
    waylock.install();
}

const ScdocStep = struct {
    builder: *zbs.Builder,
    step: zbs.Step,

    fn create(builder: *zbs.Builder) !*ScdocStep {
        const self = try builder.allocator.create(ScdocStep);
        self.* = .{
            .builder = builder,
            .step = zbs.Step.init(.custom, "Generate man pages", builder.allocator, make),
        };
        return self;
    }

    fn make(step: *zbs.Step) !void {
        const self = @fieldParentPtr(ScdocStep, "step", step);
        _ = try self.builder.exec(
            &[_][]const u8{ "sh", "-c", "scdoc < doc/waylock.1.scd > doc/waylock.1" },
        );
    }

    fn install(self: *ScdocStep) !void {
        self.builder.getInstallStep().dependOn(&self.step);
        self.builder.installFile("doc/waylock.1", "share/man/man1/waylock.1");
    }
};
