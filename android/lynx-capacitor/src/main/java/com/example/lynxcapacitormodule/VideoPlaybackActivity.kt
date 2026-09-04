package com.example.lynxcapacitormodule

import android.app.Activity
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.view.Gravity
import android.widget.FrameLayout
import android.widget.MediaController
import android.widget.TextView
import android.widget.VideoView
import androidx.activity.OnBackPressedCallback
import androidx.appcompat.app.AppCompatActivity
import org.json.JSONObject

/** Camera.playVideo 的自有播放器页面；只接受前一次 native 结果返回的可读 URI。 */
class VideoPlaybackActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val rawUri = intent.getStringExtra(EXTRA_URI).orEmpty().trim()
        val uri = runCatching { Uri.parse(rawUri) }.getOrNull()
        if (rawUri.isEmpty() || uri?.scheme.isNullOrEmpty()) {
            finishWith(error("INVALID_ARGUMENT", "playVideo 需要合法 uri"))
            return
        }

        val player = VideoView(this)
        val status = TextView(this).apply {
            text = "正在准备视频…"
            setTextColor(Color.WHITE)
            setBackgroundColor(0x99000000.toInt())
            setPadding(24, 18, 24, 18)
        }
        val root = FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
            addView(player, FrameLayout.LayoutParams(-1, -1))
            addView(status, FrameLayout.LayoutParams(-1, -2).apply { gravity = Gravity.TOP })
        }
        setContentView(root)
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() = finish()
        })

        player.setMediaController(MediaController(this).apply { setAnchorView(player) })
        player.setOnPreparedListener {
            status.text = "视频播放中"
            player.start()
        }
        player.setOnCompletionListener { status.text = "视频播放完成" }
        player.setOnErrorListener { _, what, extra ->
            status.text = "视频播放失败（$what/$extra）"
            finishWith(error("PLAYBACK_FAILED", "MediaPlayer 无法播放该视频（$what/$extra）"))
            true
        }
        runCatching { player.setVideoURI(uri) }
            .onFailure { throwable -> finishWith(error("PLAYBACK_FAILED", throwable.message ?: "无法打开视频 URI")) }
    }

    private fun finishWith(result: JSONObject) {
        if (result.has("error")) setResult(Activity.RESULT_CANCELED, intent.putExtra(EXTRA_RESULT_JSON, result.toString()))
        finish()
    }

    private fun error(code: String, message: String): JSONObject = JSONObject()
        .put("error", JSONObject().put("code", code).put("message", message))

    companion object {
        const val EXTRA_URI = "com.example.lynxcapacitormodule.video.PLAY_URI"
        const val EXTRA_RESULT_JSON = "com.example.lynxcapacitormodule.video.PLAY_RESULT_JSON"
    }
}
