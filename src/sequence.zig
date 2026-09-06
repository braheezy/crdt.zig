const std = @import("std");
const id = @import("id.zig");
const item_module = @import("sequence_item.zig");

const OpId = id.OpId;
const SequenceItem = item_module.SequenceItem;

// A reference sequence stores durable items and determines their order. This
// first slice does not materialize text or handle deletes. The implementation
// should provide:
//
//   Sequence.init(allocator) -> !*Sequence
//   sequence.deinit()
//   sequence.insert(item) -> !void       // consumes item on success
//   sequence.items() -> []const SequenceItem
//   sequence.render(allocator) -> ![]u8   // caller owns returned bytes
//   sequence.hide(id) -> !void            // retain item, omit it from render
//   sequence.insertAt(index, id, text) -> !void
//
// For now, concurrent items with the same origin use deterministic OpId order.
// This is a deliberately small stepping stone toward the FugueMax ordering
// contract, not the final merge algorithm.

pub const Sequence = struct {
    allocator: std.mem.Allocator,
    sequence_items: std.ArrayList(SequenceItem) = .empty,

    pub fn init(allocator: std.mem.Allocator) !*Sequence {
        const self = try allocator.create(Sequence);
        self.* = .{ .allocator = allocator };
        return self;
    }

    pub fn deinit(self: *Sequence) void {
        for (self.sequence_items.items) |item| {
            item.deinit(self.allocator);
        }
        self.sequence_items.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn insert(self: *Sequence, item: SequenceItem) !void {
        for (self.sequence_items.items) |seq_item| {
            if (seq_item.id.eql(item.id)) return;
        }

        const start_pos = if (item.origin) |origin| origin_block: {
            for (self.sequence_items.items, 0..) |seq_item, i| {
                if (seq_item.id.eql(origin)) {
                    break :origin_block i + 1;
                }
            }
            return error.UnknownOrigin;
        } else 0;

        var i = start_pos;
        while (i < self.sequence_items.items.len) {
            const curr_item = self.sequence_items.items[i];

            if (haveSameOrigin(curr_item, item)) {
                if (curr_item.id.order(item.id) == .gt) {
                    try self.sequence_items.insert(self.allocator, i, item);
                    return;
                }

                i += 1;
                continue;
            }
            if (item.origin) |origin| {
                if (self.isDescendantOf(curr_item.id, origin)) {
                    i += 1;
                    continue;
                }
                try self.sequence_items.insert(self.allocator, i, item);
                return;
            }
            i += 1;
        }
        try self.sequence_items.append(self.allocator, item);
    }

    pub fn insertAt(self: *Sequence, index: usize, new_id: OpId, text: []const u8) !void {
        var origin: ?OpId = null;
        if (index != 0) {
            var visible_position: usize = 0;

            for (self.items()) |item| {
                if (!item.visible) continue;
                const item_length = try std.unicode.utf8CountCodepoints(item.text);
                visible_position += item_length;

                if (visible_position == index) {
                    origin = item.id;
                    break;
                }
                if (visible_position > index) {
                    return error.UnsupportedInteriorPosition;
                }
            }
            if (origin == null) return error.IndexOutOfBounds;
        }

        const new_item = try SequenceItem.init(self.allocator, new_id, origin, text);
        try self.insert(new_item);
    }

    pub fn deleteAt(self: *Sequence, index: usize, length: usize) !void {
        if (length == 0) return;

        var visible_position: usize = 0;
        var start_item: ?usize = null;
        var end_item: ?usize = null;

        const deletion_end = index + length;

        for (self.sequence_items.items, 0..) |item, i| {
            if (!item.visible) continue;

            const item_length = try std.unicode.utf8CountCodepoints(item.text);
            const item_start = visible_position;
            const item_end = visible_position + item_length;

            if (index > item_start and index < item_end) {
                return error.IndexOutOfBounds;
            }

            if (deletion_end > item_start and deletion_end < item_end) {
                return error.UnsupportedInteriorPosition;
            }

            if (index == item_start) {
                start_item = i;
            }

            if (deletion_end == item_end) {
                end_item = i + 1;
                break;
            }

            visible_position = item_end;
        }

        if (start_item == null or end_item == null) {
            return error.IndexOutOfBounds;
        }

        for (start_item.?..end_item.?) |i| {
            self.sequence_items.items[i].visible = false;
        }
    }

    // caller owns returned bytes
    pub fn render(self: *Sequence, allocator: std.mem.Allocator) ![]u8 {
        var total_bytes: usize = 0;
        for (self.sequence_items.items) |item| {
            if (item.visible) {
                total_bytes += item.text.len;
            }
        }

        const buf = try allocator.alloc(u8, total_bytes);
        var offset: usize = 0;
        for (self.sequence_items.items) |item| {
            if (item.visible) {
                @memcpy(buf[offset .. offset + item.text.len], item.text);
                offset += item.text.len;
            }
        }

        return buf;
    }

    pub fn hide(self: *Sequence, itemToHide: OpId) !void {
        for (self.items(), 0..) |item, i| {
            if (item.id.eql(itemToHide)) {
                self.sequence_items.items[i].visible = false;
                break;
            }
        } else return error.UnknownItem;
    }

    pub fn items(self: *Sequence) []const SequenceItem {
        return self.sequence_items.items;
    }

    fn isDescendantOf(self: *Sequence, candidate_id: OpId, ancestor_id: OpId) bool {
        var current_id = candidate_id;

        while (true) {
            var parent: ?OpId = null;

            for (self.sequence_items.items) |entry| {
                if (entry.id.eql(current_id)) {
                    parent = entry.origin;
                    break;
                }
            }

            const origin = parent orelse return false;
            if (origin.eql(ancestor_id)) {
                return true;
            }
            current_id = origin;
        }
    }
};

fn haveSameOrigin(item1: SequenceItem, item2: SequenceItem) bool {
    if (item1.origin == null) {
        if (item2.origin == null) return true;
        return false;
    }
    if (item2.origin == null) {
        return false;
    }
    return item1.origin.?.eql(item2.origin.?);
}

fn actorWithLastByte(last_byte: u8) id.ActorId {
    var actor = [_]u8{0} ** 16;
    actor[15] = last_byte;
    return actor;
}

fn op(actor_last_byte: u8, counter: u64) OpId {
    return .{ .actor = actorWithLastByte(actor_last_byte), .counter = counter };
}

test "a sequence stores one inserted item" {
    var sequence = try Sequence.init(std.testing.allocator);
    defer sequence.deinit();

    const item_id = op(1, 0);
    const item = try SequenceItem.init(std.testing.allocator, item_id, null, "A");
    try sequence.insert(item);

    const items = sequence.items();
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expect(OpId.eql(items[0].id, item_id));
}

test "an item with an origin is placed after that origin" {
    var sequence = try Sequence.init(std.testing.allocator);
    defer sequence.deinit();

    const root_id = op(1, 0);
    const child_id = op(1, 1);
    const root = try SequenceItem.init(std.testing.allocator, root_id, null, "A");
    try sequence.insert(root);
    const child = try SequenceItem.init(std.testing.allocator, child_id, root_id, "B");
    try sequence.insert(child);

    const items = sequence.items();
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expect(OpId.eql(items[0].id, root_id));
    try std.testing.expect(OpId.eql(items[1].id, child_id));
}

test "concurrent items with the same origin have deterministic order" {
    var sequence = try Sequence.init(std.testing.allocator);
    defer sequence.deinit();

    const left_id = op(1, 0);
    const right_id = op(2, 0);
    const right = try SequenceItem.init(std.testing.allocator, right_id, null, "B");
    try sequence.insert(right);
    const left = try SequenceItem.init(std.testing.allocator, left_id, null, "A");
    try sequence.insert(left);

    const items = sequence.items();
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expect(OpId.eql(items[0].id, left_id));
    try std.testing.expect(OpId.eql(items[1].id, right_id));
}

test "render concatenates item text in sequence order" {
    var sequence = try Sequence.init(std.testing.allocator);
    defer sequence.deinit();

    const right = try SequenceItem.init(std.testing.allocator, op(2, 0), null, "B");
    try sequence.insert(right);
    const left = try SequenceItem.init(std.testing.allocator, op(1, 0), null, "A");
    try sequence.insert(left);

    const rendered = try sequence.render(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("AB", rendered);
}

test "render preserves multi-character insertion runs" {
    var sequence = try Sequence.init(std.testing.allocator);
    defer sequence.deinit();

    const first = try SequenceItem.init(std.testing.allocator, op(1, 0), null, "abc");
    try sequence.insert(first);
    const second = try SequenceItem.init(std.testing.allocator, op(2, 0), null, "XYZ");
    try sequence.insert(second);

    const rendered = try sequence.render(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("abcXYZ", rendered);
}

test "hiding an item removes it from render but retains its history record" {
    var sequence = try Sequence.init(std.testing.allocator);
    defer sequence.deinit();

    const item_id = op(1, 0);
    const item = try SequenceItem.init(std.testing.allocator, item_id, null, "abc");
    try sequence.insert(item);

    try sequence.hide(item_id);

    const rendered = try sequence.render(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("", rendered);
    try std.testing.expectEqual(@as(usize, 1), sequence.items().len);
    try std.testing.expect(!sequence.items()[0].visible);
}

test "hiding the same item twice is harmless" {
    var sequence = try Sequence.init(std.testing.allocator);
    defer sequence.deinit();

    const item_id = op(1, 0);
    const item = try SequenceItem.init(std.testing.allocator, item_id, null, "A");
    try sequence.insert(item);

    try sequence.hide(item_id);
    try sequence.hide(item_id);

    const rendered = try sequence.render(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("", rendered);
}

test "hiding an unknown item is rejected" {
    var sequence = try Sequence.init(std.testing.allocator);
    defer sequence.deinit();

    try std.testing.expectError(error.UnknownItem, sequence.hide(op(9, 0)));
}

test "insertAt derives the origin from the visible text position" {
    var sequence = try Sequence.init(std.testing.allocator);
    defer sequence.deinit();

    const first_id = op(1, 0);
    const second_id = op(1, 1);

    try sequence.insertAt(0, first_id, "ab");
    try sequence.insertAt(2, second_id, "c");

    const rendered = try sequence.render(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("abc", rendered);
    try std.testing.expect(sequence.items()[1].origin != null);
    try std.testing.expect(OpId.eql(sequence.items()[1].origin.?, first_id));
}

test "insertAt rejects a position past the visible end" {
    var sequence = try Sequence.init(std.testing.allocator);
    defer sequence.deinit();

    try sequence.insertAt(0, op(1, 0), "abc");
    try std.testing.expectError(error.IndexOutOfBounds, sequence.insertAt(4, op(2, 0), "x"));
}

test "insertAt rejects a position inside an existing item run" {
    var sequence = try Sequence.init(std.testing.allocator);
    defer sequence.deinit();

    try sequence.insertAt(0, op(1, 0), "abc");
    try std.testing.expectError(error.UnsupportedInteriorPosition, sequence.insertAt(1, op(2, 0), "x"));
}

test "deleteAt hides a complete inserted run but retains its history record" {
    var sequence = try Sequence.init(std.testing.allocator);
    defer sequence.deinit();

    const item_id = op(1, 0);
    try sequence.insertAt(0, item_id, "abc");

    try sequence.deleteAt(0, 3);

    const rendered = try sequence.render(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("", rendered);
    try std.testing.expectEqual(@as(usize, 1), sequence.items().len);
    try std.testing.expect(!sequence.items()[0].visible);
}

test "deleteAt with zero length changes nothing" {
    var sequence = try Sequence.init(std.testing.allocator);
    defer sequence.deinit();

    try sequence.insertAt(0, op(1, 0), "abc");
    try sequence.deleteAt(1, 0);

    const rendered = try sequence.render(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("abc", rendered);
    try std.testing.expect(sequence.items()[0].visible);
}

test "deleteAt rejects a range past the visible end without changing text" {
    var sequence = try Sequence.init(std.testing.allocator);
    defer sequence.deinit();

    try sequence.insertAt(0, op(1, 0), "abc");
    try std.testing.expectError(error.IndexOutOfBounds, sequence.deleteAt(2, 2));

    const rendered = try sequence.render(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("abc", rendered);
    try std.testing.expect(sequence.items()[0].visible);
}

test "deleteAt hides a range spanning multiple inserted runs" {
    var sequence = try Sequence.init(std.testing.allocator);
    defer sequence.deinit();

    const first_id = op(1, 0);
    const second_id = op(2, 0);
    try sequence.insertAt(0, first_id, "ab");
    try sequence.insertAt(2, second_id, "cd");

    try sequence.deleteAt(0, 4);

    const rendered = try sequence.render(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("", rendered);
    try std.testing.expectEqual(@as(usize, 2), sequence.items().len);
    try std.testing.expect(!sequence.items()[0].visible);
    try std.testing.expect(!sequence.items()[1].visible);
}

test "concurrent branches keep their descendants grouped regardless of arrival order" {
    var first = try Sequence.init(std.testing.allocator);
    defer first.deinit();
    var second = try Sequence.init(std.testing.allocator);
    defer second.deinit();

    const a = op(1, 0);
    const b = op(2, 0);
    const a_child = op(1, 1);
    const b_child = op(2, 1);

    try first.insert(try SequenceItem.init(std.testing.allocator, a, null, "A"));
    try first.insert(try SequenceItem.init(std.testing.allocator, b, null, "B"));
    try first.insert(try SequenceItem.init(std.testing.allocator, a_child, a, "a"));
    try first.insert(try SequenceItem.init(std.testing.allocator, b_child, b, "b"));

    try second.insert(try SequenceItem.init(std.testing.allocator, b, null, "B"));
    try second.insert(try SequenceItem.init(std.testing.allocator, a, null, "A"));
    try second.insert(try SequenceItem.init(std.testing.allocator, b_child, b, "b"));
    try second.insert(try SequenceItem.init(std.testing.allocator, a_child, a, "a"));

    const first_rendered = try first.render(std.testing.allocator);
    defer std.testing.allocator.free(first_rendered);
    const second_rendered = try second.render(std.testing.allocator);
    defer std.testing.allocator.free(second_rendered);

    try std.testing.expectEqualStrings("AaBb", first_rendered);
    try std.testing.expectEqualStrings(first_rendered, second_rendered);
}
