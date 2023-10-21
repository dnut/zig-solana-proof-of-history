const std = @import("std");
const print = std.debug.print;
const hash = std.crypto.hash.sha2.Sha256.hash;
const Atomic = std.atomic.Atomic;
const AtomicOrder = std.builtin.AtomicOrder;

const poh = @import("poh.zig");
const Poh = @import("poh.zig").Poh;
const PohRecorder = @import("poh_recorder.zig").PohRecorder;
const PohRecorderError = @import("poh_recorder.zig").PohRecorderError;
const Bank = @import("poh_recorder.zig").Bank;
const WorkingBankEntry = @import("poh_recorder.zig").WorkingBankEntry;
const AtomicQueue = @import("collections.zig").AtomicQueue;

const hash_bytes: usize = 32;
pub const Hash = [hash_bytes]u8;
const seed: [hash_bytes]u8 = "12345678901234567890123456789012"[0..hash_bytes].*;

const default_hashes_per_tick = 2_000_000 / 160;

pub const PohConfig = struct {
    hashes_per_tick: u64 = default_hashes_per_tick,
    hashes_per_batch: u64 = 64,
    // ticks_per_slot: u64, // used for timing
    // target_ns_per_tick: u64, // used for timing
};

/// High level PoH orchestrator that runs PoH in a loop until poh_exit is set or
/// an unhandled error occurs.
/// 
/// Delegates to Poh and PohRecorder to run hashes and publish entries.
pub fn tickProducer(
    allocator: std.mem.Allocator,
    entries: *AtomicQueue(WorkingBankEntry),
    bank: *Bank,
    poh_exit: *Atomic(bool),
    record_receiver: *AtomicQueue(Record),
    config: PohConfig,
    start_hash: Hash,
) !void {
    var poh_recorder = PohRecorder.init(allocator, start_hash, config.hashes_per_tick, bank, entries);
    var next_record: ?Record = null;
    while (true) {
        if (next_record) |record| {
            _ = try poh_recorder.record(record.slot, record.mixin, record.transactions);
            // TODO: send
        } else {
            const should_tick = poh_recorder.poh.runHash(config.hashes_per_batch);
            if (should_tick) {
                try poh_recorder.tick();
            }
        }
        next_record = record_receiver.tryRecv();
        if (poh_exit.load(AtomicOrder.Unordered)) {
            return;
        }
    }
}

/// Sent into the PoH service to mix in transaction data and publish an entry for those transactions
pub const Record = struct {
    /// The data to mix in with the final hash of the entry
    mixin: [hash_bytes]u8,
    transactions: []const Transaction,
    slot: u64,
    /// Where to send info about the record when it is processed
    sender: PohRecorderError!?usize, // TODO
};

/// Artifact produced by PoH representing the sequence of hashes and
/// transactions leading to a single tick or transaction record.
pub const Entry = struct {
    /// The number of hashes since the previous entry
    num_hashes: u64,
    /// The final hash in the sequence
    hash: Hash,
    /// Any potential transactions, which would have been mixed into the final hash.
    transactions: ?[]const Transaction,
};

/// Represents a Solana transaction but transaction data is not needed in this
/// proof of concept. Just some data to use for the hash.
pub const Transaction = u8;

/// Hack to create a deterministic "hash" value for a group of transactions.
pub fn hashTransactions(tx: []const Transaction) Hash {
    if (tx.len < 32) {
        var array: Hash = .{0} ** 32;
        std.mem.copy(u8, &array, tx);
        return array;
    }
    return tx[0..32].*;
}
