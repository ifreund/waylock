const Lock = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const log = std.log;
const mem = std.mem;
const os = std.os;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const wp = wayland.client.wp;
const ext = wayland.client.ext;

const xkb = @import("xkbcommon");

const auth = @import("auth.zig");

const Output = @import("Output.zig");
const Seat = @import("Seat.zig");

const gpa = std.heap.c_allocator;

pub const Color = enum {
    init,
    input,
    fail,
};

pub const Options = struct {
    init_color: u32 = 0xff002b36,
    input_color: u32 = 0xff6c71c4,
    fail_color: u32 = 0xffdc322f,

    fn argb(options: Options, color: Color) u32 {
        return switch (color) {
            .init => options.init_color,
            .input => options.input_color,
            .fail => options.fail_color,
        };
    }
};

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

color: Color = .init,

pollfds: [2]os.pollfd,

display: *wl.Display,
shm: ?*wl.Shm = null,
compositor: ?*wl.Compositor = null,
session_lock_manager: ?*ext.SessionLockManagerV1 = null,
session_lock: ?*ext.SessionLockV1 = null,
viewporter: ?*wp.Viewporter = null,
buffers: [3]*wl.Buffer,

seats: std.SinglyLinkedList(Seat) = .{},
outputs: std.SinglyLinkedList(Output) = .{},

xkb_context: *xkb.Context,
password: std.BoundedArray(u8, auth.password_size_max) = .{ .buffer = undefined },
auth_connection: auth.Connection,

pub fn run(options: Options) void {
    var lock: Lock = .{
        .pollfds = undefined,
        .display = wl.Display.connect(null) catch |err| {
            fatal("failed to connect to a wayland compositor: {s}", .{@errorName(err)});
        },
        .xkb_context = xkb.Context.new(.no_flags) orelse fatal_oom(),
        .auth_connection = auth.fork_child() catch |err| {
            fatal("failed to fork child authentication process: {s}", .{@errorName(err)});
        },
        .buffers = undefined,
    };
    defer lock.deinit();

    const poll_wayland = 0;
    const poll_auth = 1;

    lock.pollfds[poll_wayland] = .{
        .fd = lock.display.getFd(),
        .events = os.POLL.IN,
        .revents = 0,
    };
    lock.pollfds[poll_auth] = .{
        .fd = lock.auth_connection.read_fd,
        .events = os.POLL.IN,
        .revents = 0,
    };

    const registry = lock.display.getRegistry() catch fatal_oom();
    defer registry.destroy();
    registry.setListener(*Lock, registry_listener, &lock);

    {
        const errno = lock.display.roundtrip();
        switch (errno) {
            .SUCCESS => {},
            else => {
                fatal("initial roundtrip failed: {s}", .{@tagName(errno)});
            },
        }
    }

    if (lock.shm == null) fatal_not_advertised(wl.Shm);
    if (lock.compositor == null) fatal_not_advertised(wl.Compositor);
    if (lock.session_lock_manager == null) fatal_not_advertised(ext.SessionLockManagerV1);
    if (lock.viewporter == null) fatal_not_advertised(wp.Viewporter);

    lock.buffers = create_buffers(lock.shm.?, options) catch |err| {
        fatal("failed to create buffers: {s}", .{@errorName(err)});
    };
    lock.shm.?.destroy();
    lock.shm = null;

    lock.session_lock = lock.session_lock_manager.?.lock() catch fatal_oom();
    lock.session_lock.?.setListener(*Lock, session_lock_listener, &lock);

    lock.session_lock_manager.?.destroy();
    lock.session_lock_manager = null;

    // From this point onwards we may no longer handle OOM by exiting.
    assert(lock.state == .initializing);
    lock.state = .locking;

    {
        var it = lock.outputs.first;
        while (it) |node| {
            // Do this up front in case the node gets removed.
            it = node.next;
            node.data.create_surface() catch {
                log.err("out of memory", .{});
                // Removes the node from the list.
                node.data.destroy();
                continue;
            };
        }
    }

    while (lock.state != .exiting) {
        lock.flush_wayland_and_prepare_read();

        _ = os.poll(&lock.pollfds, -1) catch |err| {
            fatal("poll() failed: {s}", .{@errorName(err)});
        };

        if (lock.pollfds[poll_wayland].revents & os.POLL.IN != 0) {
            const errno = lock.display.readEvents();
            switch (errno) {
                .SUCCESS => {},
                else => {
                    fatal("error reading wayland events: {s}", .{@tagName(errno)});
                },
            }
        } else {
            lock.display.cancelRead();
        }

        if (lock.pollfds[poll_auth].revents & os.POLL.IN != 0) {
            const byte = lock.auth_connection.reader().readByte() catch |err| {
                fatal("failed to read response from child authentication process: {s}", .{@errorName(err)});
            };
            switch (byte) {
                @boolToInt(true) => {
                    lock.session_lock.?.unlockAndDestroy();
                    lock.session_lock = null;
                    lock.state = .exiting;
                },
                @boolToInt(false) => {
                    lock.set_color(.fail);
                },
                else => {
                    fatal("unexpected response recieved from child authentication process: {d}", .{byte});
                },
            }
        } else if (lock.pollfds[poll_auth].revents & os.POLL.HUP != 0) {
            fatal("child authentication process exited unexpectedly", .{});
        }
    }

    lock.flush_wayland_and_prepare_read();
}

/// This function does the following:
///  1. Dispatch buffered wayland events to their listener callbacks.
///  2. Prepare the wayland connection for reading.
///  3. Send all buffered wayland requests to the server.
/// After this function has been called, either wl.Display.readEvents() or
/// wl.Display.cancelRead() read must be called.
fn flush_wayland_and_prepare_read(lock: *Lock) void {
    while (!lock.display.prepareRead()) {
        const errno = lock.display.dispatchPending();
        switch (errno) {
            .SUCCESS => {},
            else => {
                fatal("failed to dispatch pending wayland events: E{s}", .{@tagName(errno)});
            },
        }
    }

    while (true) {
        const errno = lock.display.flush();
        switch (errno) {
            .SUCCESS => return,
            .PIPE => {
                // libwayland uses this error to indicate that the wayland server
                // closed its side of the wayland socket. We want to continue to
                // read any buffered messages from the server though as there is
                // likely a protocol error message we'd like libwayland to log.
                _ = lock.display.readEvents();
                fatal("connection to wayland server unexpectedly terminated", .{});
            },
            .AGAIN => {
                // The socket buffer is full, so wait for it to become writable again.
                var wayland_out = [_]os.pollfd{.{
                    .fd = lock.display.getFd(),
                    .events = os.POLL.OUT,
                    .revents = 0,
                }};
                _ = os.poll(&wayland_out, -1) catch |err| {
                    fatal("poll() failed: {s}", .{@errorName(err)});
                };
                // No need to check for POLLHUP/POLLERR here, just fall
                // through to the next flush() to handle them in one place.
            },
            else => {
                fatal("failed to flush wayland requests: E{s}", .{@tagName(errno)});
            },
        }
    }
}

/// Clean up resources just so we can better use tooling such as valgrind to check for leaks.
fn deinit(lock: *Lock) void {
    if (lock.compositor) |compositor| compositor.destroy();
    if (lock.viewporter) |viewporter| viewporter.destroy();
    for (lock.buffers) |buffer| buffer.destroy();

    assert(lock.shm == null);
    assert(lock.session_lock_manager == null);
    assert(lock.session_lock == null);

    while (lock.seats.first) |node| node.data.destroy();
    while (lock.outputs.first) |node| node.data.destroy();

    lock.display.disconnect();

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
                errdefer node.data.destroy();

                node.data = .{
                    .lock = lock,
                    .name = ev.name,
                    .wl_output = wl_output,
                };
                lock.outputs.prepend(node);

                switch (lock.state) {
                    .initializing, .exiting => {},
                    .locking, .locked => try node.data.create_surface(),
                }
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
                lock.seats.prepend(node);
            } else if (std.cstr.cmp(ev.interface, wp.Viewporter.getInterface().name) == 0) {
                lock.viewporter = try registry.bind(ev.name, wp.Viewporter, 1);
            }
        },
        .global_remove => |ev| {
            var it = lock.outputs.first;
            while (it) |node| : (it = node.next) {
                if (node.data.name == ev.name) {
                    node.data.destroy();
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

    lock.send_password_to_auth() catch |err| {
        fatal("failed to send password to child authentication process: {s}", .{@errorName(err)});
    };
}

fn send_password_to_auth(lock: *Lock) !void {
    defer lock.clear_password();
    const writer = lock.auth_connection.writer();
    try writer.writeIntNative(u32, @intCast(u32, lock.password.len));
    try writer.writeAll(lock.password.slice());
}

pub fn clear_password(lock: *Lock) void {
    std.crypto.utils.secureZero(u8, &lock.password.buffer);
    lock.password.len = 0;
}

pub fn set_color(lock: *Lock, color: Color) void {
    if (lock.color == color) return;

    lock.color = color;

    var it = lock.outputs.first;
    while (it) |node| : (it = node.next) {
        node.data.attach_buffer(lock.buffers[@enumToInt(lock.color)]);
    }
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

/// Create 3 1x1 buffers backed by the same shared memory
fn create_buffers(shm: *wl.Shm, options: Options) ![3]*wl.Buffer {
    const shm_size = 3 * @sizeOf(u32);

    const fd = try shm_fd_create();
    defer os.close(fd);

    try os.ftruncate(fd, shm_size);

    const pool = try shm.createPool(fd, shm_size);
    defer pool.destroy();

    const backing_memory = mem.bytesAsSlice(
        u32,
        try os.mmap(null, shm_size, os.PROT.READ | os.PROT.WRITE, os.MAP.SHARED, fd, 0),
    );

    var buffers: [3]*wl.Buffer = undefined;
    for ([_]Color{ .init, .input, .fail }) |color| {
        const i: u31 = @enumToInt(color);
        backing_memory[i] = options.argb(color);
        buffers[i] = try pool.createBuffer(i * @sizeOf(u32), 1, 1, @sizeOf(u32), .argb8888);
    }

    return buffers;
}

fn shm_fd_create() !os.fd_t {
    switch (builtin.target.os.tag) {
        .linux => {
            return os.memfd_createZ("waylock-shm", os.linux.MFD_CLOEXEC);
        },
        .freebsd => {
            // TODO upstream this to the zig standard library
            const freebsd = struct {
                const MFD_CLOEXEC = 1;
                extern fn memfd_create(name: [*:0]const u8, flags: c_uint) c_int;
            };

            const ret = freebsd.memfd_create("waylock-shm", freebsd.MFD_CLOEXEC);
            switch (os.errno(ret)) {
                .SUCCESS => return ret,
                .BADF => unreachable,
                .INVAL => unreachable,
                .NFILE => return error.SystemFdQuotaExceeded,
                .MFILE => return error.ProcessFdQuotaExceeded,
                else => |err| return os.unexpectedErrno(err),
            }
        },
        else => @compileError("Target OS not supported"),
    }
}
