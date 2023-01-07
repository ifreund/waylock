const PasswordBuffer = @This();

const std = @import("std");
const builtin = @import("builtin");
const log = std.log;
const mem = std.mem;
const os = std.os;

const auth = @import("auth.zig");

const gpa = std.heap.c_allocator;
pub const size_max = 1024;

buffer: []align(mem.page_size) u8,

pub fn init() PasswordBuffer {
    var password: PasswordBuffer = .{
        .buffer = gpa.alignedAlloc(u8, mem.page_size, size_max) catch {
            log.err("failed to allocate password buffer", .{});
            os.exit(1);
        },
    };

    prevent_swapping(password.buffer);
    prevent_dumping_best_effort(password.buffer);

    password.buffer.len = 0;
    return password;
}

pub fn protect_after_fork(password: *PasswordBuffer) void {
    prevent_swapping(password.buffer);
    prevent_dumping_best_effort(password.buffer);
}

pub fn unused_slice(password: PasswordBuffer) []u8 {
    return password.buffer.ptr[password.buffer.len..size_max];
}

pub fn grow(password: *PasswordBuffer, delta: usize) error{Overflow}!void {
    if (password.buffer.len + delta > size_max) {
        return error.Overflow;
    }
    password.buffer.len += delta;
}

pub fn clear(password: *PasswordBuffer) void {
    std.crypto.utils.secureZero(u8, password.buffer);
    password.buffer.len = 0;
}

fn prevent_swapping(buffer: []align(mem.page_size) const u8) void {
    var attempts: usize = 0;
    while (attempts < 10) : (attempts += 1) {
        const errno = os.errno(mlock(buffer.ptr, buffer.len));
        switch (errno) {
            .SUCCESS => return,
            .AGAIN => continue,
            else => {
                log.err("mlock() on password buffer failed: E{s}", .{@tagName(errno)});
                os.exit(1);
            },
        }
    }
    log.err("mlock() on password buffer failed: EAGAIN after 10 attempts", .{});
    os.exit(1);
}

fn prevent_dumping_best_effort(buffer: []align(mem.page_size) u8) void {
    if (builtin.target.os.tag != .linux) return;

    var attempts: usize = 0;
    while (attempts < 10) : (attempts += 1) {
        const errno = os.errno(os.system.madvise(buffer.ptr, buffer.len, os.MADV.DONTDUMP));
        switch (errno) {
            .SUCCESS => return,
            .AGAIN => continue,
            else => {
                log.warn("madvise() on password buffer failed: E{s}", .{@tagName(errno)});
                return;
            },
        }
    }
    log.warn("madvise() on password buffer failed: EAGAIN after 10 attempts", .{});
}

// TODO: Upstream this to the Zig standard library
extern fn mlock(addr: *const anyopaque, len: usize) c_int;
