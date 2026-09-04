package com.example.lynxcapacitormodule

import android.Manifest
import android.app.Activity
import android.app.Application
import android.content.pm.PackageManager
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.os.Build
import android.os.Bundle
import android.os.Looper
import java.io.File
import java.util.UUID
import java.util.WeakHashMap
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONObject

/**
 * Audio 的 Android framework 实现。
 *
 * 本文件不创建 Capacitor Bridge，也不依赖 Capacitor Plugin。权限检查和申请由 runtime
 * 的统一权限协调器负责；这里仅认领录音、播放和状态方法。所有返回值都是能力层业务对象，
 * 不包含 success/data envelope。
 */
object NativeAudioCapabilities {
    private const val METHOD_RECORD = "record"
    private const val METHOD_START_RECORDING = "startRecording"
    private const val METHOD_STOP_RECORDING = "stopRecording"
    private const val METHOD_PLAY = "play"
    private const val METHOD_START_PLAYBACK = "startPlayback"
    private const val METHOD_STOP_PLAYBACK = "stopPlayback"
    private const val METHOD_GET_STATE = "getState"

    private const val AUDIO_DIRECTORY = "lynx-audio"
    private const val RECORDING_EXTENSION = ".m4a"
    private const val MIN_RECORDING_DURATION_MS = 500L

    private val lock = Any()
    private val sessions = WeakHashMap<Activity, AudioSession>()
    private val registeredApplications = WeakHashMap<Application, Boolean>()

    /**
     * Activity 生命周期回调只从 Application 注册，不保存 Activity 引用；这样 Activity 销毁
     * 后可以主动释放 MediaRecorder/MediaPlayer，而不会让单例能力对象延长 Activity 生命周期。
     */
    private val lifecycleCallbacks = object : Application.ActivityLifecycleCallbacks {
        override fun onActivityPreCreated(activity: Activity, savedInstanceState: Bundle?) = Unit

        override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit

        override fun onActivityStarted(activity: Activity) = Unit

        override fun onActivityResumed(activity: Activity) = Unit

        override fun onActivityPaused(activity: Activity) = Unit

        override fun onActivityStopped(activity: Activity) = Unit

        override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit

        override fun onActivityDestroyed(activity: Activity) {
            release(activity)
        }
    }

    /**
     * 分发 Audio 的实际能力。
     *
     * 返回 true 表示本文件认领了 methodName；checkPermissions/requestPermissions 不在这里
     * 认领，由 runtime 权限协调器处理。异步播放准备完成、异常和取消都会通过 complete 回传。
     */
    fun dispatch(
        activity: Activity,
        methodName: String,
        options: JSONObject,
        complete: (JSONObject) -> Unit,
    ): Boolean {
        if (methodName !in HANDLED_METHODS) return false

        val run = Runnable {
            if (activity.isFinishing || (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN_MR1 && activity.isDestroyed)) {
                release(activity)
                completeSafely(complete, error("ACTIVITY_DESTROYED", "Activity 已销毁，无法执行 Audio 操作"))
                return@Runnable
            }

            registerLifecycleCallbacks(activity)
            dispatchOnMain(activity, methodName, options, complete)
        }

        if (Looper.myLooper() == Looper.getMainLooper()) {
            run.run()
        } else {
            runCatching { activity.runOnUiThread(run) }
                .onFailure {
                    completeSafely(complete, error("ACTIVITY_DESTROYED", "Activity 无法切换到主线程"))
                }
        }
        return true
    }

    /**
     * 停止当前 Activity 上正在进行的录音或播放。
     *
     * 该方法是同步业务接口，宿主应在主线程调用；MediaRecorder/MediaPlayer 的资源释放在
     * 这里完成。没有活动操作时返回 state=idle，而不是伪造成功 envelope。
     */
    fun stop(activity: Activity): JSONObject {
        if (activity.isFinishing || (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN_MR1 && activity.isDestroyed)) {
            release(activity)
            return error("ACTIVITY_DESTROYED", "Activity 已销毁，无法停止 Audio 操作")
        }

        registerLifecycleCallbacks(activity)
        val state = synchronized(lock) { sessions[activity]?.state ?: AudioState.IDLE }
        return when (state) {
            AudioState.RECORDING -> stopRecordingInternal(activity)
            AudioState.PREPARING,
            AudioState.PLAYING,
            -> stopPlaybackInternal(activity)
            AudioState.IDLE -> stateResult(activity)
        }
    }

    /**
     * 释放当前 Activity 的全部媒体资源。录音文件不会因 Activity 销毁被删除，仍可在 cache
     * 生命周期内由后续调用按 path 播放；未完成的播放准备会收到 ACTIVITY_DESTROYED。
     */
    fun release(activity: Activity) {
        val session = synchronized(lock) {
            sessions.remove(activity)
        } ?: return

        val recorderSnapshot = synchronized(lock) {
            val current = session.recorder
            val outputFile = session.recordingOutputFile
            val startedAt = session.recordingStartedAt
            session.recorder = null
            Triple(current, outputFile, startedAt)
        }
        val playerAndCompletion = synchronized(lock) {
            val currentPlayer = session.player
            val pendingCompletion = session.playbackCompletion
            session.player = null
            session.playbackCompletion = null
            session.state = AudioState.IDLE
            session.recordingOutputFile = null
            session.playbackFile = null
            Pair(currentPlayer, pendingCompletion)
        }

        if (recorderSnapshot.first != null) {
            stopRecorderForRelease(
                recorderSnapshot.first,
                recorderSnapshot.second,
                recorderSnapshot.third,
            )
        }
        recorderSnapshot.first?.let(::releaseRecorder)
        playerAndCompletion.first?.let(::releasePlayer)
        playerAndCompletion.second?.invoke(error("ACTIVITY_DESTROYED", "Activity 已销毁，Audio 操作已取消"))
    }

    private fun dispatchOnMain(
        activity: Activity,
        methodName: String,
        options: JSONObject,
        complete: (JSONObject) -> Unit,
    ) {
        when (methodName) {
            METHOD_RECORD, METHOD_START_RECORDING -> startRecording(activity, complete)
            METHOD_STOP_RECORDING -> completeSafely(complete, stopRecordingInternal(activity))
            METHOD_PLAY, METHOD_START_PLAYBACK -> startPlayback(activity, options, complete)
            METHOD_STOP_PLAYBACK -> completeSafely(complete, stopPlaybackInternal(activity))
            METHOD_GET_STATE -> completeSafely(complete, stateResult(activity))
        }
    }

    private fun startRecording(activity: Activity, complete: (JSONObject) -> Unit) {
        val completion = CompletionOnce(complete)
        if (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            completion.invoke(error("PERMISSION_DENIED", "缺少录音权限，请先由 runtime 请求 RECORD_AUDIO"))
            return
        }

        val session = synchronized(lock) {
            val current = sessions.getOrPut(activity) { AudioSession() }
            if (current.state != AudioState.IDLE) return@synchronized null
            current.apply {
                lastError = null
                recordingOutputFile = null
                playbackFile = null
            }
        }
        if (session == null) {
            completion.invoke(error("BUSY", "当前 Activity 已有录音或播放操作"))
            return
        }

        val outputFile = runCatching { createRecordingFile(activity) }.getOrElse { throwable ->
            val code = (throwable as? AudioException)?.code ?: "FILE_ERROR"
            recordFailure(session, code, throwable.message ?: "无法创建录音文件")
            completion.invoke(error(code, "无法创建录音文件"))
            return
        }

        val recorder = runCatching { MediaRecorder() }.getOrElse { throwable ->
            outputFile.delete()
            recordFailure(session, "RECORDER_ERROR", throwable.message ?: "无法创建 MediaRecorder")
            completion.invoke(error("RECORDER_ERROR", "无法创建 MediaRecorder"))
            return
        }
        val recorderStarted = runCatching {
            recorder.setAudioSource(MediaRecorder.AudioSource.MIC)
            recorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            recorder.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            recorder.setOutputFile(outputFile.absolutePath)
            recorder.setOnErrorListener { _, what, extra ->
                handleRecorderError(session, recorder, what, extra)
            }
            recorder.prepare()
            recorder.start()
        }
        if (recorderStarted.isFailure) {
            releaseRecorder(recorder)
            outputFile.delete()
            val throwable = recorderStarted.exceptionOrNull()
            val code = if (throwable is SecurityException) "PERMISSION_DENIED" else "RECORDER_ERROR"
            recordFailure(session, code, throwable?.message ?: "MediaRecorder 启动失败")
            completion.invoke(error(code, if (code == "PERMISSION_DENIED") "录音权限不可用" else "MediaRecorder 启动失败"))
            return
        }

        var activityLost = false
        synchronized(lock) {
            // Activity 可能在 recorder.start() 期间销毁；此时不能把孤立 recorder 放入状态表。
            if (sessions[activity] !== session || activity.isFinishing || isDestroyed(activity)) {
                session.state = AudioState.IDLE
                activityLost = true
            } else {
                session.recorder = recorder
                session.recordingOutputFile = outputFile
                session.recordingStartedAt = android.os.SystemClock.elapsedRealtime()
                session.state = AudioState.RECORDING
                session.lastError = null
            }
        }
        if (activityLost) {
            releaseRecorder(recorder)
            outputFile.delete()
            completion.invoke(error("ACTIVITY_DESTROYED", "Activity 已销毁，录音未启动"))
            return
        }

        val state = synchronized(lock) { stateResult(session) }
        completion.invoke(state)
    }

    private fun startPlayback(
        activity: Activity,
        options: JSONObject,
        complete: (JSONObject) -> Unit,
    ) {
        val completion = CompletionOnce(complete)
        val session = synchronized(lock) {
            val current = sessions.getOrPut(activity) { AudioSession() }
            if (current.state != AudioState.IDLE) return@synchronized null
            current.apply { lastError = null }
        }
        if (session == null) {
            completion.invoke(error("BUSY", "当前 Activity 已有录音或播放操作"))
            return
        }

        val file = resolvePlaybackFile(activity, session, options)
        if (file.error != null) {
            val details = file.error.optJSONObject("error")
            recordFailure(
                session,
                details?.optString("code", "NATIVE_ERROR") ?: "NATIVE_ERROR",
                details?.optString("message", "无法解析播放文件") ?: "无法解析播放文件",
            )
            completion.invoke(file.error)
            return
        }
        val playbackFile = file.file ?: run {
            val result = error("FILE_NOT_FOUND", "没有可播放的录音文件")
            recordFailure(session, "FILE_NOT_FOUND", "没有可播放的录音文件")
            completion.invoke(result)
            return
        }

        val player = runCatching { MediaPlayer() }.getOrElse { throwable ->
            val message = throwable.message ?: "无法创建 MediaPlayer"
            recordFailure(session, "PLAYER_ERROR", message)
            completion.invoke(error("PLAYER_ERROR", "无法创建 MediaPlayer"))
            return
        }
        synchronized(lock) {
            session.player = player
            session.playbackFile = playbackFile
            session.playbackCompletion = completion
            session.state = AudioState.PREPARING
        }

        runCatching {
            player.setOnPreparedListener { preparedPlayer ->
                handlePlayerPrepared(session, preparedPlayer)
            }
            player.setOnCompletionListener { completedPlayer ->
                handlePlayerCompletion(session, completedPlayer)
            }
            player.setOnErrorListener { failedPlayer, what, extra ->
                handlePlayerError(session, failedPlayer, what, extra)
                true
            }
            player.setDataSource(playbackFile.absolutePath)
            // prepareAsync 不阻塞主线程；成功/失败均由 MediaPlayer listener 回到主线程。
            player.prepareAsync()
        }.onFailure { throwable ->
            failPlayer(
                session,
                player,
                "PLAYER_ERROR",
                throwable.message ?: "MediaPlayer 准备失败",
            )
        }
    }

    private fun handlePlayerPrepared(session: AudioSession, player: MediaPlayer) {
        val completion: CompletionOnce?
        val file: File?
        val started = runCatching {
            synchronized(lock) {
                if (session.player !== player || session.state != AudioState.PREPARING) return@synchronized false
                player.start()
                session.state = AudioState.PLAYING
                session.lastError = null
                true
            }
        }
        if (started.isFailure || started.getOrNull() != true) {
            if (started.isFailure) {
                failPlayer(session, player, "PLAYER_ERROR", "MediaPlayer 开始播放失败")
            } else {
                releasePlayer(player)
            }
            return
        }

        synchronized(lock) {
            completion = session.playbackCompletion
            session.playbackCompletion = null
            file = session.playbackFile
        }
        completion?.invoke(
            JSONObject()
                .put("state", AudioState.PLAYING.wireValue)
                .put("playing", true)
                .put("path", file?.absolutePath ?: JSONObject.NULL),
        )
    }

    private fun handlePlayerCompletion(session: AudioSession, player: MediaPlayer) {
        synchronized(lock) {
            if (session.player !== player) return
            session.player = null
            session.playbackFile = null
            session.state = AudioState.IDLE
            session.lastError = null
        }
        releasePlayer(player)
        // 播放启动的 promise 已在 prepared 时完成；播放完成通过 getState 观察为 idle。
    }

    private fun handlePlayerError(session: AudioSession, player: MediaPlayer, what: Int, extra: Int) {
        failPlayer(session, player, "PLAYER_ERROR", "MediaPlayer 播放失败（$what/$extra）")
    }

    private fun failPlayer(
        session: AudioSession,
        player: MediaPlayer,
        code: String,
        message: String,
    ) {
        val completion: CompletionOnce?
        synchronized(lock) {
            if (session.player !== player) {
                releasePlayer(player)
                return
            }
            completion = session.playbackCompletion
            session.playbackCompletion = null
            session.player = null
            session.playbackFile = null
            session.state = AudioState.IDLE
            session.lastError = ErrorInfo(code, message)
        }
        releasePlayer(player)
        completion?.invoke(error(code, message))
    }

    private fun stopRecordingInternal(activity: Activity): JSONObject {
        val snapshot = synchronized(lock) {
            val session = sessions[activity] ?: return@synchronized null
            if (session.state != AudioState.RECORDING || session.recorder == null) {
                return@synchronized RecordingStopSnapshot(session, null, null, 0L)
            }
            val recorder = session.recorder
            val outputFile = session.recordingOutputFile
            val duration = android.os.SystemClock.elapsedRealtime() - session.recordingStartedAt
            session.recorder = null
            session.recordingOutputFile = null
            session.state = AudioState.IDLE
            RecordingStopSnapshot(session, recorder, outputFile, duration)
        }

        val actual = snapshot ?: return error("NOT_RECORDING", "当前 Activity 没有正在进行的录音")
        if (actual.recorder == null) {
            return error("NOT_RECORDING", "当前 Activity 没有正在进行的录音").put("state", actual.session.state.wireValue)
        }

        val stopFailure = runCatching { actual.recorder.stop() }.exceptionOrNull()
        releaseRecorder(actual.recorder)
        val outputFile = actual.outputFile
        if (stopFailure != null) {
            outputFile?.delete()
            val code = if (actual.durationMs < MIN_RECORDING_DURATION_MS) {
                "RECORDING_TOO_SHORT"
            } else {
                "RECORDER_ERROR"
            }
            recordFailure(actual.session, code, "MediaRecorder 停止失败")
            return error(code, if (code == "RECORDING_TOO_SHORT") "录音时长太短，无法生成有效文件" else "MediaRecorder 停止录音失败")
                .put("state", AudioState.IDLE.wireValue)
        }

        if (actual.durationMs < MIN_RECORDING_DURATION_MS) {
            outputFile?.delete()
            recordFailure(actual.session, "RECORDING_TOO_SHORT", "录音时长太短，无法生成有效文件")
            return error("RECORDING_TOO_SHORT", "录音时长太短，无法生成有效文件")
                .put("state", AudioState.IDLE.wireValue)
        }
        if (outputFile == null || !outputFile.isFile) {
            recordFailure(actual.session, "FILE_NOT_FOUND", "录音文件不存在")
            return error("FILE_NOT_FOUND", "录音文件不存在").put("state", AudioState.IDLE.wireValue)
        }
        if (outputFile.length() <= 0L) {
            outputFile.delete()
            recordFailure(actual.session, "EMPTY_FILE", "录音文件为空")
            return error("EMPTY_FILE", "录音文件为空").put("state", AudioState.IDLE.wireValue)
        }

        synchronized(lock) {
            actual.session.lastRecordingFile = outputFile
            actual.session.lastError = null
        }
        return JSONObject()
            .put("state", AudioState.IDLE.wireValue)
            .put("stopped", true)
            .put("durationMs", actual.durationMs)
            .put("path", outputFile.absolutePath)
    }

    private fun stopPlaybackInternal(activity: Activity): JSONObject {
        val snapshot = synchronized(lock) {
            val session = sessions[activity] ?: return@synchronized null
            if (session.state != AudioState.PREPARING && session.state != AudioState.PLAYING) {
                return@synchronized PlaybackStopSnapshot(session, null, null, false)
            }
            val player = session.player
            val pendingCompletion = session.playbackCompletion
            val file = session.playbackFile
            session.player = null
            session.playbackCompletion = null
            session.playbackFile = null
            session.state = AudioState.IDLE
            session.lastError = null
            PlaybackStopSnapshot(session, player, pendingCompletion, true, file)
        }

        val actual = snapshot ?: return error("NOT_PLAYING", "当前 Activity 没有正在进行的播放")
        if (!actual.wasPlaying) {
            return error("NOT_PLAYING", "当前 Activity 没有正在进行的播放")
                .put("state", actual.session.state.wireValue)
        }
        actual.player?.let(::releasePlayer)
        actual.pendingCompletion?.invoke(error("CANCELLED", "播放准备已停止"))
        return JSONObject()
            .put("state", AudioState.IDLE.wireValue)
            .put("stopped", true)
            .put("path", actual.file?.absolutePath ?: JSONObject.NULL)
    }

    private fun stateResult(activity: Activity): JSONObject = synchronized(lock) {
        val session = sessions[activity]
        if (session == null) {
            return@synchronized JSONObject()
                .put("state", AudioState.IDLE.wireValue)
                .put("recording", false)
                .put("playing", false)
                .put("path", JSONObject.NULL)
        }
        stateResult(session)
    }

    private fun stateResult(session: AudioSession): JSONObject {
        val currentFile = when (session.state) {
            AudioState.RECORDING -> session.recordingOutputFile
            AudioState.PREPARING, AudioState.PLAYING -> session.playbackFile
            AudioState.IDLE -> session.lastRecordingFile
        }
        return JSONObject()
            .put("state", session.state.wireValue)
            .put("recording", session.state == AudioState.RECORDING)
            .put("playing", session.state == AudioState.PREPARING || session.state == AudioState.PLAYING)
            .put("path", currentFile?.absolutePath ?: JSONObject.NULL)
            .apply {
                session.lastError?.let { lastError ->
                    put(
                        "lastError",
                        JSONObject().put("code", lastError.code).put("message", lastError.message),
                    )
                }
            }
    }

    private fun resolvePlaybackFile(
        activity: Activity,
        session: AudioSession,
        options: JSONObject,
    ): PlaybackFileResolution {
        val requestedPath = options.optString("path", options.optString("filePath")).trim()
        val candidate = if (requestedPath.isNotEmpty()) {
            val raw = File(requestedPath)
            if (raw.isAbsolute) raw else File(File(activity.cacheDir, AUDIO_DIRECTORY), requestedPath)
        } else {
            session.lastRecordingFile
        }
        if (candidate == null) return PlaybackFileResolution(null, error("FILE_NOT_FOUND", "没有可播放的录音文件"))

        val cacheRoot = runCatching { activity.cacheDir.canonicalFile }.getOrElse {
            return PlaybackFileResolution(null, error("FILE_ERROR", "无法解析 app cache 目录"))
        }
        val canonical = runCatching { candidate.canonicalFile }.getOrElse {
            return PlaybackFileResolution(null, error("FILE_ERROR", "无法解析录音文件路径"))
        }
        if (!isWithin(canonical, cacheRoot)) {
            return PlaybackFileResolution(null, error("INVALID_ARGUMENT", "播放文件必须位于 app cache 私有目录"))
        }
        if (!canonical.isFile) return PlaybackFileResolution(null, error("FILE_NOT_FOUND", "录音文件不存在"))
        if (canonical.length() <= 0L) return PlaybackFileResolution(null, error("EMPTY_FILE", "录音文件为空"))
        return PlaybackFileResolution(canonical, null)
    }

    private fun createRecordingFile(activity: Activity): File {
        val directory = File(activity.cacheDir, AUDIO_DIRECTORY)
        if (!directory.exists() && !directory.mkdirs() && !directory.isDirectory) {
            throw AudioException("FILE_ERROR", "无法创建 app cache 录音目录")
        }
        return File(
            directory,
            "recording-${System.currentTimeMillis()}-${UUID.randomUUID()}$RECORDING_EXTENSION",
        )
    }

    private fun registerLifecycleCallbacks(activity: Activity) {
        val application = activity.application
        synchronized(lock) {
            if (registeredApplications.containsKey(application)) return
            application.registerActivityLifecycleCallbacks(lifecycleCallbacks)
            registeredApplications[application] = true
        }
    }

    private fun recordFailure(session: AudioSession, code: String, message: String) {
        synchronized(lock) {
            session.lastError = ErrorInfo(code, message)
            session.state = AudioState.IDLE
        }
    }

    private fun handleRecorderError(session: AudioSession, recorder: MediaRecorder, what: Int, extra: Int) {
        val outputFile: File?
        synchronized(lock) {
            if (session.recorder !== recorder || session.state != AudioState.RECORDING) return
            outputFile = session.recordingOutputFile
            session.recorder = null
            session.recordingOutputFile = null
            session.state = AudioState.IDLE
            session.lastError = ErrorInfo("RECORDER_ERROR", "MediaRecorder 发生错误（$what/$extra）")
        }
        releaseRecorder(recorder)
        outputFile?.delete()
    }

    private fun stopRecorderForRelease(recorder: MediaRecorder?, outputFile: File?, startedAt: Long) {
        if (recorder == null) return
        val duration = android.os.SystemClock.elapsedRealtime() - startedAt
        val stopped = runCatching { recorder.stop() }.isSuccess
        if (!stopped || duration < MIN_RECORDING_DURATION_MS || outputFile == null || !outputFile.isFile || outputFile.length() <= 0L) {
            outputFile?.delete()
        }
    }

    private fun releaseRecorder(recorder: MediaRecorder) {
        runCatching { recorder.reset() }
        runCatching { recorder.release() }
    }

    private fun releasePlayer(player: MediaPlayer) {
        runCatching { player.reset() }
        runCatching { player.release() }
    }

    private fun isDestroyed(activity: Activity): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN_MR1 && activity.isDestroyed

    private fun isWithin(file: File, root: File): Boolean =
        file == root || file.path.startsWith(root.path + File.separator)

    private fun error(code: String, message: String): JSONObject = JSONObject()
        .put("error", JSONObject().put("code", code).put("message", message))

    private fun completeSafely(complete: (JSONObject) -> Unit, result: JSONObject) {
        runCatching { complete(result) }
    }

    private class CompletionOnce(private val complete: (JSONObject) -> Unit) {
        private val completed = AtomicBoolean(false)

        fun invoke(result: JSONObject) {
            if (completed.compareAndSet(false, true)) completeSafely(complete, result)
        }
    }

    private class AudioException(val code: String, message: String) : Exception(message)

    private class AudioSession {
        var state: AudioState = AudioState.IDLE
        var recorder: MediaRecorder? = null
        var player: MediaPlayer? = null
        var recordingOutputFile: File? = null
        var playbackFile: File? = null
        var lastRecordingFile: File? = null
        var recordingStartedAt: Long = 0L
        var playbackCompletion: CompletionOnce? = null
        var lastError: ErrorInfo? = null
    }

    private data class ErrorInfo(val code: String, val message: String)

    private data class PlaybackFileResolution(val file: File?, val error: JSONObject?)

    private data class RecordingStopSnapshot(
        val session: AudioSession,
        val recorder: MediaRecorder?,
        val outputFile: File?,
        val durationMs: Long,
    )

    private data class PlaybackStopSnapshot(
        val session: AudioSession,
        val player: MediaPlayer?,
        val pendingCompletion: CompletionOnce?,
        val wasPlaying: Boolean,
        val file: File? = null,
    )

    private enum class AudioState(val wireValue: String) {
        IDLE("idle"),
        RECORDING("recording"),
        PREPARING("preparing"),
        PLAYING("playing"),
    }

    private val HANDLED_METHODS = setOf(
        METHOD_RECORD,
        METHOD_START_RECORDING,
        METHOD_STOP_RECORDING,
        METHOD_PLAY,
        METHOD_START_PLAYBACK,
        METHOD_STOP_PLAYBACK,
        METHOD_GET_STATE,
    )
}
