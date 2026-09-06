const std = @import("std");
const id = @import("id.zig");

pub const OpId = id.OpId;

pub const ElementId = struct {
    op: OpId,
    offset: u32,
    /// Placeholder records belong to the temporary partial-replay namespace.
    /// Keeping the namespace in the key avoids relying on a magic actor ID.
    placeholder: bool = false,

    pub fn eql(self: ElementId, other: ElementId) bool {
        return self.op.eql(other.op) and self.offset == other.offset and self.placeholder == other.placeholder;
    }

    pub fn order(self: ElementId, other: ElementId) std.math.Order {
        const operation_order = self.op.order(other.op);
        if (operation_order != .eq) return operation_order;
        if (self.offset != other.offset) {
            return if (self.offset < other.offset) .lt else .gt;
        }
        if (self.placeholder == other.placeholder) return .eq;
        return if (self.placeholder) .lt else .gt;
    }
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

pub const Anchor = ?ElementId;

/// FugueMax stores the two anchors used by the reference algorithm. `parent`
/// is the item's origin-left (the item immediately to its left in the
/// insertion context); `right_origin` is the first item which was already
/// present at that context position (the reference calls it rightParent).
/// `side` remains as a compatibility/debug field for older hand-written
/// fixtures, but ordering is determined by the two anchors, not by side.
pub const Side = enum {
    left,
    right,
};

/// Sequence-ordering semantics used when deriving a durable right-parent
/// anchor from an insertion context.  FugueMax is the library default; plain
/// Fugue is retained as an explicit compatibility mode for the checked-in
/// Eg-walker/YjsMod corpus, whose reference source uses the conditional rule.
pub const Ordering = enum {
    fugue,
    fugue_max,
};

pub const Insert = struct {
    id: ElementId,
    /// The item's origin-left. Null is the start sentinel.
    parent: Anchor,
    /// The reference algorithm's rightParent. Null is the end sentinel.
    right_origin: Anchor,
    side: Side = .right,
    scalar: Scalar,
    placeholder: bool = false,
};

pub const Record = struct {
    id: ElementId,
    /// See `Insert.parent` and `Insert.right_origin`.
    parent: Anchor,
    right_origin: Anchor,
    side: Side = .right,
    scalar: Scalar,
    placeholder: bool = false,
    prepare_inserted: bool = true,
    effect_inserted: bool = true,
    prepare_delete_count: u32 = 0,
    effect_delete_count: u32 = 0,

    pub fn prepareVisible(self: Record) bool {
        return self.prepare_inserted and self.prepare_delete_count == 0;
    }

    pub fn effectVisible(self: Record) bool {
        return self.effect_inserted and self.effect_delete_count == 0;
    }
};

pub const View = enum {
    prepare,
    effect,
};

pub const MergeIndex = struct {
    allocator: std.mem.Allocator,
    ordering: Ordering = .fugue_max,
    records: std.ArrayList(Record) = .empty,
    record_index: std.AutoHashMap(ElementId, usize),

    pub fn init(allocator: std.mem.Allocator) !*MergeIndex {
        return initWithOrdering(allocator, .fugue_max);
    }

    pub fn initWithOrdering(allocator: std.mem.Allocator, ordering: Ordering) !*MergeIndex {
        const self = try allocator.create(MergeIndex);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .ordering = ordering,
            .record_index = std.AutoHashMap(ElementId, usize).init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *MergeIndex) void {
        self.records.deinit(self.allocator);
        self.record_index.deinit();
        self.allocator.destroy(self);
    }

    pub fn insert(self: *MergeIndex, inserted: Insert) !void {
        if (self.find(inserted.id) != null) return;

        if (inserted.parent) |parent| {
            if (self.find(parent) == null) return error.UnknownOrigin;
        }
        if (inserted.right_origin) |right_origin| {
            if (self.find(right_origin) == null) return error.UnknownOrigin;
        }

        // The map is updated for the inserted record and every record shifted
        // to its right. Reserve before changing the ordered storage so no
        // later map operation can fail halfway through an insertion.
        try self.record_index.ensureTotalCapacity(@intCast(self.records.items.len + 1));

        const cursor_index = if (inserted.right_origin) |right_parent|
            self.find(right_parent) orelse return error.UnknownOrigin
        else if (inserted.parent) |origin|
            (self.find(origin) orelse return error.UnknownOrigin) + 1
        else
            0;
        const position = try self.insertionPositionFromCursor(inserted, .prepare, cursor_index, false);
        try self.insertAtPosition(inserted, position);
    }

    fn insertAtPosition(self: *MergeIndex, inserted: Insert, position: usize) !void {
        try self.records.insert(self.allocator, position, .{
            .id = inserted.id,
            .parent = inserted.parent,
            .right_origin = inserted.right_origin,
            .side = inserted.side,
            .scalar = inserted.scalar,
            .placeholder = inserted.placeholder,
        });

        for (self.records.items[position + 1 ..], position + 1..) |entry, shifted_index| {
            self.record_index.putAssumeCapacity(entry.id, shifted_index);
        }
        self.record_index.putAssumeCapacity(inserted.id, position);
    }

    /// Create and insert one scalar at a visible index using the FugueMax
    /// generator rule. The returned value is the durable anchor description
    /// that must be stored in replay metadata.
    pub fn insertAt(
        self: *MergeIndex,
        view: View,
        index: usize,
        element_id: ElementId,
        scalar: Scalar,
    ) !Insert {
        if (index > self.visibleCount(view)) return error.IndexOutOfBounds;

        // This is the cursor returned by the reference findByCurPos helper:
        // current position counts records active in `view`, while the cursor
        // itself walks through every historical record, including tombstones
        // and records temporarily absent from the prepare version.
        var cursor_index: usize = 0;
        var current_position: usize = 0;
        while (current_position < index) {
            if (cursor_index >= self.records.items.len) return error.IndexOutOfBounds;
            if (self.currentVisible(self.records.items[cursor_index], view)) {
                current_position += 1;
            }
            cursor_index += 1;
        }

        // Fugue's origin-left is the physical predecessor of the cursor,
        // not merely the previous currently-visible character.  A tombstone
        // can sit between the visible predecessor and this insertion point,
        // and that historical anchor is part of the operation's semantics.
        const left_origin: Anchor = if (cursor_index == 0)
            null
        else
            self.records.items[cursor_index - 1].id;

        var inserted = Insert{
            .id = element_id,
            .parent = left_origin,
            .right_origin = null,
            .side = .right,
            .scalar = scalar,
        };

        // The reference implementation scans from the insertion cursor to
        // the first record which was already present in the current version.
        // That record is the rightParent; unlike the older tree shortcut this
        // is not conditional on sharing origin-left.
        var scan = cursor_index;
        while (scan < self.records.items.len) : (scan += 1) {
            if (self.currentInserted(self.records.items[scan], view)) {
                // Plain Fugue (the ordering used by the checked-in
                // Eg-walker/YjsMod corpus) only records a right parent when
                // the first already-present item is a sibling with the same
                // origin-left.  FugueMax removes this condition; keeping the
                // rule explicit here lets the durable descriptor match the
                // published reference rather than silently mixing semantics.
                if (self.ordering == .fugue_max or
                    sameAnchor(self.records.items[scan].parent, left_origin))
                {
                    inserted.right_origin = self.records.items[scan].id;
                }
                break;
            }
        }

        try self.record_index.ensureTotalCapacity(@intCast(self.records.items.len + 1));
        const position = try self.insertionPositionFromCursor(inserted, view, cursor_index, true);
        try self.insertAtPosition(inserted, position);
        return inserted;
    }

    /// Insert one anonymous character from the unknown base of a critical
    /// version.  Partial replay deliberately gives these records a separate
    /// ID namespace: they are local reconstruction artifacts, never durable
    /// sequence elements and never valid operation targets on the wire.
    pub fn insertPlaceholder(self: *MergeIndex, placeholder_id: ElementId) !void {
        if (!placeholder_id.placeholder) return error.InvalidPlaceholder;
        try self.insert(.{
            .id = placeholder_id,
            .parent = null,
            .right_origin = null,
            .side = .right,
            .scalar = .{},
            .placeholder = true,
        });
    }

    pub fn find(self: *const MergeIndex, wanted: ElementId) ?usize {
        return self.record_index.get(wanted);
    }

    pub fn record(self: *const MergeIndex, wanted: ElementId) ?Record {
        const index = self.find(wanted) orelse return null;
        return self.records.items[index];
    }

    pub fn setPrepareInserted(self: *MergeIndex, wanted: ElementId, inserted: bool) !void {
        const index = self.find(wanted) orelse return error.UnknownElement;
        self.records.items[index].prepare_inserted = inserted;
    }

    /// Move an insertion event out of or into the prepare version. The
    /// deletion count is intentionally left untouched: a record can be
    /// inserted in one branch while being deleted in another.
    pub fn retreatPrepareInsert(self: *MergeIndex, wanted: ElementId) !void {
        try self.setPrepareInserted(wanted, false);
    }

    pub fn advancePrepareInsert(self: *MergeIndex, wanted: ElementId) !void {
        try self.setPrepareInserted(wanted, true);
    }

    pub fn setEffectInserted(self: *MergeIndex, wanted: ElementId, inserted: bool) !void {
        const index = self.find(wanted) orelse return error.UnknownElement;
        self.records.items[index].effect_inserted = inserted;
    }

    pub fn deletePrepare(self: *MergeIndex, wanted: ElementId) !void {
        const index = self.find(wanted) orelse return error.UnknownElement;
        self.records.items[index].prepare_delete_count +|= 1;
    }

    pub fn undeletePrepare(self: *MergeIndex, wanted: ElementId) !void {
        const index = self.find(wanted) orelse return error.UnknownElement;
        if (self.records.items[index].prepare_delete_count > 0) {
            self.records.items[index].prepare_delete_count -= 1;
        }
    }

    pub fn retreatPrepareDelete(self: *MergeIndex, wanted: ElementId) !void {
        try self.undeletePrepare(wanted);
    }

    pub fn advancePrepareDelete(self: *MergeIndex, wanted: ElementId) !void {
        try self.deletePrepare(wanted);
    }

    pub fn deleteEffect(self: *MergeIndex, wanted: ElementId) !void {
        const index = self.find(wanted) orelse return error.UnknownElement;
        self.records.items[index].effect_delete_count +|= 1;
    }

    pub fn undeleteEffect(self: *MergeIndex, wanted: ElementId) !void {
        const index = self.find(wanted) orelse return error.UnknownElement;
        if (self.records.items[index].effect_delete_count > 0) {
            self.records.items[index].effect_delete_count -= 1;
        }
    }

    pub fn isVisible(self: *const MergeIndex, wanted: ElementId, view: View) !bool {
        const index = self.find(wanted) orelse return error.UnknownElement;
        return switch (view) {
            .prepare => self.records.items[index].prepareVisible(),
            .effect => self.records.items[index].effectVisible(),
        };
    }

    pub fn visibleCount(self: *const MergeIndex, view: View) usize {
        var count: usize = 0;
        for (self.records.items) |entry| {
            if (switch (view) {
                .prepare => entry.prepareVisible(),
                .effect => entry.effectVisible(),
            }) count += 1;
        }
        return count;
    }

    pub fn visibleAt(self: *const MergeIndex, view: View, wanted_index: usize) ?ElementId {
        var current_index: usize = 0;
        for (self.records.items) |entry| {
            const visible = switch (view) {
                .prepare => entry.prepareVisible(),
                .effect => entry.effectVisible(),
            };
            if (!visible) continue;
            if (current_index == wanted_index) return entry.id;
            current_index += 1;
        }
        return null;
    }

    pub fn rankBefore(self: *const MergeIndex, wanted: ElementId, view: View) !usize {
        const wanted_index = self.find(wanted) orelse return error.UnknownElement;
        var rank: usize = 0;
        for (self.records.items[0..wanted_index]) |entry| {
            const visible = switch (view) {
                .prepare => entry.prepareVisible(),
                .effect => entry.effectVisible(),
            };
            if (visible) rank += 1;
        }
        return rank;
    }

    pub fn render(self: *const MergeIndex, allocator: std.mem.Allocator, view: View) ![]u8 {
        var byte_len: usize = 0;
        for (self.records.items) |entry| {
            const visible = switch (view) {
                .prepare => entry.prepareVisible(),
                .effect => entry.effectVisible(),
            };
            if (visible) byte_len += entry.scalar.len;
        }

        const result = try allocator.alloc(u8, byte_len);
        var offset: usize = 0;
        for (self.records.items) |entry| {
            const visible = switch (view) {
                .prepare => entry.prepareVisible(),
                .effect => entry.effectVisible(),
            };
            if (!visible) continue;
            const end = offset + entry.scalar.len;
            @memcpy(result[offset..end], entry.scalar.bytes[0..entry.scalar.len]);
            offset = end;
        }
        return result;
    }

    pub fn items(self: *const MergeIndex) []const Record {
        return self.records.items;
    }

    /// Reproduce the reference Eg-walker/FugueMax `integrate` scan.  The
    /// cursor starts at the first valid position for the operation.  Only
    /// records which are NotYetInserted in the current version may be
    /// crossed; the first record already present at that position is the
    /// right-parent bound stored in the durable insert descriptor.
    fn insertionPositionFromCursor(
        self: *const MergeIndex,
        inserted: Insert,
        view: View,
        start_cursor: usize,
        respect_state: bool,
    ) !usize {
        var cursor_index = start_cursor;
        const left_index: isize = @as(isize, @intCast(cursor_index)) - 1;
        const right_index: usize = if (inserted.right_origin) |right_parent|
            self.find(right_parent) orelse return error.UnknownOrigin
        else
            self.records.items.len;

        // In the common case there is no NotYetInserted run to scan.  This
        // still returns the exact cursor position represented by origin-left.
        if (respect_state and (cursor_index >= self.records.items.len or
            self.currentInserted(self.records.items[cursor_index], view)))
        {
            return cursor_index;
        }

        var scanning = false;
        var scan_index = cursor_index;
        while (scan_index < self.records.items.len) {
            const other = self.records.items[scan_index];
            if (respect_state and self.currentInserted(other, view)) break;
            if (respect_state) {
                if (inserted.right_origin) |right_parent| {
                    if (other.id.eql(right_parent)) return error.InvalidAnchor;
                }
            }

            const other_left_index: isize = if (other.parent) |origin|
                @intCast(self.find(origin) orelse return error.UnknownOrigin)
            else
                -1;
            if (other_left_index < left_index) {
                break;
            } else if (other_left_index == left_index) {
                const other_right_index: usize = if (other.right_origin) |right_parent|
                    self.find(right_parent) orelse return error.UnknownOrigin
                else
                    self.records.items.len;

                if (other_right_index == right_index and inserted.id.order(other.id) == .lt) {
                    break;
                }
                scanning = other_right_index < right_index;
            }

            scan_index += 1;
            if (!scanning) cursor_index = scan_index;
        }
        return cursor_index;
    }

    fn currentInserted(_: *const MergeIndex, entry: Record, view: View) bool {
        return switch (view) {
            .prepare => entry.prepare_inserted,
            .effect => entry.effect_inserted,
        };
    }

    fn currentVisible(_: *const MergeIndex, entry: Record, view: View) bool {
        return switch (view) {
            .prepare => entry.prepareVisible(),
            .effect => entry.effectVisible(),
        };
    }

    fn rightSiblingBefore(self: *const MergeIndex, inserted: Insert, current: Record) !bool {
        const order = try self.anchorOrder(inserted.right_origin, current.right_origin);
        if (order == .gt) return true;
        if (order == .lt) return false;
        return inserted.id.order(current.id) == .lt;
    }

    fn anchorOrder(self: *const MergeIndex, left: Anchor, right: Anchor) !std.math.Order {
        if (sameAnchor(left, right)) return .eq;
        // null is the conceptual end sentinel for right origins.
        if (left == null) return .gt;
        if (right == null) return .lt;
        const left_index = self.find(left.?) orelse return error.UnknownOrigin;
        const right_index = self.find(right.?) orelse return error.UnknownOrigin;
        if (left_index < right_index) return .lt;
        return .gt;
    }

    fn firstChildIndex(self: *const MergeIndex, parent: Anchor, side: Side, view: ?View) ?usize {
        for (self.records.items, 0..) |entry, index| {
            if (entry.side != side or !sameAnchor(entry.parent, parent)) continue;
            if (view) |wanted_view| {
                const inserted = switch (wanted_view) {
                    .prepare => entry.prepare_inserted,
                    .effect => entry.effect_inserted,
                };
                if (!inserted) continue;
            }
            return index;
        }
        return null;
    }

    fn leftmostDescendantIndex(self: *const MergeIndex, start: usize, view: ?View) usize {
        var current = start;
        while (self.firstChildIndex(self.records.items[current].id, .left, view)) |left_child| {
            current = left_child;
        }
        return current;
    }

    fn nextNonDescendant(self: *const MergeIndex, view: View, origin: Anchor) !Anchor {
        const origin_index = origin orelse return null;
        const index = self.find(origin_index) orelse return error.UnknownOrigin;
        var next = self.subtreeEnd(index);
        while (next < self.records.items.len) : (next += 1) {
            const entry = self.records.items[next];
            const inserted = switch (view) {
                .prepare => entry.prepare_inserted,
                .effect => entry.effect_inserted,
            };
            if (inserted) return entry.id;
        }
        return null;
    }

    fn subtreeEnd(self: *const MergeIndex, start: usize) usize {
        var index = start + 1;
        while (index < self.records.items.len and self.isDescendantIndex(index, start)) : (index += 1) {}
        return index;
    }

    fn isDescendantIndex(self: *const MergeIndex, candidate: usize, ancestor: usize) bool {
        const ancestor_id = self.records.items[ancestor].id;
        var current = self.records.items[candidate].parent;
        while (current) |parent| {
            if (parent.eql(ancestor_id)) return true;
            const parent_index = self.find(parent) orelse return false;
            current = self.records.items[parent_index].parent;
        }
        return false;
    }
};

fn sameAnchor(left: Anchor, right: Anchor) bool {
    if (left == null) return right == null;
    if (right == null) return false;
    return left.?.eql(right.?);
}

fn actor(last_byte: u8) id.ActorId {
    var value = [_]u8{0} ** 16;
    value[15] = last_byte;
    return value;
}

fn actorOp(last_byte: u8, counter: u64) OpId {
    return .{ .actor = actor(last_byte), .counter = counter };
}

fn element(last_actor: u8, counter: u64, offset: u32, parent: Anchor, right_origin: Anchor, text: []const u8) Insert {
    return .{
        .id = .{ .op = .{ .actor = actor(last_actor), .counter = counter }, .offset = offset },
        .parent = parent,
        .right_origin = right_origin,
        .scalar = Scalar.fromBytes(text),
    };
}

test "insertAt derives FugueMax origin-left and right-parent anchors" {
    var index = try MergeIndex.init(std.testing.allocator);
    defer index.deinit();

    const root_id = ElementId{ .op = .{ .actor = actor(1), .counter = 0 }, .offset = 0 };
    const before_root_id = ElementId{ .op = .{ .actor = actor(2), .counter = 0 }, .offset = 0 };
    const between_id = ElementId{ .op = .{ .actor = actor(3), .counter = 0 }, .offset = 0 };

    const root = try index.insertAt(.effect, 0, root_id, Scalar.fromBytes("A"));
    try std.testing.expectEqual(Side.right, root.side);
    try std.testing.expect(root.parent == null);
    try std.testing.expect(root.right_origin == null);

    const before_root = try index.insertAt(.effect, 0, before_root_id, Scalar.fromBytes("B"));
    try std.testing.expectEqual(Side.right, before_root.side);
    try std.testing.expect(before_root.parent == null);
    try std.testing.expect(before_root.right_origin != null);
    try std.testing.expect(before_root.right_origin.?.eql(root_id));

    const between = try index.insertAt(.effect, 1, between_id, Scalar.fromBytes("C"));
    try std.testing.expectEqual(Side.right, between.side);
    try std.testing.expect(between.parent != null);
    try std.testing.expect(between.parent.?.eql(before_root_id));
    try std.testing.expect(between.right_origin != null);
    try std.testing.expect(between.right_origin.?.eql(root_id));

    const rendered = try index.render(std.testing.allocator, .effect);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("BCA", rendered);
}

test "plain Fugue compatibility mode only records sibling right parents" {
    var index = try MergeIndex.initWithOrdering(std.testing.allocator, .fugue);
    defer index.deinit();

    const root_id = ElementId{ .op = actorOp(1, 0), .offset = 0 };
    const before_root_id = ElementId{ .op = actorOp(2, 0), .offset = 0 };
    const between_id = ElementId{ .op = actorOp(3, 0), .offset = 0 };

    _ = try index.insertAt(.effect, 0, root_id, Scalar.fromBytes("A"));
    const before_root = try index.insertAt(.effect, 0, before_root_id, Scalar.fromBytes("B"));
    try std.testing.expect(before_root.right_origin != null);
    try std.testing.expect(before_root.right_origin.?.eql(root_id));

    const between = try index.insertAt(.effect, 1, between_id, Scalar.fromBytes("C"));
    try std.testing.expect(between.parent != null);
    try std.testing.expect(between.parent.?.eql(before_root_id));
    try std.testing.expect(between.right_origin == null);

    const rendered = try index.render(std.testing.allocator, .effect);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("BCA", rendered);
}

test "durable anchors keep descendants grouped when inserted causally" {
    var first = try MergeIndex.init(std.testing.allocator);
    defer first.deinit();

    const a = element(1, 0, 0, null, null, "A");
    const b = element(2, 0, 0, null, null, "B");
    const a_child = element(1, 1, 0, a.id, b.id, "a");
    const b_child = element(2, 1, 0, b.id, null, "b");

    try first.insert(a);
    try first.insert(b);
    try first.insert(a_child);
    try first.insert(b_child);

    const first_text = try first.render(std.testing.allocator, .effect);
    defer std.testing.allocator.free(first_text);
    try std.testing.expectEqualStrings("AaBb", first_text);
}

test "durable anchor insertion rejects unknown origins" {
    var first = try MergeIndex.init(std.testing.allocator);
    defer first.deinit();

    const missing = element(4, 0, 0, ElementId{ .op = actorOp(9, 0), .offset = 0 }, null, "x");
    try std.testing.expectError(error.UnknownOrigin, first.insert(missing));
    try std.testing.expectEqual(@as(usize, 0), first.items().len);
}

test "merge index ranks visible records while retaining tombstones" {
    var index = try MergeIndex.init(std.testing.allocator);
    defer index.deinit();

    const first = element(1, 0, 0, null, null, "A");
    const second = element(1, 1, 0, first.id, null, "B");
    try index.insert(first);
    try index.insert(second);

    try index.deleteEffect(first.id);
    try std.testing.expectEqual(@as(usize, 1), index.visibleCount(.effect));
    try std.testing.expectEqual(@as(usize, 0), try index.rankBefore(second.id, .effect));
    try std.testing.expect(ElementId.eql(second.id, index.visibleAt(.effect, 0).?));
    try std.testing.expectEqual(@as(usize, 2), index.items().len);

    try index.undeleteEffect(first.id);
    try std.testing.expectEqual(@as(usize, 2), index.visibleCount(.effect));
}

test "merge index tracks prepare and effect views independently" {
    var index = try MergeIndex.init(std.testing.allocator);
    defer index.deinit();

    const item = element(1, 0, 0, null, null, "A");
    try index.insert(item);
    try index.deletePrepare(item.id);
    try std.testing.expect(!(try index.isVisible(item.id, .prepare)));
    try std.testing.expect(try index.isVisible(item.id, .effect));

    try index.deleteEffect(item.id);
    try std.testing.expect(!(try index.isVisible(item.id, .effect)));
    try index.undeletePrepare(item.id);
    try index.undeleteEffect(item.id);
    try std.testing.expect(try index.isVisible(item.id, .prepare));
    try std.testing.expect(try index.isVisible(item.id, .effect));
}

test "merge index can retreat and advance insertion and deletion contributions" {
    var index = try MergeIndex.init(std.testing.allocator);
    defer index.deinit();

    const item = element(1, 0, 0, null, null, "A");
    try index.insert(item);

    try index.advancePrepareDelete(item.id);
    try std.testing.expect(!(try index.isVisible(item.id, .prepare)));
    try index.retreatPrepareInsert(item.id);
    try index.retreatPrepareDelete(item.id);
    try std.testing.expect(!(try index.isVisible(item.id, .prepare)));
    try index.advancePrepareInsert(item.id);
    try std.testing.expect(try index.isVisible(item.id, .prepare));
}
