//! A deliberately independent, readable FugueMax ordering model.
//!
//! The production `MergeIndex` stores records in an ordered array and uses a
//! compact index for anchors. This model stores the same durable anchors in a
//! plain list and performs the reference integrate scan directly. Keeping the
//! code separate is intentional: conformance tests should catch a shared
//! mistake in the production implementation.

const std = @import("std");
const id = @import("id.zig");

pub const OpId = id.OpId;

pub const ElementId = struct {
    op: OpId,
    offset: u32 = 0,

    pub fn eql(self: ElementId, other: ElementId) bool {
        return self.op.eql(other.op) and self.offset == other.offset;
    }

    pub fn order(self: ElementId, other: ElementId) std.math.Order {
        const operation_order = self.op.order(other.op);
        if (operation_order != .eq) return operation_order;
        if (self.offset < other.offset) return .lt;
        if (self.offset > other.offset) return .gt;
        return .eq;
    }
};

pub const Side = enum {
    left,
    right,
};

pub const Scalar = struct {
    bytes: [4]u8 = undefined,
    len: u8 = 0,

    pub fn fromBytes(bytes: []const u8) Scalar {
        var result = Scalar{ .len = @intCast(bytes.len) };
        @memcpy(result.bytes[0..bytes.len], bytes);
        return result;
    }
};

/// `parent` is origin-left and `right_origin` is FugueMax's rightParent.
/// `side` is retained only for source compatibility with older fixtures; it
/// does not affect ordering.
pub const Message = struct {
    id: ElementId,
    parent: ?ElementId,
    side: Side = .right,
    right_origin: ?ElementId,
    scalar: Scalar,
};

const Node = struct {
    id: ElementId,
    parent: ?ElementId,
    right_origin: ?ElementId,
    scalar: Scalar,
    deleted: bool = false,
};

pub const Oracle = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(Node) = .empty,
    index: std.AutoHashMap(ElementId, usize),

    pub fn init(allocator: std.mem.Allocator) !*Oracle {
        const self = try allocator.create(Oracle);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .index = std.AutoHashMap(ElementId, usize).init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *Oracle) void {
        self.nodes.deinit(self.allocator);
        self.index.deinit();
        self.allocator.destroy(self);
    }

    pub fn add(self: *Oracle, message: Message) !void {
        if (self.index.contains(message.id)) return;
        if (message.parent) |parent| {
            if (self.index.get(parent) == null) return error.UnknownOrigin;
        }
        if (message.right_origin) |right_origin| {
            if (self.index.get(right_origin) == null) return error.UnknownOrigin;
        }

        try self.index.ensureTotalCapacity(@intCast(self.nodes.items.len + 1));
        const position = try self.canonicalPosition(message);
        try self.nodes.insert(self.allocator, position, .{
            .id = message.id,
            .parent = message.parent,
            .right_origin = message.right_origin,
            .scalar = message.scalar,
            .deleted = false,
        });
        for (self.nodes.items[position + 1 ..], position + 1..) |node, shifted| {
            self.index.putAssumeCapacity(node.id, shifted);
        }
        self.index.putAssumeCapacity(message.id, position);
    }

    /// Generate a descriptor from a visible position. Hidden nodes remain in
    /// the historical list, so the cursor can pass over them while counting
    /// only visible nodes.
    pub fn insertAt(self: *Oracle, index: usize, element_id: ElementId, scalar: Scalar) !Message {
        const visible_count = self.visibleCount();
        if (index > visible_count) return error.IndexOutOfBounds;

        var cursor: usize = 0;
        var seen: usize = 0;
        while (seen < index) : (cursor += 1) {
            if (cursor >= self.nodes.items.len) return error.IndexOutOfBounds;
            if (!self.nodes.items[cursor].deleted) seen += 1;
        }

        const parent = if (index == 0)
            null
        else
            self.visibleAt(index - 1) orelse return error.IndexOutOfBounds;
        const right_origin = if (cursor < self.nodes.items.len) self.nodes.items[cursor].id else null;
        const message = Message{
            .id = element_id,
            .parent = parent,
            .right_origin = right_origin,
            .scalar = scalar,
        };
        try self.add(message);
        return message;
    }

    pub fn deleteAt(self: *Oracle, index: usize, length: usize) !void {
        const count = self.visibleCount();
        if (index > count or length > count - index) return error.IndexOutOfBounds;
        var remaining = length;
        while (remaining > 0) : (remaining -= 1) {
            const target = self.visibleAt(index) orelse return error.IndexOutOfBounds;
            const target_index = self.index.get(target) orelse return error.InvalidState;
            self.nodes.items[target_index].deleted = true;
        }
    }

    pub fn render(self: *const Oracle, allocator: std.mem.Allocator) ![]u8 {
        var byte_len: usize = 0;
        for (self.nodes.items) |node| {
            if (!node.deleted) byte_len += node.scalar.len;
        }

        const result = try allocator.alloc(u8, byte_len);
        var offset: usize = 0;
        for (self.nodes.items) |node| {
            if (node.deleted) continue;
            const end = offset + node.scalar.len;
            @memcpy(result[offset..end], node.scalar.bytes[0..node.scalar.len]);
            offset = end;
        }
        return result;
    }

    fn visibleCount(self: *const Oracle) usize {
        var count: usize = 0;
        for (self.nodes.items) |node| {
            if (!node.deleted) count += 1;
        }
        return count;
    }

    fn visibleAt(self: *const Oracle, wanted: usize) ?ElementId {
        var current: usize = 0;
        for (self.nodes.items) |node| {
            if (node.deleted) continue;
            if (current == wanted) return node.id;
            current += 1;
        }
        return null;
    }

    /// Anchor-only form of the reference `integrate` scan. This intentionally
    /// does not call any production ordering helper.
    fn canonicalPosition(self: *const Oracle, message: Message) !usize {
        const cursor = if (message.right_origin) |right_origin|
            self.index.get(right_origin) orelse return error.UnknownOrigin
        else if (message.parent) |parent|
            (self.index.get(parent) orelse return error.UnknownOrigin) + 1
        else
            0;
        var destination = cursor;
        const left_index: isize = @as(isize, @intCast(cursor)) - 1;
        const right_index: usize = if (message.right_origin) |right_origin|
            self.index.get(right_origin) orelse return error.UnknownOrigin
        else
            self.nodes.items.len;

        var scanning = false;
        var scan = cursor;
        while (scan < self.nodes.items.len) {
            const other = self.nodes.items[scan];
            const other_left: isize = if (other.parent) |parent|
                @intCast(self.index.get(parent) orelse return error.UnknownOrigin)
            else
                -1;

            if (other_left < left_index) break;
            if (other_left == left_index) {
                const other_right = if (other.right_origin) |right_origin|
                    self.index.get(right_origin) orelse return error.UnknownOrigin
                else
                    self.nodes.items.len;
                if (other_right == right_index and message.id.order(other.id) == .lt) break;
                scanning = other_right < right_index;
            }

            scan += 1;
            if (!scanning) destination = scan;
        }
        return destination;
    }
};

/// A small, independent replay model for Eg-walker.  `Oracle` above is useful
/// for checking durable anchor descriptors in isolation; this type additionally
/// models the two states used while walking a causal DAG:
///
/// * `cur_state` is the version currently being interpreted (the prepare
///   state), and can temporarily contain not-yet-inserted items or tombstones;
/// * `end_state` is the accumulated final version (the effect state), which is
///   never undone when the walker retreats between branches.
///
/// It intentionally does not call `MergeIndex` or any production helper.  The
/// implementation follows the readable Eg-walker reference's `findByCurPos`,
/// `integrate`, `retreat1`, `advance1`, and `apply1` steps directly.
pub const HistoryOperation = union(enum) {
    insert: struct {
        index: usize,
        text: []const u8,
    },
    delete: struct {
        index: usize,
        length: usize,
    },
};

pub const HistoryEvent = struct {
    id: OpId,
    parents: []const OpId,
    operation: HistoryOperation,
};

const HistoryNode = struct {
    id: ElementId,
    origin_left: ?ElementId,
    right_parent: ?ElementId,
    scalar: Scalar,
    cur_state: i32 = 0,
    end_state: i32 = 0,
};

const HistoryMetadata = struct {
    inserted: std.ArrayList(ElementId) = .empty,
    deleted: std.ArrayList(ElementId) = .empty,

    fn deinit(self: *HistoryMetadata, allocator: std.mem.Allocator) void {
        self.inserted.deinit(allocator);
        self.deleted.deinit(allocator);
    }
};

const HistoryCursor = struct {
    index: usize,
    end_position: usize,
};

pub const HistoryOracle = struct {
    allocator: std.mem.Allocator,
    events: []const HistoryEvent,
    order: []const usize,
    event_index: std.AutoHashMap(OpId, usize),
    nodes: std.ArrayList(HistoryNode) = .empty,
    node_index: std.AutoHashMap(ElementId, usize),
    metadata: []HistoryMetadata,

    pub fn init(
        allocator: std.mem.Allocator,
        events: []const HistoryEvent,
        order: []const usize,
    ) !*HistoryOracle {
        const self = try allocator.create(HistoryOracle);
        errdefer allocator.destroy(self);

        var event_index = std.AutoHashMap(OpId, usize).init(allocator);
        errdefer event_index.deinit();
        try event_index.ensureTotalCapacity(@intCast(events.len));
        for (events, 0..) |event, index| {
            if (event_index.contains(event.id)) return error.DuplicateEvent;
            event_index.putAssumeCapacity(event.id, index);
        }

        const metadata = try allocator.alloc(HistoryMetadata, events.len);
        errdefer allocator.free(metadata);
        for (metadata) |*entry| entry.* = .{};

        self.* = .{
            .allocator = allocator,
            .events = events,
            .order = order,
            .event_index = event_index,
            .node_index = std.AutoHashMap(ElementId, usize).init(allocator),
            .metadata = metadata,
        };
        return self;
    }

    pub fn deinit(self: *HistoryOracle) void {
        for (self.metadata) |*entry| entry.deinit(self.allocator);
        self.allocator.free(self.metadata);
        self.nodes.deinit(self.allocator);
        self.node_index.deinit();
        self.event_index.deinit();
        self.allocator.destroy(self);
    }

    /// Replay every event in the supplied topological order and return the
    /// final effect-state text. The returned bytes belong to `allocator`.
    pub fn render(self: *HistoryOracle, allocator: std.mem.Allocator) ![]u8 {
        var current_frontier: std.ArrayList(OpId) = .empty;
        defer current_frontier.deinit(self.allocator);

        const current_included = try self.allocator.alloc(bool, self.events.len);
        defer self.allocator.free(current_included);
        const target_included = try self.allocator.alloc(bool, self.events.len);
        defer self.allocator.free(target_included);
        var stack: std.ArrayList(usize) = .empty;
        defer stack.deinit(self.allocator);

        for (self.order) |event_index| {
            if (event_index >= self.events.len) return error.InvalidOrder;
            const event = &self.events[event_index];

            try self.fillIncluded(current_frontier.items, current_included, &stack);
            try self.fillIncluded(event.parents, target_included, &stack);

            var retreat_index = self.order.len;
            while (retreat_index > 0) {
                retreat_index -= 1;
                const changed_index = self.order[retreat_index];
                if (changed_index >= self.events.len) return error.InvalidOrder;
                if (current_included[changed_index] and !target_included[changed_index]) {
                    try self.retreatEvent(changed_index);
                }
            }

            for (self.order) |changed_index| {
                if (changed_index >= self.events.len) return error.InvalidOrder;
                if (target_included[changed_index] and !current_included[changed_index]) {
                    try self.advanceEvent(changed_index);
                }
            }

            try self.applyEvent(event_index);
            current_frontier.clearRetainingCapacity();
            try current_frontier.append(self.allocator, event.id);
        }

        return self.renderEnd(allocator);
    }

    fn fillIncluded(
        self: *HistoryOracle,
        frontier: []const OpId,
        included: []bool,
        stack: *std.ArrayList(usize),
    ) !void {
        @memset(included, false);
        stack.clearRetainingCapacity();
        for (frontier) |frontier_id| {
            const event_index = self.event_index.get(frontier_id) orelse return error.MissingParent;
            try stack.append(self.allocator, event_index);
        }

        while (stack.pop()) |event_index| {
            if (included[event_index]) continue;
            included[event_index] = true;
            for (self.events[event_index].parents) |parent| {
                const parent_index = self.event_index.get(parent) orelse return error.MissingParent;
                try stack.append(self.allocator, parent_index);
            }
        }
    }

    fn retreatEvent(self: *HistoryOracle, event_index: usize) !void {
        const event = &self.events[event_index];
        const metadata = &self.metadata[event_index];
        switch (event.operation) {
            .insert => {
                for (metadata.inserted.items) |element_id| {
                    const node_index = self.node_index.get(element_id) orelse return error.InvalidState;
                    if (self.nodes.items[node_index].cur_state != 0) return error.InvalidState;
                    self.nodes.items[node_index].cur_state -= 1;
                }
            },
            .delete => {
                for (metadata.deleted.items) |element_id| {
                    const node_index = self.node_index.get(element_id) orelse return error.InvalidState;
                    if (self.nodes.items[node_index].cur_state < 1) return error.InvalidState;
                    self.nodes.items[node_index].cur_state -= 1;
                }
            },
        }
    }

    fn advanceEvent(self: *HistoryOracle, event_index: usize) !void {
        const event = &self.events[event_index];
        const metadata = &self.metadata[event_index];
        switch (event.operation) {
            .insert => {
                for (metadata.inserted.items) |element_id| {
                    const node_index = self.node_index.get(element_id) orelse return error.InvalidState;
                    if (self.nodes.items[node_index].cur_state != -1) return error.InvalidState;
                    self.nodes.items[node_index].cur_state += 1;
                }
            },
            .delete => {
                for (metadata.deleted.items) |element_id| {
                    const node_index = self.node_index.get(element_id) orelse return error.InvalidState;
                    if (self.nodes.items[node_index].cur_state < 0) return error.InvalidState;
                    self.nodes.items[node_index].cur_state += 1;
                }
            },
        }
    }

    fn applyEvent(self: *HistoryOracle, event_index: usize) !void {
        const event = &self.events[event_index];
        const metadata = &self.metadata[event_index];
        switch (event.operation) {
            .insert => |insert| {
                const scalar_count = std.unicode.utf8CountCodepoints(insert.text) catch return error.InvalidUtf8;
                if (insert.index > self.visibleCountCurrent()) return error.InvalidOperation;

                var iterator = (try std.unicode.Utf8View.init(insert.text)).iterator();
                var offset: u32 = 0;
                while (iterator.nextCodepointSlice()) |slice| {
                    if (offset > std.math.maxInt(u32)) return error.InvalidOperation;
                    const element_id = ElementId{ .op = event.id, .offset = offset };
                    try self.insertCurrent(
                        insert.index + @as(usize, @intCast(offset)),
                        element_id,
                        Scalar.fromBytes(slice),
                    );
                    try metadata.inserted.append(self.allocator, element_id);
                    offset += 1;
                }
                if (offset != scalar_count) return error.InvalidUtf8;
            },
            .delete => |delete| {
                const count = self.visibleCountCurrent();
                if (delete.index > count or delete.length > count - delete.index) {
                    return error.InvalidOperation;
                }

                var remaining = delete.length;
                while (remaining > 0) : (remaining -= 1) {
                    const cursor = self.findByCurrentPosition(delete.index) orelse return error.InvalidOperation;
                    var target_index = cursor.index;
                    while (target_index < self.nodes.items.len and self.nodes.items[target_index].cur_state != 0) : (target_index += 1) {}
                    if (target_index >= self.nodes.items.len) return error.InvalidOperation;

                    const target = &self.nodes.items[target_index];
                    target.cur_state += 1;
                    target.end_state += 1;
                    try metadata.deleted.append(self.allocator, target.id);
                }
            },
        }
    }

    fn insertCurrent(self: *HistoryOracle, index: usize, element_id: ElementId, scalar: Scalar) !void {
        const cursor = self.findByCurrentPosition(index) orelse return error.InvalidOperation;
        if (cursor.index > 0 and self.nodes.items[cursor.index - 1].cur_state != 0) {
            return error.InvalidOperation;
        }

        const origin_left = if (cursor.index == 0) null else self.nodes.items[cursor.index - 1].id;
        var right_parent: ?ElementId = null;
        var scan = cursor.index;
        while (scan < self.nodes.items.len) : (scan += 1) {
            if (self.nodes.items[scan].cur_state != -1) {
                right_parent = self.nodes.items[scan].id;
                break;
            }
        }

        const inserted = HistoryNode{
            .id = element_id,
            .origin_left = origin_left,
            .right_parent = right_parent,
            .scalar = scalar,
        };
        const position = try self.integrate(inserted, cursor.index);
        try self.node_index.ensureTotalCapacity(@intCast(self.nodes.items.len + 1));
        try self.nodes.insert(self.allocator, position, inserted);
        for (self.nodes.items[position + 1 ..], position + 1..) |node, shifted| {
            self.node_index.putAssumeCapacity(node.id, shifted);
        }
        self.node_index.putAssumeCapacity(element_id, position);
    }

    fn integrate(self: *HistoryOracle, inserted: HistoryNode, start_cursor: usize) !usize {
        if (start_cursor >= self.nodes.items.len or self.nodes.items[start_cursor].cur_state != -1) {
            return start_cursor;
        }

        var cursor_index = start_cursor;
        var scan_index = start_cursor;
        const left_index: isize = @as(isize, @intCast(start_cursor)) - 1;
        const right_index: usize = if (inserted.right_parent) |right_parent|
            self.node_index.get(right_parent) orelse return error.UnknownOrigin
        else
            self.nodes.items.len;
        var scanning = false;

        while (scan_index < self.nodes.items.len) {
            const other = self.nodes.items[scan_index];
            if (other.cur_state != -1) break;

            const other_left: isize = if (other.origin_left) |origin_left|
                @intCast(self.node_index.get(origin_left) orelse return error.UnknownOrigin)
            else
                -1;
            if (other_left < left_index) break;
            if (other_left == left_index) {
                const other_right: usize = if (other.right_parent) |right_parent|
                    self.node_index.get(right_parent) orelse return error.UnknownOrigin
                else
                    self.nodes.items.len;
                if (other_right == right_index and inserted.id.order(other.id) == .lt) break;
                scanning = other_right < right_index;
            }

            scan_index += 1;
            if (!scanning) cursor_index = scan_index;
        }
        return cursor_index;
    }

    fn findByCurrentPosition(self: *const HistoryOracle, wanted: usize) ?HistoryCursor {
        var current_position: usize = 0;
        var end_position: usize = 0;
        var index: usize = 0;
        while (current_position < wanted) {
            if (index >= self.nodes.items.len) return null;
            current_position += currentWidth(self.nodes.items[index].cur_state);
            end_position += currentWidth(self.nodes.items[index].end_state);
            index += 1;
        }
        return .{ .index = index, .end_position = end_position };
    }

    fn visibleCountCurrent(self: *const HistoryOracle) usize {
        var count: usize = 0;
        for (self.nodes.items) |node| count += currentWidth(node.cur_state);
        return count;
    }

    fn renderEnd(self: *const HistoryOracle, allocator: std.mem.Allocator) ![]u8 {
        var byte_len: usize = 0;
        for (self.nodes.items) |node| {
            if (currentWidth(node.end_state) == 1) byte_len += node.scalar.len;
        }
        const result = try allocator.alloc(u8, byte_len);
        var offset: usize = 0;
        for (self.nodes.items) |node| {
            if (currentWidth(node.end_state) == 0) continue;
            const end = offset + node.scalar.len;
            @memcpy(result[offset..end], node.scalar.bytes[0..node.scalar.len]);
            offset = end;
        }
        return result;
    }
};

fn currentWidth(state: i32) usize {
    return if (state == 0) 1 else 0;
}

test "independent oracle orders anchor descriptors regardless of delivery order" {
    const a = ElementId{ .op = .{ .actor = [_]u8{0} ** 15 ++ [_]u8{1}, .counter = 0 } };
    const b = ElementId{ .op = .{ .actor = [_]u8{0} ** 15 ++ [_]u8{2}, .counter = 0 } };

    var first = try Oracle.init(std.testing.allocator);
    defer first.deinit();
    try first.add(.{ .id = a, .parent = null, .right_origin = null, .scalar = Scalar.fromBytes("A") });
    try first.add(.{ .id = b, .parent = null, .right_origin = null, .scalar = Scalar.fromBytes("B") });
    const first_text = try first.render(std.testing.allocator);
    defer std.testing.allocator.free(first_text);

    var second = try Oracle.init(std.testing.allocator);
    defer second.deinit();
    try second.add(.{ .id = b, .parent = null, .right_origin = null, .scalar = Scalar.fromBytes("B") });
    try second.add(.{ .id = a, .parent = null, .right_origin = null, .scalar = Scalar.fromBytes("A") });
    const second_text = try second.render(std.testing.allocator);
    defer std.testing.allocator.free(second_text);
    try std.testing.expectEqualStrings(first_text, second_text);
}
