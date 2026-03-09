package badgercj.db

public func bytesToString(bytes: Array<Byte>): String {
    let sb = StringBuilder()
    for (b in bytes) {
        sb.append(Rune(b))
    }
    return sb.toString()
}
