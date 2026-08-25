package com.ota.android.sdk

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BundleValidationCacheTest {
  private fun key(
    releaseId: String = "r1",
    sha256: String = "sha256:one",
    size: Long = 10,
    mtime: Long = 20,
  ) = BundleValidationCache.Key(
    scope = "TEST|capp|android|10000001",
    releaseId = releaseId,
    bundlePath = "main.lynx.bundle",
    expectedSha256 = sha256,
    fileSize = size,
    lastModifiedMillis = mtime,
  )

  @Test
  fun `same fingerprint is a cache hit`() {
    val cache = BundleValidationCache(maxEntries = 2)
    val key = key()

    assertFalse(cache.contains(key))
    cache.put(key)
    assertTrue(cache.contains(key))
    assertEquals(1, cache.size())
  }

  @Test
  fun `release and file fingerprint changes miss`() {
    val cache = BundleValidationCache()
    cache.put(key())

    assertFalse(cache.contains(key(releaseId = "r2")))
    assertFalse(cache.contains(key(sha256 = "sha256:two")))
    assertFalse(cache.contains(key(size = 11)))
    assertFalse(cache.contains(key(mtime = 21)))
  }

  @Test
  fun `least recently used entries are evicted`() {
    val cache = BundleValidationCache(maxEntries = 2)
    val first = key(releaseId = "r1")
    val second = key(releaseId = "r2")
    val third = key(releaseId = "r3")
    cache.put(first)
    cache.put(second)
    assertTrue(cache.contains(first))
    cache.put(third)

    assertTrue(cache.contains(first))
    assertFalse(cache.contains(second))
    assertTrue(cache.contains(third))
  }
}
