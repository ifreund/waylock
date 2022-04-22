const std = @import("std");
const Builder = std.build.Builder;
const ScanProtocolsStep = @import("deps/zig-wayland/build.zig").ScanProtocolsStep;

pub fn build(b: *Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const scanner = ScanProtocolsStep.create(b);
    scanner.addSystemProtocol("staging/ext-session-lock/ext-session-lock-v1.xml");

    const waylock = b.addExecutable("waylock", "src/main.zig");
    waylock.setTarget(target);
    waylock.setBuildMode(mode);

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

    // TODO: remove when https://github.com/ziglang/zig/issues/131 is implemented
    scanner.addCSource(waylock);

    waylock.install();
}
