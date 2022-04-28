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
name: u32,
wl_output: *wl.Output,
surface: ?*wl.Surface = null,
lock_surface: ?*ext.SessionLockSurfaceV1 = null,

// These fields are not used before the first configure is received.
width: u32 = undefined,
height: u32 = undefined,

pub fn create_surface(output: *Output) !void {
    const surface = try output.lock.compositor.?.createSurface();
    output.surface = surface;

    const lock_surface = try output.lock.session_lock.?.getLockSurface(surface, output.wl_output);
    lock_surface.setListener(*Output, lock_surface_listener, output);
    output.lock_surface = lock_surface;
}

pub fn destroy(output: *Output) void {
    output.wl_output.release();
    if (output.surface) |surface| surface.destroy();
    if (output.lock_surface) |lock_surface| lock_surface.destroy();

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
            output.width = ev.width;
            output.height = ev.height;
            output.lock_surface.?.ackConfigure(ev.serial);
            output.attach_buffer(output.lock.color.argb()) catch |err| {
                log.err("failed to create buffer: {s}", .{@errorName(err)});
                output.destroy();
                return;
            };
        },
    }
}

pub fn attach_buffer(output: *Output, argb: u32) !void {
    if (output.lock_surface == null) return;

    const buffer = try output.create_buffer(output.width, output.height, argb);
    defer buffer.destroy();
    output.surface.?.attach(buffer, 0, 0);
    output.surface.?.damageBuffer(0, 0, math.maxInt(i32), math.maxInt(i32));
    output.surface.?.commit();
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
