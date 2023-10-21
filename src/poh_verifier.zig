const std = @import("std");
const ArrayList = std.ArrayList;
const Atomic = std.atomic.Atomic;
const AtomicOrder = std.builtin.AtomicOrder;

const poh = @import("poh.zig");
const Hash = @import("poh_service.zig").Hash;
const Entry = @import("poh_service.zig").Entry;
const hashTransactions = @import("poh_service.zig").hashTransactions;

/// Simple PoH validation that executes every entry in sequence.
pub fn verifyPoh(initial_hash: Hash, entries: []Entry) bool {
    var current_hash = initial_hash;

    for (entries) |entry| {
        if (entry.num_hashes == 0) {
            @panic("need hashes to verify");
        }

        for (1..entry.num_hashes) |_| {
            poh.rehash(&current_hash, null);
        }
        var mixin: ?Hash = null;
        if (entry.transactions) |transactions| {
            mixin = hashTransactions(transactions);
        }
        poh.rehash(&current_hash, mixin);

        if (!std.mem.eql(u8, &current_hash, &entry.hash)) {
            return false;
        }
    }

    return true;
}

/// Verify PoH entries by parallelizing the work across multiple threads
pub fn verifyPohInParallel(allocator: std.mem.Allocator, initial_hash: Hash, entries: []Entry, num_threads: u8) !bool {
    const batch_size = entries.len / num_threads;
    var threads = ArrayList(std.Thread).init(allocator);
    var bools = ArrayList(Atomic(bool)).init(allocator);
    var prior_hash = initial_hash;
    for (0..num_threads + 1) |i| {
        const start = i * batch_size;
        const end = @min(start + batch_size, entries.len);
        if (end - start == 0) {
            continue;
        }
        try bools.append(Atomic(bool).init(false));
        const this_bool = &bools.items[bools.items.len - 1];
        const thread = try std.Thread.spawn(.{}, verifyPohAtomic, .{ prior_hash, entries[start..end], this_bool });
        try threads.append(thread);
        prior_hash = entries[end - 1].hash;
    }
    for (threads.items) |thread| {
        thread.join();
    }
    for (bools.items) |this_bool| {
        if (!this_bool.load(AtomicOrder.Monotonic)) {
            return false;
        }
    }
    return true;
}

fn verifyPohAtomic(initial_hash: Hash, entries: []Entry, result: *Atomic(bool)) void {
    result.store(verifyPoh(initial_hash, entries), AtomicOrder.Monotonic);
}
