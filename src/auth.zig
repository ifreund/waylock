const std = @import("std");
const assert = std.debug.assert;
const log = std.log;
const os = std.os;

const pam = @import("pam.zig");

pub const Connection = struct {
    read_fd: os.fd_t,
    write_fd: os.fd_t,

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
    const parent_to_child = try os.pipe();
    const child_to_parent = try os.pipe();

    const pid = try os.fork();
    if (pid == 0) {
        // We are the child
        os.close(parent_to_child[1]);
        os.close(child_to_parent[0]);

        run(.{
            .read_fd = parent_to_child[0],
            .write_fd = child_to_parent[1],
        });
    } else {
        // We are the parent
        os.close(parent_to_child[0]);
        os.close(child_to_parent[1]);

        return Connection{
            .read_fd = child_to_parent[0],
            .write_fd = parent_to_child[1],
        };
    }
}

/// Maximum password size in bytes.
pub const password_size_max = 1024;
var password: std.BoundedArray(u8, password_size_max) = .{ .buffer = undefined };

pub fn run(conn: Connection) noreturn {
    const conv: pam.Conv = .{
        .conv = converse,
        .appdata_ptr = null,
    };
    var pamh: *pam.Handle = undefined;

    {
        const pw = getpwuid(os.linux.getuid()) orelse {
            log.err("failed to get name of current user", .{});
            os.exit(1);
        };

        const result = pam.start("waylock", pw.pw_name, &conv, &pamh);
        if (result != .success) {
            log.err("failed to initialize PAM: {s}", .{result.description()});
            os.exit(1);
        }
    }

    while (true) {
        read_password(conn) catch |err| {
            log.err("failed to read password from pipe: {s}", .{@errorName(err)});
            os.exit(1);
        };

        const auth_result = pamh.authenticate(0);

        std.crypto.utils.secureZero(u8, &password.buffer);
        password.len = 0;

        if (auth_result == .success) {
            log.info("PAM authentication succeeded", .{});

            conn.writer().writeByte(@boolToInt(true)) catch |err| {
                log.err("failed to notify parent of success: {s}", .{@errorName(err)});
                os.exit(1);
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
                log.err("PAM deinitialization failed: {s}", .{end_result});
            }

            os.exit(0);
        } else {
            log.err("PAM authentication failed: {s}", .{auth_result.description()});

            conn.writer().writeByte(@boolToInt(false)) catch |err| {
                log.err("failed to notify parent of failure: {s}", .{@errorName(err)});
                os.exit(1);
            };

            if (auth_result == .abort) {
                const end_result = pamh.end(auth_result);
                if (end_result != .success) {
                    log.err("PAM deinitialization failed: {s}", .{end_result});
                }
                os.exit(1);
            }
        }
    }
}

fn read_password(conn: Connection) !void {
    assert(password.len == 0);

    const reader = conn.reader();
    const length = try reader.readIntNative(u32);
    try password.resize(length);
    try reader.readNoEof(password.slice());
}

fn converse(
    num_msg: c_int,
    msg: [*]*const pam.Message,
    resp: *[*]pam.Response,
    _: ?*anyopaque,
) callconv(.C) pam.Result {
    const ally = std.heap.raw_c_allocator;

    const count = @intCast(usize, num_msg);
    const responses = ally.alloc(pam.Response, count) catch {
        return .buf_err;
    };

    for (msg[0..count]) |message, i| {
        switch (message.msg_style) {
            .prompt_echo_off => {
                responses[i] = .{
                    .resp = ally.dupeZ(u8, password.slice()) catch {
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

    resp.* = responses.ptr;

    return .success;
}

// TODO: upstream these to the zig standard library
pub const passwd = extern struct {
    pw_name: [*:0]const u8,
    pw_passwd: [*:0]const u8,
    pw_uid: os.uid_t,
    pw_gid: os.gid_t,
    pw_change: os.time_t,
    pw_class: [*:0]const u8,
    pw_gecos: [*:0]const u8,
    pw_dir: [*:0]const u8,
    pw_shell: [*:0]const u8,
    pw_expire: os.time_t,
};

pub extern fn getpwuid(uid: os.uid_t) ?*passwd;
