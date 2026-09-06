const std = @import("std");

pub const OpType = enum(u8) {
    insert,
    delete,
};
pub const Operation = union(OpType) {
    insert: struct {
        index: usize = 0,
        text: []u8 = undefined,
    },

    delete: struct {
        index: usize = 0,
        length: usize = 0,
    },

    pub fn initInsert(allocator: std.mem.Allocator, index: usize, text: []const u8) !Operation {
        return Operation{ .insert = .{ .index = index, .text = try allocator.dupe(u8, text) } };
    }

    pub fn initDelete(index: usize, length: usize) Operation {
        return Operation{ .delete = .{ .index = index, .length = length } };
    }

    pub fn deinit(self: Operation, allocator: std.mem.Allocator) void {
        switch (self) {
            .insert => |*insert| {
                allocator.free(insert.text);
            },
            .delete => {},
        }
    }

    pub fn clone(self: Operation, allocator: std.mem.Allocator) !Operation {
        return switch (self) {
            .insert => |insert| try Operation.initInsert(allocator, insert.index, insert.text),
            .delete => |delete| Operation.initDelete(delete.index, delete.length),
        };
    }
};

test "an insert operation preserves its index and copied text" {
    var operation = try Operation.initInsert(std.testing.allocator, 3, "hello");
    defer operation.deinit(std.testing.allocator);

    switch (operation) {
        .insert => |insert| {
            try std.testing.expectEqual(@as(usize, 3), insert.index);
            try std.testing.expectEqualStrings("hello", insert.text);
        },
        .delete => return error.ExpectedInsert,
    }
}

test "an insert owns a copy rather than the caller's buffer" {
    var source = [_]u8{ 'h', 'i' };
    var operation = try Operation.initInsert(std.testing.allocator, 0, source[0..]);
    defer operation.deinit(std.testing.allocator);

    source[0] = 'x';

    switch (operation) {
        .insert => |insert| try std.testing.expectEqualStrings("hi", insert.text),
        .delete => return error.ExpectedInsert,
    }
}

test "a delete operation preserves its index and length" {
    var operation = Operation.initDelete(4, 2);
    defer operation.deinit(std.testing.allocator);

    switch (operation) {
        .insert => return error.ExpectedDelete,
        .delete => |delete| {
            try std.testing.expectEqual(@as(usize, 4), delete.index);
            try std.testing.expectEqual(@as(usize, 2), delete.length);
        },
    }
}

test "an empty insert is allowed and still has an owned text value" {
    var operation = try Operation.initInsert(std.testing.allocator, 0, "");
    defer operation.deinit(std.testing.allocator);

    switch (operation) {
        .insert => |insert| try std.testing.expectEqualStrings("", insert.text),
        .delete => return error.ExpectedInsert,
    }
}

test "clone duplicates an insert's owned text" {
    var original = try Operation.initInsert(std.testing.allocator, 1, "hi");
    defer original.deinit(std.testing.allocator);

    var copy = try original.clone(std.testing.allocator);
    defer copy.deinit(std.testing.allocator);

    switch (copy) {
        .insert => |insert| {
            try std.testing.expectEqual(@as(usize, 1), insert.index);
            try std.testing.expectEqualStrings("hi", insert.text);
        },
        .delete => return error.ExpectedInsert,
    }
}

test "clone keeps insert text independent" {
    var original = try Operation.initInsert(std.testing.allocator, 0, "hi");
    defer original.deinit(std.testing.allocator);

    var copy = try original.clone(std.testing.allocator);
    defer copy.deinit(std.testing.allocator);

    switch (original) {
        .insert => |*insert| insert.text[0] = 'x',
        .delete => return error.ExpectedInsert,
    }

    switch (copy) {
        .insert => |insert| try std.testing.expectEqualStrings("hi", insert.text),
        .delete => return error.ExpectedInsert,
    }
}

test "clone preserves a delete without payload text" {
    const original = Operation.initDelete(4, 2);
    var copy = try original.clone(std.testing.allocator);
    defer copy.deinit(std.testing.allocator);

    switch (copy) {
        .insert => return error.ExpectedDelete,
        .delete => |delete| {
            try std.testing.expectEqual(@as(usize, 4), delete.index);
            try std.testing.expectEqual(@as(usize, 2), delete.length);
        },
    }
}
