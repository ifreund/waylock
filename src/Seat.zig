const Seat = @This();

const std = @import("std");
const log = std.log;
const os = std.os;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const ext = wayland.client.ext;

const xkb = @import("xkbcommon");

const Lock = @import("Lock.zig");

const gpa = std.heap.c_allocator;

lock: *Lock,
name: u32,
wl_seat: *wl.Seat,
wl_pointer: ?*wl.Pointer = null,
wl_keyboard: ?*wl.Keyboard = null,
xkb_state: ?*xkb.State = null,

pub fn init(seat: *Seat, lock: *Lock, name: u32, wl_seat: *wl.Seat) void {
    seat.* = .{
        .lock = lock,
        .name = name,
        .wl_seat = wl_seat,
    };

    wl_seat.setListener(*Seat, seat_listener, seat);
}

pub fn destroy(seat: *Seat) void {
    seat.wl_seat.release();
    if (seat.wl_pointer) |wl_pointer| wl_pointer.release();
    if (seat.wl_keyboard) |wl_keyboard| wl_keyboard.release();
    if (seat.xkb_state) |xkb_state| xkb_state.unref();

    const node = @fieldParentPtr(std.SinglyLinkedList(Seat).Node, "data", seat);
    seat.lock.seats.remove(node);
    gpa.destroy(node);
}

fn seat_listener(wl_seat: *wl.Seat, event: wl.Seat.Event, seat: *Seat) void {
    switch (event) {
        .name => {},
        .capabilities => |ev| {
            if (ev.capabilities.pointer and seat.wl_pointer == null) {
                seat.wl_pointer = wl_seat.getPointer() catch {
                    log.err("failed to allocate memory for wl_pointer object", .{});
                    return;
                };
                seat.wl_pointer.?.setListener(?*anyopaque, pointer_listener, null);
            } else if (!ev.capabilities.pointer and seat.wl_pointer != null) {
                seat.wl_pointer.?.release();
                seat.wl_pointer = null;
            }

            if (ev.capabilities.keyboard and seat.wl_keyboard == null) {
                seat.wl_keyboard = wl_seat.getKeyboard() catch {
                    log.err("failed to allocate memory for wl_keyboard object", .{});
                    return;
                };
                seat.wl_keyboard.?.setListener(*Seat, keyboard_listener, seat);
            } else if (!ev.capabilities.keyboard and seat.wl_keyboard != null) {
                seat.wl_keyboard.?.release();
                seat.wl_keyboard = null;
            }
        },
    }
}

fn pointer_listener(wl_pointer: *wl.Pointer, event: wl.Pointer.Event, _: ?*anyopaque) void {
    switch (event) {
        .enter => |ev| {
            // Hide the cursor when it enters any surface of this client.
            wl_pointer.setCursor(ev.serial, null, 0, 0);
        },
        else => {},
    }
}

fn keyboard_listener(_: *wl.Keyboard, event: wl.Keyboard.Event, seat: *Seat) void {
    switch (event) {
        .enter => {
            // It doesn't matter which surface gains keyboard focus or what keys are
            // currently pressed. We don't implement key repeat for simiplicity.
        },
        .leave => {
            // There's nothing to do as we don't implement key repeat and
            // only care about press events, not release.
        },
        .keymap => |ev| {
            defer os.close(ev.fd);

            if (ev.format != .xkb_v1) {
                log.err("unsupported keymap format {d}", .{@intFromEnum(ev.format)});
                return;
            }

            const keymap_string = os.mmap(null, ev.size, os.PROT.READ, os.MAP.PRIVATE, ev.fd, 0) catch |err| {
                log.err("failed to mmap() keymap fd: {s}", .{@errorName(err)});
                return;
            };
            defer os.munmap(keymap_string);

            const keymap = xkb.Keymap.newFromBuffer(
                seat.lock.xkb_context,
                keymap_string.ptr,
                // The string is 0 terminated
                keymap_string.len - 1,
                .text_v1,
                .no_flags,
            ) orelse {
                log.err("failed to parse xkb keymap", .{});
                return;
            };
            defer keymap.unref();

            const state = xkb.State.new(keymap) orelse {
                log.err("failed to create xkb state", .{});
                return;
            };
            defer state.unref();

            if (seat.xkb_state) |s| s.unref();
            seat.xkb_state = state.ref();
        },
        .modifiers => |ev| {
            if (seat.xkb_state) |xkb_state| {
                _ = xkb_state.updateMask(
                    ev.mods_depressed,
                    ev.mods_latched,
                    ev.mods_locked,
                    0,
                    0,
                    ev.group,
                );
            }
        },
        .key => |ev| {
            if (ev.state != .pressed) return;
            if (seat.lock.state == .exiting) return;

            const xkb_state = seat.xkb_state orelse return;

            // The wayland protocol gives us an input event code. To convert this to an xkb
            // keycode we must add 8.
            const keycode = ev.key + 8;

            const keysym = xkb_state.keyGetOneSym(keycode);
            if (keysym == .NoSymbol) return;

            const lock = seat.lock;
            switch (@intFromEnum(keysym)) {
                xkb.Keysym.Return => {
                    // Ignore the attempt to submit the password if the locked event has not yet
                    // been received. This should be pretty much impossible to happen in practice
                    // as the compositor should send the locked event in a matter of milliseconds.
                    // However if the compositor is behaving strangely it is better to ignore this
                    // than crash on an assertion failure or commit a protocol error.
                    if (lock.state == .locked) {
                        lock.submit_password();
                    }
                    return;
                },
                xkb.Keysym.Escape => {
                    lock.password.clear();
                    lock.set_color(.init);
                    return;
                },
                xkb.Keysym.u => {
                    const Component = xkb.State.Component;
                    const ctrl_active = xkb_state.modNameIsActive(
                        xkb.names.mod.ctrl,
                        @enumFromInt(Component.mods_depressed | Component.mods_latched),
                    ) == 1;

                    if (ctrl_active) {
                        lock.password.clear();
                        lock.set_color(.init);
                        return;
                    }
                },
                else => {},
            }
            // If key was not handled, write to password buffer
            const delta = xkb_state.keyGetUtf8(keycode, lock.password.unused_slice());
            if (delta > 0) {
                lock.set_color(.input);
            }
            lock.password.grow(delta) catch log.err("password exceeds 1024 byte limit", .{});
        },
        .repeat_info => {},
    }
}
