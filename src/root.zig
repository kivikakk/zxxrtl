const std = @import("std");

const c = @cImport({
    @cInclude("cxxrtl/capi/cxxrtl_capi.h");
    @cInclude("cxxrtl/capi/cxxrtl_capi_vcd.h");
});

extern "c" fn cxxrtl_design_create() c.cxxrtl_toplevel;

const Cxxrtl = @This();

handle: c.cxxrtl_handle,

pub fn init() Cxxrtl {
    return .{
        .handle = c.cxxrtl_create(cxxrtl_design_create()),
    };
}

pub fn get(self: Cxxrtl, comptime T: type, name: [:0]const u8) Object(T) {
    return self.find(T, name) orelse std.debug.panic("object not found: {s}", .{name});
}

pub fn find(self: Cxxrtl, comptime T: type, name: [:0]const u8) ?Object(T) {
    if (c.cxxrtl_get(self.handle, name)) |handle| {
        return Object(T){ .object = handle };
    } else {
        return null;
    }
}

pub fn step(self: Cxxrtl) void {
    _ = c.cxxrtl_step(self.handle);
}

pub fn deinit(self: Cxxrtl) void {
    c.cxxrtl_destroy(self.handle);
}

pub fn Object(comptime T: type) type {
    return struct {
        const Self = @This();

        object: *c.cxxrtl_object,

        pub fn curr(self: Self) T {
            if (T == bool) {
                return self.object.*.curr[0] == 1;
            } else {
                return @as(T, @intCast(self.object.*.curr[0]));
            }
        }

        pub fn next(self: Self, value: T) void {
            if (T == bool) {
                self.object.*.next[0] = @as(u32, @intFromBool(value));
            } else {
                self.object.*.next[0] = @as(u32, value);
            }
        }
    };
}

pub const Vcd = struct {
    handle: c.cxxrtl_vcd,
    time: u64,

    pub fn init(cxxrtl: Cxxrtl) Vcd {
        const handle = c.cxxrtl_vcd_create();
        c.cxxrtl_vcd_add_from(handle, cxxrtl.handle);
        return .{
            .handle = handle,
            .time = 0,
        };
    }

    pub fn deinit(self: *Vcd) void {
        c.cxxrtl_vcd_destroy(self.handle);
    }

    pub fn sample(self: *Vcd) void {
        self.time += 1;
        c.cxxrtl_vcd_sample(self.handle, self.time);
    }

    pub fn read(self: *Vcd, allocator: std.mem.Allocator) ![]u8 {
        var data: [*c]const u8 = undefined;
        var size: usize = undefined;

        var buffer = std.ArrayList(u8).init(allocator);
        errdefer buffer.deinit();

        while (true) {
            c.cxxrtl_vcd_read(self.handle, &data, &size);
            if (size == 0) {
                break;
            }

            try buffer.appendSlice(data[0..size]);
        }

        return try buffer.toOwnedSlice();
    }
};

pub fn Sample(comptime T: type) type {
    return struct {
        const Self = @This();

        object: Object(T),
        prev: T,
        curr: T,

        pub fn init(cxxrtl: Cxxrtl, name: [:0]const u8, start: T) Self {
            return .{
                .object = cxxrtl.get(T, name),
                .prev = start,
                .curr = start,
            };
        }

        pub fn tick(self: *Self) *Self {
            self.prev = self.curr;
            self.curr = self.object.curr();
            return self;
        }

        pub fn debug(self: *Self, name: []const u8) *Self {
            if (self.prev != self.curr) {
                std.debug.print("{s}: {}\n", .{ name, self });
            }
            return self;
        }

        pub inline fn stable(self: Self) bool {
            return self.curr == self.prev;
        }

        pub fn format(self: Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
            _ = options;
            _ = fmt;
            if (self.prev != self.curr) {
                return std.fmt.format(writer, "{} -> {}", .{ self.prev, self.curr });
            } else {
                return std.fmt.format(writer, "{}", .{self.curr});
            }
        }

        pub usingnamespace if (T == bool) struct {
            pub inline fn stable_high(self: Self) bool {
                return self.prev and self.curr;
            }

            pub inline fn stable_low(self: Self) bool {
                return !self.prev and !self.curr;
            }

            pub inline fn falling(self: Self) bool {
                return self.prev and !self.curr;
            }

            pub inline fn rising(self: Self) bool {
                return !self.prev and self.curr;
            }
        } else struct {};
    };
}
