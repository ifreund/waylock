const Lock = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const log = std.log;
const mem = std.mem;
const posix = std.posix;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const wp = wayland.client.wp;
const ext = wayland.client.ext;

const xkb = @import("xkbcommon");

const auth = @import("auth.zig");

const Output = @import("Output.zig");
const Seat = @import("Seat.zig");
const PasswordBuffer = @import("PasswordBuffer.zig");

const gpa = std.heap.c_allocator;

pub const Color = enum {
    init,
    input,
    input_alt,
    fail,
};

pub const Options = struct {
    fork_on_lock: bool,
    ready_fd: ?posix.fd_t = null,
    ignore_empty_password: bool,
    init_color: u24 = 0x002b36,
    input_color: u24 = 0x6c71c4,
    input_alt_color: u24 = 0x6c71c4,
    fail_color: u24 = 0xdc322f,

    fn rgb(options: Options, color: Color) u24 {
        return switch (color) {
            .init => options.init_color,
            .input => options.input_color,
            .input_alt => options.input_alt_color,
            .fail => options.fail_color,
        };
    }
};

state: enum {
    /// The session lock object has not yet been created.
    initializing,
    /// The session lock object has been created but the locked event has not been received.
    locking,
    /// The compositor has sent the locked event indicating that the session is locked.
    locked,
    /// Gracefully exiting and cleaning up resources. This could happen because the compositor
    /// did not grant waylock's request to lock the screen or because the user or compositor
    /// has unlocked the session.
    exiting,
} = .initializing,

color: Color = .init,

fork_on_lock: bool,
ready_fd: ?posix.fd_t,
ignore_empty_password: bool,

pollfds: [2]posix.pollfd,

display: *wl.Display,
compositor: ?*wl.Compositor = null,
session_lock_manager: ?*ext.SessionLockManagerV1 = null,
session_lock: ?*ext.SessionLockV1 = null,
viewporter: ?*wp.Viewporter = null,
buffer_manager: ?*wp.SinglePixelBufferManagerV1 = null,
buffers: [4]*wl.Buffer,

seats: std.SinglyLinkedList(Seat) = .{},
outputs: std.SinglyLinkedList(Output) = .{},

xkb_context: *xkb.Context,
password: PasswordBuffer,
auth_connection: auth.Connection,

pub fn run(options: Options) void {
    var lock: Lock = .{
        .fork_on_lock = options.fork_on_lock,
        .ready_fd = options.ready_fd,
        .ignore_empty_password = options.ignore_empty_password,
        .pollfds = undefined,
        .display = wl.Display.connect(null) catch |err| {
            fatal("failed to connect to a wayland compositor: {s}", .{@errorName(err)});
        },
        .buffers = undefined,
        .xkb_context = xkb.Context.new(.no_flags) orelse fatal_oom(),
        .password = PasswordBuffer.init(),
        .auth_connection = auth.fork_child() catch |err| {
            fatal("failed to fork child authentication process: {s}", .{@errorName(err)});
        },
    };
    defer lock.deinit();

    const poll_wayland = 0;
    const poll_auth = 1;

    lock.pollfds[poll_wayland] = .{
        .fd = lock.display.getFd(),
        .events = posix.POLL.IN,
        .revents = 0,
    };
    lock.pollfds[poll_auth] = .{
        .fd = lock.auth_connection.read_fd,
        .events = posix.POLL.IN,
        .revents = 0,
    };

    const registry = lock.display.getRegistry() catch fatal_oom();
    defer registry.destroy();
    registry.setListener(*Lock, registry_listener, &lock);

    {
        const errno = lock.display.roundtrip();
        if (errno != .SUCCESS) {
            fatal("initial roundtrip failed: {s}", .{@tagName(errno)});
        }
    }

    if (lock.compositor == null) fatal_not_advertised(wl.Compositor);
    if (lock.session_lock_manager == null) fatal_not_advertised(ext.SessionLockManagerV1);
    if (lock.viewporter == null) fatal_not_advertised(wp.Viewporter);
    if (lock.buffer_manager == null) fatal_not_advertised(wp.SinglePixelBufferManagerV1);

    lock.buffers = create_buffers(lock.buffer_manager.?, options) catch fatal_oom();
    lock.buffer_manager.?.destroy();
    lock.buffer_manager = null;

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

        _ = posix.poll(&lock.pollfds, -1) catch |err| {
            fatal("poll() failed: {s}", .{@errorName(err)});
        };

        if (lock.pollfds[poll_wayland].revents & posix.POLL.IN != 0) {
            const errno = lock.display.readEvents();
            if (errno != .SUCCESS) {
                fatal("error reading wayland events: {s}", .{@tagName(errno)});
            }
        } else {
            lock.display.cancelRead();
        }

        if (lock.pollfds[poll_auth].revents & posix.POLL.IN != 0) {
            const byte = lock.auth_connection.reader().readByte() catch |err| {
                fatal("failed to read response from child authentication process: {s}", .{@errorName(err)});
            };
            switch (byte) {
                @intFromBool(true) => {
                    lock.session_lock.?.unlockAndDestroy();
                    lock.session_lock = null;
                    lock.state = .exiting;
                },
                @intFromBool(false) => {
                    lock.set_color(.fail);
                },
                else => {
                    fatal("unexpected response received from child authentication process: {d}", .{byte});
                },
            }
        }
    }

    // Calling flush_wayland_and_prepare_read() is not sufficient here as we
    // don't want to exit cleanly until the server processes our request to
    // unlock the session. The only way to guarantee this has occurred is
    // through a roundtrip using the wl_display.sync request.
    const errno = lock.display.roundtrip();
    if (errno != .SUCCESS) {
        fatal("final roundtrip failed: E{s}", .{@tagName(errno)});
    }
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
        if (errno != .SUCCESS) {
            fatal("failed to dispatch pending wayland events: E{s}", .{@tagName(errno)});
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
                var wayland_out = [_]posix.pollfd{.{
                    .fd = lock.display.getFd(),
                    .events = posix.POLL.OUT,
                    .revents = 0,
                }};
                _ = posix.poll(&wayland_out, -1) catch |err| {
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

    assert(lock.buffer_manager == null);
    assert(lock.session_lock_manager == null);
    assert(lock.session_lock == null);

    while (lock.seats.first) |node| node.data.destroy();
    while (lock.outputs.first) |node| node.data.destroy();

    lock.display.disconnect();

    lock.xkb_context.unref();

    // There may be further input after submitting a valid password.
    lock.password.clear();

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
            if (mem.orderZ(u8, ev.interface, wl.Compositor.interface.name) == .eq) {
                // Version 4 required for wl_surface.damage_buffer
                if (ev.version < 4) {
                    fatal("advertised wl_compositor version too old, version 4 required", .{});
                }
                lock.compositor = try registry.bind(ev.name, wl.Compositor, 4);
            } else if (mem.orderZ(u8, ev.interface, ext.SessionLockManagerV1.interface.name) == .eq) {
                lock.session_lock_manager = try registry.bind(ev.name, ext.SessionLockManagerV1, 1);
            } else if (mem.orderZ(u8, ev.interface, wl.Output.interface.name) == .eq) {
                // Version 3 required for wl_output.release
                if (ev.version < 3) {
                    fatal("advertised wl_output version too old, version 3 required", .{});
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
            } else if (mem.orderZ(u8, ev.interface, wl.Seat.interface.name) == .eq) {
                // Version 5 required for wl_seat.release
                if (ev.version < 5) {
                    fatal("advertised wl_seat version too old, version 5 required.", .{});
                }
                const wl_seat = try registry.bind(ev.name, wl.Seat, 5);
                errdefer wl_seat.release();

                const node = try gpa.create(std.SinglyLinkedList(Seat).Node);
                errdefer gpa.destroy(node);

                node.data.init(lock, ev.name, wl_seat);
                lock.seats.prepend(node);
            } else if (mem.orderZ(u8, ev.interface, wp.Viewporter.interface.name) == .eq) {
                lock.viewporter = try registry.bind(ev.name, wp.Viewporter, 1);
            } else if (mem.orderZ(u8, ev.interface, wp.SinglePixelBufferManagerV1.interface.name) == .eq) {
                lock.buffer_manager = try registry.bind(ev.name, wp.SinglePixelBufferManagerV1, 1);
            }
        },
        .global_remove => |ev| {
            {
                var it = lock.outputs.first;
                while (it) |node| : (it = node.next) {
                    if (node.data.name == ev.name) {
                        node.data.destroy();
                        break;
                    }
                }
            }
            {
                var it = lock.seats.first;
                while (it) |node| : (it = node.next) {
                    if (node.data.name == ev.name) {
                        node.data.destroy();
                        break;
                    }
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
            if (lock.ready_fd) |ready_fd| {
                const file = std.fs.File{ .handle = ready_fd };
                file.writeAll("\n") catch |err| {
                    log.err("failed to send readiness notification: {s}", .{@errorName(err)});
                    posix.exit(1);
                };
                file.close();
                lock.ready_fd = null;
            }
            if (lock.fork_on_lock) {
                fork_to_background();
                lock.password.protect_after_fork();
            }
        },
        .finished => {
            switch (lock.state) {
                .initializing => unreachable,
                .locking => {
                    log.err("the wayland compositor has denied our attempt to lock the session, " ++
                        "is another ext-session-lock client already running?", .{});
                    posix.exit(1);
                },
                .locked => {
                    log.info("the wayland compositor has unlocked the session, exiting", .{});
                    posix.exit(0);
                },
                .exiting => unreachable,
            }
        },
    }
}

pub fn submit_password(lock: *Lock) void {
    assert(lock.state == .locked);

    if (lock.ignore_empty_password and lock.password.buffer.len == 0) {
        log.info("ignoring submission of empty password", .{});
        return;
    }

    lock.send_password_to_auth() catch |err| {
        fatal("failed to send password to child authentication process: {s}", .{@errorName(err)});
    };
}

fn send_password_to_auth(lock: *Lock) !void {
    defer lock.password.clear();
    const writer = lock.auth_connection.writer();
    try writer.writeInt(u32, @as(u32, @intCast(lock.password.buffer.len)), builtin.cpu.arch.endian());
    try writer.writeAll(lock.password.buffer);
}

pub fn set_color(lock: *Lock, color: Color) void {
    if (lock.color == color) return;

    lock.color = color;

    var it = lock.outputs.first;
    while (it) |node| : (it = node.next) {
        node.data.attach_buffer(lock.buffers[@intFromEnum(lock.color)]);
    }
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    log.err(format, args);
    posix.exit(1);
}

fn fatal_oom() noreturn {
    fatal("out of memory during initialization", .{});
}

fn fatal_not_advertised(comptime Global: type) noreturn {
    fatal("{s} not advertised", .{Global.interface.name});
}

fn create_buffers(
    buffer_manager: *wp.SinglePixelBufferManagerV1,
    options: Options,
) error{OutOfMemory}![4]*wl.Buffer {
    var buffers: [4]*wl.Buffer = undefined;
    for ([_]Color{ .init, .input, .input_alt, .fail }) |color| {
        const rgb = options.rgb(color);
        buffers[@intFromEnum(color)] = try buffer_manager.createU32RgbaBuffer(
            @as(u32, (rgb >> 16) & 0xff) * (0xffff_ffff / 0xff),
            @as(u32, (rgb >> 8) & 0xff) * (0xffff_ffff / 0xff),
            @as(u32, (rgb >> 0) & 0xff) * (0xffff_ffff / 0xff),
            0xffff_ffff,
        );
    }
    return buffers;
}

// TODO: Upstream this to the Zig standard library
extern fn setsid() posix.pid_t;

fn fork_to_background() void {
    const pid = posix.fork() catch |err| fatal("fork failed: {s}", .{@errorName(err)});
    if (pid == 0) {
        // This can't fail as we are the child of a fork() and therefore not
        // a process group leader.
        assert(setsid() != -1);
        // Ensure the working directory is on the root filesystem to avoid potentially
        // blocking some other filesystem from being unmounted.
        posix.chdirZ("/") catch |err| {
            // While this is a nice thing to do, it is not critical to the locking functionality
            // and it is better to allow potentially unlocking the session rather than aborting
            // and leaving the session locked if this fails.
            log.warn("failed to change working directory to / on fork: {s}", .{@errorName(err)});
        };
    } else {
        // Terminate the parent process with a clean exit code.
        posix.exit(0);
    }
}
