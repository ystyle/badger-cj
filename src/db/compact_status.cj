package badgercj.db

import std.collection.*

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
    
    private func keysEqual(a: Array<Byte>, b: Array<Byte>): Bool {
        if (a.size != b.size) { return false }
        for (i in 0..a.size) {
            if (a[i] != b[i]) { return false }
        }
        return true
    }
}

public let infRange = keyRange(inf: true)