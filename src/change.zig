const std = @import("std");
const id = @import("id.zig");
const operation = @import("operation.zig");

const OpId = id.OpId;
const Operation = operation.Operation;

pub const Change = struct {
    id: OpId,
    parents: std.ArrayList(OpId) = .empty,
    operation: Operation,

    pub fn init(allocator: std.mem.Allocator, op_id: OpId, parents: []const OpId, opr: Operation) !Change {
        var p = try std.ArrayList(OpId).initCapacity(allocator, parents.len);
        errdefer p.deinit(allocator);
        try p.appendSlice(allocator, parents);
        std.sort.heap(OpId, p.items, {}, lessOpId);
        if (p.items.len > 1) {
            for (p.items[1..], 1..) |parent, i| {
                if (parent.eql(p.items[i - 1])) {
                    return error.DuplicateParent;
                }
            }
        }
        return .{
            .id = op_id,
            .parents = p,
            .operation = try opr.clone(allocator),
        };
    }

    pub fn initOwned(allocator: std.mem.Allocator, op_id: OpId, parents: []const OpId, opr: Operation) !Change {
        var p = try std.ArrayList(OpId).initCapacity(allocator, parents.len);
        errdefer p.deinit(allocator);
        p.appendSliceAssumeCapacity(parents);
        std.sort.heap(OpId, p.items, {}, lessOpId);
        if (p.items.len > 1) {
            for (p.items[1..], 1..) |parent, i| {
                if (parent.eql(p.items[i - 1])) {
                    return error.DuplicateParent;
                }
            }
        }
        return .{
            .id = op_id,
            .parents = p,
            .operation = opr,
        };
    }

    pub fn deinit(self: Change, allocator: std.mem.Allocator) void {
        var p = self.parents;
        p.deinit(allocator);

        self.operation.deinit(allocator);
    }

    pub fn clone(self: *const Change, allocator: std.mem.Allocator) !Change {
        var parents = try std.ArrayList(OpId).initCapacity(allocator, self.parents.items.len);
        errdefer parents.deinit(allocator);
        try parents.appendSlice(allocator, self.parents.items);

        return .{
            .id = self.id,
            .parents = parents,
            .operation = try self.operation.clone(allocator),
        };
    }

    fn lessOpId(_: void, left: OpId, right: OpId) bool {
        return left.order(right) == .lt;
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

test "a change preserves its ID, parents, and operation" {
    const change_id = op(1, 0);
    const parent = op(2, 3);
    var source_operation = try Operation.initInsert(std.testing.allocator, 4, "hello");
    defer source_operation.deinit(std.testing.allocator);

    var change = try Change.init(std.testing.allocator, change_id, &.{parent}, source_operation);
    defer change.deinit(std.testing.allocator);

    try std.testing.expect(OpId.eql(change.id, change_id));
    try std.testing.expectEqual(@as(usize, 1), change.parents.items.len);
    try std.testing.expect(OpId.eql(change.parents.items[0], parent));

    switch (change.operation) {
        .insert => |insert| {
            try std.testing.expectEqual(@as(usize, 4), insert.index);
            try std.testing.expectEqualStrings("hello", insert.text);
        },
        .delete => return error.ExpectedInsert,
    }
}

test "a change owns independent copies of its inputs" {
    var parent = op(2, 3);
    var source_operation = try Operation.initInsert(std.testing.allocator, 0, "hi");
    defer source_operation.deinit(std.testing.allocator);

    var change = try Change.init(std.testing.allocator, op(1, 0), &.{parent}, source_operation);
    defer change.deinit(std.testing.allocator);

    parent.counter = 99;
    switch (source_operation) {
        .insert => |*insert| insert.text[0] = 'x',
        .delete => return error.ExpectedInsert,
    }

    try std.testing.expectEqual(@as(u64, 3), change.parents.items[0].counter);
    switch (change.operation) {
        .insert => |insert| try std.testing.expectEqualStrings("hi", insert.text),
        .delete => return error.ExpectedInsert,
    }
}

test "a delete change carries no inserted text allocation" {
    const source_operation = Operation.initDelete(2, 1);
    var change = try Change.init(std.testing.allocator, op(1, 0), &.{}, source_operation);
    defer change.deinit(std.testing.allocator);

    switch (change.operation) {
        .insert => return error.ExpectedDelete,
        .delete => |delete| {
            try std.testing.expectEqual(@as(usize, 2), delete.index);
            try std.testing.expectEqual(@as(usize, 1), delete.length);
        },
    }
}

test "initOwned transfers operation storage into the change" {
    const source_operation = try Operation.initInsert(std.testing.allocator, 0, "owned");
    var change = try Change.initOwned(std.testing.allocator, op(1, 0), &.{}, source_operation);
    defer change.deinit(std.testing.allocator);

    switch (change.operation) {
        .insert => |insert| try std.testing.expectEqualStrings("owned", insert.text),
        .delete => return error.ExpectedInsert,
    }
}
