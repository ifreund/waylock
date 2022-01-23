const Output = @This();

const std = @import("std");
const log = std.log;
const math = std.math;
const mem = std.mem;
const os = std.os;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const ext = wayland.client.ext;

const Lock = @import("Lock.zig");

const gpa = std.heap.c_allocator;

lock: *Lock,
// TODO refactor this away
name: u32,
wl_output: *wl.Output,
surface: *wl.Surface,
lock_surface: *ext.SessionLockSurfaceV1,

pub fn init(output: *Output, lock: *Lock, name: u32, wl_output: *wl.Output) !void {
    const surface = try lock.compositor.?.createSurface();
    errdefer surface.destroy();

    const lock_surface = try lock.session_lock.?.getLockSurface(surface, wl_output);
    lock_surface.setListener(*Output, lock_surface_listener, output);

    output.* = .{
        .lock = lock,
        .name = name,
        .wl_output = wl_output,
        .surface = surface,
        .lock_surface = lock_surface,
    };
}

pub fn destroy(output: *Output) void {
    output.wl_output.destroy();
    output.surface.destroy();
    output.lock_surface.destroy();

    const node = @fieldParentPtr(std.SinglyLinkedList(Output).Node, "data", output);
    output.lock.outputs.remove(node);
    gpa.destroy(node);
}

fn lock_surface_listener(
    _: *ext.SessionLockSurfaceV1,
    event: ext.SessionLockSurfaceV1.Event,
    output: *Output,
) void {
    switch (event) {
        .configure => |ev| {
            const buffer = output.create_buffer(ev.width, ev.height, 0xff002b36) catch |err| {
                log.err("failed to create buffer: {s}", .{@errorName(err)});
                output.destroy();
                return;
            };
            defer buffer.destroy();

            output.lock_surface.ackConfigure(ev.serial);
            output.surface.attach(buffer, 0, 0);
            output.surface.damageBuffer(0, 0, math.maxInt(i32), math.maxInt(i32));
            output.surface.commit();
        },
    }
}

// TODO manage buffers more efficiently with a nice abstraction that allows for re-use.
fn create_buffer(output: *Output, width: u32, height: u32, argb: u32) !*wl.Buffer {
    const stride = width * 4;
    const size = stride * height;

    // TODO support non-linux systems
    const fd = try os.memfd_create("waylock-shm-buffer-pool", os.linux.MFD_CLOEXEC);
    defer os.close(fd);

    try os.ftruncate(fd, size);
    const data = try os.mmap(null, size, os.PROT.READ | os.PROT.WRITE, os.MAP.SHARED, fd, 0);
    mem.set(u32, mem.bytesAsSlice(u32, data), argb);

    const pool = try output.lock.shm.?.createPool(fd, @intCast(i32, size));
    defer pool.destroy();

    return try pool.createBuffer(
        0,
        @intCast(i32, width),
        @intCast(i32, height),
        @intCast(i32, stride),
        wl.Shm.Format.argb8888,
    );
}
