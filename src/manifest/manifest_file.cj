package badgercj.manifest

import std.fs.*
import std.io.*
import std.collection.*
import std.sync.*

protected class ManifestFile {
    private let path: String
    private var file: ?File
    private var bufferedOut: ?BufferedOutputStream<File>
    private let manifest: Manifest
    private let mutex: Mutex
    
    private init(path: String, manifest: Manifest) {
        this.path = path
        this.file = None
        this.bufferedOut = None
        this.manifest = manifest
        this.mutex = Mutex()
    }
    
    public static func open(path: String): ManifestFile {
        let manifest = Manifest()
        let mf = ManifestFile(path, manifest)
        
        let p = Path(path)
        let dir = p.parent
        if (dir.toString() != "" && !exists(dir)) {
            Directory.create(dir, recursive: true)
        }
        
        if (exists(p)) {
            mf.loadFromFile()
        }
        
        let f = File(p, ReadWrite)
        f.seek(SeekPosition.End(0))
        mf.file = f
        mf.bufferedOut = BufferedOutputStream<File>(f, 4096)
        
        return mf
    }
    
    private func loadFromFile(): Unit {
        let p = Path(path)
        let f = File(p, Read)
        
        f.seek(SeekPosition.Begin(0))
        let len = f.length
        
        if (len == 0) {
            f.close()
            return
        }
        
        let data = Array<Byte>(len, repeat: 0)
        f.read(data)
        f.close()
        
        var offset: Int64 = 0
        while (offset < data.size) {
            let changesetLen = Int64(UInt32(data[offset]) |
                                   (UInt32(data[offset + 1]) << 8) |
                                   (UInt32(data[offset + 2]) << 16) |
                                   (UInt32(data[offset + 3]) << 24))
            offset += 4
            
            let changesetData = data[offset..(offset + changesetLen)]
            let changeset = ManifestChangeSet.decode(changesetData)
            manifest.applyChanges(changeset.changes)
            offset += changesetLen
        }
    }
    
    public func getManifest(): Manifest {
        manifest
    }
    
    public func saveChanges(changes: ManifestChangeSet): Unit {
        mutex.lock()
        try {
            let encoded = changes.encode()
            
            let out = bufferedOut ?? throw Exception("ManifestFile not open")
            
            let len = UInt32(encoded.size)
            out.write(UInt8(len & 0xFF))
            out.write(UInt8((len >> 8) & 0xFF))
            out.write(UInt8((len >> 16) & 0xFF))
            out.write(UInt8((len >> 24) & 0xFF))
            
            out.write(encoded)
            out.flush()
            
            manifest.applyChanges(changes.changes)
        } finally {
            mutex.unlock()
        }
    }
    
    public func close(): Unit {
        if (let Some(out) <- bufferedOut) {
            out.flush()
            out.close()
            bufferedOut = None
        }
        
        if (let Some(f) <- file) {
            f.close()
            file = None
        }
    }
}
