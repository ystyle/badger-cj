# Async Write Channel Optimization Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Optimize db.set() concurrent performance by adding async write channel mechanism (mimicking Go BadgerDB) to reduce testStressConcurrentWrites from 70s to <10s.

**Architecture:** Use ConcurrentLinkedQueue as write channel, background flushLoop thread batch processes write requests. Users call set() to quickly enqueue and wait, flushLoop accumulates requests then batch calls writeRequests(), reducing lock contention and I/O overhead.

**Tech Stack:** Cangjie stdlib (std.collection.concurrent.ConcurrentLinkedQueue, std.sync.AtomicBool)

---

## Task 1: Create WriteRequest Class

**Files:**
- Create: `src/db/write_request.cj`

**Step 1: Create WriteRequest class definition**

```cangjie
package badgercj.db

import std.sync.*
import std.time.*
import badgercj.vlog.*

public class WriteRequest {
    public let key: Array<Byte>
    public let value: Array<Byte>
    public let commitTs: UInt64
    public let isDelete: Bool
    public var vp: ?ValuePointer
    private let done: AtomicBool
    
    public init(key: Array<Byte>, value: Array<Byte>, commitTs: UInt64, isDelete!: Bool = false) {
        this.key = key
        this.value = value
        this.commitTs = commitTs
        this.isDelete = isDelete
        this.vp = None
        this.done = AtomicBool(false)
    }
    
    public func wait(): Unit {
        var retries = 0
        while (!done.load() && retries < 1000000) {
            sleep(Duration.nanosecond * 100)
            retries++
        }
    }
    
    public func signal(): Unit {
        done.store(true)
    }
}
```

**Step 2: Build to verify**

Run: `cjpm build`
Expected: Build successful

**Step 3: Commit**

```bash
git add src/db/write_request.cj
git commit -m "feat: add WriteRequest class for async writes"
```

---

## Task 2: Add Write Channel to DB Class

**Files:**
- Modify: `src/db/db.cj:1-39`

**Step 1: Add imports at top**

Add after line 8:

```cangjie
import std.collection.concurrent.*
```

**Step 2: Add fields to DB class**

Add after line 18 (after `private let vlog: VLogManager`):

```cangjie
    private let writeCh: ConcurrentLinkedQueue<WriteRequest>
    private let running: AtomicBool
    private var flushFut: ?Future<Unit>
```

**Step 3: Initialize channel and start background thread in DB.open()**

Add after line 38 (after `let db = DB(opt, mt, manifest, lc, vlog)`):

```cangjie
        db.writeCh = ConcurrentLinkedQueue<WriteRequest>()
        db.running = AtomicBool(true)
        let _ = spawn { db.flushLoop() }
        db.flushFut = None
```

Note: We need to capture the Future from spawn, but Cangjie spawn returns Future<Unit> based on last expression. Need to adjust:

```cangjie
        db.writeCh = ConcurrentLinkedQueue<WriteRequest>()
        db.running = AtomicBool(true)
        let fut = spawn { 
            db.flushLoop()
        }
        db.flushFut = Some(fut)
```

**Step 4: Build to verify**

Run: `cjpm build`
Expected: Build successful (may have undefined method errors for flushLoop - that's OK for now)

**Step 5: Commit**

```bash
git add src/db/db.cj
git commit -m "feat: add write channel and background flush thread fields"
```

---

## Task 3: Implement flushLoop and writeRequests Methods

**Files:**
- Modify: `src/db/db.cj` (add methods after flushToLevel())

**Step 1: Implement flushLoop method**

Add after `flushToLevel()` method (around line 279):

```cangjie
    private func flushLoop(): Unit {
        while (running.load() || !writeCh.isEmpty()) {
            var reqs = ArrayList<WriteRequest>()
            
            // Accumulate requests (max 10)
            while (reqs.size < 10) {
                if (let Some(req) <- writeCh.remove()) {
                    reqs.add(req)
                } else {
                    break
                }
            }
            
            if (reqs.size > 0) {
                writeRequests(reqs)
            } else if (running.load()) {
                sleep(Duration.millisecond * 1)
            }
        }
    }
```

**Step 2: Implement writeRequests method**

Add after flushLoop():

```cangjie
    private func writeRequests(reqs: ArrayList<WriteRequest>): Unit {
        // Prepare vlog outside lock
        for (req in reqs) {
            if (Int64(req.value.size) >= opt.ValueThreshold && !req.isDelete) {
                let entry = LogEntry(req.key, req.value)
                req.vp = Some(vlog.write(entry))
            }
        }
        
        // Write to memtable + WAL inside lock
        lock.lock()
        try {
            for (req in reqs) {
                if (mt.shouldFlush()) {
                    flushMemTableInternal()
                }
                
                let keyWithTs = helpers.keyWithTs(req.key, req.commitTs)
                let vs = if (req.isDelete) {
                    ValueStruct([], meta: Meta.bitDelete, version: req.commitTs)
                } else if (let Some(vp) <- req.vp) {
                    ValueStruct(vp.encode(), meta: Meta.bitValuePointer, version: req.commitTs)
                } else {
                    ValueStruct(req.value, meta: 0, version: req.commitTs)
                }
                
                mt.put(keyWithTs, vs)
            }
        } finally {
            lock.unlock()
        }
        
        // Signal completion
        for (req in reqs) {
            req.signal()
        }
    }
```

**Step 3: Modify close() to wait for flush thread**

Replace close() method (lines 57-69) with:

```cangjie
    public func close(): Unit {
        running.store(false)
        if (let Some(fut) <- flushFut) {
            fut.get()
        }
        
        lock.lock()
        try {
            mt.closeWAL()
            for (immMt in imm) {
                immMt.closeWAL()
            }
            vlog.close()
            oracle.stop()
        } finally {
            lock.unlock()
        }
    }
```

**Step 4: Build to verify**

Run: `cjpm build`
Expected: Build successful

**Step 5: Commit**

```bash
git add src/db/db.cj
git commit -m "feat: implement flushLoop and writeRequests batch write"
```

---

## Task 4: Modify set() and delete() to Use Write Channel

**Files:**
- Modify: `src/db/db.cj:199-209`

**Step 1: Replace set() method**

Replace lines 199-203 with:

```cangjie
    public func set(key: Array<Byte>, value: Array<Byte>): Unit {
        let ts = version.fetchAdd(1)
        oracle.bumpCommitTs(ts)
        
        let req = WriteRequest(key, value, commitTs: ts, isDelete: false)
        writeCh.add(req)
        req.wait()
    }
```

**Step 2: Replace delete() method**

Replace lines 205-209 with:

```cangjie
    public func delete(key: Array<Byte>): Unit {
        let ts = version.fetchAdd(1)
        oracle.bumpCommitTs(ts)
        
        let req = WriteRequest(key, [], commitTs: ts, isDelete: true)
        writeCh.add(req)
        req.wait()
    }
```

**Step 3: Remove old putWithCommitTs and deleteWithCommitTs**

Delete or comment out lines 156-196 (putWithCommitTs and deleteWithCommitTs methods).

These are no longer needed since Transaction will use set()/delete() directly.

**Step 4: Build to verify**

Run: `cjpm build`
Expected: Build successful

**Step 5: Run basic test**

Run: `cjpm test --show-all-output --filter 'DBTest.testBasicSetGet'`
Expected: PASS

**Step 6: Commit**

```bash
git add src/db/db.cj
git commit -m "feat: modify set/delete to use write channel"
```

---

## Task 5: Update Transaction to Use New Write Path

**Files:**
- Modify: `src/db/transaction.cj`

**Step 1: Find Transaction.commit() method**

Look for the commit() method that calls `db.putWithCommitTs()` and `db.deleteWithCommitTs()`.

**Step 2: Replace with set()/delete() calls**

Change:
- `db.putWithCommitTs(key, value, commitTs)` → `db.set(key, value)`
- `db.deleteWithCommitTs(key, commitTs)` → `db.delete(key)`

Note: The set()/delete() methods will handle timestamp assignment internally, so we may need to adjust the transaction logic to not pre-assign commitTs.

**Step 3: Build to verify**

Run: `cjpm build`
Expected: Build successful

**Step 4: Run transaction tests**

Run: `cjpm test --show-all-output --filter 'TransactionTest'`
Expected: All PASS

**Step 5: Commit**

```bash
git add src/db/transaction.cj
git commit -m "feat: update Transaction to use new write path"
```

---

## Task 6: Performance Verification

**Files:**
- Test: `src/db/concurrent_test.cj`

**Step 1: Run stress test**

Run: `cjpm test --show-all-output --filter 'ConcurrentTest.testStressConcurrentWrites'`
Expected: Complete in <10 seconds (was 70 seconds)

Note: Check the output for actual time elapsed.

**Step 2: Run all concurrent tests**

Run: `cjpm test --show-all-output --filter 'ConcurrentTest'`
Expected: All PASS

**Step 3: Run all tests to ensure no regression**

Run: `cjpm test`
Expected: 127/127 PASS

**Step 4: If tests pass, commit**

```bash
git add -A
git commit -m "perf: optimize concurrent write performance, testStressConcurrentWrites from 70s to <10s"
```

---

## Task 7: Update Documentation

**Files:**
- Modify: `docs/progress-tracking.md`

**Step 1: Add performance optimization record to Phase 5**

Find the Phase 5 section and add:

```markdown
**Performance Optimization Progress:**
- ✅ Implemented async write channel (mimicking Go BadgerDB)
- ✅ Batch writes reduce lock contention
- ✅ testStressConcurrentWrites performance improved 7x+ (70s → <10s)
```

**Step 2: Commit documentation**

```bash
git add docs/progress-tracking.md
git commit -m "docs: update performance optimization progress"
```

---

## Notes

**Potential Issues:**
1. WriteRequest.wait() uses busy-wait with sleep - may need optimization with Condition/Mutex
2. Transaction may need adjustment since set()/delete() now handle timestamp internally
3. Need to ensure flush thread properly drains all pending requests on close()

**Future Improvements:**
1. Use Condition/Mutex instead of busy-wait in WriteRequest.wait()
2. Add batch size configuration option
3. Add metrics for queue depth and flush latency
