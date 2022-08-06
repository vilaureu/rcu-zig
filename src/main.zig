//! This program tests the RCU library by using a single writer to add and
//! remove from a linked list while concurrently reading from the list using
//! multiple readers.

const rcuLib = @import("./rcu.zig");
const Rcu = rcuLib.Rcu;
const Reader = rcuLib.Reader;

const listLib = @import("./list.zig");
const List = listLib.List;
const Node = listLib.Node;

const std = @import("std");
const Gpa = std.heap.GeneralPurposeAllocator(.{});
const Allocator = std.mem.Allocator;
const sleep = std.time.sleep;
const print = std.debug.print;
const Atomic = std.atomic.Atomic;
const Thread = std.Thread;
const DefaultPrng = std.rand.DefaultPrng;
const maxInt = std.math.maxInt;
const Timer = std.time.Timer;
const ArrayList = std.ArrayList;

const BOUND = 1 << 10;
/// Number of reader threads to spawn.
const THREADS = 15;

pub fn main() !void {
    var gpa = Gpa{};
    defer if (gpa.deinit()) @panic("memory leaked");
    var allocator = gpa.allocator();

    var orphan: ?*Node = null;
    errdefer if (orphan) |o| allocator.destroy(o);

    var list = List{};
    defer list.deinit(allocator);

    var garbage = ArrayList(*Node).init(allocator);
    defer {
        for (garbage.items) |node| {
            allocator.destroy(node);
        }
        garbage.deinit();
    }

    var rcu = Rcu.init(allocator);
    defer rcu.deinit();

    var stop = Atomic(bool).init(false);
    var handles: [THREADS]Thread = undefined;
    var handlesInit: usize = 0;
    errdefer {
        stop.store(true, .Monotonic);
        for (handles[0..handlesInit]) |handle| {
            handle.join();
        }
    }
    var stats: [THREADS]ReaderStat = undefined;
    for (handles) |*handle, i| {
        handle.* = try Thread.spawn(.{}, readerFunc, .{ &rcu, &list, &stop, i, &stats[i] });
        handlesInit += 1;
    }

    try rcu.startBackground();

    var insertions: u64 = 0;
    var removals: u64 = 0;
    var i: u64 = 0;
    var rng = DefaultPrng.init(maxInt(u64)).random();
    var timer = try Timer.start();
    while (i < 1 << 23) : (i += 1) {
        const value = rng.uintLessThanBiased(u32, BOUND);

        var node = try list.toggle(value, allocator);
        if (node) |n| {
            removals += 1;

            garbage.append(n) catch |err| {
                orphan = n;
                return err;
            };
        } else {
            insertions += 1;
        }

        // reduce number of RCU calls
        if (garbage.items.len >= 1 << 10) {
            var arg = try allocator.create(Arg);
            errdefer allocator.destroy(arg);
            arg.* = .{ .garbage = garbage, .allocator = allocator };
            try rcu.call(Arg.free, arg);
            garbage = ArrayList(*Node).init(allocator);
        }
    }
    const time = timer.read();

    stop.store(true, .Monotonic);
    for (handles) |handle| {
        handle.join();
    }

    print("writer made {} iterations ({} insertions, {} removals) in {} ns\n", .{ i, insertions, removals, time });
    var iters_avg: u64 = 0;
    var hits_avg: u64 = 0;
    for (stats) |stat| {
        iters_avg += stat.iterations;
        hits_avg += stat.hits;
        print("reader {} made {} iterations with {} hits in {} ns\n", .{ stat.id, stat.iterations, stat.hits, stat.time });
    }
    iters_avg /= stats.len * 1_000;
    hits_avg /= stats.len * 1_000;
    print("{} ms for writing, {}K average read iterations and {}K hits\n", .{ time / 1_000_000, iters_avg, hits_avg });
}

fn readerFunc(rcu: *Rcu, list: *const List, stop: *const Atomic(bool), id: u64, stat: *ReaderStat) !void {
    var rng = DefaultPrng.init(id).random();

    var reader = Reader{};
    try rcu.addReader(&reader);
    defer rcu.removeReader(&reader);

    var iterations: u64 = 0;
    var hits: u64 = 0;
    var timer = try Timer.start();

    try reader.lock();
    while (!stop.load(.Monotonic)) : (iterations += 1) {
        // serialize less often
        if (iterations != 0 and iterations % (1 << 10) == 0) {
            reader.unlock();
            try reader.lock();
        }

        const value = rng.uintLessThanBiased(u32, BOUND);
        if (list.lookup(value))
            hits += 1;
    }
    reader.unlock();

    const time = timer.read();

    stat.* = .{ .id = id, .iterations = iterations, .hits = hits, .time = time };
}

const ReaderStat = struct {
    id: u64,
    iterations: u64,
    hits: u64,
    time: u64,
};

const Arg = struct {
    garbage: ArrayList(*Node),
    allocator: Allocator,

    fn free(ptr: *anyopaque) void {
        const arg: *Arg = @ptrCast(*Arg, @alignCast(@alignOf(*Arg), ptr));
        const allocator = arg.allocator;
        for (arg.garbage.items) |node|
            allocator.destroy(node);
        arg.garbage.deinit();
        allocator.destroy(arg);
    }
};
