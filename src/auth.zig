const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const log = std.log;
const mem = std.mem;
const process = std.process;
const fatal = process.fatal;
const system = std.posix.system;

const pam = @import("pam.zig");

const PasswordBuffer = @import("PasswordBuffer.zig");

pub const Connection = struct {
    read_fd: system.fd_t,
    write_fd: system.fd_t,

    pub fn reader(conn: Connection, io: Io) Io.File.Reader {
        const file = Io.File{ .handle = conn.read_fd, .flags = .{ .nonblocking = false } };
        return file.readerStreaming(io, &.{});
    }

    pub fn writer(conn: Connection, io: Io) Io.File.Writer {
        const file = Io.File{ .handle = conn.write_fd, .flags = .{ .nonblocking = false } };
        return file.writerStreaming(io, &.{});
    }
};

pub fn fork_child(io: Io) Connection {
    var parent_to_child: [2]system.fd_t = undefined;
    var child_to_parent: [2]system.fd_t = undefined;
    switch (system.errno(system.pipe(&parent_to_child))) {
        .SUCCESS => {},
        else => |err| fatal("failed to fork child authentication process: {}", .{err}),
    }
    switch (system.errno(system.pipe(&child_to_parent))) {
        .SUCCESS => {},
        else => |err| fatal("failed to fork child authentication process: {}", .{err}),
    }

    const pid: system.pid_t = fork: {
        const rc = system.fork();
        switch (system.errno(rc)) {
            .SUCCESS => break :fork @intCast(rc),
            else => |err| fatal("failed to fork child authentication process: {}", .{err}),
        }
    };

    if (pid == 0) {
        // We are the child
        _ = system.close(parent_to_child[1]);
        _ = system.close(child_to_parent[0]);

        run(io, .{
            .read_fd = parent_to_child[0],
            .write_fd = child_to_parent[1],
        });
    } else {
        // We are the parent
        _ = system.close(parent_to_child[0]);
        _ = system.close(child_to_parent[1]);

        return Connection{
            .read_fd = child_to_parent[0],
            .write_fd = parent_to_child[1],
        };
    }
}

var password: PasswordBuffer = undefined;

fn run(io: Io, conn: Connection) noreturn {
    password = PasswordBuffer.init();

    const conv: pam.Conv = .{
        .conv = converse,
        .appdata_ptr = null,
    };
    var pamh: *pam.Handle = undefined;

    {
        const pw = std.c.getpwuid(std.c.getuid()) orelse {
            log.err("failed to get name of current user", .{});
            process.exit(1);
        };

        const result = pam.start("waylock", pw.name, &conv, &pamh);
        if (result != .success) {
            log.err("failed to initialize PAM: {s}", .{result.description()});
            process.exit(1);
        }
    }

    while (true) {
        read_password(io, conn) catch |err| {
            log.err("failed to read password from pipe: {s}", .{@errorName(err)});
            process.exit(1);
        };

        const auth_result = pamh.authenticate(0);

        password.clear();

        if (auth_result == .success) {
            log.debug("PAM authentication succeeded", .{});

            var writer = conn.writer(io);
            writer.interface.writeByte(@intFromBool(true)) catch |err| {
                log.err("failed to notify parent of success: {s}", .{@errorName(err)});
                process.exit(1);
            };

            // We don't need to prevent unlocking if this fails. Failure just
            // means that some extra things like Kerberos might not work without
            // user intervention.
            const setcred_result = pamh.setcred(pam.flags.reinitialize_cred);
            if (setcred_result != .success) {
                log.err("PAM failed to reinitialize credentials: {s}", .{
                    setcred_result.description(),
                });
            }

            const end_result = pamh.end(setcred_result);
            if (end_result != .success) {
                log.err("PAM deinitialization failed: {s}", .{end_result.description()});
            }

            process.exit(0);
        } else {
            log.err("PAM authentication failed: {s}", .{auth_result.description()});

            var writer = conn.writer(io);
            writer.interface.writeByte(@intFromBool(false)) catch |err| {
                log.err("failed to notify parent of failure: {s}", .{@errorName(err)});
                process.exit(1);
            };

            if (auth_result == .abort) {
                const end_result = pamh.end(auth_result);
                if (end_result != .success) {
                    log.err("PAM deinitialization failed: {s}", .{end_result.description()});
                }
                process.exit(1);
            }
        }
    }
}

fn read_password(io: Io, conn: Connection) !void {
    assert(password.buffer.len == 0);

    var reader = conn.reader(io);
    var len_bytes: [4]u8 = undefined;
    try reader.interface.readSliceAll(&len_bytes);
    try password.grow(@as(u32, @bitCast(len_bytes)));
    try reader.interface.readSliceAll(password.buffer);
}

fn converse(
    num_msg: c_int,
    msg: [*]*const pam.Message,
    resp: *[*]pam.Response,
    _: ?*anyopaque,
) callconv(.c) pam.Result {
    const ally = std.heap.c_allocator;

    const responses = ally.alloc(pam.Response, @intCast(num_msg)) catch {
        return .buf_err;
    };

    @memset(responses, .{});
    resp.* = responses.ptr;

    for (msg, responses) |message, *response| {
        switch (message.msg_style) {
            .prompt_echo_off => {
                response.* = .{
                    .resp = ally.dupeSentinel(u8, password.buffer, 0) catch {
                        return .buf_err;
                    },
                };
            },
            .prompt_echo_on, .error_msg, .text_info => {
                log.warn("ignoring PAM message: msg_style={s} msg='{s}'", .{
                    @tagName(message.msg_style),
                    message.msg,
                });
            },
        }
    }

    return .success;
}
