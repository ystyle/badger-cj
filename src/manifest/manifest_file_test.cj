package badgercj.manifest

import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*

@Test
class ManifestFileTest {
    @TestCase
    func testOpenEmptyFile() {
        let testDir = Path("/tmp/badger_manifest_test")
        if (exists(testDir)) {
            remove(testDir, recursive: true)
        }
        Directory.create(testDir.toString())
        
        let path = testDir.toString() + "/MANIFEST"
        let mf = ManifestFile.open(path)
        
        @Assert(mf.getManifest().nextFileID, 0)
        @Assert(mf.getManifest().levels.size, 7)
        
        mf.close()
        
        if (exists(testDir)) {
            remove(testDir, recursive: true)
        }
    }
    
    @TestCase
    func testLoadExistingFile() {
        let testDir = Path("/tmp/badger_manifest_test_load")
        if (exists(testDir)) {
            remove(testDir, recursive: true)
        }
        Directory.create(testDir.toString())
        
        let path = testDir.toString() + "/MANIFEST"
        
        let changes = ArrayList<ManifestChange>()
        changes.add(ManifestChange(1, ManifestChangeOp.Create, level: 0))
        changes.add(ManifestChange(2, ManifestChangeOp.Create, level: 0))
        let changeset = ManifestChangeSet(changes)
        let changesetData = changeset.encode()
        
        let lenBytes = Array<Byte>(4, {i => UInt8((changesetData.size >> (i * 8)) & 0xFF)})
        
        let p = Path(path)
        let f = File(p, ReadWrite)
        f.write(lenBytes)
        f.write(changesetData)
        f.close()
        
        let mf = ManifestFile.open(path)
        @Assert(mf.getManifest().nextFileID, 3)
        @Assert(mf.getManifest().levels[0].size, 2)
        @Assert(mf.getManifest().levels[0][0].id, 1)
        @Assert(mf.getManifest().levels[0][1].id, 2)
        mf.close()
        
        if (exists(testDir)) {
            remove(testDir, recursive: true)
        }
    }
}
