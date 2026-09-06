const std = @import("std");
const id = @import("id.zig");
const TextBuffer = @import("text_buffer.zig").TextBuffer;
const CausalGraph = @import("causal_graph.zig").CausalGraph;
const Operation = @import("operation.zig").Operation;
const Change = @import("change.zig").Change;
const Sequence = @import("sequence.zig").Sequence;

const ActorId = id.ActorId;
const OpId = id.OpId;

pub const Document = struct {
    allocator: std.mem.Allocator,
    actor: ActorId,
    counter: usize = 0,
    sequence: *Sequence,
    buffer: *TextBuffer,
    graph: *CausalGraph,

    pub fn init(allocator: std.mem.Allocator, actor: ActorId) !*Document {
        const self = try allocator.create(Document);
        self.* = .{
            .allocator = allocator,
            .actor = actor,
            .sequence = try Sequence.init(allocator),
            .buffer = try TextBuffer.init(allocator),
            .graph = try CausalGraph.init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *Document) void {
        self.sequence.deinit();
        self.buffer.deinit();
        self.graph.deinit();
        self.allocator.destroy(self);
    }

    pub fn text(self: *Document) ![]u8 {
        return self.sequence.render(self.allocator);
    }

    pub fn heads(self: *Document) []const OpId {
        return self.graph.frontier.heads.items;
    }

    pub fn insert(self: *Document, index: usize, textToInsert: []const u8) !OpId {
        const parents = self.graph.heads();
        const new_op = OpId{ .actor = self.actor, .counter = self.counter };

        var owned_parents: std.ArrayList(OpId) = .empty;
        try owned_parents.appendSlice(self.allocator, parents);
        errdefer owned_parents.deinit(self.allocator);

        const operation = try Operation.initInsert(self.allocator, index, textToInsert);
        errdefer operation.deinit(self.allocator);
        try self.sequence.insertAt(index, new_op, textToInsert);

        try self.graph.addWithOperation(new_op, operation, owned_parents);
        self.counter += 1;

        return new_op;
    }

    pub fn delete(self: *Document, index: usize, length: usize) !OpId {
        const parents = self.graph.heads();
        const new_op = OpId{ .actor = self.actor, .counter = self.counter };

        var owned_parents: std.ArrayList(OpId) = .empty;
        try owned_parents.appendSlice(self.allocator, parents);
        errdefer owned_parents.deinit(self.allocator);

        const operation = Operation.initDelete(index, length);
        try self.sequence.deleteAt(index, length);

        try self.graph.addWithOperation(new_op, operation, owned_parents);

        self.counter += 1;
        return new_op;
    }

    pub fn receiveChange(self: *Document, change: Change) !void {
        if (self.graph.contains(change.id)) {
            change.deinit(self.allocator);
            return;
        }

        for (change.parents.items) |parent| {
            var found = false;
            for (self.graph.events.items) |event| {
                if (event.id.eql(parent)) {
                    found = true;
                    break;
                }
            }
            if (!found) return error.MissingParent;
        }

        switch (change.operation) {
            .insert => |ins| {
                try self.sequence.insertAt(ins.index, change.id, ins.text);
            },
            .delete => |del| {
                try self.sequence.deleteAt(del.index, del.length);
            },
        }

        try self.graph.addWithOperation(change.id, change.operation, change.parents);
    }
};

fn actorWithLastByte(last_byte: u8) ActorId {
    var actor = [_]u8{0} ** 16;
    actor[15] = last_byte;
    return actor;
}

fn expectText(document: *Document, expected: []const u8) !void {
    const rendered = try document.text();
    defer document.allocator.free(rendered);
    try std.testing.expectEqualStrings(expected, rendered);
}

fn expectDocumentsEqual(first: *Document, second: *Document) !void {
    const first_text = try first.text();
    defer first.allocator.free(first_text);
    const second_text = try second.text();
    defer second.allocator.free(second_text);
    try std.testing.expectEqualStrings(first_text, second_text);
}

test "a new document starts empty with no history heads" {
    var document = try Document.init(std.testing.allocator, actorWithLastByte(1));
    defer document.deinit();

    try expectText(document, "");
    try std.testing.expectEqual(@as(usize, 0), document.heads().len);
}

test "insert creates a local operation and updates visible text" {
    var document = try Document.init(std.testing.allocator, actorWithLastByte(1));
    defer document.deinit();

    const first = try document.insert(0, "hello");

    try std.testing.expectEqual(@as(u64, 0), first.counter);
    try expectText(document, "hello");
    try std.testing.expectEqual(@as(usize, 1), document.heads().len);
    try std.testing.expect(OpId.eql(first, document.heads()[0]));
}

test "sequential local edits advance the operation counter" {
    var document = try Document.init(std.testing.allocator, actorWithLastByte(1));

    const first = try document.insert(0, "helo");
    const second = try document.insert(2, "l");
    defer document.deinit();

    try std.testing.expectEqual(@as(u64, 0), first.counter);
    try std.testing.expectEqual(@as(u64, 1), second.counter);
    try expectText(document, "hello");
    try std.testing.expectEqual(@as(usize, 1), document.heads().len);
    try std.testing.expect(OpId.eql(second, document.heads()[0]));
}

test "delete creates an operation and updates visible text" {
    var document = try Document.init(std.testing.allocator, actorWithLastByte(1));
    defer document.deinit();

    _ = try document.insert(0, "hello world");
    const deletion = try document.delete(5, 1);

    try std.testing.expectEqual(@as(u64, 1), deletion.counter);
    try expectText(document, "helloworld");
    try std.testing.expectEqual(@as(usize, 1), document.heads().len);
    try std.testing.expect(OpId.eql(deletion, document.heads()[0]));
}

test "an invalid local edit changes neither text nor history" {
    var document = try Document.init(std.testing.allocator, actorWithLastByte(1));
    defer document.deinit();

    _ = try document.insert(0, "abc");
    try std.testing.expectError(error.IndexOutOfBounds, document.insert(4, "x"));

    try expectText(document, "abc");
    try std.testing.expectEqual(@as(usize, 1), document.heads().len);
}

test "a document receives a remote genesis change" {
    var document = try Document.init(std.testing.allocator, actorWithLastByte(2));
    defer document.deinit();

    const remote_id = OpId{ .actor = actorWithLastByte(1), .counter = 0 };
    var source_operation = try Operation.initInsert(std.testing.allocator, 0, "hello");
    defer source_operation.deinit(std.testing.allocator);
    const change = try Change.init(std.testing.allocator, remote_id, &.{}, source_operation);

    try document.receiveChange(change);

    try expectText(document, "hello");
    try std.testing.expectEqual(@as(usize, 1), document.heads().len);
}

test "receiving the same remote change twice is idempotent" {
    var document = try Document.init(std.testing.allocator, actorWithLastByte(2));
    defer document.deinit();

    const remote_id = OpId{ .actor = actorWithLastByte(1), .counter = 0 };
    var source_operation = try Operation.initInsert(std.testing.allocator, 0, "hello");
    defer source_operation.deinit(std.testing.allocator);
    const first = try Change.init(std.testing.allocator, remote_id, &.{}, source_operation);
    try document.receiveChange(first);

    var second_operation = try Operation.initInsert(std.testing.allocator, 0, "hello");
    defer second_operation.deinit(std.testing.allocator);
    const second = try Change.init(std.testing.allocator, remote_id, &.{}, second_operation);
    try document.receiveChange(second);

    try expectText(document, "hello");
    try std.testing.expectEqual(@as(usize, 1), document.heads().len);
}

test "a remote child cannot arrive before its parent" {
    var document = try Document.init(std.testing.allocator, actorWithLastByte(2));
    defer document.deinit();

    const parent_id = OpId{ .actor = actorWithLastByte(1), .counter = 0 };
    const child_id = OpId{ .actor = actorWithLastByte(1), .counter = 1 };
    var source_operation = try Operation.initInsert(std.testing.allocator, 5, " world");
    defer source_operation.deinit(std.testing.allocator);
    var child = try Change.init(std.testing.allocator, child_id, &.{parent_id}, source_operation);

    try std.testing.expectError(error.MissingParent, document.receiveChange(child));
    child.deinit(std.testing.allocator);

    try expectText(document, "");
    try std.testing.expectEqual(@as(usize, 0), document.heads().len);
}

test "a document applies a remote child after its parent" {
    var document = try Document.init(std.testing.allocator, actorWithLastByte(2));
    defer document.deinit();

    const parent_id = OpId{ .actor = actorWithLastByte(1), .counter = 0 };
    const child_id = OpId{ .actor = actorWithLastByte(1), .counter = 1 };

    var parent_operation = try Operation.initInsert(std.testing.allocator, 0, "hello");
    defer parent_operation.deinit(std.testing.allocator);
    const parent = try Change.init(std.testing.allocator, parent_id, &.{}, parent_operation);
    try document.receiveChange(parent);

    var child_operation = try Operation.initInsert(std.testing.allocator, 5, " world");
    defer child_operation.deinit(std.testing.allocator);
    const child = try Change.init(std.testing.allocator, child_id, &.{parent_id}, child_operation);
    try document.receiveChange(child);

    try expectText(document, "hello world");
    try std.testing.expectEqual(@as(usize, 1), document.heads().len);
    try std.testing.expect(OpId.eql(child_id, document.heads()[0]));
}

test "concurrent inserts converge despite opposite delivery order" {
    var replica_a = try Document.init(std.testing.allocator, actorWithLastByte(10));
    defer replica_a.deinit();
    var replica_b = try Document.init(std.testing.allocator, actorWithLastByte(11));
    defer replica_b.deinit();

    const a_id = OpId{ .actor = actorWithLastByte(1), .counter = 0 };
    const b_id = OpId{ .actor = actorWithLastByte(2), .counter = 0 };

    var a_source = try Operation.initInsert(std.testing.allocator, 0, "A");
    defer a_source.deinit(std.testing.allocator);
    const a_for_a = try Change.init(std.testing.allocator, a_id, &.{}, a_source);
    try replica_a.receiveChange(a_for_a);

    var b_source = try Operation.initInsert(std.testing.allocator, 0, "B");
    defer b_source.deinit(std.testing.allocator);
    const b_for_b = try Change.init(std.testing.allocator, b_id, &.{}, b_source);
    try replica_b.receiveChange(b_for_b);

    var a_remote_source = try Operation.initInsert(std.testing.allocator, 0, "A");
    defer a_remote_source.deinit(std.testing.allocator);
    const a_for_b = try Change.init(std.testing.allocator, a_id, &.{}, a_remote_source);
    try replica_b.receiveChange(a_for_b);

    var b_remote_source = try Operation.initInsert(std.testing.allocator, 0, "B");
    defer b_remote_source.deinit(std.testing.allocator);
    const b_for_a = try Change.init(std.testing.allocator, b_id, &.{}, b_remote_source);
    try replica_a.receiveChange(b_for_a);

    try expectDocumentsEqual(replica_a, replica_b);
    try expectText(replica_a, "AB");
}

test "concurrent multi-character inserts do not interleave" {
    var replica_a = try Document.init(std.testing.allocator, actorWithLastByte(10));
    defer replica_a.deinit();
    var replica_b = try Document.init(std.testing.allocator, actorWithLastByte(11));
    defer replica_b.deinit();

    const a_id = OpId{ .actor = actorWithLastByte(1), .counter = 0 };
    const b_id = OpId{ .actor = actorWithLastByte(2), .counter = 0 };

    var a_source = try Operation.initInsert(std.testing.allocator, 0, "abc");
    defer a_source.deinit(std.testing.allocator);
    const a_for_a = try Change.init(std.testing.allocator, a_id, &.{}, a_source);
    try replica_a.receiveChange(a_for_a);

    var b_source = try Operation.initInsert(std.testing.allocator, 0, "XYZ");
    defer b_source.deinit(std.testing.allocator);
    const b_for_b = try Change.init(std.testing.allocator, b_id, &.{}, b_source);
    try replica_b.receiveChange(b_for_b);

    var a_remote_source = try Operation.initInsert(std.testing.allocator, 0, "abc");
    defer a_remote_source.deinit(std.testing.allocator);
    const a_for_b = try Change.init(std.testing.allocator, a_id, &.{}, a_remote_source);
    try replica_b.receiveChange(a_for_b);

    var b_remote_source = try Operation.initInsert(std.testing.allocator, 0, "XYZ");
    defer b_remote_source.deinit(std.testing.allocator);
    const b_for_a = try Change.init(std.testing.allocator, b_id, &.{}, b_remote_source);
    try replica_a.receiveChange(b_for_a);

    try expectDocumentsEqual(replica_a, replica_b);
    try expectText(replica_a, "abcXYZ");
}

test "a child insert stays with its branch when a concurrent root arrives" {
    var first = try Document.init(std.testing.allocator, actorWithLastByte(10));
    defer first.deinit();
    var second = try Document.init(std.testing.allocator, actorWithLastByte(11));
    defer second.deinit();

    const root_a = OpId{ .actor = actorWithLastByte(1), .counter = 0 };
    const root_b = OpId{ .actor = actorWithLastByte(2), .counter = 0 };
    const child_a = OpId{ .actor = actorWithLastByte(1), .counter = 1 };

    var root_a_op = try Operation.initInsert(std.testing.allocator, 0, "A");
    defer root_a_op.deinit(std.testing.allocator);
    try first.receiveChange(try Change.init(std.testing.allocator, root_a, &.{}, root_a_op));

    var child_op = try Operation.initInsert(std.testing.allocator, 1, "c");
    defer child_op.deinit(std.testing.allocator);
    try first.receiveChange(try Change.init(std.testing.allocator, child_a, &.{root_a}, child_op));

    var root_b_op = try Operation.initInsert(std.testing.allocator, 0, "B");
    defer root_b_op.deinit(std.testing.allocator);
    try second.receiveChange(try Change.init(std.testing.allocator, root_b, &.{}, root_b_op));

    var root_a_for_second = try Operation.initInsert(std.testing.allocator, 0, "A");
    defer root_a_for_second.deinit(std.testing.allocator);
    try second.receiveChange(try Change.init(std.testing.allocator, root_a, &.{}, root_a_for_second));

    var root_b_for_first = try Operation.initInsert(std.testing.allocator, 0, "B");
    defer root_b_for_first.deinit(std.testing.allocator);
    try first.receiveChange(try Change.init(std.testing.allocator, root_b, &.{}, root_b_for_first));

    var child_for_second = try Operation.initInsert(std.testing.allocator, 1, "c");
    defer child_for_second.deinit(std.testing.allocator);
    try second.receiveChange(try Change.init(std.testing.allocator, child_a, &.{root_a}, child_for_second));

    try expectText(first, "AcB");
    try expectDocumentsEqual(first, second);
}

test "deleting a complete inserted run updates the sequence-backed document" {
    var document = try Document.init(std.testing.allocator, actorWithLastByte(1));
    defer document.deinit();

    _ = try document.insert(0, "abc");
    _ = try document.delete(0, 3);

    try expectText(document, "");
    try std.testing.expectEqual(@as(usize, 1), document.heads().len);
}

test "receiving a complete-run delete updates the sequence-backed document" {
    var document = try Document.init(std.testing.allocator, actorWithLastByte(2));
    defer document.deinit();

    const insert_id = OpId{ .actor = actorWithLastByte(1), .counter = 0 };
    var insert_operation = try Operation.initInsert(std.testing.allocator, 0, "abc");
    defer insert_operation.deinit(std.testing.allocator);
    try document.receiveChange(try Change.init(std.testing.allocator, insert_id, &.{}, insert_operation));

    const delete_id = OpId{ .actor = actorWithLastByte(1), .counter = 1 };
    const delete_operation = Operation.initDelete(0, 3);
    try document.receiveChange(try Change.init(std.testing.allocator, delete_id, &.{insert_id}, delete_operation));

    try expectText(document, "");
    try std.testing.expectEqual(@as(usize, 1), document.heads().len);
    try std.testing.expect(OpId.eql(delete_id, document.heads()[0]));
}
