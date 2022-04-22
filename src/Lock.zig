const Lock = @This();

const std = @import("std");
const assert = std.debug.assert;
const log = std.log;
const os = std.os;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const ext = wayland.client.ext;

const xkb = @import("xkbcommon");
const pam = @import("pam.zig");

const Output = @import("Output.zig");
const Seat = @import("Seat.zig");

const gpa = std.heap.c_allocator;

state: enum {
    /// The session lock object has not yet been created.
    initializing,
    /// The session lock object has been created but the locked event has not been recieved.
    locking,
    /// The compositor has sent the locked event indicating that the session is locked.
    locked,
    /// Gracefully exiting and cleaning up resources. This could happen because the compositor
    /// did not grant waylock's request to lock the screen or because the user or compositor
    /// has unlocked the session.
    exiting,
} = .initializing,

shm: ?*wl.Shm = null,
compositor: ?*wl.Compositor = null,
session_lock_manager: ?*ext.SessionLockManagerV1 = null,
session_lock: ?*ext.SessionLockV1 = null,

seats: std.SinglyLinkedList(Seat) = .{},
outputs: std.SinglyLinkedList(Output) = .{},

xkb_context: *xkb.Context,
pamh: *pam.Handle,
password: std.BoundedArray(u8, 1024) = .{ .buffer = undefined },

pub fn run() void {
    var lock: Lock = undefined;

    const conv: pam.Conv = .{
        .conv = converse,
        .appdata_ptr = &lock,
    };
    var pamh: *pam.Handle = undefined;

    {
        const pw = getpwuid(os.linux.getuid()) orelse {
            fatal("failed to get name of current user", .{});
        };

        const result = pam.start("system-auth", pw.pw_name, &conv, &pamh);
        if (result != .success) {
            fatal("failed to initialize PAM: {s}", .{result.description()});
        }
    }

    const display = wl.Display.connect(null) catch |e| {
        fatal("failed to connect to a wayland compositor: {s}", .{@errorName(e)});
    };
    const registry = display.getRegistry() catch fatal_oom();

    const xkb_context = xkb.Context.new(.no_flags) orelse fatal_oom();

    lock = .{
        .xkb_context = xkb_context,
        .pamh = pamh,
    };
    defer lock.deinit();

    registry.setListener(*Lock, registry_listener, &lock);
    _ = display.roundtrip() catch |e| fatal("initial roundtrip failed: {s}", .{@errorName(e)});

    if (lock.shm == null) fatal_not_advertised(wl.Shm);
    if (lock.compositor == null) fatal_not_advertised(wl.Compositor);
    if (lock.session_lock_manager == null) fatal_not_advertised(ext.SessionLockManagerV1);

    lock.session_lock = lock.session_lock_manager.?.lock() catch fatal_oom();
    lock.session_lock.?.setListener(*Lock, session_lock_listener, &lock);

    lock.session_lock_manager.?.destroy();
    lock.session_lock_manager = null;

    // From this point onwards we may no longer handle OOM by exiting.
    assert(lock.state == .initializing);
    lock.state = .locking;

    {
        var initial_outputs = lock.outputs;
        lock.outputs = .{};
        while (initial_outputs.popFirst()) |node| {
            node.data.init(&lock, node.data.name, node.data.wl_output) catch {
                log.err("out of memory", .{});
                node.data.wl_output.release();
                gpa.destroy(node);
                return;
            };
            lock.outputs.prepend(node);
        }
    }

    while (lock.state != .exiting) {
        _ = display.dispatch() catch |err| {
            // TODO are there any errors here that we can handle without exiting?
            fatal("wayland display dispatch failed: {s}", .{@errorName(err)});
        };
    }

    // A roundtrip isn't strictly necessary, but we do need to call wl_display_flush() and
    // handle the case where it could not flush all requests. The simplest way to do this
    // using libwayland's API is wl_display_roundtrip() and the slight inefficiency isn't
    // relevant here.
    _ = display.roundtrip() catch |e| fatal("Final roundtrip failed: {s}", .{@errorName(e)});
}

/// Clean up resources just so we can better use tooling such as valgrind to check for leaks.
fn deinit(lock: *Lock) void {
    if (lock.shm) |shm| shm.destroy();
    if (lock.compositor) |compositor| compositor.destroy();
    assert(lock.session_lock_manager == null);
    assert(lock.session_lock == null);

    while (lock.seats.first) |node| node.data.destroy();
    while (lock.outputs.first) |node| node.data.destroy();

    lock.xkb_context.unref();

    assert(lock.password.len == 0);

    lock.* = undefined;
}

fn registry_listener(registry: *wl.Registry, event: wl.Registry.Event, lock: *Lock) void {
    lock.registry_event(registry, event) catch |err| switch (err) {
        error.OutOfMemory => {
            log.err("out of memory", .{});
            return;
        },
    };
}

fn registry_event(lock: *Lock, registry: *wl.Registry, event: wl.Registry.Event) !void {
    switch (event) {
        .global => |ev| {
            if (std.cstr.cmp(ev.interface, wl.Shm.getInterface().name) == 0) {
                lock.shm = try registry.bind(ev.name, wl.Shm, 1);
            } else if (std.cstr.cmp(ev.interface, wl.Compositor.getInterface().name) == 0) {
                // Version 4 required for wl_surface.damage_buffer
                if (ev.version < 4) {
                    fatal("The advertised wl_compositor version is too old. Version 4 is required.", .{});
                }
                lock.compositor = try registry.bind(ev.name, wl.Compositor, 4);
            } else if (std.cstr.cmp(ev.interface, ext.SessionLockManagerV1.getInterface().name) == 0) {
                lock.session_lock_manager = try registry.bind(ev.name, ext.SessionLockManagerV1, 1);
            } else if (std.cstr.cmp(ev.interface, wl.Output.getInterface().name) == 0) {
                // Version 3 required for wl_output.release
                if (ev.version < 3) {
                    fatal("The advertised wl_output version is too old. Version 3 is required.", .{});
                }
                const wl_output = try registry.bind(ev.name, wl.Output, 3);
                errdefer wl_output.release();

                const node = try gpa.create(std.SinglyLinkedList(Output).Node);
                errdefer gpa.destroy(node);

                switch (lock.state) {
                    .initializing => node.data = .{
                        .lock = undefined,
                        .name = ev.name,
                        .wl_output = wl_output,
                        .surface = undefined,
                        .lock_surface = undefined,
                    },
                    .locking, .locked, .exiting => try node.data.init(lock, ev.name, wl_output),
                }

                lock.outputs.prepend(node);
            } else if (std.cstr.cmp(ev.interface, wl.Seat.getInterface().name) == 0) {
                // Version 5 required for wl_seat.release
                if (ev.version < 5) {
                    fatal("The advertised wl_seat version is too old. Version 5 is required.", .{});
                }
                const wl_seat = try registry.bind(ev.name, wl.Seat, 5);
                errdefer wl_seat.release();

                const node = try gpa.create(std.SinglyLinkedList(Seat).Node);
                errdefer gpa.destroy(node);

                node.data.init(lock, wl_seat);
            }
        },
        .global_remove => |ev| {
            var it = lock.outputs.first;
            while (it) |node| : (it = node.next) {
                if (node.data.name == ev.name) {
                    switch (lock.state) {
                        .initializing => {
                            lock.outputs.remove(node);
                            node.data.wl_output.release();
                            gpa.destroy(node);
                        },
                        .locking, .locked, .exiting => node.data.destroy(),
                    }
                    break;
                }
            }
        },
    }
}

fn session_lock_listener(_: *ext.SessionLockV1, event: ext.SessionLockV1.Event, lock: *Lock) void {
    switch (event) {
        .locked => {
            assert(lock.state == .locking);
            lock.state = .locked;
        },
        .finished => {
            switch (lock.state) {
                .initializing => unreachable,
                .locking => {
                    log.err("the wayland compositor has denied our attempt to lock the session, " ++
                        "is another ext-session-lock client already running?", .{});
                    lock.state = .exiting;
                },
                .locked => {
                    log.info("the wayland compositor has unlocked the session, exiting", .{});
                    lock.state = .exiting;
                },
                .exiting => unreachable,
            }
        },
    }
}

pub fn submit_password(lock: *Lock) void {
    assert(lock.state == .locked);

    log.info("starting PAM authentication", .{});

    const auth_result = lock.pamh.authenticate(0);
    lock.clear_password();

    if (auth_result == .success) {
        log.info("PAM authentication succeeded", .{});

        // We don't need to prevent unlocking if this fails. Failure just
        // means that some extra things like Kerberos might not work without
        // user intervention.
        const setcred_result = lock.pamh.setcred(pam.flags.reinitialize_cred);
        if (setcred_result != .success) {
            log.err("PAM failed to reinitialize credentials: {s}", .{
                setcred_result.description(),
            });
        }

        const end_result = lock.pamh.end(setcred_result);
        if (end_result != .success) {
            log.err("PAM deinitialization failed: {s}", .{end_result});
        }

        lock.session_lock.?.unlockAndDestroy();
        lock.session_lock = null;

        lock.state = .exiting;
    } else {
        log.err("PAM authentication failed: {s}", .{auth_result.description()});

        if (auth_result == .abort) {
            const end_result = lock.pamh.end(auth_result);
            if (end_result != .success) {
                log.err("PAM deinitialization failed: {s}", .{end_result});
            }
            os.exit(1);
        }
    }
}

fn converse(
    num_msg: c_int,
    msg: [*]*const pam.Message,
    resp: *[*]pam.Response,
    appdata_ptr: ?*anyopaque,
) callconv(.C) pam.Result {
    const ally = std.heap.raw_c_allocator;
    const lock = @ptrCast(*Lock, @alignCast(@alignOf(Lock), appdata_ptr.?));

    const count = @intCast(usize, num_msg);
    const responses = ally.alloc(pam.Response, count) catch {
        return .buf_err;
    };

    for (msg[0..count]) |message, i| {
        switch (message.msg_style) {
            .prompt_echo_off => {
                const password = ally.dupeZ(u8, lock.password.slice()) catch {
                    return .buf_err;
                };
                responses[i] = .{
                    .resp = password,
                };
            },
            .prompt_echo_on, .error_msg, .text_info => {},
        }
    }

    resp.* = responses.ptr;

    return .success;
}

pub fn clear_password(lock: *Lock) void {
    std.crypto.utils.secureZero(u8, lock.password.slice());
    lock.password.resize(0) catch unreachable;
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    log.err(format, args);
    os.exit(1);
}

fn fatal_oom() noreturn {
    fatal("out of memory during initialization", .{});
}

fn fatal_not_advertised(comptime Global: type) noreturn {
    fatal("{s} not advertised", .{Global.getInterface().name});
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
