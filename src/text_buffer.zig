const std = @import("std");

pub const TextBuffer = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) !*TextBuffer {
        const self = try allocator.create(TextBuffer);
        self.* = .{ .allocator = allocator };
        return self;
    }

    pub fn deinit(self: *TextBuffer) void {
        self.bytes.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn slice(self: *TextBuffer) []const u8 {
        return self.bytes.items;
    }

    pub fn insert(self: *TextBuffer, index: usize, text: []const u8) !void {
        _ = try std.unicode.Utf8View.init(text);
        const bytes_view = try std.unicode.Utf8View.init(self.bytes.items);
        var it = bytes_view.iterator();
        var scalar_position: usize = 0;
        var byte_offset: usize = 0;
        while (scalar_position < index) {
            _ = it.nextCodepoint() orelse break;
            scalar_position += 1;
            byte_offset = it.i;
        }
        if (scalar_position < index) return error.IndexOutOfBounds;

        try self.bytes.insertSlice(self.allocator, byte_offset, text);
    }

    pub fn delete(self: *TextBuffer, index: usize, length: usize) !void {
        const bytes_view = try std.unicode.Utf8View.init(self.bytes.items);
        var it = bytes_view.iterator();
        var scalar_position: usize = 0;
        var start_byte: usize = 0;
        while (scalar_position < index) {
            _ = it.nextCodepoint() orelse break;
            scalar_position += 1;
            start_byte = it.i;
        }
        if (scalar_position != index) return error.IndexOutOfBounds;

        var end_byte = start_byte;
        var removed: usize = 0;
        while (removed < length) {
            _ = it.nextCodepoint() orelse return error.IndexOutOfBounds;
            removed += 1;
            end_byte = it.i;
        }
        try self.bytes.replaceRange(self.allocator, start_byte, end_byte - start_byte, &.{});
    }
};

test "an insert into an empty buffer becomes its contents" {
    var buffer = try TextBuffer.init(std.testing.allocator);
    defer buffer.deinit();

    try buffer.insert(0, "hello");

    try std.testing.expectEqualStrings("hello", buffer.slice());
}

test "an insert at the middle shifts existing text" {
    var buffer = try TextBuffer.init(std.testing.allocator);
    defer buffer.deinit();

    try buffer.insert(0, "helo");
    try buffer.insert(2, "l");

    try std.testing.expectEqualStrings("hello", buffer.slice());
}

test "delete removes a range of Unicode scalars" {
    var buffer = try TextBuffer.init(std.testing.allocator);
    defer buffer.deinit();

    try buffer.insert(0, "hello world");
    try buffer.delete(5, 1);

    try std.testing.expectEqualStrings("helloworld", buffer.slice());
}

test "indices count Unicode scalars rather than UTF-8 bytes" {
    var buffer = try TextBuffer.init(std.testing.allocator);
    defer buffer.deinit();

    try buffer.insert(0, "café");
    try buffer.insert(4, "!");

    try std.testing.expectEqualStrings("café!", buffer.slice());
}

test "an insert past the end is rejected without changing text" {
    var buffer = try TextBuffer.init(std.testing.allocator);
    defer buffer.deinit();

    try buffer.insert(0, "abc");
    try std.testing.expectError(error.IndexOutOfBounds, buffer.insert(4, "x"));

    try std.testing.expectEqualStrings("abc", buffer.slice());
}

test "a delete range past the end is rejected without changing text" {
    var buffer = try TextBuffer.init(std.testing.allocator);
    defer buffer.deinit();

    try buffer.insert(0, "abc");
    try std.testing.expectError(error.IndexOutOfBounds, buffer.delete(2, 2));

    try std.testing.expectEqualStrings("abc", buffer.slice());
}
