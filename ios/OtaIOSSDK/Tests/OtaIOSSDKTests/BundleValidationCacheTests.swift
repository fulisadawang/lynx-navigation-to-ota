import Testing
@testable import OtaIOSSDK

@Suite("Bundle validation cache")
struct BundleValidationCacheTests {
    @Test("same key hits after insert")
    func sameKeyHits() {
        var cache = OtaBundleValidationCache<Int>(maxEntries: 2)
        let initialHit = cache.contains(1)
        #expect(!initialHit)
        cache.insert(1)
        let hitAfterInsert = cache.contains(1)
        #expect(hitAfterInsert)
        #expect(cache.count == 1)
    }

    @Test("bounded cache evicts the least recently used key")
    func lruEviction() {
        var cache = OtaBundleValidationCache<Int>(maxEntries: 2)
        cache.insert(1)
        cache.insert(2)
        let firstHitBeforeEviction = cache.contains(1)
        #expect(firstHitBeforeEviction)
        cache.insert(3)
        let firstHitAfterEviction = cache.contains(1)
        let secondHitAfterEviction = cache.contains(2)
        let thirdHitAfterEviction = cache.contains(3)
        #expect(firstHitAfterEviction)
        #expect(!secondHitAfterEviction)
        #expect(thirdHitAfterEviction)
    }

    @Test("remove and remove all invalidate entries")
    func invalidation() {
        var cache = OtaBundleValidationCache<Int>(maxEntries: 2)
        cache.insert(1)
        cache.insert(2)
        cache.remove(1)
        let removedHit = cache.contains(1)
        #expect(!removedHit)
        cache.removeAll()
        #expect(cache.count == 0)
    }
}
