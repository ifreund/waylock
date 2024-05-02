const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const log = std.log;
const mem = std.mem;
const posix = std.posix;

const c = @cImport({
    @cInclude("unistd.h"); // getuid()
    @cInclude("pwd.h"); // getpwuid()
});

const pam = @import("pam.zig");

const PasswordBuffer = @import("PasswordBuffer.zig");

pub const Connection = struct {
    read_fd: posix.fd_t,
    write_fd: posix.fd_t,

    pub fn reader(conn: Connection) std.fs.File.Reader {
        const file = std.fs.File{ .handle = conn.read_fd };
        return file.reader();
    }

    pub fn writer(conn: Connection) std.fs.File.Writer {
        const file = std.fs.File{ .handle = conn.write_fd };
        return file.writer();
    }
};

pub fn fork_child() !Connection {
    const parent_to_child = try posix.pipe();
    const child_to_parent = try posix.pipe();

    const pid = try posix.fork();
    if (pid == 0) {
        // We are the child
        posix.close(parent_to_child[1]);
        posix.close(child_to_parent[0]);

        run(.{
            .read_fd = parent_to_child[0],
            .write_fd = child_to_parent[1],
        });
    } else {
        // We are the parent
        posix.close(parent_to_child[0]);
        posix.close(child_to_parent[1]);

        return Connection{
            .read_fd = child_to_parent[0],
            .write_fd = parent_to_child[1],
        };
    }
}

var password: PasswordBuffer = undefined;

pub fn run(conn: Connection) noreturn {
    password = PasswordBuffer.init();

    const conv: pam.Conv = .{
        .conv = converse,
        .appdata_ptr = null,
    };
    var pamh: *pam.Handle = undefined;

    {
        const pw = @as(?*c.struct_passwd, c.getpwuid(c.getuid())) orelse {
            log.err("failed to get name of current user", .{});
            posix.exit(1);
        };

        const result = pam.start("waylock", pw.pw_name, &conv, &pamh);
        if (result != .success) {
            log.err("failed to initialize PAM: {s}", .{result.description()});
            posix.exit(1);
        }
    }

    while (true) {
        read_password(conn) catch |err| {
            log.err("failed to read password from pipe: {s}", .{@errorName(err)});
            posix.exit(1);
        };

        const auth_result = pamh.authenticate(0);

        password.clear();

        if (auth_result == .success) {
            log.debug("PAM authentication succeeded", .{});

            conn.writer().writeByte(@intFromBool(true)) catch |err| {
                log.err("failed to notify parent of success: {s}", .{@errorName(err)});
                posix.exit(1);
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

            posix.exit(0);
        } else {
            log.err("PAM authentication failed: {s}", .{auth_result.description()});

            conn.writer().writeByte(@intFromBool(false)) catch |err| {
                log.err("failed to notify parent of failure: {s}", .{@errorName(err)});
                posix.exit(1);
            };

            if (auth_result == .abort) {
                const end_result = pamh.end(auth_result);
                if (end_result != .success) {
                    log.err("PAM deinitialization failed: {s}", .{end_result.description()});
                }
                posix.exit(1);
            }
        }
    }
}

fn read_password(conn: Connection) !void {
    assert(password.buffer.len == 0);

    const reader = conn.reader();
    const length = try reader.readInt(u32, builtin.cpu.arch.endian());
    try password.grow(length);
    try reader.readNoEof(password.buffer);
}

fn converse(
    num_msg: c_int,
    msg: [*]*const pam.Message,
    resp: *[*]pam.Response,
    _: ?*anyopaque,
) callconv(.C) pam.Result {
    const ally = std.heap.raw_c_allocator;

    const responses = ally.alloc(pam.Response, @intCast(num_msg)) catch {
        return .buf_err;
    };

    @memset(responses, .{});
    resp.* = responses.ptr;

    for (msg, responses) |message, *response| {
        switch (message.msg_style) {
            .prompt_echo_off => {
                response.* = .{
                    .resp = ally.dupeZ(u8, password.buffer) catch {
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
