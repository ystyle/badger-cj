package badgercj.db

import std.fs.*

public func bytesToString(bytes: Array<Byte>): String {
    String.fromUtf8(bytes)
}

public func cleanupDir(path: String): Unit {
    if (exists(Path(path))) {
        remove(Path(path), recursive: true)
    }
}