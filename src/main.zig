const std = @import("std");
const assert = std.debug.assert;
const io = std.io;
const mem = std.mem;
const os = std.os;
const log = std.log;

const build_options = @import("build_options");
const builtin = @import("builtin");

const Lock = @import("Lock.zig");
const flags = @import("flags.zig");

const usage =
    \\usage: waylock [options]
    \\
    \\  -h                      Print this help message and exit.
    \\  -version                Print the version number and exit.
    \\  -log-level <level>      Set the log level to error, warning, info, or debug.
    \\
    \\  -fork-on-lock           Fork to the background after locking.
    \\  -ready-fd <fd>          Write a newline to fd after locking.
    \\  -ignore-empty-password  Do not validate an empty password.
    \\
    \\  -init-color 0xRRGGBB    Set the initial color.
    \\  -input-color 0xRRGGBB   Set the color used after input.
    \\  -fail-color 0xRRGGBB    Set the color used on authentication failure.
    \\
;

pub fn main() void {
    const result = flags.parser([*:0]const u8, &.{
        .{ .name = "h", .kind = .boolean },
        .{ .name = "version", .kind = .boolean },
        .{ .name = "log-level", .kind = .arg },
        .{ .name = "fork-on-lock", .kind = .boolean },
        .{ .name = "ready-fd", .kind = .arg },
        .{ .name = "ignore-empty-password", .kind = .boolean },
        .{ .name = "init-color", .kind = .arg },
        .{ .name = "input-color", .kind = .arg },
        .{ .name = "fail-color", .kind = .arg },
    }).parse(os.argv[1..]) catch {
        io.getStdErr().writeAll(usage) catch {};
        os.exit(1);
    };
    if (result.flags.h) {
        io.getStdOut().writeAll(usage) catch os.exit(1);
        os.exit(0);
    }
    if (result.args.len != 0) {
        log.err("unknown option '{s}'", .{result.args[0]});
        io.getStdErr().writeAll(usage) catch {};
        os.exit(1);
    }

    if (result.flags.version) {
        io.getStdOut().writeAll(build_options.version ++ "\n") catch os.exit(1);
        os.exit(0);
    }
    if (result.flags.@"log-level") |level| {
        if (mem.eql(u8, level, "error")) {
            runtime_log_level = .err;
        } else if (mem.eql(u8, level, "warning")) {
            runtime_log_level = .warn;
        } else if (mem.eql(u8, level, "info")) {
            runtime_log_level = .info;
        } else if (mem.eql(u8, level, "debug")) {
            runtime_log_level = .debug;
        } else {
            log.err("invalid log level '{s}'", .{level});
            os.exit(1);
        }
    }

    var options: Lock.Options = .{
        .fork_on_lock = result.flags.@"fork-on-lock",
        .ignore_empty_password = result.flags.@"ignore-empty-password",
    };
    if (result.flags.@"ready-fd") |raw| {
        options.ready_fd = std.fmt.parseInt(os.fd_t, raw, 10) catch {
            log.err("invalid file descriptor '{s}'", .{raw});
            os.exit(1);
        };
    }
    if (result.flags.@"init-color") |raw| options.init_color = parse_color(raw);
    if (result.flags.@"input-color") |raw| options.input_color = parse_color(raw);
    if (result.flags.@"fail-color") |raw| options.fail_color = parse_color(raw);

    Lock.run(options);
}

fn parse_color(raw: []const u8) u24 {
    if (raw.len != 8) fatal_bad_color(raw);
    if (!mem.eql(u8, raw[0..2], "0x")) fatal_bad_color(raw);

    return std.fmt.parseUnsigned(u24, raw[2..], 16) catch fatal_bad_color(raw);
}

fn fatal_bad_color(raw: []const u8) noreturn {
    log.err("invalid color '{s}', expected format '0xRRGGBB'", .{raw});
    os.exit(1);
}

/// Set the default log level based on the build mode.
var runtime_log_level: log.Level = switch (builtin.mode) {
    .Debug => .debug,
    .ReleaseSafe, .ReleaseFast, .ReleaseSmall => .err,
};

pub const std_options = struct {
    /// Tell std.log to leave all log level filtering to us.
    pub const log_level: log.Level = .debug;

    pub fn logFn(
        comptime level: log.Level,
        comptime scope: @TypeOf(.EnumLiteral),
        comptime format: []const u8,
        args: anytype,
    ) void {
        // waylock is small enough that we don't need scopes
        comptime assert(scope == .default);

        if (@intFromEnum(level) > @intFromEnum(runtime_log_level)) return;

        const stderr = io.getStdErr().writer();
        stderr.print(level.asText() ++ ": " ++ format ++ "\n", args) catch {};
    }
};
