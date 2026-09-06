const std = @import("std");
const id = @import("id.zig");

const OpId = id.OpId;

pub const SequenceItem = struct {
    id: OpId,
    origin: ?OpId,
    visible: bool = true,
    text: []const u8,

    pub fn init(allocator: std.mem.Allocator, op_id: OpId, origin: ?OpId, txt: []const u8) !SequenceItem {
        return .{
            .id = op_id,
            .origin = origin,
            .text = try allocator.dupe(u8, txt),
        };
    }

    pub fn deinit(self: SequenceItem, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

fn actorWithLastByte(last_byte: u8) id.ActorId {
    var actor = [_]u8{0} ** 16;
    actor[15] = last_byte;
    return actor;
}

fn op(actor_last_byte: u8, counter: u64) OpId {
    return .{ .actor = actorWithLastByte(actor_last_byte), .counter = counter };
}

test "a sequence item preserves its identity, origin, and text" {
    const item_id = op(1, 0);
    const origin = op(2, 4);
    var item = try SequenceItem.init(std.testing.allocator, item_id, origin, "hello");
    defer item.deinit(std.testing.allocator);

    try std.testing.expect(OpId.eql(item.id, item_id));
    try std.testing.expect(item.origin != null);
    try std.testing.expect(OpId.eql(item.origin.?, origin));
    try std.testing.expectEqualStrings("hello", item.text);
}

test "a null origin represents insertion at the beginning" {
    var item = try SequenceItem.init(std.testing.allocator, op(1, 0), null, "A");
    defer item.deinit(std.testing.allocator);

    try std.testing.expect(item.origin == null);
}

test "a sequence item owns an independent copy of its text" {
    var source = [_]u8{ 'h', 'i' };
    var item = try SequenceItem.init(std.testing.allocator, op(1, 0), null, source[0..]);
    defer item.deinit(std.testing.allocator);

    source[0] = 'x';
    try std.testing.expectEqualStrings("hi", item.text);
}
