package com.example.lynxshell.transition

import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.ArgbEvaluator
import android.animation.ValueAnimator
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Rect
import android.graphics.drawable.Drawable
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.animation.PathInterpolator
import android.widget.FrameLayout
import android.widget.ImageView
import androidx.activity.BackEventCompat
import androidx.activity.OnBackPressedCallback
import androidx.core.view.ViewCompat
import com.example.lynxshell.container.LynxShellActivity
import com.lynx.react.bridge.JavaOnlyArray
import com.lynx.react.bridge.JavaOnlyMap
import com.lynx.tasm.LynxView
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * 一个 Activity 一份的内容层转场状态机。
 *
 * Window 动画在 Runtime/Activity 两处均已关闭。本类只操作 underlay、当前 liveContent
 * 与 overlay：动画帧不调用 JS，不创建第二个 LynxView，也不重新 PixelCopy。
 */
class LynxTransitionCoordinator(
    private val activity: LynxShellActivity,
    private val root: FrameLayout,
    private val underlay: ImageView,
    private val liveContent: ViewGroup,
    private val overlay: FrameLayout,
    private val targetContent: View,
    restoredAfterRecreation: Boolean,
    private val onSystemBackCommit: () -> Unit,
) : LynxCompatEdgeGestureDelegate {
    private enum class PopRenderer {
        BASIC,
        PRESET,
        SHARED,
        OPEN_CONTAINER,
    }

    private data class SharedProxy(
        val spec: LynxSharedElementSpec,
        val view: ImageView,
        val start: Rect,
        val end: Rect,
    )

    private val mainHandler = Handler(Looper.getMainLooper())
    private var transactionID = LynxTransitionIntent.transactionID(activity.intent)
    private var ticket = LynxTransitionRuntime.ticket(transactionID)
    private var currentLynxView: LynxView? = null
    private var contentGeneration = 0L
    private var firstScreenReady = false
    private var targetFrameReady = false
    private var businessReady = false
    private var destroyed = false
    private var entryPending = ticket != null
    private var restoredReason: String? = if (restoredAfterRecreation && ticket != null) {
        "window_geometry_changed"
    } else {
        null
    }
    private var gateDeadlineMs = 0L
    private var gateRetryPosted = false
    private var animator: ValueAnimator? = null
    private var barrierView: View? = null
    private var bottomSheetBackdropDrawable: GradientDrawable? = null
    private var bottomSheetGrabberView: View? = null
    private var openMorphView: LynxOpenContainerMorphView? = null
    private val sharedProxies = mutableListOf<SharedProxy>()
    private val transientViews = mutableListOf<View>()
    private val maskedTargetAlphas = LinkedHashMap<View, Float>()
    private var interactiveProgress = 0f
    private var interactiveActive = false
    private var compatTouchDriving = false
    private var sheetDragActive = false
    private var sheetDetentIndex: Int? = null
    private var sheetDragStartHeightPx = 0f
    private var sheetDragRawHeightPx = 0f
    private var activePopRenderer = PopRenderer.BASIC
    private var pendingCommit: (() -> Unit)? = null
    private val commitGuard = AtomicBoolean(false)
    private var backGestureEnabled = true
    private var activeDegradeReason: String? = null

    private val originalLiveLayout = copyLayoutParams(liveContent.layoutParams)
    private val originalLiveBackground: Drawable? = liveContent.background
    private val originalClipToOutline = liveContent.clipToOutline
    private val originalElevation = ViewCompat.getElevation(liveContent)

    private val gateTimeout = Runnable {
        if (!destroyed && isWaitingForEnter()) {
            runDegradedEntry("target_not_ready")
        }
    }
    private val gateRetry = object : Runnable {
        override fun run() {
            gateRetryPosted = false
            if (destroyed || !isWaitingForEnter()) return
            if (!tryStartEnter() && android.os.SystemClock.elapsedRealtime() < gateDeadlineMs) {
                gateRetryPosted = true
                mainHandler.postDelayed(this, 32L)
            }
        }
    }

    private val predictiveBackCallback = object : OnBackPressedCallback(false) {
        override fun handleOnBackStarted(backEvent: BackEventCompat) {
            if (canStartInteractiveSystemBack()) {
                compatTouchDriving = false
                beginPop(
                    commit = onSystemBackCommit,
                    useStoredTransition = true,
                    gestureDriven = true,
                )
            }
        }

        override fun handleOnBackProgressed(backEvent: BackEventCompat) {
            if (interactiveActive && !compatTouchDriving) {
                applyPopProgress(backEvent.progress)
            }
        }

        override fun handleOnBackCancelled() {
            if (interactiveActive && !compatTouchDriving) cancelInteractivePop()
        }

        override fun handleOnBackPressed() {
            if (interactiveActive && compatTouchDriving) return
            handleSystemBackCommit()
        }
    }

    init {
        activity.onBackPressedDispatcher.addCallback(activity, predictiveBackCallback)
        (root as? LynxCompatEdgeBackLayout)?.gestureDelegate = this
        transactionID?.let { LynxTransitionRuntime.attachCoordinator(it, this) }

        if (ticket == null && transactionID != null) {
            LynxTransitionIntent.markDegraded(
                activity.intent,
                LynxTransitionStyle.FADE,
                "snapshot_unavailable",
            )
        } else {
            prepareIncomingTransition()
        }
        root.post {
            configurePresetFrame()
            if (ticket != null && entryPending) applyInitialEntryVisual()
        }
        updatePredictiveBackAvailability()
    }

    fun setBackGestureEnabled(enabled: Boolean) {
        backGestureEnabled = enabled
        updatePredictiveBackAvailability()
    }

    /** redirect/singleTop reload 会递增 generation，旧 onFirstScreen 回调必须被忽略。 */
    fun onPageGenerationChanged(lynxView: LynxView, generation: Long) {
        currentLynxView = lynxView
        contentGeneration = generation
        firstScreenReady = false
        targetFrameReady = false
        businessReady = false
    }

    fun onFirstScreen(lynxView: LynxView, generation: Long) {
        if (destroyed || currentLynxView !== lynxView || generation != contentGeneration) return
        if (firstScreenReady) return
        firstScreenReady = true
        /*
         * Lynx 的 onFirstScreen 表示 TASM 首屏布局完成，但 Android 原生节点与目标
         * Activity Surface 不一定已经提交。更关键的是，业务 markTransitionReady 可能
         * 比 onFirstScreen 更早到达；旧 retry 队列会在 firstScreenReady=true 后立即
         * 绕过 postOnAnimation，导致 open-container 对尚未绘制的 View 抓出一张白图。
         *
         * targetFrameReady 是独立硬门禁。至少留出数个真机 vsync，再在下一绘制帧开放
         * renderer；任何 business-ready retry 都不能提前越过这里。
         */
        mainHandler.postDelayed(
            {
                root.postOnAnimation targetFrame@{
                    if (destroyed || generation != contentGeneration) return@targetFrame
                    targetFrameReady = true
                    configurePresetFrame()
                    if (!tryStartEnter()) scheduleGateRetry()
                }
            },
            TARGET_FRAME_SETTLE_MS,
        )
    }

    fun onBusinessReady() {
        if (destroyed) return
        businessReady = true
        root.post {
            if (!tryStartEnter()) scheduleGateRetry()
        }
    }

    fun onLoadError() {
        /*
         * LynxViewClient.onReceivedError 也会收到图片等子资源错误。目标首屏已经成立后，
         * 这类错误不能再把整场 shared/open-container 强制降级成 target_not_ready；
         * 页面自身的错误展示与日志仍由 Lynx/宿主原有链路处理。
         */
        if (!firstScreenReady && isWaitingForEnter()) {
            runDegradedEntry("target_not_ready")
        }
    }

    /**
     * Toolbar、NativeModules.close/back、批量 pop 共用这一入口。
     *
     * 即使快照缺失或 useStoredTransition=false，也只播放本地内容层 fallback；不会把事件
     * 交回 Activity 默认 Window 动画。
     */
    fun requestBack(
        animated: Boolean,
        useStoredTransition: Boolean,
        transitionSpecOverride: LynxTransitionSpec? = null,
        snapshotTicket: AndroidTransitionTicket? = null,
        forceTransaction: Boolean = false,
        routeKey: String? = null,
        transactionReason: String? = null,
        commit: () -> Unit,
    ): Boolean {
        if (destroyed || animator != null || interactiveActive) {
            Log.w(
                TRANSITION_LOG_TAG,
                "pop rejected destroyed=$destroyed animatorRunning=${animator != null} " +
                    "interactiveActive=$interactiveActive transaction=$transactionID",
            )
            return false
        }
        val storedTicket = ticket
        val invocationSpec = transitionSpecOverride ?: storedTicket?.spec?.copy(
            // 旧 push 如果已经降级，未显式覆盖的 pop 延续其 effective style，不能重新
            // 尝试一遍已经失败的 shared/open renderer。
            style = storedTicket.effectiveTransition,
        ) ?: LynxTransitionSpec(
            style = LynxTransitionStyle.FADE,
            fallbackStyle = LynxTransitionStyle.FADE,
            explicitlyRequested = true,
        )

        if (forceTransaction || transitionSpecOverride != null) {
            val oldTransactionID = transactionID
            val popTicket = LynxTransitionRuntime.beginPopTransaction(
                context = activity,
                currentTicket = storedTicket,
                snapshotTicket = snapshotTicket,
                invocationSpec = invocationSpec,
                animated = animated,
                routeKey = routeKey,
                reasonOverride = transactionReason,
            )
            LynxTransitionRuntime.detachCoordinator(oldTransactionID, this)
            transactionID = popTicket.transactionID
            ticket = popTicket
            LynxTransitionIntent.write(activity.intent, popTicket)
            LynxTransitionRuntime.attachCoordinator(popTicket.transactionID, this)
        }

        val currentTicket = ticket
        val requestedStyle = currentTicket?.effectiveTransition ?: invocationSpec.style
        val duration = currentTicket?.spec?.reverseDurationMs ?: invocationSpec.reverseDurationMs
        val motion = LynxMotionPolicy.resolve(
            activity,
            requestedStyle,
            duration,
            animated,
        )
        if (motion.style == LynxTransitionStyle.NONE) {
            val reason = currentTicket?.reason ?: motion.reason
            val commitFailure = runCatching(commit).exceptionOrNull()
            if (commitFailure != null) {
                terminal(
                    status = LynxTransitionStatus.FAILED,
                    direction = LynxTransitionDirection.POP,
                    progress = 0f,
                    reason = commitFailureReason(commitFailure),
                )
                return true
            }
            terminal(
                status = terminalStatus(reason),
                direction = LynxTransitionDirection.POP,
                progress = 1f,
                reason = reason,
            )
            return true
        }

        if (
            currentTicket != null &&
            beginPop(
                commit = commit,
                useStoredTransition = useStoredTransition,
                gestureDriven = false,
            )
        ) {
            commitInteractivePop()
            return true
        }

        // 无 ticket 的普通 Toolbar 返回也保持内容层可控；显式 ticket 不会落到这里。
        runFallbackPop(motion.style, motion.durationMs, commit)
        return true
    }

    /**
     * 显式 ticket 的系统 Back 永远在 coordinator 内提交；Back 常驻拦截不能因为快照
     * 缺失而失效，否则系统默认返回动画会重新叠加。
     */
    private fun handleSystemBackCommit() {
        Log.i(
            TRANSITION_LOG_TAG,
            "systemBack intercepted transaction=$transactionID entryPending=$entryPending " +
                "animatorRunning=${animator != null} interactiveActive=$interactiveActive",
        )
        if (interactiveActive) {
            commitInteractivePop()
            return
        }
        interruptCurrentVisualForBack()
        if (
            !requestBack(
                animated = true,
                useStoredTransition = true,
                commit = onSystemBackCommit,
            )
        ) {
            onSystemBackCommit()
        }
    }

    private fun interruptCurrentVisualForBack() {
        mainHandler.removeCallbacks(gateTimeout)
        mainHandler.removeCallbacks(gateRetry)
        gateRetryPosted = false
        animator?.cancel()
        animator = null
        entryPending = false
        interactiveActive = false
        compatTouchDriving = false
        sheetDragActive = false
        interactiveProgress = 0f
        pendingCommit = null
        commitGuard.set(false)
        clearTransientVisuals()
        applyFinalPresentation()
    }

    fun onPause() {
        if (interactiveActive) cancelInteractivePop(immediate = true)
    }

    fun onWindowFocusChanged(hasFocus: Boolean) {
        if (!hasFocus && interactiveActive) cancelInteractivePop(immediate = true)
    }

    fun onDestroy(changingConfigurations: Boolean) {
        destroyed = true
        mainHandler.removeCallbacks(gateTimeout)
        mainHandler.removeCallbacks(gateRetry)
        animator?.cancel()
        animator = null
        clearTransientVisuals()
        removeBarrier()
        removeBottomSheetGrabber()
        sheetDragActive = false
        (root as? LynxCompatEdgeBackLayout)?.apply {
            compatGestureEnabled = false
            gestureDelegate = null
        }
        LynxTransitionRuntime.detachCoordinator(transactionID, this)
        if (!changingConfigurations && activity.isFinishing) {
            LynxTransitionRuntime.release(transactionID)
        }
    }

    override fun onCompatEdgeStart(): Boolean {
        if (canStartSheetDetentDrag()) {
            animator?.cancel()
            animator = null
            sheetDragActive = true
            val options = requireNotNull(ticket).spec.routeOptions
            val rootHeight = sheetRootHeightPx()
            sheetDetentIndex = sheetDetentIndex?.coerceIn(0, options.detentsVh.lastIndex)
                ?: options.initialDetentIndex
            sheetDragStartHeightPx = liveContent.height.toFloat().takeIf { it > 0f }
                ?: detentHeightPx(sheetDetentIndex ?: options.initialDetentIndex, rootHeight)
            sheetDragRawHeightPx = sheetDragStartHeightPx
            compatTouchDriving = true
            return true
        }
        val accepted = beginPop(
            commit = onSystemBackCommit,
            useStoredTransition = true,
            gestureDriven = true,
        )
        compatTouchDriving = accepted
        return accepted
    }

    override fun onCompatEdgeProgress(progress: Float) {
        if (interactiveActive) applyPopProgress(progress)
    }

    override fun onCompatEdgeDelta(deltaPx: Float) {
        if (sheetDragActive) updateSheetDrag(deltaPx)
    }

    override fun onCompatEdgeCancel() {
        if (sheetDragActive) {
            finishSheetDetentDrag(velocityPxPerSecond = 0f, cancelled = true)
        } else if (interactiveActive) {
            cancelInteractivePop()
        }
    }

    override fun onCompatEdgeFinish(velocityPxPerSecond: Float) {
        if (sheetDragActive) {
            finishSheetDetentDrag(velocityPxPerSecond)
        } else if (interactiveActive) {
            commitInteractivePop()
        }
    }

    private fun canStartSheetDetentDrag(): Boolean {
        val currentTicket = ticket ?: return false
        val routeOptions = currentTicket.spec.routeOptions
        return currentTicket.spec.routePreset == LynxRoutePreset.BOTTOM_SHEET &&
            routeOptions.isMultiDetent &&
            canStartInteractiveSystemBack()
    }

    private fun sheetRootHeightPx(): Float =
        (root.height.takeIf { it > 0 }
            ?: activity.resources.displayMetrics.heightPixels).toFloat().coerceAtLeast(1f)

    private fun detentHeightPx(index: Int, rootHeightPx: Float = sheetRootHeightPx()): Float {
        val detents = ticket?.spec?.routeOptions?.detentsVh ?: return rootHeightPx
        return (rootHeightPx * detents[index.coerceIn(0, detents.lastIndex)] / 100f)
            .coerceAtLeast(1f)
    }

    private fun applySheetHeightPx(heightPx: Float) {
        val currentTicket = ticket ?: return
        if (currentTicket.spec.routePreset != LynxRoutePreset.BOTTOM_SHEET) return
        val params = (liveContent.layoutParams as? FrameLayout.LayoutParams) ?: return
        val nextHeight = heightPx.roundToInt().coerceAtLeast(1)
        val fullscreen = false
        val appliedHeight = nextHeight
        val targetGravity = Gravity.BOTTOM
        if (params.height != appliedHeight || params.gravity != targetGravity) {
            params.height = appliedHeight
            params.gravity = targetGravity
            params.topMargin = 0
            liveContent.layoutParams = params
            liveContent.requestLayout()
        }
        applySheetSurfaceMode(fullscreen, appliedHeight)
    }

    private fun applySheetSurfaceMode(fullscreen: Boolean, heightPx: Int) {
        val currentTicket = ticket ?: return
        if (currentTicket.spec.routePreset != LynxRoutePreset.BOTTOM_SHEET) return
        val density = activity.resources.displayMetrics.density
        val rootHeight = sheetRootHeightPx()
        if (fullscreen) {
            liveContent.background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                setColor((targetContent.background as? ColorDrawable)?.color ?: Color.TRANSPARENT)
                cornerRadius = 0f
            }
            liveContent.clipToOutline = false
            ViewCompat.setElevation(liveContent, 0f)
            removeBottomSheetGrabber()
            barrierView?.alpha = 0f
            barrierView?.isClickable = false
            underlay.alpha = 0f
            resetBottomSheetBackdropMask()
            return
        }

        val radiusDp = if (currentTicket.spec.routeOptions.round) {
            LynxBottomSheetMotion.SHEET_CORNER_RADIUS_DP
        } else {
            0f
        }
        liveContent.background = GradientDrawable().apply {
            shape = GradientDrawable.RECTANGLE
            setColor((targetContent.background as? ColorDrawable)?.color ?: Color.TRANSPARENT)
            if (radiusDp > 0f) {
                val radius = radiusDp * density
                cornerRadii = floatArrayOf(radius, radius, radius, radius, 0f, 0f, 0f, 0f)
            } else {
                cornerRadius = 0f
            }
        }
        liveContent.clipToOutline = true
        ViewCompat.setElevation(liveContent, 16f * density)
        ensureBottomSheetGrabber(
            rootHeight = rootHeight.roundToInt(),
            sheetHeight = heightPx,
            density = density,
        )
        barrierView?.alpha = 1f
        barrierView?.isClickable = currentTicket.spec.routeConfig.barrierDismissible
        underlay.alpha = 1f
        val motion = LynxBottomSheetMotion.state(1f)
        underlay.scaleX = motion.backdropScale
        underlay.scaleY = motion.backdropScale
        underlay.translationY = motion.backdropTranslationYDp * density
        applyBottomSheetBackdropCornerRadius(motion.backdropCornerRadiusDp * density)
    }

    private fun updateSheetDrag(deltaPx: Float) {
        val options = ticket?.spec?.routeOptions ?: return
        val rootHeight = sheetRootHeightPx()
        val minimum = detentHeightPx(0, rootHeight)
        val maximum = detentHeightPx(options.detentsVh.lastIndex, rootHeight)
        val rawHeight = sheetDragStartHeightPx - deltaPx
        sheetDragRawHeightPx = rawHeight
        val visibleHeight = when {
            rawHeight < minimum -> minimum - (minimum - rawHeight) * 0.22f
            rawHeight > maximum -> maximum + (rawHeight - maximum) * 0.18f
            else -> rawHeight
        }
        applySheetHeightPx(visibleHeight.coerceAtLeast(1f))
    }

    private fun finishSheetDetentDrag(
        velocityPxPerSecond: Float,
        cancelled: Boolean = false,
    ) {
        if (!sheetDragActive) return
        val options = ticket?.spec?.routeOptions ?: return
        val rootHeight = sheetRootHeightPx()
        val minimum = detentHeightPx(0, rootHeight)
        val dismiss = !cancelled && LynxHeroSheetMotion.shouldDismiss(
            rawHeightPx = sheetDragRawHeightPx,
            minimumHeightPx = minimum,
            velocityPxPerSecond = velocityPxPerSecond,
        )
        if (dismiss) {
            sheetDragActive = false
            compatTouchDriving = true
            if (beginPop(
                    commit = onSystemBackCommit,
                    useStoredTransition = true,
                    gestureDriven = true,
                )
            ) {
                commitInteractivePop()
                return
            }
            compatTouchDriving = false
        }

        val currentHeightVh = sheetDragRawHeightPx / rootHeight * 100f
        val projectedHeightVh = if (cancelled) {
            currentHeightVh
        } else {
            LynxHeroSheetMotion.projectedHeightVh(
                currentHeightVh = currentHeightVh,
                velocityPxPerSecond = velocityPxPerSecond,
                rootHeightPx = rootHeight,
            )
        }
        val targetIndex = LynxHeroSheetMotion.nearestDetentIndex(
            heightVh = projectedHeightVh,
            detentsVh = options.detentsVh,
        )
        sheetDragActive = false
        compatTouchDriving = false
        sheetDetentIndex = targetIndex
        settleSheetDetent(targetIndex)
    }

    private fun settleSheetDetent(targetIndex: Int) {
        val targetHeight = detentHeightPx(targetIndex)
        val startHeight = liveContent.height.toFloat().coerceAtLeast(1f)
        if (abs(targetHeight - startHeight) < 1f) {
            applySheetHeightPx(targetHeight)
            updatePredictiveBackAvailability()
            return
        }
        animateProgress(
            from = 0f,
            to = 1f,
            durationMs = 220L,
            onUpdate = { progress ->
                applySheetHeightPx(startHeight + (targetHeight - startHeight) * progress)
            },
            onEnd = {
                applySheetHeightPx(targetHeight)
                updatePredictiveBackAvailability()
            },
        )
    }

    private fun prepareIncomingTransition() {
        val currentTicket = ticket ?: return
        if (!currentTicket.spec.routeConfig.opaque) {
            // 非 opaque route 由当前 Window 内的 source underlay 模拟透出上一页；容器
            // 自身必须透明，Lynx 页面若主动绘制背景仍按页面内容为准。
            targetContent.setBackgroundColor(Color.TRANSPARENT)
        }
        configureSourceUnderlay(currentTicket)
        configurePresetFrame()
        entryPending = true
        gateDeadlineMs = android.os.SystemClock.elapsedRealtime() +
            currentTicket.spec.readyTimeoutMs
        mainHandler.postDelayed(gateTimeout, currentTicket.spec.readyTimeoutMs)
        applyInitialEntryVisual()
    }

    private fun applyInitialEntryVisual() {
        val currentTicket = ticket ?: return
        if (currentTicket.effectiveTransition == LynxTransitionStyle.NONE) {
            liveContent.alpha = 1f
            return
        }
        when (currentTicket.effectiveTransition) {
            LynxTransitionStyle.SHARED_ELEMENT,
            LynxTransitionStyle.OPEN_CONTAINER,
            -> liveContent.alpha = 0f
            else -> applyBasicOrPresetEntryProgress(0f)
        }
    }

    private fun tryStartEnter(): Boolean {
        if (!isWaitingForEnter() || !firstScreenReady || !targetFrameReady) return false
        val currentTicket = ticket ?: return false
        mainHandler.removeCallbacks(gateTimeout)
        mainHandler.removeCallbacks(gateRetry)
        gateRetryPosted = false

        restoredReason?.let { reason ->
            restoredReason = null
            entryPending = false
            clearTransientVisuals()
            applyFinalPresentation()
            terminal(
                status = LynxTransitionStatus.DEGRADED,
                direction = LynxTransitionDirection.PUSH,
                progress = 1f,
                reason = reason,
            )
            return true
        }
        if (currentTicket.effectiveTransition == LynxTransitionStyle.NONE) {
            entryPending = false
            applyFinalPresentation()
            terminal(
                status = LynxTransitionStatus.COMPLETED,
                direction = LynxTransitionDirection.PUSH,
                progress = 1f,
                reason = currentTicket.reason,
            )
            return true
        }

        return when (currentTicket.effectiveTransition) {
            LynxTransitionStyle.OPEN_CONTAINER -> startOpenContainerEnter(currentTicket)
            LynxTransitionStyle.SHARED_ELEMENT -> startSharedElementEnter(currentTicket)
            else -> {
                startBasicOrPresetEnter(currentTicket)
                true
            }
        }
    }

    private fun startBasicOrPresetEnter(currentTicket: AndroidTransitionTicket) {
        Log.i(
            TRANSITION_LOG_TAG,
            "push renderer=${currentTicket.spec.routeType ?: currentTicket.effectiveTransition.wireName} " +
                "duration=${currentTicket.spec.durationMs}ms",
        )
        activeDegradeReason = currentTicket.reason
        LynxTransitionRuntime.update(
            requireNotNull(transactionID),
            LynxTransitionStatus.RUNNING,
            direction = LynxTransitionDirection.PUSH,
            progress = 0f,
        )
        animateProgress(
            from = 0f,
            to = 1f,
            durationMs = currentTicket.spec.durationMs,
            onUpdate = { progress ->
                applyBasicOrPresetEntryProgress(progress)
                updateRunningProgress(progress, LynxTransitionDirection.PUSH)
            },
        ) {
            entryPending = false
            finishEntryVisual()
            terminal(
                status = terminalStatus(activeDegradeReason),
                direction = LynxTransitionDirection.PUSH,
                progress = 1f,
                reason = activeDegradeReason,
            )
            activeDegradeReason = null
        }
    }

    private fun startOpenContainerEnter(currentTicket: AndroidTransitionTicket): Boolean {
        val source = currentTicket.sourceElements.firstOrNull()
            ?: return runDegradedEntry("source_selector_missing")
        val sourceBitmap = LynxSnapshotStore.get(source.snapshotToken)
            ?: return runDegradedEntry("snapshot_unavailable")
        val targetBitmap = LynxSnapshotter.captureViewBitmap(liveContent)
            ?: return runDegradedEntry("target_snapshot_unavailable")
        val sourceRect = toRootLocal(source.rectOnScreen)
        val targetRect = toRootLocal(LynxElementResolver.rectOnScreen(liveContent))
        if (!isUsableRect(sourceRect) || !isUsableRect(targetRect)) {
            return runDegradedEntry("window_geometry_changed")
        }
        Log.i(
            TRANSITION_LOG_TAG,
            "push renderer=openContainer duration=${currentTicket.spec.durationMs}ms " +
                "source=$sourceRect target=$targetRect " +
                "sourceBitmap=${sourceBitmap.width}x${sourceBitmap.height} " +
                "spec=${currentTicket.spec.openContainer}",
        )

        liveContent.alpha = 0f
        val morph = LynxOpenContainerMorphView(
            context = activity,
            sourceBitmap = sourceBitmap,
            targetPageBitmap = targetBitmap,
            sourceRect = sourceRect,
            targetRect = targetRect,
            spec = requireNotNull(currentTicket.spec.openContainer),
            reverse = false,
        )
        openMorphView = morph
        addTransientView(
            morph,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            ),
        )
        activeDegradeReason = currentTicket.reason
        // 先把关闭态容器真正提交一帧，再启动形变；否则 addView 与 ValueAnimator 同帧
        // 执行时，用户可能从 source underlay 直接看到中途甚至最终形态。
        morph.setTransitionProgress(0f)
        updateRunningProgress(0f, LynxTransitionDirection.PUSH)
        root.postOnAnimation openContainerStart@{
            if (destroyed || !entryPending || openMorphView !== morph) {
                return@openContainerStart
            }
            animateProgress(
                0f,
                1f,
                currentTicket.spec.durationMs,
                onUpdate = { progress ->
                    morph.setTransitionProgress(progress)
                    updateRunningProgress(progress, LynxTransitionDirection.PUSH)
                },
            ) {
                entryPending = false
                clearTransientVisuals()
                liveContent.alpha = 1f
                finishUnderlayForCurrentRoute()
                terminal(
                    terminalStatus(activeDegradeReason),
                    LynxTransitionDirection.PUSH,
                    1f,
                    activeDegradeReason,
                )
                activeDegradeReason = null
            }
        }
        return true
    }

    private fun startSharedElementEnter(currentTicket: AndroidTransitionTicket): Boolean {
        val targetPage = LynxSnapshotter.captureViewBitmap(liveContent)
            ?: return runDegradedEntry("target_snapshot_unavailable")
        val targets = currentTicket.spec.sharedElements.map { spec ->
            spec to (
                LynxElementResolver.resolve(currentLynxView, spec.targetSelector)
                    ?: return runDegradedEntry("target_selector_missing:${spec.key}")
                )
        }
        val sourceByKey = currentTicket.sourceElements.associateBy { it.key }
        var localReason = currentTicket.reason
        Log.i(
            TRANSITION_LOG_TAG,
            "push renderer=sharedElement duration=${currentTicket.spec.durationMs}ms " +
                "elements=${currentTicket.spec.sharedElements.size}",
        )
        targets.forEach { (spec, target) ->
            val source = sourceByKey[spec.key]
                ?: return runDegradedEntry("source_selector_missing:${spec.key}")
            val sourceBitmap = LynxSnapshotStore.get(source.snapshotToken)
                ?: return runDegradedEntry("snapshot_unavailable:${spec.key}")
            val targetBitmap = cropViewBitmap(
                viewBitmap = targetPage,
                view = liveContent,
                rectOnScreen = target.rectOnScreen,
            ) ?: return runDegradedEntry("target_snapshot_unavailable:${spec.key}")
            val selectedBitmap = if (
                spec.shuttleOnPush == LynxSharedElementShuttle.TO
            ) {
                targetBitmap
            } else {
                sourceBitmap
            }
            val start = toRootLocal(source.rectOnScreen)
            val end = toRootLocal(target.rectOnScreen)
            if (!isUsableRect(start) || !isUsableRect(end)) {
                return runDegradedEntry("window_geometry_changed:${spec.key}")
            }
            target.nativeView?.let(::maskTarget) ?: run {
                localReason = localReason ?: "target_native_view_unmaskable:${spec.key}"
            }
            sharedProxies += createSharedProxy(spec, selectedBitmap, start, end)
        }

        liveContent.alpha = 0f
        activeDegradeReason = localReason
        underlay.alpha = 1f
        sharedProxies.forEach {
            applySharedProxyProgress(it, 0f, reverseAppearance = false)
        }
        updateRunningProgress(0f, LynxTransitionDirection.PUSH)
        root.postOnAnimation sharedElementStart@{
            if (destroyed || !entryPending || sharedProxies.isEmpty()) {
                return@sharedElementStart
            }
            animateProgress(
                0f,
                1f,
                currentTicket.spec.durationMs,
                onUpdate = { progress ->
                    liveContent.alpha = progress
                    underlay.alpha = 1f - progress
                    sharedProxies.forEach {
                        applySharedProxyProgress(it, progress, reverseAppearance = false)
                    }
                    enforceSecondaryTransitionPolicy()
                    updateRunningProgress(progress, LynxTransitionDirection.PUSH)
                },
            ) {
                entryPending = false
                clearTransientVisuals()
                liveContent.alpha = 1f
                finishUnderlayForCurrentRoute()
                terminal(
                    terminalStatus(activeDegradeReason),
                    LynxTransitionDirection.PUSH,
                    1f,
                    activeDegradeReason,
                )
                activeDegradeReason = null
            }
        }
        return true
    }

    private fun runDegradedEntry(reason: String): Boolean {
        val currentTicket = ticket ?: return false
        if (!isWaitingForEnter()) return false
        mainHandler.removeCallbacks(gateTimeout)
        mainHandler.removeCallbacks(gateRetry)
        gateRetryPosted = false
        clearTransientVisuals()

        val fallback = currentTicket.fallbackTransition
        ticket = currentTicket.copy(
            effectiveTransition = fallback,
            reason = reason,
        )
        LynxTransitionIntent.markDegraded(activity.intent, fallback, reason)
        LynxTransitionRuntime.update(
            requireNotNull(transactionID),
            LynxTransitionStatus.DEGRADED,
            effectiveTransition = fallback,
            reason = reason,
        )
        activeDegradeReason = reason
        Log.w(
            TRANSITION_LOG_TAG,
            "push degraded requested=${currentTicket.requestedTransition.wireName} " +
                "fallback=${fallback.wireName} reason=$reason",
        )
        applyBasicEntryProgress(fallback, 0f)
        animateProgress(
            0f,
            1f,
            if (fallback == LynxTransitionStyle.NONE) 0L else {
                currentTicket.spec.durationMs.coerceAtMost(300L)
            },
            onUpdate = { progress ->
                applyBasicEntryProgress(fallback, progress)
                updateRunningProgress(progress, LynxTransitionDirection.PUSH)
            },
        ) {
            entryPending = false
            clearTransientVisuals()
            liveContent.alpha = 1f
            finishUnderlayForCurrentRoute()
            terminal(
                LynxTransitionStatus.DEGRADED,
                LynxTransitionDirection.PUSH,
                1f,
                reason,
            )
            activeDegradeReason = null
        }
        return true
    }

    private fun beginPop(
        commit: () -> Unit,
        useStoredTransition: Boolean,
        gestureDriven: Boolean,
    ): Boolean {
        if (
            destroyed ||
            animator != null ||
            interactiveActive ||
            ticket == null ||
            entryPending
        ) {
            return false
        }
        val currentTicket = requireNotNull(ticket)
        animator?.cancel()
        interactiveProgress = 0f
        interactiveActive = true
        pendingCommit = commit
        commitGuard.set(false)
        activeDegradeReason = currentTicket.reason
        clearTransientVisuals()

        val canUseStoredSnapshot = useStoredTransition &&
            currentTicket.spec.routeConfig.allowExitRouteSnapshotting
        val rendererNeedsSourceSnapshot =
            currentTicket.effectiveTransition == LynxTransitionStyle.SHARED_ELEMENT ||
                currentTicket.effectiveTransition == LynxTransitionStyle.OPEN_CONTAINER ||
                currentTicket.spec.routePreset != null ||
                !currentTicket.spec.routeConfig.opaque
        val hasStoredWindowSnapshot =
            currentTicket.sourceWindowSnapshotToken?.let(LynxSnapshotStore::get) != null
        if (
            useStoredTransition &&
            !currentTicket.spec.routeConfig.allowExitRouteSnapshotting &&
            rendererNeedsSourceSnapshot
        ) {
            activeDegradeReason = activeDegradeReason ?: "exit_route_snapshotting_disabled"
        } else if (canUseStoredSnapshot && rendererNeedsSourceSnapshot && !hasStoredWindowSnapshot) {
            activeDegradeReason = activeDegradeReason ?: "reverse_snapshot_unavailable"
        }
        activePopRenderer = when {
            currentTicket.effectiveTransition == LynxTransitionStyle.OPEN_CONTAINER &&
                canUseStoredSnapshot -> {
                if (prepareOpenContainerPop(currentTicket)) {
                    PopRenderer.OPEN_CONTAINER
                } else {
                    clearTransientVisuals()
                    activeDegradeReason = activeDegradeReason ?: "reverse_snapshot_unavailable"
                    PopRenderer.BASIC
                }
            }
            currentTicket.effectiveTransition == LynxTransitionStyle.SHARED_ELEMENT &&
                canUseStoredSnapshot -> {
                if (prepareSharedElementPop(currentTicket, gestureDriven)) {
                    PopRenderer.SHARED
                } else {
                    clearTransientVisuals()
                    activeDegradeReason = activeDegradeReason ?: "reverse_snapshot_unavailable"
                    PopRenderer.BASIC
                }
            }
            currentTicket.effectiveTransition in setOf(
                LynxTransitionStyle.SHARED_ELEMENT,
                LynxTransitionStyle.OPEN_CONTAINER,
            ) &&
                useStoredTransition &&
                !currentTicket.spec.routeConfig.allowExitRouteSnapshotting -> {
                activeDegradeReason = activeDegradeReason ?: "exit_route_snapshotting_disabled"
                PopRenderer.BASIC
            }
            currentTicket.spec.routePreset != null -> PopRenderer.PRESET
            else -> PopRenderer.BASIC
        }

        if (canUseStoredSnapshot) {
            configureSourceUnderlay(currentTicket)
        } else {
            clearSourceUnderlay()
        }
        Log.i(
            TRANSITION_LOG_TAG,
            "pop renderer=${activePopRenderer.name.lowercase()} " +
                "duration=${currentTicket.spec.reverseDurationMs}ms " +
                "style=${currentTicket.effectiveTransition.wireName} " +
                "storedSnapshot=$hasStoredWindowSnapshot reason=$activeDegradeReason",
        )
        applyPopProgress(0f)
        LynxTransitionRuntime.update(
            requireNotNull(transactionID),
            LynxTransitionStatus.RUNNING,
            direction = LynxTransitionDirection.POP,
            progress = 0f,
        )
        return true
    }

    private fun prepareOpenContainerPop(currentTicket: AndroidTransitionTicket): Boolean {
        val source = currentTicket.sourceElements.firstOrNull() ?: return false
        val sourceBitmap = LynxSnapshotStore.get(source.snapshotToken) ?: return false
        val targetBitmap = LynxSnapshotter.captureViewBitmap(liveContent) ?: return false
        val sourceRect = toRootLocal(source.rectOnScreen)
        val targetRect = toRootLocal(LynxElementResolver.rectOnScreen(liveContent))
        if (!isUsableRect(sourceRect) || !isUsableRect(targetRect)) return false

        liveContent.alpha = 0f
        val morph = LynxOpenContainerMorphView(
            context = activity,
            sourceBitmap = sourceBitmap,
            targetPageBitmap = targetBitmap,
            sourceRect = sourceRect,
            targetRect = targetRect,
            spec = requireNotNull(currentTicket.spec.openContainer),
            reverse = true,
        )
        openMorphView = morph
        addTransientView(
            morph,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            ),
        )
        return true
    }

    private fun prepareSharedElementPop(
        currentTicket: AndroidTransitionTicket,
        gestureDriven: Boolean,
    ): Boolean {
        val targetPage = LynxSnapshotter.captureViewBitmap(liveContent) ?: return false
        val sourceByKey = currentTicket.sourceElements.associateBy { it.key }
        val eligible = currentTicket.spec.sharedElements.filter {
            !gestureDriven || it.transitionOnGesture
        }
        // transitionOnGesture=false 时页面仍走本地 fallback，但不创建共享元素跟手层。
        if (eligible.isEmpty()) return true

        eligible.forEach { spec ->
            val source = sourceByKey[spec.key] ?: return false
            val sourceBitmap = LynxSnapshotStore.get(source.snapshotToken) ?: return false
            val target = LynxElementResolver.resolve(currentLynxView, spec.targetSelector)
                ?: return false
            val targetBitmap = cropViewBitmap(targetPage, liveContent, target.rectOnScreen)
                ?: return false
            val selectedBitmap = if (
                spec.shuttleOnPop == LynxSharedElementShuttle.TO
            ) {
                // pop 的 to 页是原 source 页面，因此使用冻结的 source 快照。
                sourceBitmap
            } else {
                targetBitmap
            }
            val start = toRootLocal(target.rectOnScreen)
            val end = toRootLocal(source.rectOnScreen)
            target.nativeView?.let(::maskTarget)
            sharedProxies += createSharedProxy(spec, selectedBitmap, start, end)
        }
        return true
    }

    private fun applyPopProgress(rawProgress: Float) {
        val progress = rawProgress.coerceIn(0f, 1f)
        interactiveProgress = progress
        when (activePopRenderer) {
            PopRenderer.OPEN_CONTAINER -> {
                liveContent.alpha = 0f
                underlay.alpha = 1f
                openMorphView?.setTransitionProgress(progress)
            }
            PopRenderer.SHARED -> {
                liveContent.alpha = 1f - progress
                underlay.alpha = progress
                sharedProxies.forEach {
                    applySharedProxyProgress(it, progress, reverseAppearance = true)
                }
            }
            PopRenderer.PRESET -> applyPresetEntryProgress(1f - progress)
            PopRenderer.BASIC -> {
                val style = popFallbackStyle()
                applyBasicEntryProgress(style, 1f - progress)
                underlay.alpha = progress
            }
        }
        enforceSecondaryTransitionPolicy()
        updateRunningProgress(progress, LynxTransitionDirection.POP)
    }

    private fun cancelInteractivePop(immediate: Boolean = false) {
        if (!interactiveActive) return
        val start = interactiveProgress
        if (immediate || start <= 0f) {
            restoreAfterPopCancellation()
            terminal(
                LynxTransitionStatus.CANCELLED,
                LynxTransitionDirection.POP,
                0f,
                activeDegradeReason,
            )
            return
        }
        LynxTransitionRuntime.update(
            requireNotNull(transactionID),
            LynxTransitionStatus.SETTLING,
            direction = LynxTransitionDirection.POP,
        )
        animateProgress(
            from = start,
            to = 0f,
            durationMs = remainingDuration(
                ticket?.spec?.reverseDurationMs ?: 300L,
                start,
            ),
            onUpdate = ::applyPopProgress,
        ) {
            restoreAfterPopCancellation()
            terminal(
                LynxTransitionStatus.CANCELLED,
                LynxTransitionDirection.POP,
                0f,
                activeDegradeReason,
            )
        }
    }

    private fun commitInteractivePop() {
        if (!interactiveActive || commitGuard.get()) return
        LynxTransitionRuntime.update(
            requireNotNull(transactionID),
            LynxTransitionStatus.SETTLING,
            direction = LynxTransitionDirection.POP,
        )
        val start = interactiveProgress
        animateProgress(
            from = start,
            to = 1f,
            durationMs = remainingDuration(
                ticket?.spec?.reverseDurationMs ?: 300L,
                1f - start,
            ),
            onUpdate = ::applyPopProgress,
        ) {
            if (!commitGuard.compareAndSet(false, true)) return@animateProgress
            val commit = pendingCommit
            pendingCommit = null
            interactiveActive = false
            compatTouchDriving = false
            // pop 的 onRouteDone 必须发生在栈提交之后；finish() 同步标记 Activity，
            // 真正 onDestroy 在后续 lifecycle 消息中，当前 LynxView 此刻仍可安全收事件。
            val commitFailure = runCatching { commit?.invoke() }.exceptionOrNull()
            if (commitFailure != null) {
                restoreAfterPopCancellation()
                terminal(
                    LynxTransitionStatus.FAILED,
                    LynxTransitionDirection.POP,
                    0f,
                    commitFailureReason(commitFailure),
                )
                activeDegradeReason = null
                return@animateProgress
            }
            if (!activity.isFinishing) {
                // 防御非 finish 型宿主实现；正常 pop/close 会走下面的冻结尾帧分支。
                clearTransientVisuals()
                removeBarrier()
            }
            // Activity.finish() 后到上一页 Surface 真正恢复之间仍可能跨一帧。此时保留
            // “已挖空的 source underlay + 到达终点的 shared proxies/open morph”，交给
            // onDestroy 统一清理，避免返回瞬间出现共享元素白洞或空卡片。
            terminal(
                terminalStatus(activeDegradeReason),
                LynxTransitionDirection.POP,
                1f,
                activeDegradeReason,
            )
            activeDegradeReason = null
        }
    }

    private fun restoreAfterPopCancellation() {
        interactiveActive = false
        compatTouchDriving = false
        interactiveProgress = 0f
        pendingCommit = null
        clearTransientVisuals()
        if (isPersistentPreset(ticket?.spec?.routePreset)) {
            // 取消返回必须完整恢复 Sheet 打开态，包括圆角、elevation、遮罩和来源页终态。
            applyPresetEntryProgress(1f)
        } else {
            applyFinalPresentation()
        }
        updatePredictiveBackAvailability()
    }

    private fun runFallbackPop(
        style: LynxTransitionStyle,
        durationMs: Long,
        commit: () -> Unit,
    ) {
        animateProgress(
            0f,
            1f,
            durationMs,
            onUpdate = { progress ->
                applyBasicEntryProgress(style, 1f - progress)
            },
        ) {
            resetLiveTransforms()
            commit()
        }
    }

    /**
     * 官方 routeType 与 heroSheet 的 renderer 在这里保持独立，不再折叠成 slide/zoom。
     */
    private fun applyPresetEntryProgress(progress: Float) {
        val preset = ticket?.spec?.routePreset ?: return
        val p = progress.coerceIn(0f, 1f)
        val density = activity.resources.displayMetrics.density
        val rootHeight = root.height.coerceAtLeast(1).toFloat()
        val rootWidth = root.width.coerceAtLeast(1).toFloat()
        when (preset) {
            LynxRoutePreset.BOTTOM_SHEET -> {
                val motion = LynxBottomSheetMotion.state(p)
                liveContent.alpha = 1f
                liveContent.translationY = liveContent.height.coerceAtLeast(1) *
                    motion.sheetTranslationFraction
                bottomSheetGrabberView?.apply {
                    translationY = liveContent.translationY
                    alpha = motion.barrierAlpha
                }
                barrierView?.alpha = motion.barrierAlpha
                underlay.alpha = 1f
                underlay.scaleX = motion.backdropScale
                underlay.scaleY = motion.backdropScale
                underlay.translationY = motion.backdropTranslationYDp * density
                applyBottomSheetBackdropCornerRadius(
                    motion.backdropCornerRadiusDp * density,
                )
            }
            LynxRoutePreset.HERO_SHEET -> {
                // heroSheet 是透明宿主模式：liveContent 不做任何原生位移、缩放或
                // alpha 动画，首屏入场、滚动和下拉关闭全部由 Lynx 页面负责。
                liveContent.alpha = 1f
                liveContent.translationX = 0f
                liveContent.translationY = 0f
                liveContent.scaleX = 1f
                liveContent.scaleY = 1f
                liveContent.background = null
                liveContent.clipToOutline = false
                ViewCompat.setElevation(liveContent, 0f)
                removeBottomSheetGrabber()
                barrierView?.alpha = 0f
                barrierView?.isClickable = false
                underlay.alpha = 1f
                underlay.scaleX = 1f
                underlay.scaleY = 1f
                underlay.translationX = 0f
                underlay.translationY = 0f
                resetBottomSheetBackdropMask()
            }
            LynxRoutePreset.UPWARDS -> {
                liveContent.alpha = 0.96f + 0.04f * p
                liveContent.translationY = rootHeight * (1f - p)
                underlay.alpha = 1f - 0.18f * p
            }
            LynxRoutePreset.ZOOM -> {
                val scale = 0.78f + 0.22f * p
                liveContent.scaleX = scale
                liveContent.scaleY = scale
                liveContent.alpha = p
                underlay.alpha = 1f - 0.2f * p
            }
            LynxRoutePreset.CUPERTINO_MODAL -> {
                liveContent.alpha = p
                liveContent.translationY = liveContent.height.coerceAtLeast(1) * (1f - p)
                underlay.scaleX = 1f - 0.06f * p
                underlay.scaleY = 1f - 0.06f * p
                underlay.translationY = 12f * density * p
                underlay.alpha = 1f
                barrierView?.alpha = p
            }
            LynxRoutePreset.CUPERTINO_MODAL_INSIDE -> {
                liveContent.alpha = 0.86f + 0.14f * p
                // 保持 modal 外形不变，只在 modal frame 内做横向导航。
                liveContent.translationX = rootWidth * (1f - p) * horizontalDirection()
                barrierView?.alpha = p
                underlay.alpha = 1f
            }
            LynxRoutePreset.MODAL_NAVIGATION -> {
                val scale = 0.92f + 0.08f * p
                liveContent.scaleX = scale
                liveContent.scaleY = scale
                liveContent.translationY = 36f * density * (1f - p)
                liveContent.alpha = p
                barrierView?.alpha = p
                underlay.alpha = 1f
            }
            LynxRoutePreset.MODAL -> {
                val scale = 0.72f + 0.28f * p
                liveContent.scaleX = scale
                liveContent.scaleY = scale
                liveContent.alpha = p
                barrierView?.alpha = p
                underlay.alpha = 1f
            }
        }
        enforceSecondaryTransitionPolicy()
    }

    private fun applyBasicOrPresetEntryProgress(progress: Float) {
        if (ticket?.spec?.routePreset != null) {
            applyPresetEntryProgress(progress)
        } else {
            applyBasicEntryProgress(
                ticket?.effectiveTransition ?: LynxTransitionStyle.FADE,
                progress,
            )
        }
    }

    private fun applyBasicEntryProgress(
        style: LynxTransitionStyle,
        rawProgress: Float,
    ) {
        val p = rawProgress.coerceIn(0f, 1f)
        resetLiveTransforms(keepAlpha = true)
        when (style) {
            LynxTransitionStyle.SLIDE -> {
                liveContent.translationX =
                    root.width.coerceAtLeast(1) * (1f - p) * horizontalDirection()
                liveContent.alpha = 0.94f + 0.06f * p
            }
            LynxTransitionStyle.SLIDE_UP -> {
                liveContent.translationY = root.height.coerceAtLeast(1) * (1f - p)
                liveContent.alpha = 0.94f + 0.06f * p
            }
            LynxTransitionStyle.ZOOM -> {
                val scale = 0.84f + 0.16f * p
                liveContent.scaleX = scale
                liveContent.scaleY = scale
                liveContent.alpha = p
            }
            LynxTransitionStyle.NONE -> liveContent.alpha = 1f
            else -> liveContent.alpha = p
        }
        underlay.alpha = 1f - p
        enforceSecondaryTransitionPolicy()
    }

    /**
     * Skyline 的 canTransitionTo/canTransitionFrom 只约束次级 route（这里是 source
     * underlay）是否跟随主 route 运动，不能取消当前 Activity 的主 push/pop 动画。
     *
     * - push 读取 canTransitionTo；
     * - pop/交互返回读取 canTransitionFrom。
     */
    private fun enforceSecondaryTransitionPolicy() {
        val routeConfig = ticket?.spec?.routeConfig ?: return
        val allowSecondaryTransition = if (interactiveActive) {
            routeConfig.canTransitionFrom
        } else {
            routeConfig.canTransitionTo
        }
        if (allowSecondaryTransition) return
        underlay.alpha = 1f
        underlay.translationX = 0f
        underlay.translationY = 0f
        underlay.scaleX = 1f
        underlay.scaleY = 1f
        if (ticket?.spec?.routePreset?.isSheet == true) {
            applyBottomSheetBackdropCornerRadius(0f)
        }
    }

    private fun configurePresetFrame() {
        val currentTicket = ticket ?: return
        val preset = currentTicket.spec.routePreset ?: return
        val isPersistent = isPersistentPreset(preset)
        if (!isPersistent) {
            restoreOriginalLiveLayout()
            return
        }
        if (preset == LynxRoutePreset.HERO_SHEET) {
            // heroSheet 不是真正的原生 Sheet：目标 Lynx 页面本身是全屏透明
            // 内容层，首屏露出多少由页面自己的 scroll-view 决定。
            liveContent.layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
                Gravity.TOP,
            )
            liveContent.translationY = 0f
            liveContent.background = null
            liveContent.clipToOutline = false
            ViewCompat.setElevation(liveContent, 0f)
            removeBottomSheetGrabber()
            removeBarrier()
            configureSourceUnderlay(currentTicket)
            return
        }
        val rootWidth = root.width.takeIf { it > 0 }
            ?: activity.resources.displayMetrics.widthPixels
        val rootHeight = root.height.takeIf { it > 0 }
            ?: activity.resources.displayMetrics.heightPixels
        val density = activity.resources.displayMetrics.density
        val margin = (12f * density).roundToInt()
        if (preset.isSheet && sheetDetentIndex == null) {
            sheetDetentIndex = currentTicket.spec.routeOptions.initialDetentIndex
        }
        val sheetHeightVh = currentTicket.spec.routeOptions.detentsVh[
            (sheetDetentIndex ?: currentTicket.spec.routeOptions.initialDetentIndex)
                .coerceIn(0, currentTicket.spec.routeOptions.detentsVh.lastIndex)
        ]
        val params = when (preset) {
            LynxRoutePreset.BOTTOM_SHEET -> FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                (rootHeight * sheetHeightVh / 100f)
                    .roundToInt()
                    .coerceAtLeast(1),
                Gravity.BOTTOM,
            )
            LynxRoutePreset.CUPERTINO_MODAL,
            LynxRoutePreset.CUPERTINO_MODAL_INSIDE,
            -> FrameLayout.LayoutParams(
                (rootWidth - margin * 2).coerceAtLeast(1),
                (rootHeight * 0.92f).roundToInt().coerceAtLeast(1),
                Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL,
            ).apply {
                leftMargin = margin
                rightMargin = margin
            }
            LynxRoutePreset.MODAL_NAVIGATION -> FrameLayout.LayoutParams(
                (rootWidth * 0.92f).roundToInt().coerceAtLeast(1),
                (rootHeight * 0.86f).roundToInt().coerceAtLeast(1),
                Gravity.CENTER,
            )
            LynxRoutePreset.MODAL -> FrameLayout.LayoutParams(
                (rootWidth * 0.86f).roundToInt().coerceAtLeast(1),
                (rootHeight * 0.56f).roundToInt().coerceAtLeast(1),
                Gravity.CENTER,
            )
            else -> return
        }
        liveContent.layoutParams = params
        val radiusDp = when (preset) {
            LynxRoutePreset.BOTTOM_SHEET ->
                if (currentTicket.spec.routeOptions.round) {
                    LynxBottomSheetMotion.SHEET_CORNER_RADIUS_DP
                } else {
                    0f
                }
            LynxRoutePreset.CUPERTINO_MODAL,
            LynxRoutePreset.CUPERTINO_MODAL_INSIDE,
            -> 26f
            LynxRoutePreset.MODAL_NAVIGATION -> 24f
            LynxRoutePreset.MODAL -> 20f
            else -> 0f
        }
        liveContent.background = GradientDrawable().apply {
            shape = GradientDrawable.RECTANGLE
            val targetColor = (targetContent.background as? ColorDrawable)?.color
                ?: Color.TRANSPARENT
            setColor(if (preset.isSheet) targetColor else Color.WHITE)
            if (preset.isSheet && radiusDp > 0f) {
                val r = radiusDp * density
                cornerRadii = floatArrayOf(r, r, r, r, 0f, 0f, 0f, 0f)
            } else {
                cornerRadius = radiusDp * density
            }
        }
        liveContent.clipToOutline = true
        ViewCompat.setElevation(liveContent, 16f * density)
        if (preset.isSheet) {
            ensureBottomSheetGrabber(
                rootHeight = rootHeight,
                sheetHeight = params.height,
                density = density,
            )
        } else {
            removeBottomSheetGrabber()
        }
        ensureBarrier()
        configureSourceUnderlay(currentTicket)
    }

    private fun ensureBarrier() {
        val currentTicket = ticket ?: return
        if (!isPersistentPreset(currentTicket.spec.routePreset)) return
        val existing = barrierView
        if (existing != null) {
            existing.setBackgroundColor(parseColor(currentTicket.spec.routeConfig.barrierColor, 0x66000000))
            return
        }
        val barrier = View(activity).apply {
            setBackgroundColor(
                parseColor(currentTicket.spec.routeConfig.barrierColor, 0x66000000),
            )
            alpha = 0f
            isClickable = currentTicket.spec.routeConfig.barrierDismissible
            isFocusable = currentTicket.spec.routeConfig.barrierDismissible
            contentDescription = currentTicket.spec.routeConfig.barrierLabel
            importantForAccessibility = if (
                currentTicket.spec.routeConfig.barrierDismissible
            ) {
                View.IMPORTANT_FOR_ACCESSIBILITY_YES
            } else {
                View.IMPORTANT_FOR_ACCESSIBILITY_NO
            }
            if (currentTicket.spec.routeConfig.barrierDismissible) {
                setOnClickListener {
                    requestBack(
                        animated = true,
                        useStoredTransition = true,
                        commit = onSystemBackCommit,
                    )
                }
            }
        }
        val liveIndex = root.indexOfChild(liveContent).coerceAtLeast(1)
        root.addView(
            barrier,
            liveIndex,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            ),
        )
        barrierView = barrier
    }

    private fun configureSourceUnderlay(currentTicket: AndroidTransitionTicket) {
        val bitmap = LynxSnapshotStore.get(currentTicket.sourceWindowSnapshotToken)
        if (bitmap == null) {
            clearSourceUnderlay()
            return
        }
        underlay.setImageBitmap(bitmap)
        underlay.visibility = View.VISIBLE
        underlay.alpha = 1f
        if (currentTicket.spec.routePreset?.isSheet != true) {
            resetBottomSheetBackdropMask()
        }
    }

    private fun clearSourceUnderlay() {
        underlay.setImageDrawable(null)
        underlay.visibility = View.GONE
        underlay.alpha = 0f
        underlay.translationX = 0f
        underlay.translationY = 0f
        underlay.scaleX = 1f
        underlay.scaleY = 1f
        resetBottomSheetBackdropMask()
    }

    private fun applyBottomSheetBackdropCornerRadius(radiusPx: Float) {
        val drawable = bottomSheetBackdropDrawable ?: GradientDrawable().apply {
            shape = GradientDrawable.RECTANGLE
            setColor(Color.BLACK)
        }.also {
            bottomSheetBackdropDrawable = it
            underlay.background = it
        }
        drawable.cornerRadius = radiusPx.coerceAtLeast(0f)
        underlay.clipToOutline = radiusPx > 0f
    }

    private fun resetBottomSheetBackdropMask() {
        underlay.clipToOutline = false
        underlay.background = null
        bottomSheetBackdropDrawable = null
    }

    private fun ensureBottomSheetGrabber(
        rootHeight: Int,
        sheetHeight: Int,
        density: Float,
    ) {
        val grabber = bottomSheetGrabberView ?: View(activity).apply {
            isClickable = false
            isFocusable = false
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                setColor(Color.parseColor("#B5B5B7"))
                cornerRadius = 2.5f * density
            }
            ViewCompat.setElevation(this, 18f * density)
        }.also { view ->
            val overlayIndex = root.indexOfChild(overlay).takeIf { it >= 0 }
                ?: root.childCount
            root.addView(view, overlayIndex)
            bottomSheetGrabberView = view
        }
        grabber.layoutParams = FrameLayout.LayoutParams(
            (36f * density).roundToInt().coerceAtLeast(1),
            (5f * density).roundToInt().coerceAtLeast(1),
            Gravity.TOP or Gravity.CENTER_HORIZONTAL,
        ).apply {
            topMargin = (rootHeight - sheetHeight + 8f * density).roundToInt()
                .coerceAtLeast(0)
        }
        grabber.translationY = liveContent.translationY
        grabber.alpha = if (entryPending) 0f else 1f
        grabber.visibility = View.VISIBLE
        grabber.bringToFront()
        overlay.bringToFront()
    }

    private fun removeBottomSheetGrabber() {
        bottomSheetGrabberView?.let { (it.parent as? ViewGroup)?.removeView(it) }
        bottomSheetGrabberView = null
    }

    private fun finishEntryVisual() {
        clearTransientVisuals()
        resetLiveTransforms()
        if (isPersistentPreset(ticket?.spec?.routePreset)) {
            applyPresetEntryProgress(1f)
        } else {
            finishUnderlayForCurrentRoute()
            removeBarrier()
        }
    }

    private fun applyFinalPresentation() {
        clearTransientVisuals()
        resetLiveTransforms()
        configurePresetFrame()
        if (isPersistentPreset(ticket?.spec?.routePreset)) {
            applyPresetEntryProgress(1f)
        } else {
            finishUnderlayForCurrentRoute()
            removeBarrier()
        }
    }

    private fun createSharedProxy(
        spec: LynxSharedElementSpec,
        bitmap: Bitmap,
        start: Rect,
        end: Rect,
    ): SharedProxy {
        val image = ImageView(activity).apply {
            scaleType = ImageView.ScaleType.CENTER_CROP
            setImageBitmap(bitmap)
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                setColor(Color.TRANSPARENT)
            }
            clipToOutline = true
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
        }
        addTransientView(
            image,
            FrameLayout.LayoutParams(start.width().coerceAtLeast(1), start.height().coerceAtLeast(1)),
        )
        val proxy = SharedProxy(spec, image, start, end)
        applySharedProxyProgress(proxy, 0f, reverseAppearance = false)
        return proxy
    }

    private fun applySharedProxyProgress(
        proxy: SharedProxy,
        progress: Float,
        reverseAppearance: Boolean,
    ) {
        val rect = interpolateSharedRect(
            proxy.start,
            proxy.end,
            progress,
            proxy.spec.rectTween,
        )
        setViewRect(proxy.view, rect)
        val appearanceProgress = if (reverseAppearance) 1f - progress else progress
        val density = activity.resources.displayMetrics.density
        val drawable = proxy.view.background as? GradientDrawable ?: return
        drawable.setColor(
            ArgbEvaluator().evaluate(
                appearanceProgress,
                parseColor(proxy.spec.sourceStyle.backgroundColor, Color.TRANSPARENT),
                parseColor(proxy.spec.targetStyle.backgroundColor, Color.TRANSPARENT),
            ) as Int,
        )
        drawable.cornerRadius = lerp(
            (proxy.spec.sourceStyle.cornerRadius ?: 0f) * density,
            (proxy.spec.targetStyle.cornerRadius ?: 0f) * density,
            appearanceProgress,
        )
        ViewCompat.setElevation(
            proxy.view,
            lerp(
                (proxy.spec.sourceStyle.elevation ?: 0f) * density,
                (proxy.spec.targetStyle.elevation ?: 0f) * density,
                appearanceProgress,
            ),
        )
    }

    private fun interpolateSharedRect(
        start: Rect,
        end: Rect,
        rawProgress: Float,
        tween: LynxRectTweenSpec,
    ): Rect {
        val p = tweenProgress(rawProgress, tween)
        val width = lerp(start.width().toFloat(), end.width().toFloat(), p)
            .coerceAtLeast(1f)
        val height = lerp(start.height().toFloat(), end.height().toFloat(), p)
            .coerceAtLeast(1f)
        val startCx = start.exactCenterX()
        val startCy = start.exactCenterY()
        val endCx = end.exactCenterX()
        val endCy = end.exactCenterY()
        val (cx, cy) = when (tween) {
            LynxRectTweenSpec.MaterialRectArc -> {
                val controlX = if (abs(endCx - startCx) > abs(endCy - startCy)) {
                    endCx
                } else {
                    startCx
                }
                val controlY = if (abs(endCx - startCx) > abs(endCy - startCy)) {
                    startCy
                } else {
                    endCy
                }
                quadratic(startCx, controlX, endCx, p) to
                    quadratic(startCy, controlY, endCy, p)
            }
            LynxRectTweenSpec.MaterialRectCenterArc -> {
                val dx = endCx - startCx
                val dy = endCy - startCy
                val controlX = (startCx + endCx) * 0.5f - dy * 0.18f
                val controlY = (startCy + endCy) * 0.5f + dx * 0.18f
                quadratic(startCx, controlX, endCx, p) to
                    quadratic(startCy, controlY, endCy, p)
            }
            else -> lerp(startCx, endCx, p) to lerp(startCy, endCy, p)
        }
        return Rect(
            (cx - width / 2f).roundToInt(),
            (cy - height / 2f).roundToInt(),
            (cx + width / 2f).roundToInt(),
            (cy + height / 2f).roundToInt(),
        )
    }

    private fun tweenProgress(rawProgress: Float, tween: LynxRectTweenSpec): Float {
        val p = rawProgress.coerceIn(0f, 1f)
        return when (tween) {
            LynxRectTweenSpec.Linear,
            LynxRectTweenSpec.MaterialRectArc,
            LynxRectTweenSpec.MaterialRectCenterArc,
            -> p
            LynxRectTweenSpec.ElasticIn -> elasticIn(p)
            LynxRectTweenSpec.ElasticOut -> elasticOut(p)
            LynxRectTweenSpec.ElasticInOut ->
                if (p < 0.5f) elasticIn(p * 2f) / 2f else {
                    elasticOut(p * 2f - 1f) / 2f + 0.5f
                }
            LynxRectTweenSpec.BounceIn -> 1f - bounceOut(1f - p)
            LynxRectTweenSpec.BounceOut -> bounceOut(p)
            LynxRectTweenSpec.BounceInOut ->
                if (p < 0.5f) (1f - bounceOut(1f - 2f * p)) / 2f else {
                    (1f + bounceOut(2f * p - 1f)) / 2f
                }
            is LynxRectTweenSpec.CubicBezier -> cubicBezierProgress(p, tween)
        }.coerceIn(-0.35f, 1.35f)
    }

    private fun elasticIn(p: Float): Float {
        if (p == 0f || p == 1f) return p
        return -(2.0.pow(10.0 * p - 10.0) *
            sin((p * 10.0 - 10.75) * (2.0 * PI / 3.0))).toFloat()
    }

    private fun elasticOut(p: Float): Float {
        if (p == 0f || p == 1f) return p
        return (
            2.0.pow(-10.0 * p) *
                sin((p * 10.0 - 0.75) * (2.0 * PI / 3.0)) +
                1.0
            ).toFloat()
    }

    private fun bounceOut(value: Float): Float {
        var p = value
        val n = 7.5625f
        val d = 2.75f
        return when {
            p < 1f / d -> n * p * p
            p < 2f / d -> {
                p -= 1.5f / d
                n * p * p + 0.75f
            }
            p < 2.5f / d -> {
                p -= 2.25f / d
                n * p * p + 0.9375f
            }
            else -> {
                p -= 2.625f / d
                n * p * p + 0.984375f
            }
        }
    }

    /** 反解 cubic-bezier 的 x(t)，再返回 y(t)；不把每帧计算交给 Worklet/JS。 */
    private fun cubicBezierProgress(
        x: Float,
        spec: LynxRectTweenSpec.CubicBezier,
    ): Float {
        var low = 0f
        var high = 1f
        repeat(12) {
            val t = (low + high) / 2f
            if (cubicCoordinate(t, spec.x1, spec.x2) < x) low = t else high = t
        }
        return cubicCoordinate((low + high) / 2f, spec.y1, spec.y2)
    }

    private fun cubicCoordinate(t: Float, control1: Float, control2: Float): Float {
        val inverse = 1f - t
        return 3f * inverse * inverse * t * control1 +
            3f * inverse * t * t * control2 +
            t * t * t
    }

    private fun quadratic(start: Float, control: Float, end: Float, p: Float): Float {
        val inverse = 1f - p
        return inverse * inverse * start + 2f * inverse * p * control + p * p * end
    }

    private fun maskTarget(view: View) {
        if (maskedTargetAlphas.containsKey(view)) return
        maskedTargetAlphas[view] = view.alpha
        view.alpha = 0f
    }

    private fun clearTransientVisuals() {
        transientViews.toList().forEach { view ->
            (view.parent as? ViewGroup)?.removeView(view)
        }
        transientViews.clear()
        sharedProxies.clear()
        openMorphView = null
        maskedTargetAlphas.forEach { (view, alpha) -> view.alpha = alpha }
        maskedTargetAlphas.clear()
    }

    private fun addTransientView(view: View, params: FrameLayout.LayoutParams) {
        overlay.addView(view, params)
        transientViews += view
    }

    private fun finishUnderlayForCurrentRoute() {
        val currentTicket = ticket
        if (
            currentTicket != null &&
            (
                isPersistentPreset(currentTicket.spec.routePreset) ||
                    !currentTicket.spec.routeConfig.opaque
                ) &&
            LynxSnapshotStore.get(currentTicket.sourceWindowSnapshotToken) != null
        ) {
            configureSourceUnderlay(currentTicket)
            underlay.alpha = 1f
            return
        }
        clearUnderlayForFullPage()
    }

    private fun clearUnderlayForFullPage() {
        underlay.setImageDrawable(null)
        underlay.visibility = View.GONE
        underlay.alpha = 1f
        underlay.translationX = 0f
        underlay.translationY = 0f
        underlay.scaleX = 1f
        underlay.scaleY = 1f
        resetBottomSheetBackdropMask()
    }

    private fun removeBarrier() {
        barrierView?.let { root.removeView(it) }
        barrierView = null
    }

    private fun restoreOriginalLiveLayout() {
        removeBottomSheetGrabber()
        liveContent.layoutParams = copyLayoutParams(originalLiveLayout)
        liveContent.background = originalLiveBackground
        liveContent.clipToOutline = originalClipToOutline
        ViewCompat.setElevation(liveContent, originalElevation)
    }

    private fun resetLiveTransforms(keepAlpha: Boolean = false) {
        if (!keepAlpha) liveContent.alpha = 1f
        liveContent.translationX = 0f
        liveContent.translationY = 0f
        liveContent.scaleX = 1f
        liveContent.scaleY = 1f
    }

    private fun animateProgress(
        from: Float,
        to: Float,
        durationMs: Long,
        onUpdate: (Float) -> Unit,
        onEnd: () -> Unit,
    ) {
        animator?.cancel()
        if (durationMs <= 0L) {
            onUpdate(to)
            onEnd()
            return
        }
        var cancelled = false
        animator = ValueAnimator.ofFloat(from, to).apply {
            duration = durationMs
            interpolator = if (ticket?.spec?.routePreset?.isSheet == true) {
                // iOS sheet 的高阻尼 spring 近似：快速离底、无明显回弹、末段平滑收敛。
                PathInterpolator(0.16f, 1f, 0.3f, 1f)
            } else {
                PathInterpolator(0.2f, 0f, 0f, 1f)
            }
            addUpdateListener { onUpdate(it.animatedValue as Float) }
            addListener(object : AnimatorListenerAdapter() {
                override fun onAnimationCancel(animation: Animator) {
                    cancelled = true
                }

                override fun onAnimationEnd(animation: Animator) {
                    if (animator === animation) animator = null
                    if (!cancelled && !destroyed) onEnd()
                    updatePredictiveBackAvailability()
                }
            })
            start()
        }
    }

    private fun updateRunningProgress(
        progress: Float,
        direction: LynxTransitionDirection,
    ) {
        // 只写原生状态，严禁在动画帧内 sendGlobalEvent。
        transactionID?.let {
            LynxTransitionRuntime.update(
                it,
                LynxTransitionStatus.RUNNING,
                direction = direction,
                progress = progress,
            )
        }
    }

    /**
     * 官方 onRouteDone 只表示路由已经完成；手势 cancel 只发壳扩展
     * onTransitionSettled。lynxRouteDone 是早期壳协议的兼容别名，也遵循相同边界。
     */
    private fun terminal(
        status: LynxTransitionStatus,
        direction: LynxTransitionDirection,
        progress: Float,
        reason: String?,
    ) {
        val id = transactionID ?: return
        LynxTransitionRuntime.update(
            id,
            status,
            direction = direction,
            progress = progress,
            reason = reason,
        )
        val state = LynxTransitionRuntime.state(id) ?: return
        val payload = state.toMap().apply {
            ticket?.spec?.routeType?.let { put("routeType", it) }
            if (ticket?.effectiveTransition == LynxTransitionStyle.SHARED_ELEMENT) {
                // Module-only 架构没有同步 on-frame Worklet 通道；所有已声明 tween 均由
                // 原生驱动。这个诊断字段明确边界，但不把已经完成的原生动画标成失败。
                put("frameDriver", "native")
                put("workletReason", "module_only_native_tween_no_js_frame_bridge")
            }
        }
        val lynxView = currentLynxView
        if (
            status == LynxTransitionStatus.COMPLETED ||
            status == LynxTransitionStatus.DEGRADED
        ) {
            sendGlobalEvent(lynxView, "onRouteDone", payload)
            sendGlobalEvent(lynxView, "lynxRouteDone", payload)
        }
        if (
            status == LynxTransitionStatus.COMPLETED ||
            status == LynxTransitionStatus.CANCELLED ||
            status == LynxTransitionStatus.DEGRADED ||
            status == LynxTransitionStatus.FAILED
        ) {
            sendGlobalEvent(lynxView, "onTransitionSettled", payload)
        }
        updatePredictiveBackAvailability()
    }

    private fun sendGlobalEvent(
        lynxView: LynxView?,
        name: String,
        payload: HashMap<String, Any>,
    ) {
        runCatching {
            lynxView?.sendGlobalEvent(
                name,
                JavaOnlyArray.of(JavaOnlyMap.from(payload)),
            )
        }
    }

    private fun terminalStatus(reason: String?): LynxTransitionStatus =
        if (reason == null) LynxTransitionStatus.COMPLETED else LynxTransitionStatus.DEGRADED

    private fun commitFailureReason(error: Throwable): String =
        error.message
            ?.takeIf { it.matches(Regex("[a-z0-9_:\\-]{1,160}")) }
            ?: "navigation_commit_failed"

    private fun updatePredictiveBackAvailability() {
        val interceptSystemBack = backGestureEnabled &&
            transactionID != null &&
            (ticket == null || ticket?.spec?.explicitlyRequested == true) &&
            !destroyed
        val interactiveAvailable = interceptSystemBack && canStartInteractiveSystemBack()
        predictiveBackCallback.isEnabled = interceptSystemBack
        (root as? LynxCompatEdgeBackLayout)?.apply {
            edgeWidthDp = ticket?.spec?.popGesture?.edgeWidth ?: 28f
            gestureDirection = ticket?.spec?.popGesture?.direction
                ?: LynxPopGestureDirection.HORIZONTAL
            fullScreenGesture = ticket?.spec?.popGesture?.fullScreen == true
            verticalGestureExtentPx = if (ticket?.spec?.routePreset == LynxRoutePreset.BOTTOM_SHEET) {
                bottomSheetGestureExtentPx()
            } else {
                null
            }
            verticalSheetDragEnabled = interactiveAvailable &&
                ticket?.spec?.routePreset == LynxRoutePreset.BOTTOM_SHEET &&
                ticket?.spec?.routeOptions?.isMultiDetent == true &&
                gestureDirection != LynxPopGestureDirection.HORIZONTAL
            // heroSheet 的上滑是 Lynx scroll-view 自己的职责；原生只提供透明
            // Activity/VC 承载，不能在这里抢走纵向触摸流。
            compatGestureEnabled = interactiveAvailable &&
                ticket?.spec?.routePreset != LynxRoutePreset.HERO_SHEET &&
                (
                    Build.VERSION.SDK_INT < 34 ||
                        fullScreenGesture ||
                        gestureDirection != LynxPopGestureDirection.HORIZONTAL
                    )
        }
    }

    private fun bottomSheetGestureExtentPx(): Float {
        val measured = liveContent.height.toFloat()
        if (measured > 0f) return measured
        val layoutHeight = liveContent.layoutParams?.height ?: 0
        if (layoutHeight > 0) return layoutHeight.toFloat()
        val rootHeight = root.height.takeIf { it > 0 }
            ?: activity.resources.displayMetrics.heightPixels
        val heightVh = ticket?.spec?.routeOptions?.heightVh
            ?: LynxBottomSheetMotion.DEFAULT_HEIGHT_VH
        return (rootHeight * heightVh / 100f).coerceAtLeast(1f)
    }

    private fun canStartInteractiveSystemBack(): Boolean {
        val stateAllowsBack = LynxTransitionRuntime.state(transactionID)?.status in setOf(
            LynxTransitionStatus.COMPLETED,
            LynxTransitionStatus.CANCELLED,
            LynxTransitionStatus.DEGRADED,
        )
        return ticket?.spec?.popGesture?.enabled == true &&
            animator == null &&
            !interactiveActive &&
            !entryPending &&
            stateAllowsBack
    }

    private fun isWaitingForEnter(): Boolean =
        entryPending &&
            ticket != null &&
            LynxTransitionRuntime.state(transactionID)?.status in setOf(
                LynxTransitionStatus.ACCEPTED,
                LynxTransitionStatus.WAITING_TARGET,
                LynxTransitionStatus.DEGRADED,
            )

    private fun scheduleGateRetry() {
        if (!isWaitingForEnter() || gateRetryPosted) return
        gateRetryPosted = true
        mainHandler.postDelayed(gateRetry, if (businessReady) 0L else 32L)
    }

    private fun popFallbackStyle(): LynxTransitionStyle {
        val currentTicket = ticket ?: return LynxTransitionStyle.FADE
        return when (currentTicket.effectiveTransition) {
            LynxTransitionStyle.SHARED_ELEMENT,
            LynxTransitionStyle.OPEN_CONTAINER,
            -> currentTicket.fallbackTransition
            else -> currentTicket.effectiveTransition
        }
    }

    private fun isPersistentPreset(preset: LynxRoutePreset?): Boolean =
        preset in setOf(
            LynxRoutePreset.BOTTOM_SHEET,
            LynxRoutePreset.HERO_SHEET,
            LynxRoutePreset.CUPERTINO_MODAL,
            LynxRoutePreset.CUPERTINO_MODAL_INSIDE,
            LynxRoutePreset.MODAL_NAVIGATION,
            LynxRoutePreset.MODAL,
        )

    private fun setViewRect(view: View, rect: Rect) {
        val params = (view.layoutParams as? FrameLayout.LayoutParams)
            ?: FrameLayout.LayoutParams(rect.width(), rect.height())
        params.width = rect.width().coerceAtLeast(1)
        params.height = rect.height().coerceAtLeast(1)
        params.leftMargin = rect.left
        params.topMargin = rect.top
        view.layoutParams = params
    }

    private fun cropViewBitmap(
        viewBitmap: Bitmap,
        view: View,
        rectOnScreen: Rect,
    ): Bitmap? {
        val location = IntArray(2)
        view.getLocationOnScreen(location)
        val local = Rect(rectOnScreen).apply { offset(-location[0], -location[1]) }
        val bounds = Rect(0, 0, viewBitmap.width, viewBitmap.height)
        if (!local.intersect(bounds) || local.isEmpty) return null
        return runCatching {
            Bitmap.createBitmap(
                viewBitmap,
                local.left,
                local.top,
                local.width(),
                local.height(),
            )
        }.getOrNull()
    }

    private fun toRootLocal(rectOnScreen: Rect): Rect {
        val rootLocation = IntArray(2)
        root.getLocationOnScreen(rootLocation)
        return Rect(rectOnScreen).apply {
            offset(-rootLocation[0], -rootLocation[1])
        }
    }

    private fun isUsableRect(rect: Rect): Boolean =
        !rect.isEmpty &&
            rect.right > 0 &&
            rect.bottom > 0 &&
            rect.left < root.width &&
            rect.top < root.height

    private fun copyLayoutParams(params: ViewGroup.LayoutParams): FrameLayout.LayoutParams =
        when (params) {
            is FrameLayout.LayoutParams -> FrameLayout.LayoutParams(params)
            else -> FrameLayout.LayoutParams(params.width, params.height)
        }

    private fun remainingDuration(duration: Long, fraction: Float): Long =
        if (duration <= 0L) {
            0L
        } else {
            (duration * fraction.coerceIn(0f, 1f))
                .roundToInt()
                .toLong()
                .coerceAtLeast(0L)
        }

    private fun horizontalDirection(): Float =
        if (root.layoutDirection == View.LAYOUT_DIRECTION_RTL) -1f else 1f

    private fun lerp(start: Float, end: Float, progress: Float): Float =
        start + (end - start) * progress

    private fun parseColor(value: String?, fallback: Int): Int =
        LynxColorParser.parse(value, fallback)

    private companion object {
        const val TRANSITION_LOG_TAG = "LynxTransition"
        const val TARGET_FRAME_SETTLE_MS = 64L
    }
}
