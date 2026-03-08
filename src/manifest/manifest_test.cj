package badgercj.manifest

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*

@Test
class ManifestTest {
    @TestCase
    func testNew() {
        let manifest = Manifest()
        @Assert(manifest.levels.size, 7)  // L0-L6 共7层
    }
    
    @TestCase
    func testApplyCreate() {
        let manifest = Manifest()
        let changes = ArrayList<ManifestChange>()
        changes.add(ManifestChange(100, ManifestChangeOp.Create, level: 1))
        
        manifest.applyChanges(changes)
        
        @Assert(manifest.levels[1].size, 1)
        @Assert(manifest.levels[1][0].id, 100)
    }
    
    @TestCase
    func testApplyDelete() {
        let manifest = Manifest()
        let changes = ArrayList<ManifestChange>()
        changes.add(ManifestChange(1, ManifestChangeOp.Create, level: 1))
        changes.add(ManifestChange(1, ManifestChangeOp.Delete, level: 1))
        
        manifest.applyChanges(changes)
        
        @Assert(manifest.levels[1].size, 0)
    }
    
    @TestCase
    func testGetFileIDs() {
        let manifest = Manifest()
        let changes = ArrayList<ManifestChange>()
        changes.add(ManifestChange(1, ManifestChangeOp.Create, level: 1))
        changes.add(ManifestChange(2, ManifestChangeOp.Create, level: 2))
        
        manifest.applyChanges(changes)
        
        let files = manifest.getFileIDs()
        @Assert(files.size, 2)
    }
    
    @TestCase
    func testClone() {
        let manifest1 = Manifest()
        let changes = ArrayList<ManifestChange>()
        changes.add(ManifestChange(1, ManifestChangeOp.Create, level: 1))
        manifest1.applyChanges(changes)
        
        let manifest2 = manifest1.clone()
        @Assert(manifest2.levels[1].size, 1)
        @Assert(manifest2.levels[1][0].id, 1)
    }
}
