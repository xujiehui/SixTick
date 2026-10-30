package app.sixtick.six_tick

import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PersistableBundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private var privacy: MethodChannel? = null
    private val handler = Handler(Looper.getMainLooper())
    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == Intent.ACTION_SCREEN_OFF) privacy?.invokeMethod("systemLocked", null)
        }
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(screenReceiver, IntentFilter(Intent.ACTION_SCREEN_OFF), Context.RECEIVER_NOT_EXPORTED)
        else registerReceiver(screenReceiver, IntentFilter(Intent.ACTION_SCREEN_OFF))
    }
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        privacy = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "six_tick/privacy")
        privacy?.setMethodCallHandler { call, result ->
            if (call.method != "copyCode") { result.notImplemented(); return@setMethodCallHandler }
            val text = call.argument<String>("code") ?: ""
            val clear = call.argument<Boolean>("clear") ?: true
            val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            val clip = ClipData.newPlainText("Six Tick", text)
            clip.description.extras = PersistableBundle().apply { putBoolean("android.content.extra.IS_SENSITIVE", true) }
            clipboard.setPrimaryClip(clip)
            val copiedAt = clipboard.primaryClipDescription?.timestamp
            if (clear) handler.postDelayed({
                // Android may deny background clipboard access; no polling or monitoring.
                try {
                    val current = clipboard.primaryClip
                    if (current != null && current.itemCount > 0 && current.description.timestamp == copiedAt &&
                        current.getItemAt(0).text?.toString() == text) clipboard.clearPrimaryClip()
                } catch (_: Exception) { }
            }, 30000)
            result.success(null)
        }
    }
    override fun onDestroy() {
        unregisterReceiver(screenReceiver)
        privacy?.setMethodCallHandler(null)
        super.onDestroy()
    }
}
