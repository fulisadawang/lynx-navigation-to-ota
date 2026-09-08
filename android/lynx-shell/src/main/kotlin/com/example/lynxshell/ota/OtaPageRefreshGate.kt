package com.example.lynxshell.ota

/** 进程内门控按身份代际拥有 reservation；旧任务不能占住/清掉新用户的名额。 */
internal class OtaPageRefreshGate(initialEpoch: Long) {
    private var epoch = initialEpoch
    private val lastSuccess = LinkedHashMap<String, Long>()
    private val reservations = LinkedHashMap<String, Long>()

    @Synchronized fun reset(nextEpoch: Long) { epoch = nextEpoch; lastSuccess.clear(); reservations.clear() }
    @Synchronized fun reserve(appId: String, expectedEpoch: Long, now: Long, interval: Long): Boolean {
        if (expectedEpoch != epoch || reservations.containsKey(appId)) return false
        val last = lastSuccess[appId]
        if (last != null && interval > 0L && now - last < interval) return false
        reservations[appId] = expectedEpoch
        return true
    }
    @Synchronized fun complete(appId: String, expectedEpoch: Long) {
        if (reservations[appId] == expectedEpoch) reservations.remove(appId)
    }
    @Synchronized fun markSuccess(appIds: Collection<String>, expectedEpoch: Long, now: Long) {
        if (expectedEpoch == epoch) appIds.forEach { lastSuccess[it] = now }
    }
    @Synchronized fun clearApp(appId: String) { lastSuccess.remove(appId); reservations.remove(appId) }
    @Synchronized fun clearAll() { lastSuccess.clear(); reservations.clear() }
}
