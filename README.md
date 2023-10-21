This is an implementation in Zig of Solana's Proof-of-History (PoH). It is a simple proof of concept translation of Solana's Rust implementation of the algorithm. It focuses on the PoH algorithm and the data used for that, stubbing or excluding components unnecessary for PoH where it was expedient to do so.

Currently, the test coverage is limited to a single end-to-end happy path test in the form of a main function. I'd like to flesh it out with some more comprehensive test cases, this was just the quickest way to test the core functionality while implementing as much of it as possible in a short amount of time.

To run the test":
```
zig run src/main.zig
```

See the main function for code that you can un/comment or edit for variants of this test.

Table of contents:
- **Theory**: General high-level explanation of the theory behind PoH.
- **Application**: Technical details about how PoH can be used in practice for Solana.
- **Implementation**: Explanation of how the applied theory is implemented in code.

# Theory

Solana's Proof-of-History (PoH) is a mechanism to measure time and write a verifiable historical record of events. It measures clock ticks using a verifiable delay function, which is a sequence of computations that require a known duration to execute, and outputs a value that can be used to verify that the computation was executed.

To record spans of arbitrarily duration, we must record sequential clock ticks one after another. To enforce this, each clock tick must use the output of the last tick as its input. This prevents someone from creating a fake historical record by running the function on many CPU cores at the same time. Any sequence of ticks implies that real-world time must have passed in their creation.

To associate real-world events with the historical record of clock ticks, data emitted by those events is mixed in with the clock data. The output of the delay function is combined with some data from an event, and that combined data is fed into the next iteration of the delay function.

This guarantees that the clock tick must have happened *after* the event it records. If the clock has continuously ticked until today, we can also verify that the tick (and thus the event) must have happened at least some amount of time before today. PoH can also be combined with a reliable consensus mechanism to provide additional timing assurances to coarsely calibrate the clock.

# Application

Solana PoH's verifiable delay function is a SHA-256 hash function that repeatedly hashes its own output. To keep the output reasonably sized, it does not record the output of every single hash execution. Every hash does not need to be recorded because, given a seed value, end hash, and number of hashes, a verifier can reproduce the intermediate hashes to verify the end result.

A solana validator producing a PoH will periodically output PoH entries representing either a tick or a transaction record. 
- Tick: After calculating a predetermined number of hashes in a sequence, an entry will be published that states the final hash value and the number of hashes that it took to reach this since the last entry.
- Transaction record: If some transactions were received by the validator, it will data from those transactions with its latest PoH hash, and then hash that combined value. An entry is immediately published containing the resulting combined hash, the number of hashes since the previous entry, and the list of transactions.

To verify that a list of PoH entries are valid, you can take the hash value from a one entry, hash it the number of times specified in the next entry, and then compare the resulting hash to hash in that same next entry. If that next entry contains a list of transactions, then you should mix-in the hash of those transactions during the final hash. This process can be done in parallel by individually verifying chunks of the list of entries, being sure to check that the last entry in one chunk results in the first entry in the next chunk.

# Implementation

Solana's Rust implementation of Proof-of-History is based around primarily three structs.
- `Poh`: Simple low level PoH hash calculator.
- `PohService`: High level loop to run PoH as a long-running service.
- `PohRecorder`: Tracks PoH and blockchain state, and publishes PoH entries when called by PohService.

This Zig implementation includes the core behavior of those structs, but is streamlined in some ways, for example:
- Nothing is timed, and likewise the PoH algorithm does not sleep if it executes faster than expected.
- There is no logging/reporting.
- There is no low power mode
- PohRecorder does not track the state that isn't part of PoH, such as Bank and Blockstore.
- PohRecorder does not have several methods that other parts of a validator can use to tweak the PohRecorder's state
- There is minimal use of locks and reference counting for shared pointers. It is not currently designed to be read and mutated from various threads. Only a few components use synchronization primitives as needed for this simple proof of concept.

## Poh

The Poh struct stores the latest hash, a count of hashes executed so far, the remaining number of hashes to perform before the next tick, and a count of ticks. The most important methods are:
- `hash`: calculates the desired number of hashes in a loop, increment its internal state. 
- `tick`: calculates a single hash to produce a tick entry.
- `record`: calculates a single hash to produce a record entry including mixed in data

## PohService

`PohService` is used by calling its `new` function which spawns a thread that runs the PoH algorithm in a loop. It returns an instance of `PohService` which only contains a handle to the thread, which can be joined.

Depending on configuration, `PohService` may run the full PoH algorithm, a short lived version, or a short lived version that sleeps instead of hashing. The full algorithm is executed by calling `PohService::tick_producer`, which then calls `PohService::record_or_hash`. Each of those functions runs its own loop to keep PoH going. Basically they work together run an infinite loop including these steps:
- if there is a record, process and publish it (handled mainly by PohService::record_or_hash)
- if there are no more records, call Poh to run a batch of hashes. If necessary, call PohRecorder to publish a tick entry if necessary (handled mainly by PohService::tick_producer)
- exit if the poh_exit bool parameter has been mutated by another thread to set it to `true`.

These two methods have a weird interplay where they return and call back and forth to each other to hand off responsibilities. But actually the logic can be expressed simply with a single loop. 

In Zig, I've implemented it this with a function called `tickProducer`. The logic is the same except for the absence of timing, locks, and it has a slightly more eager exit behavior. I believe the difference in exit behavior is arbitrary and likely unimportant, but it may be worth a second look.

## PohRecorder

This is a complex struct with many fields and methods. The Zig implementation only includes state that the actual PoH generation uses and depends on to produce PoH entries, which is about 1/4 as many fields. There are several methods that other services may call to read or mutate the state in this struct. The Zig implementation focuses on the methods that are called either directly or indirectly from PohService.

Important fields:
- `poh`: This is the instance of the `Poh` struct described above that tracks and updates the latest hash.
- `working_bank`: This points to the state of the blockchain and is included with every PoH entry. The Bank has been stubbed out in the Zig implementation.
- `sender`: This is the target where PohRecorder publishes Poh entries. It should be hooked up to a Receiver in another thread that processes the entries.

Important methods:
- `tick`: Called by PohService when it is time to record a tick. Calls Poh::tick, increments the tick height, and publishes an entry for the tick.
- `record`: Called by PohService when a record has been received. Calls Poh::record with the record's mixin data and publishes an entry including any transactions
- `flush_cache`: Under the hood, the above tick method actually first pushes the tick entry into a list, then calls this method. This method is the one that actually sends the tick entries from the cache using the sender. This method has logic to delay sending ticks until there is a working bank available, then it sends them in a batch up to the maximum tick height.

## Verifier

This Zig implementation also comes with two functions to verify the PoH entries:
- verifyPoh: Sequentially hashes all entries in order, one at a time.
- verifyPohInParallel: Splits the job into multiple chunks and verifies each chunk on a separate thread, delegating to verifyPoh
