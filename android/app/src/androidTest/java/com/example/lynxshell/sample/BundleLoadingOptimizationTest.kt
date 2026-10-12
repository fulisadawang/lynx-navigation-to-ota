package com.example.lynxshell.sample

import android.os.Build
import android.os.Bundle
import android.os.Debug
import android.content.Context
import android.content.ContextWrapper
import android.os.FileObserver
import android.test.InstrumentationTestCase
import com.example.lynxshell.resource.ShellTemplateProvider
import com.lynx.tasm.provider.AbsTemplateProvider
import com.ota.android.sdk.ContentAddressedOtaStore
import com.ota.android.sdk.OtaJson
import com.ota.android.sdk.OtaModels
import com.ota.android.sdk.OtaSidecarModels
import com.ota.android.sdk.ReleaseTransaction
import java.io.File
import java.io.RandomAccessFile
import java.lang.reflect.InvocationTargetException
import java.lang.reflect.Proxy
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URI
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.AbstractExecutorService
import java.util.concurrent.ExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/** 公共 Provider/Store 的设备回归；反射只观察私有读取与源引用，不增加产品测试接口。 */
class BundleLoadingOptimizationTest : InstrumentationTestCase() {
    private lateinit var root: File

    override fun setUp() {
        super.setUp()
        assertEquals("只允许隔离的验收 App", "com.hugboga.custom.otae2e", instrumentation.targetContext.packageName)
        root = File(instrumentation.targetContext.cacheDir, "bundle-loading-${UUID.randomUUID()}")
        assertTrue(root.mkdirs())
    }

    override fun tearDown() {
        root.deleteRecursively()
        super.tearDown()
    }

    fun testPreparedFilePreservesBytesAcrossReadBoundaries() {
        val provider = provider()
        try {
            for (size in listOf(1, 8191, 8192, 8193, 2 * 1024 * 1024, MAX_BYTES)) {
                val bytes = ByteArray(size) { ((it * 31 + 7) and 0xff).toByte() }
                val file = File(root, "$size.bundle").also { it.writeBytes(bytes) }
                assertTrue("文件字节不一致: $size", bytes.contentEquals(readFile(provider, file)))
            }
        } finally { provider.close() }
    }

    fun testPreparedFileRejectsEmptyAndOverLimit() {
        val provider = provider()
        try {
            val empty = File(root, "empty.bundle").also { it.writeBytes(byteArrayOf()) }
            assertReadFails(provider, empty, "为空")
            val oversized = File(root, "oversized.bundle")
            RandomAccessFile(oversized, "rw").use { it.setLength(MAX_BYTES.toLong() + 1L) }
            assertReadFails(provider, oversized, "限制")
        } finally { provider.close() }
    }

    fun testPreparedFileAllocatesOnePayloadBuffer() {
        val size = 2 * 1024 * 1024
        val file = File(root, "allocation.bundle").also { it.writeBytes(ByteArray(size) { 0x36 }) }
        val provider = provider()
        try {
            repeat(3) { assertEquals(size, readFile(provider, file).size) }
            val before = requireNotNull(Debug.getRuntimeStat("art.gc.bytes-allocated")).toLong()
            val started = System.nanoTime()
            repeat(3) { assertEquals(size, readFile(provider, file).size) }
            val elapsed = System.nanoTime() - started
            val allocated = requireNotNull(Debug.getRuntimeStat("art.gc.bytes-allocated")).toLong() - before
            record("file-read payload=$size repetitions=3 allocatedApprox=$allocated elapsedNs=$elapsed")
            // ART 是进程级近似统计，预算留 50% 测量余量；旧扩容和 toByteArray 仍明显超出。
            assertTrue("读取应只分配一个载荷数组；近似分配=$allocated", allocated < size.toLong() * 3L * 3L / 2L)
        } finally { provider.close() }
    }

    fun testPreparedFileRejectsChangedLengthSnapshot() {
        val source = File(root, "length.bundle").also { it.writeBytes(ByteArray(8193) { 0x37 }) }
        val provider = provider()
        try {
            // 模拟 stat 完成后文件缩短/增长，不用随机 sleep 制造竞争。
            for (declared in listOf(source.length() - 1L, source.length() + 1L)) {
                val changed = object : File(source.absolutePath) { override fun length() = declared }
                assertReadFails(provider, changed, "变化")
            }
        } finally { provider.close() }
    }

    fun testPreparedFileCancellationIsCheckedBeforeRead() {
        val source = File(root, "cancel.bundle").also { it.writeBytes(ByteArray(8193) { 0x38 }) }
        val provider = provider()
        val cancelled = object : File(source.absolutePath) {
            override fun length(): Long { provider.close(); return source.length() }
        }
        assertReadFails(provider, cancelled, "取消")
    }

    fun testPreparedBytesAreSameInstanceAndReleasedAfterConsumption() {
        val bytes = ByteArray(8193) { 0x39 }
        val provider = provider(bytes, PREPARED_URL)
        try {
            val first = load(provider, PREPARED_URL)
            assertNull(first.error.get())
            assertSame("预备字节不应再次复制", bytes, first.bytes.get())
            assertNull("消费后 Provider 不能继续保留源字节", preparedBytes(provider))
            val second = load(provider, PREPARED_URL)
            assertNull("第二次不能再次消费预备字节", second.bytes.get())
            assertNotNull(second.error.get())
        } finally { provider.close() }
    }

    fun testMismatchedUrlDoesNotConsumePreparedBytes() {
        val bytes = byteArrayOf(0x40, 0x41)
        val provider = provider(bytes, PREPARED_URL)
        try {
            assertNotNull(load(provider, "assets://missing-bundle-loading.bundle").error.get())
            assertSame(bytes, preparedBytes(provider))
            assertSame(bytes, load(provider, PREPARED_URL).bytes.get())
            assertNull(preparedBytes(provider))
        } finally { provider.close() }
    }

    fun testCloseReleasesUnconsumedPreparedBytes() {
        val provider = provider(byteArrayOf(0x42), PREPARED_URL)
        provider.close()
        assertNull("销毁后不能保留未消费源字节", preparedBytes(provider))
    }

    fun testQueuedPreparedRequestClosePreventsFallbackAndCallbacks() {
        val field = ShellTemplateProvider::class.java.getDeclaredField("ioExecutor").apply { isAccessible = true }
        val original = field.get(null) as ExecutorService
        val gate = GateExecutor()
        AttemptServer().use { server ->
            val provider = provider(byteArrayOf(0x42), "https://127.0.0.1:${server.port}/queued.bundle")
            val callbacks = AtomicInteger()
            try {
                field.set(null, gate)
                assertSame("ART测试必须真实替换共享executor", gate, field.get(null))
                provider.loadTemplate("https://127.0.0.1:${server.port}/queued.bundle", object : AbsTemplateProvider.Callback {
                    override fun onSuccess(data: ByteArray) { callbacks.incrementAndGet() }
                    override fun onFailed(message: String) { callbacks.incrementAndGet() }
                })
                assertEquals(1, gate.pendingCount())
                provider.close()
                assertNull(preparedBytes(provider))
                gate.runPending()
                server.barrier()
                record("queued-close connectionAttempts=${server.attempts.get()} callbacks=${callbacks.get()}")
                assertEquals("排队预备请求关闭后不能fallback联网", 0, server.attempts.get())
                assertEquals("close后不能回调", 0, callbacks.get())
            } finally {
                provider.close()
                field.set(null, original)
                gate.shutdown()
            }
        }
    }

    fun testPreparedFileClosedAfterClaimHasNoCallbackOrFallback() {
        AttemptServer().use { server ->
            val source = File(root, "close-after-claim.bundle").also { it.writeBytes(byteArrayOf(0x51)) }
            val reference = AtomicReference<ShellTemplateProvider?>()
            val file = object : File(source.absolutePath) {
                override fun length(): Long { reference.get()!!.close(); return source.length() }
            }
            val uri = "https://127.0.0.1:${server.port}/claimed.bundle"
            val provider = ShellTemplateProvider(instrumentation.targetContext, preparedUrl = uri, preparedFile = file)
            reference.set(provider)
            withGate { gate ->
                val callbacks = AtomicInteger()
                provider.loadTemplate(uri, countingCallback(callbacks))
                gate.runPending()
                server.barrier()
                val consumed = ShellTemplateProvider::class.java.getDeclaredField("preparedConsumed")
                    .apply { isAccessible = true }.get(provider) as java.util.concurrent.atomic.AtomicBoolean
                assertTrue("本测试必须发生在claim后", consumed.get())
                assertEquals(0, server.attempts.get())
                assertEquals(0, callbacks.get())
                assertNull(preparedBytes(provider))
            }
        }
    }

    fun testCloseBeforeRemoteCallRegistrationHasNoNetworkOrCallback() {
        AttemptServer().use { server ->
            val reference = AtomicReference<ShellTemplateProvider?>()
            val wrapper = object : ContextWrapper(instrumentation.targetContext) {
                override fun getApplicationContext(): Context = this
                override fun getFilesDir(): File {
                    assertEquals("关闭边界需在Call登记前", 0, activeCallCount(reference.get()!!))
                    reference.get()!!.close()
                    return instrumentation.targetContext.filesDir
                }
            }
            val provider = ShellTemplateProvider(wrapper)
            reference.set(provider)
            withGate { gate ->
                val callbacks = AtomicInteger()
                provider.loadTemplate("https://127.0.0.1:${server.port}/before-registration.bundle", countingCallback(callbacks))
                gate.runPending()
                server.barrier()
                assertEquals(0, server.attempts.get())
                assertEquals(0, callbacks.get())
                assertEquals(0, activeCallCount(provider))
            }
        }
    }

    fun testCloseAfterRemoteCallRegistrationCancelsBeforeConnect() {
        AttemptServer().use { server ->
            val provider = provider()
            val clientField = ShellTemplateProvider::class.java.getDeclaredField("httpClient").apply { isAccessible = true }
            val original = clientField.get(null)
            val interceptorType = Class.forName("okhttp3.Interceptor")
            val chainType = Class.forName("okhttp3.Interceptor\$Chain")
            val requestType = Class.forName("okhttp3.Request")
            val entered = AtomicInteger()
            val interceptor = Proxy.newProxyInstance(interceptorType.classLoader, arrayOf(interceptorType)) { proxy, method, args ->
                when (method.name) {
                    "intercept" -> {
                        assertEquals("关闭边界需在Call登记后", 1, activeCallCount(provider))
                        entered.incrementAndGet()
                        provider.close()
                        val chain = args!![0]
                        val request = chainType.getMethod("request").invoke(chain)
                        try { chainType.getMethod("proceed", requestType).invoke(chain, request) }
                        catch (error: InvocationTargetException) { throw error.targetException }
                    }
                    "toString" -> "CloseAfterRegistrationInterceptor"
                    "hashCode" -> System.identityHashCode(proxy)
                    "equals" -> proxy === args!![0]
                    else -> error("未知Interceptor方法")
                }
            }
            val builder = original.javaClass.getMethod("newBuilder").invoke(original)
            builder.javaClass.getMethod("addInterceptor", interceptorType).invoke(builder, interceptor)
            try {
                clientField.set(null, builder.javaClass.getMethod("build").invoke(builder))
                withGate { gate ->
                    val callbacks = AtomicInteger()
                    provider.loadTemplate("https://127.0.0.1:${server.port}/after-registration.bundle", countingCallback(callbacks))
                    gate.runPending()
                    server.barrier()
                    assertEquals(1, entered.get())
                    assertEquals(0, server.attempts.get())
                    assertEquals(0, callbacks.get())
                    assertEquals(0, activeCallCount(provider))
                }
            } finally { provider.close(); clientField.set(null, original) }
        }
    }

    fun testConcurrentRequestsConsumePreparedBytesOnlyOnce() {
        val bytes = byteArrayOf(0x43, 0x44)
        val provider = provider(bytes, PREPARED_URL)
        try {
            val first = Result()
            val second = Result()
            provider.loadTemplate(PREPARED_URL, first)
            provider.loadTemplate(PREPARED_URL, second)
            first.await()
            second.await()
            assertEquals(1, listOf(first, second).count { it.bytes.get() === bytes })
            assertEquals(1, listOf(first, second).count { it.error.get() != null })
            assertNull(preparedBytes(provider))
        } finally { provider.close() }
    }

    fun testWarmLeaseReadsEachManifestOnlyOnce() {
        assertTrue("解析读取计数使用 API 27+ 纳秒文件身份缓存", Build.VERSION.SDK_INT >= 27)
        FixtureServer().use { server ->
            val fixture = fixture(server)
            fixture.install("A")
            val warmLease = requireNotNull(fixture.store.acquireCurrentBundleLease(fixture.scope, OWNER))
            val app = File(fixture.storeRoot, "apps/$APP_ID")
            val main = File(app, "manifests").listFiles()!!.single { it.extension == "json" }
            val async = File(app, "async-bundles/manifests").listFiles()!!.single { it.extension == "json" }
            val mainWatch = ManifestReads(main)
            val asyncWatch = ManifestReads(async)
            var lease: ReleaseTransaction.BundleLease? = null
            try {
                mainWatch.start()
                asyncWatch.start()
                lease = requireNotNull(fixture.store.acquireCurrentBundleLease(fixture.scope, OWNER))
                mainWatch.barrier()
                asyncWatch.barrier()
                record("lease-read mainManifestOpens=${mainWatch.opens.get()} asyncManifestOpens=${asyncWatch.opens.get()}")
                assertEquals("同一次 lease 主 Manifest 重复解析", 1, mainWatch.opens.get())
                assertEquals("同一次 lease Async Manifest 重复解析", 1, asyncWatch.opens.get())
                assertEquals("A-lazy", lease.sidecars!!.resource(LAZY_KEY)!!.readBytes().toString(Charsets.UTF_8))
            } finally {
                // 先关闭观察器，再关闭 lease，排除 close -> prune 引起的额外 JSON 读取。
                mainWatch.close()
                asyncWatch.close()
                lease?.close()
                warmLease.close()
            }
        }
    }

    fun testLeaseValidatesUnrequestedMainAndAsyncObjects() {
        FixtureServer().use { server ->
            val fixture = fixture(server)
            fixture.install("A")
            val warm = requireNotNull(fixture.store.acquireCurrentBundleLease(fixture.scope, OWNER))
            val peerMain = File(warm.release.bundles.single { it.bundlePath == PEER }.localFilePath)
            val peerLazy = requireNotNull(fixture.store.acquireCurrentBundleLease(fixture.scope, PEER))
            val peerAsync = peerLazy.sidecars!!.resource(LAZY_KEY)!!.file
            warm.close()
            peerLazy.close()
            val original = peerMain.readBytes()
            peerMain.writeBytes(ByteArray(original.size) { 0x45 })
            assertNull("未请求的主包损坏仍应拒绝整个 Release", fixture.store.acquireCurrentBundleLease(fixture.scope, OWNER))
            peerMain.writeBytes(original)
            val asyncOriginal = peerAsync.readBytes()
            peerAsync.writeBytes(ByteArray(asyncOriginal.size) { 0x46 })
            assertNull("其他 owner 的 Async 损坏仍应拒绝整个 Release", fixture.store.acquireCurrentBundleLease(fixture.scope, OWNER))
        }
    }

    fun testOldLeaseKeepsAResourcesAfterBIsInstalled() {
        FixtureServer().use { server ->
            val fixture = fixture(server)
            fixture.install("A")
            val old = requireNotNull(fixture.store.acquireCurrentBundleLease(fixture.scope, OWNER))
            try {
                fixture.install("B")
                val current = requireNotNull(fixture.store.acquireCurrentBundleLease(fixture.scope, OWNER))
                try {
                    assertEquals("A", old.release.context.releaseId)
                    assertEquals("B", current.release.context.releaseId)
                    assertEquals("A-lazy", old.sidecars!!.resource(LAZY_KEY)!!.readBytes().toString(Charsets.UTF_8))
                    assertEquals("B-lazy", current.sidecars!!.resource(LAZY_KEY)!!.readBytes().toString(Charsets.UTF_8))
                } finally { current.close() }
            } finally { old.close() }
        }
    }

    fun testInvalidAsyncOwnerUrlAndAmbiguousShortNameAreRejected() {
        FixtureServer().use { server ->
            val fixture = fixture(server)
            for ((owner, url) in listOf("Unknown.bundle" to "${server.base}/resource", OWNER to "http://invalid.example/resource")) {
                val entry = OtaSidecarModels.AsyncEntry(owner, LAZY_KEY, "lazy-bundle/panel.bundle", URI.create(url), sha(byteArrayOf(1)), 1, OtaSidecarModels.AsyncKind.BUNDLE)
                val bytes = OtaJson.stringify(OtaSidecarModels.AsyncManifest(1, listOf(entry)).toJsonMap()).toByteArray()
                server.bodies["/invalid"] = bytes
                val ref = OtaSidecarModels.AsyncManifestRef(1, URI.create("${server.base}/invalid"), sha(bytes), bytes.size)
                var failed = false
                try { fixture.store.stageAsyncResources(fixture.manifest("invalid", ref)) } catch (_: Exception) { failed = true }
                assertTrue("非法 owner/URL 不能通过 Async stage", failed)
            }
            fixture.install("A")
            assertNull("相同短名称必须保持歧义拒绝", fixture.store.acquireCurrentBundleLease(fixture.scope, "Page.lynx.bundle"))
        }
    }

    private fun provider(bytes: ByteArray? = null, url: String? = null) = ShellTemplateProvider(
        instrumentation.targetContext, preparedUrl = url, preparedBytes = bytes,
    )

    private fun preparedBytes(provider: ShellTemplateProvider): Any? = ShellTemplateProvider::class.java
        .getDeclaredField("preparedBytes").apply { isAccessible = true }.get(provider)

    private fun readFile(provider: ShellTemplateProvider, file: File): ByteArray = try {
        ShellTemplateProvider::class.java.getDeclaredMethod("loadFile", File::class.java)
            .apply { isAccessible = true }.invoke(provider, file) as ByteArray
    } catch (error: InvocationTargetException) { throw error.targetException }

    private fun assertReadFails(provider: ShellTemplateProvider, file: File, contains: String) {
        var failure: Throwable? = null
        try { readFile(provider, file) } catch (error: Throwable) { failure = error }
        assertNotNull("预备文件应拒绝: ${file.name}", failure)
        assertTrue("错误需说明边界: $failure", failure!!.message.orEmpty().contains(contains))
    }

    private fun load(provider: ShellTemplateProvider, uri: String): Result = Result().also {
        provider.loadTemplate(uri, it)
        it.await()
    }

    private fun activeCallCount(provider: ShellTemplateProvider) =
        (ShellTemplateProvider::class.java.getDeclaredField("activeCalls").apply { isAccessible = true }.get(provider) as Set<*>).size

    private fun countingCallback(count: AtomicInteger) = object : AbsTemplateProvider.Callback {
        override fun onSuccess(data: ByteArray) { count.incrementAndGet() }
        override fun onFailed(message: String) { count.incrementAndGet() }
    }

    private fun withGate(block: (GateExecutor) -> Unit) {
        val field = ShellTemplateProvider::class.java.getDeclaredField("ioExecutor").apply { isAccessible = true }
        val original = field.get(null)
        val gate = GateExecutor()
        try { field.set(null, gate); block(gate) }
        finally { field.set(null, original); gate.shutdown() }
    }

    private fun record(message: String) {
        instrumentation.sendStatus(0, Bundle().apply { putString("stream", "\nBundleLoadingOptimization: $message\n") })
    }

    private class Result : AbsTemplateProvider.Callback {
        val bytes = AtomicReference<ByteArray?>()
        val error = AtomicReference<String?>()
        private val done = CountDownLatch(1)
        override fun onSuccess(data: ByteArray) { bytes.set(data); done.countDown() }
        override fun onFailed(message: String) { error.set(message); done.countDown() }
        fun await() { check(done.await(10, TimeUnit.SECONDS)) { "Provider 回调未完成" } }
    }

    private class GateExecutor : AbstractExecutorService() {
        private val pending = mutableListOf<Runnable>()
        private var stopped = false
        @Synchronized override fun execute(command: Runnable) { check(!stopped); pending += command }
        @Synchronized fun pendingCount() = pending.size
        fun runPending() { val tasks = synchronized(this) { pending.toList().also { pending.clear() } }; tasks.forEach(Runnable::run) }
        @Synchronized override fun shutdown() { stopped = true }
        @Synchronized override fun shutdownNow(): MutableList<Runnable> { stopped = true; return pending.toMutableList().also { pending.clear() } }
        @Synchronized override fun isShutdown() = stopped
        @Synchronized override fun isTerminated() = stopped && pending.isEmpty()
        override fun awaitTermination(timeout: Long, unit: TimeUnit) = isTerminated
    }

    /** 仅统计TLS连接尝试；不提供可信证书、不把TLS失败当零请求。marker握手作为accept顺序barrier。 */
    private class AttemptServer : AutoCloseable {
        private val socket = ServerSocket(0, 10, InetAddress.getByName("127.0.0.1"))
        val port = socket.localPort
        val attempts = AtomicInteger()
        private val barrierReached = CountDownLatch(1)
        private val worker = Thread {
            while (!socket.isClosed) {
                val connection = try { socket.accept() } catch (_: Exception) { break }
                connection.use {
                    if (it.getInputStream().read() == 0x7f) barrierReached.countDown() else attempts.incrementAndGet()
                }
            }
        }.apply { isDaemon = true; start() }
        fun barrier() {
            Socket("127.0.0.1", port).use { it.getOutputStream().write(0x7f); it.getOutputStream().flush() }
            check(barrierReached.await(10, TimeUnit.SECONDS)) { "连接计数barrier未到达" }
        }
        override fun close() { socket.close(); worker.join(1000) }
    }

    private fun fixture(server: FixtureServer): Fixture = Fixture(File(root, "store"), server)

    private class Fixture(val storeRoot: File, private val server: FixtureServer) {
        val store = ContentAddressedOtaStore(storeRoot, allowLocalHTTPForTest = true)
        val scope = ReleaseTransaction.ReleaseScope(OtaModels.Environment.TEST, OtaModels.HostApp.TEMPLATE, APP_ID, OtaModels.Platform.ANDROID)
        private var phase = "A"

        fun install(id: String) {
            phase = id
            val entries = listOf(OWNER, PEER).mapIndexed { index, owner ->
                val bytes = "$id-${if (index == 0) "lazy" else "peer-lazy"}".toByteArray()
                val route = "/$id/lazy-$index"
                server.bodies[route] = bytes
                OtaSidecarModels.AsyncEntry(owner, LAZY_KEY, "lazy-bundle/panel-$index.bundle", URI.create(server.base + route), sha(bytes), bytes.size, OtaSidecarModels.AsyncKind.BUNDLE)
            }
            val bytes = OtaJson.stringify(OtaSidecarModels.AsyncManifest(1, entries).toJsonMap()).toByteArray()
            server.bodies["/$id/async"] = bytes
            val ref = OtaSidecarModels.AsyncManifestRef(1, URI.create("${server.base}/$id/async"), sha(bytes), bytes.size)
            val manifest = manifest(id, ref)
            store.reserveSidecars(APP_ID, ref).use {
                store.stageAsyncResources(manifest)
                store.install(ReleaseTransaction.InstallRequest(scope, manifest))
            }
        }

        fun manifest(id: String, ref: OtaSidecarModels.AsyncManifestRef) = OtaModels.ReleaseManifest(
            OtaModels.Environment.TEST, OtaModels.HostApp.TEMPLATE, APP_ID, id,
            OtaModels.Platform.ANDROID, listOf(OtaModels.Platform.ANDROID), listOf(OWNER, PEER).mapIndexed { index, path ->
                val bytes = "$phase-main-$index".toByteArray()
                val route = "/$phase/main-$index"
                server.bodies[route] = bytes
                OtaModels.BundleArtifact(index + 1, path, sha(bytes), URI.create(server.base + route), bytes.size)
            }, OtaModels.ReleaseStatus.ACTIVE, ref,
        )
    }

    private class ManifestReads(private val target: File) : AutoCloseable {
        val opens = AtomicInteger()
        private val markers = ConcurrentHashMap<String, CountDownLatch>()
        @Suppress("DEPRECATION")
        private val observer = object : FileObserver(target.parent!!, FileObserver.OPEN or FileObserver.CLOSE_NOWRITE) {
            override fun onEvent(event: Int, path: String?) {
                if (path == null) return
                if (event and FileObserver.OPEN != 0 && path == target.name) opens.incrementAndGet()
                if (event and FileObserver.CLOSE_NOWRITE != 0) markers[path]?.countDown()
            }
        }
        fun start() { observer.startWatching(); barrier(); opens.set(0) }
        fun barrier() {
            val marker = File(target.parentFile, ".observer-${UUID.randomUUID()}")
            val done = CountDownLatch(1)
            markers[marker.name] = done
            try {
                marker.writeText("barrier")
                marker.inputStream().use { it.read() }
                check(done.await(10, TimeUnit.SECONDS)) { "FileObserver marker 未到达" }
            } finally { markers.remove(marker.name); marker.delete() }
        }
        override fun close() { observer.stopWatching() }
    }

    private class FixtureServer : AutoCloseable {
        private val socket = ServerSocket(0, 10, InetAddress.getByName("127.0.0.1"))
        val base = "http://127.0.0.1:${socket.localPort}"
        val bodies = ConcurrentHashMap<String, ByteArray>()
        private val worker = Thread {
            while (!socket.isClosed) {
                val client = try { socket.accept() } catch (_: Exception) { break }
                client.use(::respond)
            }
        }.apply { isDaemon = true; start() }
        private fun respond(connection: Socket) {
            val reader = connection.getInputStream().bufferedReader(Charsets.US_ASCII)
            val path = reader.readLine().split(' ')[1].substringBefore('?')
            while (!reader.readLine().isNullOrEmpty()) { }
            val data = bodies[path]
            val body = data ?: "missing".toByteArray()
            val header = "HTTP/1.1 ${if (data == null) "404 Not Found" else "200 OK"}\r\nContent-Length: ${body.size}\r\nConnection: close\r\n\r\n"
            connection.getOutputStream().use { it.write(header.toByteArray(Charsets.US_ASCII)); it.write(body); it.flush() }
        }
        override fun close() { socket.close(); worker.join(1000) }
    }

    private companion object {
        const val MAX_BYTES = 20 * 1024 * 1024
        const val APP_ID = "10030071"
        const val OWNER = "left/Page.lynx.bundle"
        const val PEER = "right/Page.lynx.bundle"
        const val LAZY_KEY = "/lazy-bundle/panel.bundle"
        const val PREPARED_URL = "assets://missing-prepared.bundle"
        fun sha(bytes: ByteArray): String = "sha256:" + MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }
}
