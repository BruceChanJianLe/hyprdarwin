import Foundation
import Testing
@testable import HyprdarwinCore

@Suite struct KeyMappingMergeTests {
    let escape = HIDKeyMapping(src: KeyMappingMerge.capsLock, dst: 0x7_0000_0029)
    let other = HIDKeyMapping(src: 0x7_0000_0064, dst: 0x7_0000_0035)

    func raw(_ entries: [HIDKeyMapping]) -> [Any] {
        KeyMappingMerge.propertyList(entries)
    }

    @Test func installIntoEmptyAndKeepsOthers() throws {
        let empty = try #require(KeyMappingMerge.plan(.install, read: nil, held: []))
        #expect(empty.mapping == [KeyMappingMerge.ours])
        #expect(empty.changed)

        let kept = try #require(KeyMappingMerge.plan(.install, read: raw([other]), held: []))
        #expect(kept.mapping == [other, KeyMappingMerge.ours])

        let again = try #require(KeyMappingMerge.plan(.install, read: raw([other, KeyMappingMerge.ours]), held: []))
        #expect(!again.changed)
    }

    @Test func installDisplacesAndRemoveRestoresForeignCapsLock() throws {
        let install = try #require(KeyMappingMerge.plan(.install, read: raw([escape, other]), held: []))
        #expect(install.mapping == [KeyMappingMerge.ours, other])
        #expect(install.held == [escape])
        #expect(install.displaced == [escape])

        let remove = try #require(KeyMappingMerge.plan(.remove, read: raw(install.mapping), held: install.held))
        #expect(remove.mapping == [escape, other])
        #expect(remove.restored == [escape])
        #expect(remove.held.isEmpty)
    }

    @Test func removeWithoutOursIsANoOp() throws {
        let plan = try #require(KeyMappingMerge.plan(.remove, read: raw([other]), held: [escape]))
        #expect(!plan.changed)
        #expect(plan.held.isEmpty)
    }

    @Test func unreadableListsAreLeftAlone() {
        #expect(KeyMappingMerge.plan(.install, read: "nope", held: []) == nil)
        let extraKey: [Any] = [[KeyMappingMerge.srcKey: 1, KeyMappingMerge.dstKey: 2, "Extra": 3]]
        #expect(KeyMappingMerge.plan(.install, read: extraKey, held: []) == nil)
        let fractional: [Any] = [[KeyMappingMerge.srcKey: 1.5, KeyMappingMerge.dstKey: 2]]
        #expect(KeyMappingMerge.plan(.install, read: fractional, held: []) == nil)
    }
}
