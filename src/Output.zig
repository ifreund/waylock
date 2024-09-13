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

const gpa = std.heap.c_allocator;

lock: *Lock,
name: u32,
wl_output: *wl.Output,
surface: ?*wl.Surface = null,
viewport: ?*wp.Viewport = null,
lock_surface: ?*ext.SessionLockSurfaceV1 = null,

configured: bool = false,
// These fields are not used before the first configure is received.
width: u31 = undefined,
height: u31 = undefined,

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
    if (output.lock_surface) |lock_surface| lock_surface.destroy();
    if (output.surface) |surface| surface.destroy();

    const node: *std.SinglyLinkedList(Output).Node = @fieldParentPtr("data", output);
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
            output.configured = true;
            output.width = @min(std.math.maxInt(u31), ev.width);
            output.height = @min(std.math.maxInt(u31), ev.height);
            output.lock_surface.?.ackConfigure(ev.serial);
            output.attach_buffer(lock.buffers[@intFromEnum(lock.color)]);
        },
    }
}

pub fn attach_buffer(output: *Output, buffer: *wl.Buffer) void {
    if (!output.configured) return;
    output.surface.?.attach(buffer, 0, 0);
    output.surface.?.damageBuffer(0, 0, math.maxInt(i32), math.maxInt(i32));
    output.viewport.?.setDestination(output.width, output.height);
    output.surface.?.commit();
}
