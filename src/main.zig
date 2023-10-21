const std = @import("std");
const print = std.debug.print;
const Atomic = std.atomic.Atomic;
const AtomicOrder = std.builtin.AtomicOrder;
const ArrayList = std.ArrayList;

const poh_service = @import("poh_service.zig");
const poh_recorder = @import("poh_recorder.zig");
const poh_verifier = @import("poh_verifier.zig");

const Hash = @import("poh_service.zig").Hash;
const PohEntry = @import("poh.zig").PohEntry;
const Entry = poh_service.Entry;
const Record = poh_service.Record;
const hashTransactions = poh_service.hashTransactions;
const PohConfig = poh_service.PohConfig;
const Bank = poh_recorder.Bank;
const WorkingBankEntry = poh_recorder.WorkingBankEntry;
const AtomicQueue = @import("collections.zig").AtomicQueue;

pub fn main() !void {
    var poh_entries = AtomicQueue(WorkingBankEntry).init(std.heap.page_allocator);
    var tx_records = AtomicQueue(Record).init(std.heap.page_allocator);
    var poh_exit = Atomic(bool).init(false);
    var bank = Bank{};
    defer poh_entries.deinit();
    defer tx_records.deinit();

    const poh_thread = try std.Thread.spawn(.{}, poh_service.tickProducer, .{
        std.heap.page_allocator,
        &poh_entries,
        &bank,
        &poh_exit,
        &tx_records,
        PohConfig{},
        .{0} ** 32,
    });

    const transactions = .{1};

    // toggle the comments for test cases
    std.time.sleep(100_000_000);
    try tx_records.send(Record{
        // .mixin = .{0} ** 32, // negative test: should fail
        .mixin = hashTransactions(&transactions), // happy path
        .transactions = &transactions,
        .slot = 0,
        .sender = null,
    });

    // add two zeros here to observe a noticeable performance difference between
    // the serial and parallel verifications.
    std.time.sleep(100_000_000);

    poh_exit.store(true, AtomicOrder.Unordered);
    poh_thread.join();
    print("done\n", .{});

    var entries = ArrayList(Entry).init(std.heap.page_allocator);
    while (true) {
        if (poh_entries.tryRecv()) |working_bank_entry| {
            try entries.append(working_bank_entry.tick_entry.entry);
        } else {
            break;
        }
    }
    const owned_entries = try entries.toOwnedSlice();
    print("{} entries\n", .{owned_entries.len});

    if (!poh_verifier.verifyPoh(.{0} ** 32, owned_entries)) {
        print("serial fail\n", .{});
    } else {
        print("serial success\n", .{});
    }

    if (!try poh_verifier.verifyPohInParallel(std.heap.page_allocator, .{0} ** 32, owned_entries, 8)) {
        print("parallel fail\n", .{});
    } else {
        print("parallel success\n", .{});
    }
}
