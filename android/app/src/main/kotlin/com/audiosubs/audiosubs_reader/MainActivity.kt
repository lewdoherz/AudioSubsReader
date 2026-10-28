package com.audiosubs.audiosubs_reader

import android.os.Build
import android.util.Log
import android.view.View
import android.view.ViewTreeObserver
import android.view.WindowInsets
import android.view.WindowInsetsController
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var displayChannel: MethodChannel? = null
    private var fullscreenRequested = false
    private var normalPresentation: Presentation? = null
    private var pendingTransition: PendingTransition? = null

    private data class Presentation(
        val legacyVisibility: Int = 0,
        val barBehavior: Int = 0,
        val visibleBars: Int = 0,
    )

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        displayChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "audiosubs_reader/display",
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                if (call.method != "setFullscreen") {
                    result.notImplemented()
                } else {
                    val enabled = call.arguments as? Boolean
                    if (enabled == null) {
                        result.error(
                            "invalid_argument",
                            "setFullscreen requires a boolean argument.",
                            null,
                        )
                    } else {
                        setFullscreen(enabled, result)
                    }
                }
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        displayChannel?.setMethodCallHandler(null)
        displayChannel = null
        pendingTransition?.let { transition ->
            transition.detach()
            pendingTransition = null
            transition.results.forEach {
                it.error("activity_detached", "The reader activity was detached.", null)
            }
        }
        // The engine may be detached while this Activity still owns a window.
        // Do not leave that window in the old engine's immersive presentation.
        fullscreenRequested = false
        try {
            normalPresentation?.let { restorePresentation(it) }
            normalPresentation = null
        } catch (error: Exception) {
            Log.e(TAG, "Could not restore system bars while detaching the engine", error)
        }
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onResume() {
        super.onResume()
        reapplyRequestedPresentation()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) {
            reapplyRequestedPresentation()
        }
    }

    private fun setFullscreen(enabled: Boolean, result: MethodChannel.Result) {
        val currentTransition = pendingTransition
        if (currentTransition != null) {
            if (currentTransition.enabled == enabled) {
                currentTransition.results.add(result)
            } else {
                result.error("fullscreen_busy", "A display transition is in progress.", null)
            }
            return
        }
        if (!enabled && !fullscreenRequested && normalPresentation == null) {
            result.success(null)
            return
        }
        // Even an idempotent immersive request is reapplied and observed:
        // Android may have revealed bars after a focus change or edge swipe.

        val wasFullscreen = fullscreenRequested
        try {
            if (enabled && normalPresentation == null) {
                normalPresentation = capturePresentation()
            }
            val transition = PendingTransition(enabled, wasFullscreen, result)
            pendingTransition = transition
            fullscreenRequested = enabled
            transition.attach()
            applyRequestedPresentation()
            window.decorView.requestApplyInsets()
            window.decorView.postInvalidateOnAnimation()
        } catch (error: Exception) {
            val transition = pendingTransition
            if (transition != null) {
                failTransition(transition, "Could not change system bars: ${error.message}")
            } else {
                result.error("fullscreen_failed", "Could not capture system bars: ${error.message}", null)
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun capturePresentation(): Presentation {
        val decor = window.decorView
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val controller = window.insetsController
                ?: throw IllegalStateException("The window insets controller is unavailable")
            val insets = decor.rootWindowInsets
                ?: throw IllegalStateException("The window has not received system bar insets yet")
            var visibleBars = 0
            if (insets.isVisible(WindowInsets.Type.statusBars())) {
                visibleBars = visibleBars or WindowInsets.Type.statusBars()
            }
            if (insets.isVisible(WindowInsets.Type.navigationBars())) {
                visibleBars = visibleBars or WindowInsets.Type.navigationBars()
            }
            return Presentation(
                barBehavior = controller.systemBarsBehavior,
                visibleBars = visibleBars,
            )
        }
        return Presentation(legacyVisibility = decor.systemUiVisibility)
    }

    @Suppress("DEPRECATION")
    private fun hideSystemBars() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            // Direct WindowInsetsController calls work with enforced edge-to-edge
            // on target SDK 35/36; Flutter's legacy system-UI modes may not.
            val controller = window.insetsController
                ?: throw IllegalStateException("The window insets controller is unavailable")
            controller.systemBarsBehavior =
                WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            controller.hide(WindowInsets.Type.systemBars())
        } else {
            val decor = window.decorView
            decor.systemUiVisibility = decor.systemUiVisibility or LEGACY_FULLSCREEN_FLAGS
        }
    }

    @Suppress("DEPRECATION")
    private fun restorePresentation(presentation: Presentation) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val controller = window.insetsController
                ?: throw IllegalStateException("The window insets controller is unavailable")
            controller.systemBarsBehavior = presentation.barBehavior
            val bars = WindowInsets.Type.statusBars() or WindowInsets.Type.navigationBars()
            val hiddenBars = bars and presentation.visibleBars.inv()
            if (hiddenBars != 0) {
                controller.hide(hiddenBars)
            }
            if (presentation.visibleBars != 0) {
                controller.show(presentation.visibleBars)
            }
        } else {
            window.decorView.systemUiVisibility = presentation.legacyVisibility
        }
    }

    private fun applyRequestedPresentation() {
        if (fullscreenRequested) {
            hideSystemBars()
        } else {
            normalPresentation?.let { restorePresentation(it) }
        }
    }

    private fun reapplyRequestedPresentation() {
        if (!fullscreenRequested && normalPresentation == null) {
            return
        }
        try {
            applyRequestedPresentation()
        } catch (error: Exception) {
            val transition = pendingTransition
            if (transition != null) {
                failTransition(transition, "Could not restore requested system bars: ${error.message}")
            } else {
                Log.e(TAG, "Could not restore requested system bar presentation", error)
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun presentationApplied(enabled: Boolean): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val insets = window.decorView.rootWindowInsets ?: return false
            val targetVisibility = if (enabled) 0 else normalPresentation?.visibleBars ?: return true
            val statusBars = WindowInsets.Type.statusBars()
            val navigationBars = WindowInsets.Type.navigationBars()
            return insets.isVisible(statusBars) == (targetVisibility and statusBars != 0) &&
                insets.isVisible(navigationBars) == (targetVisibility and navigationBars != 0)
        }
        val visibility = window.decorView.systemUiVisibility
        return if (enabled) {
            visibility and LEGACY_FULLSCREEN_FLAGS == LEGACY_FULLSCREEN_FLAGS
        } else {
            visibility == normalPresentation?.legacyVisibility
        }
    }

    private fun completeTransition(transition: PendingTransition) {
        if (pendingTransition !== transition) {
            return
        }
        transition.detach()
        pendingTransition = null
        if (!transition.enabled) {
            normalPresentation = null
        }
        transition.results.forEach { it.success(null) }
    }

    private fun failTransition(transition: PendingTransition, reason: String) {
        if (pendingTransition !== transition) {
            return
        }
        transition.detach()
        pendingTransition = null
        fullscreenRequested = transition.wasFullscreen
        var message = reason
        try {
            // Preserve the last committed Dart/native state on a failed request.
            applyRequestedPresentation()
        } catch (error: Exception) {
            // Keep the snapshot so a later exit/focus/resume can recover it.
            message += " Restoring the previous presentation also failed: ${error.message}"
        }
        // Insets requests are asynchronous. Retain the normal snapshot after
        // failure even if rollback was accepted, until an exit is confirmed.
        transition.results.forEach { it.error("fullscreen_failed", message, null) }
    }

    private inner class PendingTransition(
        val enabled: Boolean,
        val wasFullscreen: Boolean,
        result: MethodChannel.Result,
    ) : ViewTreeObserver.OnPreDrawListener, Runnable {
        val results = mutableListOf(result)
        private val decor = window.decorView
        private val observer = decor.viewTreeObserver

        fun attach() {
            observer.addOnPreDrawListener(this)
            decor.postDelayed(this, TRANSITION_TIMEOUT_MS)
        }

        fun detach() {
            if (observer.isAlive) {
                observer.removeOnPreDrawListener(this)
            }
            decor.removeCallbacks(this)
        }

        override fun onPreDraw(): Boolean {
            if (pendingTransition === this) {
                if (presentationApplied(enabled)) {
                    completeTransition(this)
                } else {
                    decor.postInvalidateOnAnimation()
                }
            }
            return true
        }

        override fun run() {
            failTransition(
                this,
                "Android did not apply the requested system bar visibility. " +
                    "Keep the reader in the foreground and retry.",
            )
        }
    }

    private companion object {
        const val TAG = "AudioSubsDisplay"
        const val TRANSITION_TIMEOUT_MS = 2000L

        @Suppress("DEPRECATION")
        const val LEGACY_FULLSCREEN_FLAGS =
            View.SYSTEM_UI_FLAG_FULLSCREEN or
                View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or
                View.SYSTEM_UI_FLAG_LAYOUT_STABLE or
                View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
                View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
    }
}
