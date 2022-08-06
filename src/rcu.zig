//! This is a simple RCU library with explicit reader registration.
//! It uses barriers and shared variables to detect quiescent state.
//! It also supports nesting read-side critical sections.

const std = @import("std");
const Atomic = std.atomic.Atomic;
const ArrayList = std.ArrayList;
const Mutex = std.Thread.Mutex;
const Allocator = std.mem.Allocator;
const fence = std.atomic.fence;
const Thread = std.Thread;
const ResetEvent = std.Thread.ResetEvent;

const Trackers = ArrayList(Tracker);
const Callbacks = ArrayList(Callback);
pub const Rcu = struct {
    trackers: Trackers,
    callbacks: Callbacks,
    next: Callbacks,
    mutex: Mutex = .{},
    background: ?Thread = null,
    reset: ResetEvent = .{ .impl = .{} },

    pub fn init(allocator: Allocator) Rcu {
        return .{
            .trackers = Trackers.init(allocator),
            .callbacks = Callbacks.init(allocator),
            .next = Callbacks.init(allocator),
        };
    }

    pub fn addReader(self: *Rcu, reader: *Reader) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.trackers.append(.{ .reader = reader });
    }

    pub fn removeReader(self: *Rcu, reader: *Reader) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.trackers.items) |tracker, i| {
            if (tracker.reader != reader)
                continue;

            if (tracker.reader.nesting.load(.Monotonic) > 0) @panic("reader busy");
            _ = self.trackers.swapRemove(i);
            return;
        }
        @panic("reader not registered");
    }

    /// This spawns a separate thread for periodically invoking the callbacks.
    pub fn startBackground(self: *Rcu) !void {
        if (self.background != null) @panic("background already started");

        self.reset.reset();
        self.background = try Thread.spawn(.{}, Rcu.backgroundFunc, .{self});
    }

    fn backgroundFunc(self: *Rcu) void {
        while (true) {
            const reason = self.reset.timedWait(1 << 23);

            self.mutex.lock();
            defer self.mutex.unlock();

            var setPin = false;
            if (self.next.items.len == 0) {
                std.mem.swap(Callbacks, &self.callbacks, &self.next);
                setPin = true;
            }
            if (self.next.items.len == 0) {
                if (reason == .event_set)
                    return;
                continue;
            }

            if (self.checkGracePeriod(setPin)) {
                for (self.trackers.items) |*tracker| {
                    tracker.quiescent = false;
                }

                fence(.SeqCst);
                for (self.next.items) |callback| {
                    callback.func(callback.arg);
                }
                self.next.clearRetainingCapacity();
            }
        }
    }

    fn checkGracePeriod(self: *Rcu, setPin: bool) bool {
        var gracePeriod = true;
        for (self.trackers.items) |*tracker| {
            if (tracker.quiescent)
                continue;

            const reader = tracker.reader;
            if (setPin) {
                reader.pin.store(true, .Monotonic);
            } else if (reader.pin.load(.Monotonic) == false) {
                tracker.quiescent = true;
                continue;
            }

            if (reader.nesting.load(.Monotonic) == 0) {
                tracker.quiescent = true;
                continue;
            }

            gracePeriod = false;
        }
        return gracePeriod;
    }

    pub fn stopBackground(self: *Rcu) void {
        if (self.background) |background| {
            self.reset.set();
            background.join();
        }
    }

    /// Register RCU callback.
    pub fn call(self: *Rcu, func: fn (*anyopaque) void, arg: *anyopaque) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.callbacks.append(.{ .func = func, .arg = arg });
    }

    pub fn deinit(self: *Rcu) void {
        self.stopBackground();
        self.callbacks.deinit();
        self.next.deinit();

        for (self.trackers.items) |tracker|
            if (tracker.reader.nesting.load(.Monotonic) > 0) @panic("reader busy");

        self.trackers.deinit();
    }
};

pub const Reader = struct {
    nesting: Atomic(u8) = Atomic(u8).init(0),
    pin: Atomic(bool) = Atomic(bool).init(false),

    pub fn lock(self: *Reader) !void {
        const nesting = self.nesting.load(.Unordered);
        self.nesting.store(try std.math.add(u8, nesting, 1), .Monotonic);
        fence(.SeqCst);
    }

    pub fn unlock(self: *Reader) void {
        fence(.SeqCst);

        var nesting = self.nesting.load(.Unordered);
        nesting = std.math.sub(u8, nesting, 1) catch @panic("reader not locked");
        self.nesting.store(nesting, .Monotonic);
        if (nesting == 0)
            self.pin.store(false, .Monotonic);
    }
};

const Tracker = struct {
    reader: *Reader,
    quiescent: bool = false,
};

const Callback = struct {
    func: fn (*anyopaque) void,
    arg: *anyopaque,
};
