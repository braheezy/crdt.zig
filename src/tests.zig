const std = @import("std");

// Import every test-bearing module so `zig build test` compiles all of the
// project's tests, even when a module is not reachable from a library root.
const id = @import("id.zig");
const frontier = @import("frontier.zig");
const operation = @import("operation.zig");
const change = @import("change.zig");
const causal_graph = @import("causal_graph.zig");
const text_buffer = @import("text_buffer.zig");
const document = @import("document.zig");
const sequence_item = @import("sequence_item.zig");
const sequence = @import("sequence.zig");

comptime {
    std.testing.refAllDecls(id);
    std.testing.refAllDecls(frontier);
    std.testing.refAllDecls(operation);
    std.testing.refAllDecls(change);
    std.testing.refAllDecls(causal_graph);
    std.testing.refAllDecls(text_buffer);
    std.testing.refAllDecls(document);
    std.testing.refAllDecls(sequence_item);
    std.testing.refAllDecls(sequence);
}
