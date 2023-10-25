const std = @import("std");
const mem = std.mem;

pub const Flag = struct {
    name: [*:0]const u8,
    kind: enum { boolean, arg },
};

pub fn ParseResult(comptime flags: []const Flag) type {
    return struct {
        const Self = @This();

        const FlagData = struct {
            name: [*:0]const u8,
            value: union {
                boolean: bool,
                arg: ?[*:0]const u8,
            },
        };

        /// Remaining args after the recognized flags
        args: [][*:0]const u8,
        /// Data obtained from parsed flags
        flag_data: [flags.len]FlagData = blk: {
            // Init all flags to false/null
            var flag_data: [flags.len]FlagData = undefined;
            inline for (flags, 0..) |flag, i| {
                flag_data[i] = switch (flag.kind) {
                    .boolean => .{
                        .name = flag.name,
                        .value = .{ .boolean = false },
                    },
                    .arg => .{
                        .name = flag.name,
                        .value = .{ .arg = null },
                    },
                };
            }
            break :blk flag_data;
        },

        pub fn boolFlag(self: Self, flag_name: [*:0]const u8) bool {
            for (self.flag_data) |flag_data| {
                if (mem.orderZ(u8, flag_data.name, flag_name) == .eq) return flag_data.value.boolean;
            }
            unreachable; // Invalid flag_name
        }

        pub fn argFlag(self: Self, flag_name: [*:0]const u8) ?[:0]const u8 {
            for (self.flag_data) |flag_data| {
                if (mem.orderZ(u8, flag_data.name, flag_name) == .eq) {
                    return std.mem.span(flag_data.value.arg);
                }
            }
            unreachable; // Invalid flag_name
        }
    };
}

pub fn parse(args: [][*:0]const u8, comptime flags: []const Flag) !ParseResult(flags) {
    var ret: ParseResult(flags) = .{ .args = undefined };

    var arg_idx: usize = 0;
    while (arg_idx < args.len) : (arg_idx += 1) {
        var parsed_flag = false;
        inline for (flags, 0..) |flag, flag_idx| {
            if (mem.orderZ(u8, flag.name, args[arg_idx]) == .eq) {
                switch (flag.kind) {
                    .boolean => ret.flag_data[flag_idx].value.boolean = true,
                    .arg => {
                        arg_idx += 1;
                        if (arg_idx == args.len) {
                            std.log.err("option '" ++ flag.name ++
                                "' requires an argument but none was provided!", .{});
                            return error.MissingFlagArgument;
                        }
                        ret.flag_data[flag_idx].value.arg = args[arg_idx];
                    },
                }
                parsed_flag = true;
            }
        }
        if (!parsed_flag) break;
    }

    ret.args = args[arg_idx..];

    return ret;
}
