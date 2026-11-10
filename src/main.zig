const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const mem = std.mem;
const posix = std.posix;
const process = std.process;
const log = std.log;

const build_options = @import("build_options");
const builtin = @import("builtin");

const Lock = @import("Lock.zig");
const flags = @import("flags.zig");

const usage =
    \\usage: waylock [options]
    \\
    \\  -h                         Print this help message and exit.
    \\  -version                   Print the version number and exit.
    \\  -log-level <level>         Set the log level to error, warning, info, or debug.
    \\
    \\  -fork-on-lock              Fork to the background after locking.
    \\  -ready-fd <fd>             Write a newline to fd after locking.
    \\  -ignore-empty-password     Do not validate an empty password.
    \\
    \\  -init-color 0xRRGGBB       Set the initial color.
    \\  -input-color 0xRRGGBB      Set the color used after input.
    \\  -input-alt-color 0xRRGGBB  Set the alternate color used after input.
    \\  -fail-color 0xRRGGBB       Set the color used on authentication failure.
    \\
;

pub fn main(init: process.Init) error{ OutOfMemory, Unexpected }!void {
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_buffer: [512]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [512]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    const args = try init.minimal.args.toSlice(arena);
    const result = flags.parser(&.{
        .{ .name = "h", .kind = .boolean },
        .{ .name = "version", .kind = .boolean },
        .{ .name = "log-level", .kind = .arg },
        .{ .name = "fork-on-lock", .kind = .boolean },
        .{ .name = "ready-fd", .kind = .arg },
        .{ .name = "ignore-empty-password", .kind = .boolean },
        .{ .name = "init-color", .kind = .arg },
        .{ .name = "input-color", .kind = .arg },
        .{ .name = "input-alt-color", .kind = .arg },
        .{ .name = "fail-color", .kind = .arg },
    }).parse(args[1..]) catch {
        stderr.writeAll(usage) catch {};
        stderr.flush() catch process.exit(1);
        process.exit(1);
    };
    if (result.flags.h) {
        stdout.writeAll(usage) catch process.exit(1);
        stdout.flush() catch process.exit(1);
        process.exit(0);
    }
    if (result.args.len != 0) {
        log.err("unknown option '{s}'", .{result.args[0]});
        stderr.writeAll(usage) catch {};
        stderr.flush() catch process.exit(1);
        process.exit(1);
    }

    if (result.flags.version) {
        stdout.writeAll(build_options.version ++ "\n") catch process.exit(1);
        stdout.flush() catch process.exit(1);
        process.exit(0);
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
            process.exit(1);
        }
    }

    var options: Lock.Options = .{
        .fork_on_lock = result.flags.@"fork-on-lock",
        .ignore_empty_password = result.flags.@"ignore-empty-password",
    };
    if (result.flags.@"ready-fd") |raw| {
        options.ready_fd = std.fmt.parseInt(posix.fd_t, raw, 10) catch {
            log.err("invalid file descriptor '{s}'", .{raw});
            process.exit(1);
        };
    }
    if (result.flags.@"init-color") |raw| options.init_color = parse_color(raw);
    if (result.flags.@"input-color") |raw| {
        options.input_color = parse_color(raw);
        options.input_alt_color = parse_color(raw);
    }
    if (result.flags.@"input-alt-color") |raw| options.input_alt_color = parse_color(raw);
    if (result.flags.@"fail-color") |raw| options.fail_color = parse_color(raw);

    Lock.run(io, init.gpa, options);
}

fn parse_color(raw: []const u8) u24 {
    if (raw.len != 8) fatal_bad_color(raw);
    if (!mem.eql(u8, raw[0..2], "0x")) fatal_bad_color(raw);

    return std.fmt.parseUnsigned(u24, raw[2..], 16) catch fatal_bad_color(raw);
}

fn fatal_bad_color(raw: []const u8) noreturn {
    log.err("invalid color '{s}', expected format '0xRRGGBB'", .{raw});
    process.exit(1);
}

/// Set the default log level based on the build mode.
var runtime_log_level: log.Level = switch (builtin.mode) {
    .Debug => .debug,
    .ReleaseSafe, .ReleaseFast, .ReleaseSmall => .err,
};

pub const std_options: std.Options = .{
    // Tell std.log to leave all log level filtering to us.
    .log_level = .debug,
    .logFn = logFn,
};

fn logFn(
    comptime level: log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(level) > @intFromEnum(runtime_log_level)) return;

    log.defaultLog(level, scope, format, args);
}
