package com.ojimpo.mokkori.android

import android.app.Application
import android.content.SharedPreferences
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.core.content.edit
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.ojimpo.mokkori.core.DemoData
import com.ojimpo.mokkori.core.DemoSession
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Explicitly fake device states. No platform Bluetooth service is touched. */
enum class DemoConnection(val label: String, val detail: String) {
    CONNECTED("デモ本体に接続中", "架空のデバイスです。実機には接続していません"),
    DISCONNECTED("未接続", "本体のスイッチが入っているか確認してください"),
    BLUETOOTH_OFF("Bluetooth がオフです", "Bluetooth オフ時の表示を再現しています"),
    PERMISSION_DENIED("Bluetooth が許可されていません", "権限がない場合の表示を再現しています"),
}

/** Small persistence boundary. Demo identities cannot be mistaken for captured recordings. */
class DemoPreferences(private val prefs: SharedPreferences) {
    fun sessionIds(): Set<String> = prefs.getStringSet("demo.sessionIds", null)?.toSet()
        ?: DemoData.sessions.take(2).map { it.id }.toSet()
    fun saveSessionIds(ids: Set<String>) { prefs.edit { putStringSet("demo.sessionIds", ids.toSet()) } }
    fun triggers(): List<Int> = (1..3).map { prefs.getInt("demo.haptic.$it", 0) }
    fun saveTriggers(values: List<Int>) {
        prefs.edit { values.forEachIndexed { i, value -> putInt("demo.haptic.${i + 1}", value) } }
    }
    fun strength(): Int = prefs.getInt("demo.strength", 100).coerceIn(0, 100)
    fun saveStrength(value: Int) { prefs.edit { putInt("demo.strength", value) } }
}

class DemoModel(application: Application) : AndroidViewModel(application) {
    private val storage = DemoPreferences(application.getSharedPreferences("mokkori_demo_v1", 0))
    var sessionIds by mutableStateOf(storage.sessionIds()); private set
    val sessions: List<DemoSession> get() = DemoData.sessions.filter { it.id in sessionIds }
    var connection by mutableStateOf(DemoConnection.CONNECTED); private set
    var progress by mutableStateOf<Int?>(null); private set
    var notice by mutableStateOf<String?>(null); private set
    var memoryErased by mutableStateOf(false); private set
    var failNextTransfer by mutableStateOf(false); private set
    var triggers by mutableStateOf(storage.triggers()); private set
    var strength by mutableIntStateOf(storage.strength()); private set
    private var transferJob: Job? = null
    val canUseDevice get() = connection == DemoConnection.CONNECTED && progress == null

    fun updateConnection(value: DemoConnection) {
        if (value != DemoConnection.CONNECTED && progress != null) cancelTransfer("接続が切れました。途中のデータは保存していません")
        connection = value
    }
    fun failNext(value: Boolean) { failNextTransfer = value }
    fun dismissNotice() { notice = null }
    fun importDemo() {
        if (!canUseDevice || memoryErased) return
        progress = 0
        notice = null
        val shouldFail = failNextTransfer
        failNextTransfer = false
        transferJob = viewModelScope.launch {
            for (step in 1..20) {
                delay(100)
                if (shouldFail && step == 10) {
                    progress = null
                    notice = "デモ転送エラー：サンプル番号が連続していません。途中のデータは保存していません。もう一度取り込めます"
                    return@launch
                }
                progress = step * 5
            }
            val id = DemoData.sessions.last().id
            val exists = id in sessionIds
            sessionIds = sessionIds + id
            storage.saveSessionIds(sessionIds)
            progress = null
            notice = if (exists) "このデモログは取り込み済みです。重複は追加していません" else "デモログを取り込みました。ログタブで開けます。本体のデモメモリーは残しています"
        }
    }
    fun cancelTransfer(message: String = "取り込みを中止しました。途中のデータは保存していません") {
        if (progress == null) return
        transferJob?.cancel()
        transferJob = null
        progress = null
        notice = message
    }
    fun eraseDemoMemory() {
        if (!canUseDevice) return
        memoryErased = true
        notice = "デモ本体のメモリーを空にしました。取り込み済みのログは残ります"
    }
    fun restoreDemoMemory() { memoryErased = false; notice = "デモ本体のデータを戻しました" }
    fun syncClock() { if (canUseDevice) notice = "デモの時刻合わせを試しました。実機への送信はありません" }
    fun setTrigger(index: Int, meters: Int) {
        require(index in 0..2 && meters in listOf(0, 25, 50, 100, 200, 500, 1000))
        triggers = triggers.toMutableList().apply { this[index] = meters }
        storage.saveTriggers(triggers)
    }
    fun updateStrength(value: Int) { strength = value.coerceIn(0, 100); storage.saveStrength(strength) }
    fun previewHaptic(index: Int) {
        if (canUseDevice) notice = "振動パターン${index + 1}のデモ操作です。実機のモーターは動きません"
    }
}
