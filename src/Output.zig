const Output = @This();

const std = @import("std");
const log = std.log;
const math = std.math;
const mem = std.mem;
const os = std.os;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const wp = wayland.client.wp;
const ext = wayland.client.ext;

const Lock = @import("Lock.zig");
const Color = Lock.Color;

const gpa = std.heap.c_allocator;

lock: *Lock,
name: u32,
wl_output: *wl.Output,
surface: ?*wl.Surface = null,
viewport: ?*wp.Viewport = null,
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

    output.viewport = try output.lock.viewporter.?.getViewport(surface);
}

pub fn destroy(output: *Output) void {
    output.wl_output.release();
    if (output.viewport) |viewport| viewport.destroy();
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
    const lock = output.lock;
    switch (event) {
        .configure => |ev| {
            output.width = ev.width;
            output.height = ev.height;
            output.lock_surface.?.ackConfigure(ev.serial);
            output.attach_buffer(lock.buffer[@enumToInt(lock.color)].?);
        },
    }
}

pub fn attach_buffer(output: *Output, buffer: *wl.Buffer) void {
    output.surface.?.attach(buffer, 0, 0);
    output.surface.?.damageBuffer(0, 0, math.maxInt(i32), math.maxInt(i32));
    output.viewport.?.setDestination(
        @intCast(i32, output.width),
        @intCast(i32, output.height),
    );
    output.surface.?.commit();
}
