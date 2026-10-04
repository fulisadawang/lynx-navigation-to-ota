package com.example.lynxcapacitormodule

/** 最后一个 owner 退出才恢复原值，任意 Tab 不能覆盖另一个 Tab 的保持状态。 */
internal class NativeBooleanLeases<K : Any, O : Any>(private val read: (K) -> Boolean, private val write: (K, Boolean) -> Unit) {
    private data class State<O>(val original: Boolean, val owners: MutableSet<O>)
    private val states = LinkedHashMap<K, State<O>>()
    @Synchronized fun acquire(key: K, owner: O) {
        val state = states.getOrPut(key) { State(read(key), linkedSetOf()) }
        state.owners.add(owner)
        write(key, true)
    }
    @Synchronized fun release(key: K, owner: O) {
        val state = states[key] ?: return
        if (!state.owners.remove(owner)) return
        if (state.owners.isEmpty()) { states.remove(key); write(key, state.original) }
    }
}
