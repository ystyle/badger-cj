package badgercj.db

import std.collection.ArrayList
import badgercj.table.ValueStruct
import badgercj.skiplist.Node
import badgercj.skiplist.AtomicStorage
import badgercj.skiplist.Skiplist
import badgercj.arena.Arena
import badgercj.utils.compareKeys

public class MemTableIterator <: SimpleIterator {
    private let mt: MemTable
    private let reverse: Bool
    
    private var lazyIter: LazySkipIterator
    private var entries: ArrayList<(Array<Byte>, Array<Byte>)>
    private var index: Int64
    private var currentKey: Array<Byte>
    private var currentValue: Array<Byte>
    private var valid_: Bool
    
    protected init(mt: MemTable, reverse!: Bool = false) {
        super()
        this.mt = mt
        this.reverse = reverse
        this.lazyIter = LazySkipIterator(mt.getTable(), mt.getTable().getAtomicStorage())
        this.entries = ArrayList<(Array<Byte>, Array<Byte>)>()
        this.index = -1
        this.currentKey = []
        this.currentValue = []
        this.valid_ = false
        
        if (reverse) {
            let iter = mt.iterator()
            while (iter.hasNext()) {
                if (let Some((key, vs)) <- iter.next()) {
                    entries.add((key, vs.encode()))
                }
            }
        }
        
        rewind()
    }
    
    public override func valid(): Bool {
        return valid_
    }
    
    public override func key(): Array<Byte> {
        return currentKey
    }
    
    public override func value(): Array<Byte> {
        return currentValue
    }
    
    public override func next(): Unit {
        if (reverse) {
            index--
            if (index < 0) {
                valid_ = false
                return
            }
            updateCurrentFromEntries()
        } else {
            if (lazyIter.hasNext()) {
                if (let Some((key, vs)) <- lazyIter.next()) {
                    currentKey = key
                    currentValue = vs.encode()
                    valid_ = true
                } else {
                    valid_ = false
                }
            } else {
                valid_ = false
            }
        }
    }
    
    public override func rewind(): Unit {
        if (reverse) {
            if (entries.isEmpty()) {
                valid_ = false
                return
            }
            index = Int64(entries.size) - 1
            updateCurrentFromEntries()
        } else {
            lazyIter = LazySkipIterator(mt.getTable(), mt.getTable().getAtomicStorage())
            if (lazyIter.hasNext()) {
                if (let Some((key, vs)) <- lazyIter.next()) {
                    currentKey = key
                    currentValue = vs.encode()
                    valid_ = true
                } else {
                    valid_ = false
                }
            } else {
                valid_ = false
            }
        }
    }
    
    public override func seek(key: Array<Byte>): Unit {
        if (reverse) {
            if (entries.isEmpty()) {
                valid_ = false
                return
            }
            
            var lo: Int64 = 0
            var hi: Int64 = entries.size - 1
            var found: Int64 = -1
            
            while (lo <= hi) {
                let mid = (lo + hi) / 2
                let cmp = compareKeys(entries[mid][0], key)
                if (cmp <= 0) {
                    found = mid
                    lo = mid + 1
                } else {
                    hi = mid - 1
                }
            }
            
            if (found >= 0) {
                index = found
                updateCurrentFromEntries()
            } else {
                valid_ = false
            }
        } else {
            if (let Some(node) <- mt.getTable().findGe(key)) {
                currentKey = node.getKey()
                let value = node.getValue()
                let offset = UInt32(value >> 32)
                let size = UInt16(value & 0xFFFFu64)
                let encoded = mt.getTable().getArena().getBytes(offset, size)
                currentValue = encoded
                lazyIter = LazySkipIterator.fromNode(mt.getTable(), node)
                valid_ = true
            } else {
                valid_ = false
            }
        }
    }
    
    private func updateCurrentFromEntries(): Unit {
        if (index >= 0 && index < entries.size) {
            let entry = entries[index]
            currentKey = entry[0]
            currentValue = entry[1]
            valid_ = true
        } else {
            valid_ = false
        }
    }
}

class LazySkipIterator {
    private let table: Skiplist
    private let atomicStorage: AtomicStorage
    private var current: ?Node
    
    protected init(table: Skiplist, atomicStorage: AtomicStorage) {
        this.table = table
        this.atomicStorage = atomicStorage
        this.current = None
        
        let head = table.getHead()
        let firstOffset = head.getNextOffset(0)
        if (firstOffset != 0) {
            current = Some(Node(table.getArena(), firstOffset, atomicStorage))
        }
    }
    
    public static func fromNode(table: Skiplist, node: Node): LazySkipIterator {
        let iter = LazySkipIterator(table, table.getAtomicStorage())
        iter.current = Some(node)
        return iter
    }
    
    public func hasNext(): Bool {
        if (let Some(node) <- current) {
            return true
        }
        return false
    }
    
    public func next(): ?(Array<Byte>, ValueStruct) {
        if (let Some(node) <- current) {
            let key = node.getKey()
            let value = node.getValue()
            let offset = UInt32(value >> 32)
            let size = UInt16(value & 0xFFFFu64)
            let encoded = table.getArena().getBytes(offset, size)
            let vs = ValueStruct.decode(encoded)
            
            let nextOffset = node.getNextOffset(0)
            if (nextOffset != 0) {
                current = Some(Node(table.getArena(), nextOffset, atomicStorage))
            } else {
                current = None
            }
            
            return Some((key, vs))
        }
        None
    }
}