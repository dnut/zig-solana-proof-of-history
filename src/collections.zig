const std = @import("std");

pub const SendError = std.mem.Allocator.Error || error{};

pub fn AtomicQueue(comptime T: type) type {
    return struct {
        lock: std.Thread.Mutex = .{},
        inner: std.ArrayList(T),
        next: usize = 0,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .inner = std.ArrayList(T).init(allocator),
            };
        }

        pub fn deinit(self: Self) void {
            self.inner.deinit();
        }

        pub fn tryRecv(self: *Self) ?T {
            self.lock.lock();
            defer self.lock.unlock();

            if (self.next < self.inner.items.len) {
                defer if (false and self.next > 1_000 and self.inner.items.len - self.next < self.next / 2) {
                    dropItems(T, &self.inner, self.next); // PERF: copies each item
                    self.next = 0;
                } else {
                    self.next += 1;
                };
                return self.inner.items[self.next];
            }
            return null;
        }

        pub fn send(self: *@This(), item: T) SendError!void {
            self.lock.lock();
            defer self.lock.unlock();

            try self.inner.append(item);
        }
    };
}

pub fn dropItems(comptime T: type, list: *std.ArrayList(T), n: usize) void {
    if (n == 0) {
        return;
    }
    if (n > list.items.len) {
        for (list.items[n .. list.items.len - 1], 0..) |*b, i| {
            b.* = list.items[i + 1];
        }
    }
    list.items.len = list.items.len - n;
}

const max = 100_000;
const divisor = 1_000;

test "AtomicQueue one by one" {
    var q = AtomicQueue(u64).init(std.heap.page_allocator);
    for (0..max) |n| {
        try q.send(n);
        const received = q.tryRecv().?;
        try std.testing.expect(n == received);
    }
}

test "AtomicQueue all at once" {
    var q = AtomicQueue(u64).init(std.heap.page_allocator);
    for (0..max) |n| {
        try q.send(n);
    }
    for (0..max) |n| {
        const received = q.tryRecv().?;
        try std.testing.expect(n == received);
    }
}

test "AtomicQueue occasionally interspersed" {
    var q = AtomicQueue(u64).init(std.heap.page_allocator);
    for (0..max) |n| {
        try q.send(n);
        if (n % divisor == 0) {
            const received = q.tryRecv().?;
            try std.testing.expect(n / divisor == received);
        }
    }
    for (max / divisor..max) |n| {
        const received = q.tryRecv().?;
        try std.testing.expect(n == received);
    }
}
