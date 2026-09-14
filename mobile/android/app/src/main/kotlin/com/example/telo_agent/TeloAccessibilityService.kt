package com.example.telo_agent

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Path
import android.graphics.Rect
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** Generic, app-agnostic Android UI control service. */
class TeloAccessibilityService : AccessibilityService() {
    companion object {
        const val ACTION_COMMAND = "com.example.telo_agent.ACCESSIBILITY_COMMAND"
        const val ACTION_SCREEN = "com.example.telo_agent.ACCESSIBILITY_SCREEN"
        const val ACTION_RESULT = "com.example.telo_agent.ACCESSIBILITY_RESULT"
        private const val MAX_NODES = 180
        private const val SCREEN_DEBOUNCE_MS = 450L
    }

    private val handler = Handler(Looper.getMainLooper())
    private var lastSnapshot: Snapshot? = null
    private var pendingRefresh = false
    private data class NodeRef(val id: String, val path: List<Int>, val fingerprint: String, val packageName: String)
    private data class Snapshot(val id: String, val packageName: String, val nodes: Map<String, NodeRef>)

    private val commandReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val raw = intent?.getStringExtra("data") ?: return
            try { executeCommand(JSONObject(raw)) }
            catch (error: Exception) { sendResult(JSONObject().put("action", "unknown"), false, "Malformed command: ${error.message}") }
        }
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        registerReceiver(commandReceiver, IntentFilter(ACTION_COMMAND), Context.RECEIVER_NOT_EXPORTED)
        log("Connected")
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null || event.packageName == packageName) return
        when (event.eventType) {
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED, AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED,
            AccessibilityEvent.TYPE_VIEW_CLICKED, AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED,
            AccessibilityEvent.TYPE_VIEW_FOCUSED -> scheduleScreenRefresh()
        }
    }

    private fun scheduleScreenRefresh() {
        if (pendingRefresh) return
        pendingRefresh = true
        handler.postDelayed({ pendingRefresh = false; emitScreenSnapshot("accessibility_event") }, SCREEN_DEBOUNCE_MS)
    }

    private fun executeCommand(command: JSONObject) {
        val action = command.optString("action").trim()
        if (action.isBlank()) { sendResult(command, false, "Missing action"); return }
        log("Action: $action node=${command.optString("node_id")}")
        if (action == "read_screen") {
            val screen = emitScreenSnapshot("requested")
            sendResult(command, screen != null, if (screen == null) "No active window" else null, extra = JSONObject().put("snapshot_id", screen?.id ?: ""))
            return
        }
        if (action == "open_app" || action == "open_youtube") {
            val target = if (action == "open_youtube") "com.google.android.youtube" else command.optString("package")
            openApp(command, target)
            return
        }
        if (action == "back" || action == "home") {
            val success = performGlobalAction(if (action == "back") GLOBAL_ACTION_BACK else GLOBAL_ACTION_HOME)
            sendResult(command, success, if (success) null else "Global $action action was rejected")
            if (success) scheduleScreenRefresh()
            return
        }
        if (action == "press_key") {
            val key = command.optString("key").lowercase()
            val globalAction = when (key) {
                "back" -> GLOBAL_ACTION_BACK
                "home" -> GLOBAL_ACTION_HOME
                else -> null
            }
            if (globalAction == null) sendResult(command, false, "Only back and home are safely supported keys")
            else { val success = performGlobalAction(globalAction); sendResult(command, success, if (success) null else "Global $key action was rejected"); if (success) scheduleScreenRefresh() }
            return
        }
        if (action == "swipe") { performSwipe(command); return }
        val target = resolveCurrentNode(command) ?: return
        val actionResult = performNodeAction(target, action, command)
        sendResult(command, actionResult.first, actionResult.second)
        if (actionResult.first) scheduleScreenRefresh()
    }

    /** Launch with the same reliable launcher intent as the pre-generic app, then verify it. */
    private fun openApp(command: JSONObject, targetPackage: String) {
        if (targetPackage.isBlank()) {
            sendResult(command, false, "Missing package name")
            return
        }
        log("open_app requested: $targetPackage")
        val launchIntent = packageManager.getLaunchIntentForPackage(targetPackage)
            ?: Intent(Intent.ACTION_MAIN)
                .addCategory(Intent.CATEGORY_LAUNCHER)
                .setPackage(targetPackage)
                .resolveActivity(packageManager)
                ?.let { component -> Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER).setComponent(component) }

        log("launch intent found: ${launchIntent != null}")
        if (launchIntent == null) {
            sendResult(command, false, "No launch intent found for $targetPackage", extra = JSONObject().put("package", targetPackage).put("verified", false))
            return
        }
        try {
            launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(launchIntent)
            log("startActivity called")
            verifyLaunchedApp(command, targetPackage, attemptsRemaining = 3)
        } catch (error: Exception) {
            log("FAILED to launch $targetPackage: ${error.message}")
            sendResult(command, false, "Failed to launch $targetPackage: ${error.message}", extra = JSONObject().put("package", targetPackage).put("verified", false))
        }
    }

    private fun verifyLaunchedApp(command: JSONObject, targetPackage: String, attemptsRemaining: Int) {
        handler.postDelayed({
            val activePackage = rootInActiveWindow?.packageName?.toString()
            log("active package after launch: ${activePackage ?: "none"}")
            if (activePackage == targetPackage) {
                sendResult(command, true, extra = JSONObject().put("package", targetPackage).put("verified", true))
                emitScreenSnapshot("app_launch_verified")
            } else if (attemptsRemaining > 0) {
                verifyLaunchedApp(command, targetPackage, attemptsRemaining - 1)
            } else {
                sendResult(command, false, "${targetPackage} did not become the active window (active: ${activePackage ?: "none"})", extra = JSONObject().put("package", targetPackage).put("verified", false))
            }
        }, 500)
    }

    /** Re-finds each target from the latest root; no node object is retained. */
    private fun resolveCurrentNode(command: JSONObject): AccessibilityNodeInfo? {
        val snapshot = lastSnapshot
        val nodeId = command.optString("node_id")
        if (snapshot == null || nodeId.isBlank()) { sendResult(command, false, "Missing node_id or no screen snapshot. Request read_screen first.", true); return null }
        if (command.optString("snapshot_id").let { it.isNotBlank() && it != snapshot.id }) { sendResult(command, false, "Stale snapshot; request a fresh screen.", true); return null }
        val ref = snapshot.nodes[nodeId]
        if (ref == null) { sendResult(command, false, "Node no longer exists in the latest snapshot.", true); return null }
        val root = rootInActiveWindow
        if (root == null || root.packageName?.toString() != ref.packageName) { sendResult(command, false, "The active app changed; request a fresh screen.", true); return null }
        val current = nodeAtPath(root, ref.path)
        if (current == null || fingerprint(current) != ref.fingerprint) { sendResult(command, false, "Node is stale after a UI change; request a fresh screen.", true); return null }
        return current
    }

    private fun performNodeAction(node: AccessibilityNodeInfo, action: String, command: JSONObject): Pair<Boolean, String?> {
        if (!node.isVisibleToUser) return Pair(false, "Node is not visible")
        if (!node.isEnabled && action !in setOf("focus", "scroll")) return Pair(false, "Node is disabled")
        val accessibilityAction = when (action) {
            "click", "play", "pause", "next", "previous" -> AccessibilityNodeInfo.ACTION_CLICK
            "long_click" -> AccessibilityNodeInfo.ACTION_LONG_CLICK
            "focus" -> AccessibilityNodeInfo.ACTION_FOCUS
            "select" -> AccessibilityNodeInfo.ACTION_SELECT
            "expand" -> AccessibilityNodeInfo.ACTION_EXPAND
            "collapse" -> AccessibilityNodeInfo.ACTION_COLLAPSE
            "dismiss" -> AccessibilityNodeInfo.ACTION_DISMISS
            "scroll", "page_down" -> if (command.optString("direction", "down") == "up") AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD else AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
            "page_up" -> AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD
            "clear_text", "type_text" -> AccessibilityNodeInfo.ACTION_SET_TEXT
            "seek" -> AccessibilityNodeInfo.AccessibilityAction.ACTION_SET_PROGRESS.id
            else -> return Pair(false, "Unsupported node action: $action")
        }
        if (!hasAction(node, accessibilityAction)) return Pair(false, "Node does not support $action")
        val args = if (action == "type_text" || action == "clear_text") Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, if (action == "clear_text") "" else command.optString("text"))
        } else if (action == "seek") {
            val range = node.rangeInfo ?: return Pair(false, "This control does not expose a seek range")
            val percent = command.optDouble("percent", -1.0)
            if (percent !in 0.0..100.0) return Pair(false, "Seek percent must be from 0 to 100")
            Bundle().apply { putFloat(AccessibilityNodeInfo.ACTION_ARGUMENT_PROGRESS_VALUE, (range.max - range.min) * (percent / 100.0).toFloat() + range.min) }
        } else null
        val success = node.performAction(accessibilityAction, args)
        return Pair(success, if (success) null else "Android rejected $action")
    }

    private fun performSwipe(command: JSONObject) {
        val from = command.optJSONArray("from"); val to = command.optJSONArray("to")
        if (from == null || to == null || from.length() < 2 || to.length() < 2) { sendResult(command, false, "Swipe requires from and to [x, y] coordinates"); return }
        val path = Path().apply { moveTo(from.getDouble(0).toFloat(), from.getDouble(1).toFloat()); lineTo(to.getDouble(0).toFloat(), to.getDouble(1).toFloat()) }
        val gesture = GestureDescription.Builder().addStroke(GestureDescription.StrokeDescription(path, 0, command.optLong("duration_ms", 300))).build()
        val started = dispatchGesture(gesture, object : GestureResultCallback() {
            override fun onCompleted(gestureDescription: GestureDescription?) { sendResult(command, true); scheduleScreenRefresh() }
            override fun onCancelled(gestureDescription: GestureDescription?) { sendResult(command, false, "Swipe was cancelled") }
        }, null)
        if (!started) sendResult(command, false, "Android could not start the swipe")
    }

    private fun emitScreenSnapshot(reason: String): Snapshot? {
        val root = rootInActiveWindow ?: return null
        val snapshotId = "s_${UUID.randomUUID().toString().replace("-", "").take(12)}"
        val nodes = JSONArray(); val refs = linkedMapOf<String, NodeRef>(); var index = 0
        fun walk(node: AccessibilityNodeInfo?, path: List<Int>, parentId: String?) {
            if (node == null || index >= MAX_NODES) return
            val include = isUseful(node); val id = if (include) "n_${index++}" else null
            if (id != null) {
                val bounds = Rect().also { node.getBoundsInScreen(it) }
                nodes.put(JSONObject().put("id", id).put("parent_id", parentId ?: JSONObject.NULL).put("path", JSONArray(path))
                    .put("text", node.text?.toString() ?: "").put("content_description", node.contentDescription?.toString() ?: "")
                    .put("hint_text", node.hintText?.toString() ?: "").put("view_id", node.viewIdResourceName ?: "")
                    .put("class_name", node.className?.toString() ?: "").put("package", node.packageName?.toString() ?: "")
                    .put("clickable", node.isClickable).put("long_clickable", node.isLongClickable).put("scrollable", node.isScrollable)
                    .put("editable", node.isEditable).put("focusable", node.isFocusable).put("focused", node.isFocused)
                    .put("selected", node.isSelected).put("checked", node.isChecked).put("enabled", node.isEnabled)
                    .put("visible", node.isVisibleToUser).put("password", node.isPassword)
                    .put("bounds", JSONArray(listOf(bounds.left, bounds.top, bounds.right, bounds.bottom))).put("actions", actionNames(node)))
                refs[id] = NodeRef(id, path, fingerprint(node), root.packageName?.toString() ?: "")
            }
            for (childIndex in 0 until node.childCount) walk(node.getChild(childIndex), path + childIndex, id ?: parentId)
        }
        walk(root, emptyList(), null)
        val snapshot = Snapshot(snapshotId, root.packageName?.toString() ?: "", refs); lastSnapshot = snapshot
        val payload = JSONObject().put("type", "screen_snapshot").put("snapshot_id", snapshotId).put("package", snapshot.packageName)
            .put("reason", reason).put("truncated", index >= MAX_NODES).put("node_count", nodes.length()).put("nodes", nodes)
        broadcast(ACTION_SCREEN, payload); log("Screen changed: package=${snapshot.packageName} nodes=${nodes.length()} reason=$reason")
        return snapshot
    }

    private fun isUseful(node: AccessibilityNodeInfo) = node.isVisibleToUser && (node.text?.isNotBlank() == true || node.contentDescription?.isNotBlank() == true || node.hintText?.isNotBlank() == true || node.viewIdResourceName?.isNotBlank() == true || node.isClickable || node.isLongClickable || node.isScrollable || node.isEditable || node.isFocusable || node.actionList.isNotEmpty())
    private fun actionNames(node: AccessibilityNodeInfo): JSONArray { val map: Map<Int, String> = mapOf(AccessibilityNodeInfo.ACTION_CLICK to "CLICK", AccessibilityNodeInfo.ACTION_LONG_CLICK to "LONG_CLICK", AccessibilityNodeInfo.ACTION_SET_TEXT to "SET_TEXT", AccessibilityNodeInfo.AccessibilityAction.ACTION_SET_PROGRESS.id to "SET_PROGRESS", AccessibilityNodeInfo.ACTION_FOCUS to "FOCUS", AccessibilityNodeInfo.ACTION_SCROLL_FORWARD to "SCROLL_FORWARD", AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD to "SCROLL_BACKWARD", AccessibilityNodeInfo.ACTION_SELECT to "SELECT", AccessibilityNodeInfo.ACTION_EXPAND to "EXPAND", AccessibilityNodeInfo.ACTION_COLLAPSE to "COLLAPSE", AccessibilityNodeInfo.ACTION_DISMISS to "DISMISS"); return JSONArray(node.actionList.mapNotNull { map[it.id] }) }
    private fun hasAction(node: AccessibilityNodeInfo, id: Int) = node.actionList.any { it.id == id }
    private fun fingerprint(node: AccessibilityNodeInfo) = listOf(node.className, node.viewIdResourceName, node.text, node.contentDescription).joinToString("|") { it?.toString() ?: "" }
    private fun nodeAtPath(root: AccessibilityNodeInfo, path: List<Int>): AccessibilityNodeInfo? { var current: AccessibilityNodeInfo? = root; for (index in path) current = current?.getChild(index); return current }
    private fun sendResult(command: JSONObject, success: Boolean, error: String? = null, refresh: Boolean = false, extra: JSONObject? = null) { val payload = JSONObject().put("type", "android_action_result").put("success", success).put("action", command.optString("action")).put("node_id", command.optString("node_id")).put("request_id", command.optString("request_id")).put("refresh_required", refresh).put("retry_recommended", refresh); if (error != null) payload.put("error", error); if (extra != null) for (key in extra.keys()) payload.put(key, extra.get(key)); broadcast(ACTION_RESULT, payload); log("Action result: ${command.optString("action")} ${if (success) "SUCCESS" else "FAILED: $error"}") }
    private fun broadcast(action: String, data: JSONObject) { sendBroadcast(Intent(action).setPackage(packageName).putExtra("data", data.toString())) }
    private fun log(message: String) = android.util.Log.i("TeloAccessibility", message)
    override fun onInterrupt() = Unit
    override fun onDestroy() { try { unregisterReceiver(commandReceiver) } catch (_: Exception) {}; super.onDestroy() }
}
