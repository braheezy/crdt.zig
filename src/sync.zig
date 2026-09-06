const std = @import("std");
const id = @import("id.zig");

pub const ActorId = id.ActorId;
pub const OpId = id.OpId;

/// An inclusive interval of counters belonging to one actor.
///
/// A Have is deliberately sparse: out-of-order delivery can leave holes, so
/// one actor may be represented by several ranges instead of one version-vector
/// entry. Ranges in a Have are kept sorted by actor and then by start.
pub const CounterRange = struct {
    actor: ActorId,
    start: u64,
    end: u64,

    pub fn contains(self: CounterRange, counter: u64) bool {
        return counter >= self.start and counter <= self.end;
    }
};

pub const DecodeOptions = struct {
    max_ranges: usize = 1 << 20,
};

/// A canonical summary of the accepted operation IDs known by a replica.
///
/// The summary is only a sync hint. The receiver still validates every Change
/// and checks its causal parents. Pending changes are intentionally not
/// included: advertising a child that cannot yet be applied could make a peer
/// suppress the parent it actually needs.
pub const Have = struct {
    allocator: std.mem.Allocator,
    ranges: std.ArrayList(CounterRange) = .empty,

    pub fn init(allocator: std.mem.Allocator) Have {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Have) void {
        self.ranges.deinit(self.allocator);
    }

    pub fn clone(self: *const Have, allocator: std.mem.Allocator) !Have {
        var result = Have.init(allocator);
        errdefer result.deinit();
        try result.ranges.appendSlice(allocator, self.ranges.items);
        return result;
    }

    /// Encode the canonical summary into a standalone sync frame.
    ///
    /// The frame intentionally carries no document ID; the application-level
    /// session supplies that context. The core only defines the summary's
    /// deterministic bytes and validation rules.
    pub fn encode(self: *const Have, allocator: std.mem.Allocator) ![]u8 {
        var bytes: std.ArrayList(u8) = .empty;
        errdefer bytes.deinit(allocator);

        try bytes.appendSlice(allocator, "CRDTHAV\x00");
        try bytes.append(allocator, 1);
        try appendVarint(&bytes, allocator, self.ranges.items.len);
        for (self.ranges.items) |range| {
            try bytes.appendSlice(allocator, &range.actor);
            try appendU64Varint(&bytes, allocator, range.start);
            try appendU64Varint(&bytes, allocator, range.end);
        }
        return bytes.toOwnedSlice(allocator);
    }

    /// Decode and validate a canonical summary. Decoding never normalizes
    /// malformed input: a sender must have emitted sorted, non-overlapping,
    /// non-adjacent ranges already.
    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8, options: DecodeOptions) !Have {
        const magic = "CRDTHAV\x00";
        if (bytes.len < magic.len + 1 or !std.mem.eql(u8, bytes[0..magic.len], magic)) {
            return error.InvalidFormat;
        }

        var cursor: usize = magic.len;
        const version = try readByte(bytes, &cursor);
        if (version != 1) return error.UnsupportedFormat;

        const range_count = try readVarint(bytes, &cursor);
        if (range_count > @as(u64, @intCast(options.max_ranges))) return error.TooManyRanges;

        var result = Have.init(allocator);
        errdefer result.deinit();
        try result.ranges.ensureTotalCapacity(allocator, @intCast(range_count));

        var previous: ?CounterRange = null;
        var range_index: u64 = 0;
        while (range_index < range_count) : (range_index += 1) {
            var actor_id: ActorId = undefined;
            const actor_bytes = try readBytes(bytes, &cursor, actor_id.len);
            @memcpy(&actor_id, actor_bytes);
            const start = try readVarint(bytes, &cursor);
            const end = try readVarint(bytes, &cursor);
            if (start > end) return error.InvalidRange;

            const current = CounterRange{ .actor = actor_id, .start = start, .end = end };
            if (previous) |prior| {
                const actor_order = std.mem.order(u8, &prior.actor, &current.actor);
                if (actor_order == .gt) return error.NonCanonical;
                if (actor_order == .eq and rangesTouch(prior, current)) {
                    return error.NonCanonical;
                }
            }
            try result.ranges.append(allocator, current);
            previous = current;
        }

        if (cursor != bytes.len) return error.InvalidFormat;
        return result;
    }

    /// Add one operation ID, merging it with adjacent or overlapping ranges.
    pub fn add(self: *Have, operation_id: OpId) !void {
        try self.addRange(operation_id.actor, operation_id.counter, operation_id.counter);
    }

    /// Add an inclusive counter interval. Empty/reversed intervals are
    /// rejected instead of silently creating a malformed summary.
    pub fn addRange(self: *Have, actor_id: ActorId, start: u64, end: u64) !void {
        if (start > end) return error.InvalidRange;

        // Appending is the only fallible operation. Canonicalization below is
        // in-place, so an allocation failure leaves the previous summary
        // untouched.
        try self.ranges.append(self.allocator, .{ .actor = actor_id, .start = start, .end = end });
        std.sort.heap(CounterRange, self.ranges.items, {}, lessRange);

        var write: usize = 0;
        for (self.ranges.items) |candidate| {
            if (write == 0) {
                self.ranges.items[write] = candidate;
                write += 1;
                continue;
            }

            const previous = &self.ranges.items[write - 1];
            if (sameActor(previous.actor, candidate.actor) and rangesTouch(previous.*, candidate)) {
                if (candidate.end > previous.end) previous.end = candidate.end;
            } else {
                self.ranges.items[write] = candidate;
                write += 1;
            }
        }
        self.ranges.items.len = write;
    }

    pub fn contains(self: *const Have, operation_id: OpId) bool {
        var lower: usize = 0;
        var upper: usize = self.ranges.items.len;
        while (lower < upper) {
            const middle = lower + (upper - lower) / 2;
            const range = self.ranges.items[middle];
            const actor_order = std.mem.order(u8, &operation_id.actor, &range.actor);
            if (actor_order == .lt) {
                upper = middle;
            } else if (actor_order == .gt) {
                lower = middle + 1;
            } else if (operation_id.counter < range.start) {
                upper = middle;
            } else if (operation_id.counter > range.end) {
                lower = middle + 1;
            } else {
                return true;
            }
        }
        return false;
    }

    pub fn isEmpty(self: *const Have) bool {
        return self.ranges.items.len == 0;
    }

    pub fn rangeCount(self: *const Have) usize {
        return self.ranges.items.len;
    }

    /// Borrow the canonical range list. It remains valid until the next
    /// mutating call on this Have or deinit.
    pub fn rangesView(self: *const Have) []const CounterRange {
        return self.ranges.items;
    }

    pub fn merge(self: *Have, other: *const Have) !void {
        if (@as(*const Have, self) == other) return;
        const combined = @addWithOverflow(self.ranges.items.len, other.ranges.items.len);
        if (combined[1] != 0) return error.TooManyRanges;
        // Reserve all possible raw ranges before canonicalizing.  addRange
        // only appends one item and then performs an in-place merge, so this
        // makes the whole operation failure-atomic with respect to OOM.
        try self.ranges.ensureTotalCapacity(self.allocator, combined[0]);
        for (other.ranges.items) |range| {
            try self.addRange(range.actor, range.start, range.end);
        }
    }

    /// Return true when every ID represented by `self` is represented by
    /// `other`. Canonical ranges make this an interval containment check.
    pub fn isSubsetOf(self: *const Have, other: *const Have) bool {
        for (self.ranges.items) |range| {
            if (!other.containsRange(range)) return false;
        }
        return true;
    }

    fn containsRange(self: *const Have, wanted: CounterRange) bool {
        var lower: usize = 0;
        var upper: usize = self.ranges.items.len;
        while (lower < upper) {
            const middle = lower + (upper - lower) / 2;
            const candidate = self.ranges.items[middle];
            const actor_order = std.mem.order(u8, &wanted.actor, &candidate.actor);
            if (actor_order == .lt) {
                upper = middle;
            } else if (actor_order == .gt) {
                lower = middle + 1;
            } else if (candidate.end < wanted.start) {
                lower = middle + 1;
            } else if (candidate.start > wanted.end) {
                upper = middle;
            } else {
                return candidate.start <= wanted.start and candidate.end >= wanted.end;
            }
        }
        return false;
    }
};

fn sameActor(left: ActorId, right: ActorId) bool {
    return std.mem.eql(u8, &left, &right);
}

fn rangesTouch(left: CounterRange, right: CounterRange) bool {
    if (left.end >= right.start) return true;
    if (left.end == std.math.maxInt(u64)) return true;
    return left.end + 1 >= right.start;
}

fn lessRange(_: void, left: CounterRange, right: CounterRange) bool {
    const actor_order = std.mem.order(u8, &left.actor, &right.actor);
    if (actor_order == .lt) return true;
    if (actor_order == .gt) return false;
    if (left.start != right.start) return left.start < right.start;
    return left.end < right.end;
}

fn appendU64Varint(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u64) !void {
    var remaining = value;
    while (remaining >= 0x80) {
        try list.append(allocator, @as(u8, @intCast(remaining & 0x7f)) | 0x80);
        remaining >>= 7;
    }
    try list.append(allocator, @intCast(remaining));
}

fn appendVarint(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: usize) !void {
    try appendU64Varint(list, allocator, @intCast(value));
}

fn readByte(bytes: []const u8, cursor: *usize) !u8 {
    if (cursor.* >= bytes.len) return error.UnexpectedEnd;
    const result = bytes[cursor.*];
    cursor.* += 1;
    return result;
}

fn readBytes(bytes: []const u8, cursor: *usize, length: usize) ![]const u8 {
    if (cursor.* > bytes.len or length > bytes.len - cursor.*) return error.UnexpectedEnd;
    const result = bytes[cursor.* .. cursor.* + length];
    cursor.* += length;
    return result;
}

fn readVarint(bytes: []const u8, cursor: *usize) !u64 {
    var result: u64 = 0;
    var shift: u7 = 0;
    while (true) {
        const byte = try readByte(bytes, cursor);
        const payload = byte & 0x7f;
        if (shift == 63 and payload > 1) return error.InvalidFormat;
        result |= @as(u64, payload) << @intCast(shift);
        if ((byte & 0x80) == 0) {
            if (shift > 0 and result < (@as(u64, 1) << @intCast(shift))) return error.NonCanonical;
            return result;
        }
        if (shift >= 63) return error.InvalidFormat;
        shift += 7;
    }
}

fn actor(last_byte: u8) ActorId {
    var value = [_]u8{0} ** 16;
    value[15] = last_byte;
    return value;
}

fn op(actor_last_byte: u8, counter: u64) OpId {
    return .{ .actor = actor(actor_last_byte), .counter = counter };
}

test "Have merges overlapping and adjacent ranges but preserves holes" {
    var have = Have.init(std.testing.allocator);
    defer have.deinit();

    try have.add(op(1, 3));
    try have.addRange(actor(1), 5, 7);

    try std.testing.expectEqual(@as(usize, 2), have.rangeCount());
    try std.testing.expect(!have.contains(op(1, 2)));
    try std.testing.expect(have.contains(op(1, 3)));
    try std.testing.expect(have.contains(op(1, 7)));
    try std.testing.expect(!have.contains(op(1, 8)));

    try have.addRange(actor(1), 4, 4);
    try std.testing.expectEqual(@as(usize, 1), have.rangeCount());
}

test "Have keeps ranges in canonical actor and counter order" {
    var have = Have.init(std.testing.allocator);
    defer have.deinit();

    try have.add(op(2, 9));
    try have.add(op(1, 4));
    try have.add(op(2, 1));

    const ranges = have.rangesView();
    try std.testing.expectEqual(@as(usize, 3), ranges.len);
    try std.testing.expectEqual(@as(u8, 1), ranges[0].actor[15]);
    try std.testing.expectEqual(@as(u8, 2), ranges[1].actor[15]);
    try std.testing.expectEqual(@as(u64, 1), ranges[1].start);
    try std.testing.expectEqual(@as(u64, 9), ranges[2].start);
}

test "Have rejects reversed ranges without mutation" {
    var have = Have.init(std.testing.allocator);
    defer have.deinit();

    try std.testing.expectError(error.InvalidRange, have.addRange(actor(1), 8, 2));
    try std.testing.expect(have.isEmpty());
}

test "Have merge and subset operations use sparse ranges" {
    var left = Have.init(std.testing.allocator);
    defer left.deinit();
    var right = Have.init(std.testing.allocator);
    defer right.deinit();

    try left.addRange(actor(1), 1, 3);
    try left.addRange(actor(2), 8, 8);
    try right.addRange(actor(1), 0, 5);
    try right.addRange(actor(2), 8, 9);

    try std.testing.expect(left.isSubsetOf(&right));
    try std.testing.expect(!right.isSubsetOf(&left));
    try left.merge(&right);
    try std.testing.expectEqual(@as(usize, 2), left.rangeCount());
    try std.testing.expect(left.contains(op(1, 5)));
    try std.testing.expect(left.contains(op(2, 9)));
}

test "Have.merge with itself is a no-op" {
    var have = Have.init(std.testing.allocator);
    defer have.deinit();
    try have.addRange(actor(1), 2, 4);
    try have.merge(&have);
    try std.testing.expectEqual(@as(usize, 1), have.rangeCount());
    try std.testing.expect(have.contains(op(1, 3)));
}

test "Have encoding round trips to canonical bytes" {
    var original = Have.init(std.testing.allocator);
    defer original.deinit();
    try original.addRange(actor(2), 4, 8);
    try original.addRange(actor(1), 0, 0);

    const encoded = try original.encode(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    var decoded = try Have.decode(std.testing.allocator, encoded, .{});
    defer decoded.deinit();

    try std.testing.expect(decoded.isSubsetOf(&original));
    try std.testing.expect(original.isSubsetOf(&decoded));
    const reencoded = try decoded.encode(std.testing.allocator);
    defer std.testing.allocator.free(reencoded);
    try std.testing.expectEqualSlices(u8, encoded, reencoded);
}

test "Have decoding rejects truncation, trailing bytes, and non-canonical ranges" {
    var have = Have.init(std.testing.allocator);
    defer have.deinit();
    try have.add(op(1, 2));
    const encoded = try have.encode(std.testing.allocator);
    defer std.testing.allocator.free(encoded);

    try std.testing.expectError(error.UnexpectedEnd, Have.decode(std.testing.allocator, encoded[0 .. encoded.len - 1], .{}));

    var trailing = try std.testing.allocator.alloc(u8, encoded.len + 1);
    defer std.testing.allocator.free(trailing);
    @memcpy(trailing[0..encoded.len], encoded);
    trailing[encoded.len] = 0;
    try std.testing.expectError(error.InvalidFormat, Have.decode(std.testing.allocator, trailing, .{}));

    // The frame below is the valid one-range header followed by a second
    // range for the same actor that touches the first. Canonical Have values
    // must have coalesced those intervals before encoding.
    var malformed = std.ArrayList(u8).empty;
    defer malformed.deinit(std.testing.allocator);
    const malformed_actor = actor(1);
    try malformed.appendSlice(std.testing.allocator, "CRDTHAV\x00");
    try malformed.append(std.testing.allocator, 1);
    try appendVarint(&malformed, std.testing.allocator, 2);
    try malformed.appendSlice(std.testing.allocator, &malformed_actor);
    try appendU64Varint(&malformed, std.testing.allocator, 0);
    try appendU64Varint(&malformed, std.testing.allocator, 0);
    try malformed.appendSlice(std.testing.allocator, &malformed_actor);
    try appendU64Varint(&malformed, std.testing.allocator, 1);
    try appendU64Varint(&malformed, std.testing.allocator, 2);
    try std.testing.expectError(error.NonCanonical, Have.decode(std.testing.allocator, malformed.items, .{}));
}

test "Have decoding enforces a range count limit" {
    var have = Have.init(std.testing.allocator);
    defer have.deinit();
    try have.add(op(1, 0));
    const encoded = try have.encode(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectError(
        error.TooManyRanges,
        Have.decode(std.testing.allocator, encoded, .{ .max_ranges = 0 }),
    );
}

fn allocationFailureHaveMerge(allocator: std.mem.Allocator) !void {
    const actor_a = [_]u8{0} ** 15 ++ [_]u8{121};
    const actor_b = [_]u8{0} ** 15 ++ [_]u8{122};
    var left = Have.init(allocator);
    defer left.deinit();
    var right = Have.init(allocator);
    defer right.deinit();

    try left.addRange(actor_a, 0, 0);
    try right.addRange(actor_b, 0, 0);
    try right.addRange(actor_b, 2, 2);
    try left.merge(&right);
}

test "Have.merge is allocation-failure atomic" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocationFailureHaveMerge,
        .{},
    );
}
