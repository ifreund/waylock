const PasswordBuffer = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const log = std.log;
const heap = std.heap;
const posix = std.posix;

const auth = @import("auth.zig");

const gpa = heap.c_allocator;
pub const size_max = 1024;

buffer: []align(heap.page_size_min) u8,

pub fn init() PasswordBuffer {
    var password: PasswordBuffer = .{
        .buffer = gpa.alignedAlloc(u8, heap.page_size_min, size_max) catch {
            log.err("failed to allocate password buffer", .{});
            posix.exit(1);
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

pub fn pop_codepoint(password: *PasswordBuffer) void {
    if (password.buffer.len == 0) {
        return;
    }

    // Unicode codepoints may be encoded in 1-4 bytes.
    // Check for a 1 byte final codepoint, then a 2 byte, etc.
    for (1..@min(password.buffer.len, 4) + 1) |check_len| {
        const codepoint_bytes = password.buffer[password.buffer.len - check_len ..];
        const actual_len = std.unicode.utf8ByteSequenceLength(codepoint_bytes[0]) catch continue;

        assert(check_len == actual_len);
        std.crypto.utils.secureZero(u8, codepoint_bytes);
        password.buffer.len -= actual_len;
        return;
    }

    // Only valid UTF-8 is written to the buffer.
    unreachable;
}

pub fn clear(password: *PasswordBuffer) void {
    std.crypto.utils.secureZero(u8, password.buffer);
    password.buffer.len = 0;
}

fn prevent_swapping(buffer: []align(heap.page_size_min) const u8) void {
    var attempts: usize = 0;
    while (attempts < 10) : (attempts += 1) {
        const errno = posix.errno(mlock(buffer.ptr, buffer.len));
        switch (errno) {
            .SUCCESS => return,
            .AGAIN => continue,
            else => {
                log.err("mlock() on password buffer failed: E{s}", .{@tagName(errno)});
                posix.exit(1);
            },
        }
    }
    log.err("mlock() on password buffer failed: EAGAIN after 10 attempts", .{});
    posix.exit(1);
}

fn prevent_dumping_best_effort(buffer: []align(heap.page_size_min) u8) void {
    if (builtin.target.os.tag != .linux) return;

    var attempts: usize = 0;
    while (attempts < 10) : (attempts += 1) {
        const errno = posix.errno(std.os.linux.madvise(buffer.ptr, buffer.len, posix.MADV.DONTDUMP));
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
