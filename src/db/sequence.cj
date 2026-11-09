package badgercj.db

import std.sync.*

/**
 * Sequence - 单调递增序列（对齐 badger-go sequence.go）。
 *
 * 每个 `getSequence(key, bandwidth)` 实例从库里读出当前租约，并在内存里发号：
 * - `nextValue()` 返回下一个值（从 0 开始），超过租约时自动续租；
 * - 续租 = 把 `next + bandwidth` 写回 key（大端 8 字节）；进程崩溃只浪费未用的区间；
 * - `release()` 把未用区间退回（仅当库里租约仍是本实例持有的那个值）。
 *
 * 注意：序列值直接存在传入的 key 上（占用该 key，不要与业务数据混用）。
 */
public class Sequence {
    private let db: Badger
    private let key: Array<Byte>
    private let bandwidth: UInt64
    private let lock: Mutex
    private var next: UInt64
    private var leased: UInt64

    protected init(db: Badger, key: Array<Byte>, bandwidth: UInt64) {
        this.db = db
        this.key = key
        this.bandwidth = bandwidth
        this.lock = Mutex()
        this.next = 0
        this.leased = 0
    }

    /** 返回下一个序列值（从 0 开始，单调递增）。 */
    public func nextValue(): UInt64 {
        lock.lock()
        try {
            if (next >= leased) {
                updateLease()
            }
            let val = next
            next++
            val
        } finally {
            lock.unlock()
        }
    }

    /** 把未使用的区间退回库里（下次 getSequence 从退回处继续）。 */
    public func release(): Unit {
        lock.lock()
        try {
            match (db.get(key)) {
                case Some(vs) =>
                    let stored = u64FromBE(vs.value)
                    if (stored == leased) {
                        db.updateOrThrow({ txn => txn.set(key, u64ToBE(next)) })
                    }
                case None => ()
            }
            leased = next
        } finally {
            lock.unlock()
        }
    }

    /** 创建时立即取一次租约（对齐 go GetSequence → updateLease）。 */
    internal func ensureLease(): Unit {
        lock.lock()
        try {
            updateLease()
        } finally {
            lock.unlock()
        }
    }
    
    /** 续租：读当前租约值，写回 next+bandwidth，本地 next = 读到的值。 */
    private func updateLease(): Unit {
        let current: UInt64 = match (db.get(key)) {
            case Some(vs) => u64FromBE(vs.value)
            case None => 0
        }
        let lease = current + bandwidth
        db.updateOrThrow({ txn => txn.set(key, u64ToBE(lease)) })
        next = current
        leased = lease
    }
}

private func u64ToBE(value: UInt64): Array<Byte> {
    let bytes = Array<Byte>(8, repeat: 0)
    var i: Int64 = 0
    while (i < 8) {
        let shift = UInt64((7 - i) * 8)
        bytes[i] = UInt8((value >> shift) & 0xFF)
        i++
    }
    bytes
}

private func u64FromBE(data: Array<Byte>): UInt64 {
    if (data.size < 8) {
        return 0
    }
    var value: UInt64 = 0
    var i: Int64 = 0
    while (i < 8) {
        value = (value << 8) | UInt64(data[i])
        i++
    }
    value
}
