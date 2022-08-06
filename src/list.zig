const std = @import("std");
const Atomic = std.atomic.Atomic;
const Allocator = std.mem.Allocator;

const NodePtr = Atomic(?*Node);

/// This is a simple, concurrent linked list using acquire/release semantics.
/// It can be used by a single writer and multiple readers simultaniously.
pub const List = struct {
    head: NodePtr = NodePtr.init(null),

    /// Insert or remove node from list.
    /// A removed node must only be freed after all readers have dropped
    /// their references to that node.
    pub fn toggle(self: *List, value: u32, allocator: Allocator) !?*Node {
        var ptr = &self.head;
        var current: ?*Node = undefined;
        while (true) : (ptr = &current.?.next) {
            current = ptr.load(.Unordered);
            if (current == null or current.?.value > value) {
                var node = try allocator.create(Node);
                node.* = .{ .value = value, .next = NodePtr.init(current) };
                ptr.store(node, .Release);
                return null;
            } else if (current.?.value == value) {
                ptr.store(current.?.next.load(.Unordered), .Monotonic);
                return current;
            }
        }
    }

    pub fn lookup(self: *const List, value: u32) bool {
        var ptr = &self.head;
        var current: ?*Node = undefined;
        while (true) : (ptr = &current.?.next) {
            current = ptr.load(.Acquire);
            if (current == null or current.?.value > value)
                return false;
            if (current.?.value == value)
                return true;
        }
    }

    pub fn deinit(self: *List, allocator: Allocator) void {
        var current = self.head.load(.Unordered);
        while (true) {
            if (current == null)
                return;

            const tmp = current.?.next.load(.Unordered);
            allocator.destroy(current.?);
            current = tmp;
        }
    }
};

pub const Node = struct {
    next: NodePtr,
    value: u32,
};
