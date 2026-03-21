package badgercj.db

import std.collection.*
import std.sync.*
import badgercj.utils.{compareKeys, keysEqual}

public class levelCompactStatus {
    public var ranges: ArrayList<keyRange>
    public var delSize: Int64
    
    public init() {
        this.ranges = ArrayList<keyRange>()
        this.delSize = 0
    }
    
    public func overlapsWith(range: keyRange): Bool {
        for (r in ranges) {
            if (r.overlapsWith(range)) {
                return true
            }
        }
        return false
    }
    
    public func remove(range: keyRange): Bool {
        var found = false
        let newRanges = ArrayList<keyRange>()
        for (r in ranges) {
            if (!r.equals(range)) {
                newRanges.add(r)
            } else {
                found = true
            }
        }
        ranges = newRanges
        return found
    }
}

public struct compactionPriority {
    public let level: Int
    public let score: Float64
    
    public init(level!: Int, score!: Float64) {
        this.level = level
        this.score = score
    }
}

public struct compactDef {
    public var thisLevel: Int
    public var nextLevel: Int
    public var thisRange: keyRange
    public var nextRange: keyRange
    public var thisSize: Int64
    public var top: ArrayList<TableInterface>
    public var bot: ArrayList<TableInterface>
    
    public init() {
        this.thisLevel = 0
        this.nextLevel = 0
        this.thisRange = keyRange()
        this.nextRange = keyRange()
        this.thisSize = 0
        this.top = ArrayList<TableInterface>()
        this.bot = ArrayList<TableInterface>()
    }
}

public class compactStatus {
    private let lock: ReadWriteLock
    private var levels: ArrayList<levelCompactStatus>
    private var tables: HashSet<UInt64>
    
    public init(numLevels: Int) {
        this.lock = ReadWriteLock()
        this.levels = ArrayList<levelCompactStatus>()
        this.tables = HashSet<UInt64>()
        
        for (_ in 0..numLevels) {
            levels.add(levelCompactStatus())
        }
    }
    
    public func overlapsWith(level: Int, range: keyRange): Bool {
        lock.readLock.lock()
        try {
            return levels[level].overlapsWith(range)
        } finally {
            lock.readLock.unlock()
        }
    }
    
    public func compareAndAdd(cd: compactDef): Bool {
        lock.writeLock.lock()
        try {
            var thisLevel = levels[cd.thisLevel]
            var nextLevel = levels[cd.nextLevel]
            
            if (thisLevel.overlapsWith(cd.thisRange)) {
                return false
            }
            if (nextLevel.overlapsWith(cd.nextRange)) {
                return false
            }
            
            for (t in cd.top) {
                if (tables.contains(t.getId())) {
                    return false
                }
            }
            for (t in cd.bot) {
                if (tables.contains(t.getId())) {
                    return false
                }
            }
            
            thisLevel.ranges.add(cd.thisRange)
            nextLevel.ranges.add(cd.nextRange)
            thisLevel.delSize += cd.thisSize
            
            for (t in cd.top) {
                tables.add(t.getId())
            }
            for (t in cd.bot) {
                tables.add(t.getId())
            }
            
            return true
        } finally {
            lock.writeLock.unlock()
        }
    }
    
    public func delete(cd: compactDef): Unit {
        lock.writeLock.lock()
        try {
            var thisLevel = levels[cd.thisLevel]
            var nextLevel = levels[cd.nextLevel]
            
            thisLevel.delSize -= cd.thisSize
            thisLevel.remove(cd.thisRange)
            if (cd.thisLevel != cd.nextLevel && !cd.nextRange.isEmpty()) {
                nextLevel.remove(cd.nextRange)
            }
            
            for (t in cd.top) {
                tables.remove(t.getId())
            }
            for (t in cd.bot) {
                tables.remove(t.getId())
            }
        } finally {
            lock.writeLock.unlock()
        }
    }
    
    public func delSize(level: Int): Int64 {
        lock.readLock.lock()
        try {
            return levels[level].delSize
        } finally {
            lock.readLock.unlock()
        }
    }
}

public struct keyRange {
    public var left: Array<Byte>
    public var right: Array<Byte>
    public var inf: Bool
    
    public init(left!: Array<Byte> = [], right!: Array<Byte> = [], inf!: Bool = false) {
        this.left = left
        this.right = right
        this.inf = inf
    }
    
    public func isEmpty(): Bool {
        return left.size == 0 && right.size == 0 && !inf
    }
    
    public func overlapsWith(other: keyRange): Bool {
        if (isEmpty() || other.isEmpty()) {
            return true
        }
        if (inf || other.inf) {
            return true
        }
        
        // [other.left, other.right] ... [this.left, this.right]
        if (compareKeys(left, other.right) > 0) {
            return false
        }
        // [this.left, this.right] ... [other.left, other.right]
        if (compareKeys(right, other.left) < 0) {
            return false
        }
        return true
    }
    
    public mut func extendRange(other: keyRange) {
        if (other.isEmpty()) {
            return
        }
        if (isEmpty()) {
            left = other.left
            right = other.right
            inf = other.inf
            return
        }
        if (left.size == 0 || compareKeys(other.left, left) < 0) {
            left = other.left
        }
        if (right.size == 0 || compareKeys(other.right, right) > 0) {
            right = other.right
        }
        if (other.inf) {
            inf = true
        }
    }
    
    public func equals(other: keyRange): Bool {
        if (inf != other.inf) {
            return false
        }
        return keysEqual(left, other.left) && keysEqual(right, other.right)
    }
}

public let infRange = keyRange(inf: true)