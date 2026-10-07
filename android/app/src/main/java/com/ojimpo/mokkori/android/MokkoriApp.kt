package com.ojimpo.mokkori.android

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ojimpo.mokkori.core.DemoData
import com.ojimpo.mokkori.core.DemoSession
import com.ojimpo.mokkori.core.HapticPattern
import com.ojimpo.mokkori.core.SwimReport
import java.text.NumberFormat
import java.util.Locale
import kotlin.math.roundToInt

private val Ink = Color(0xFF081A24)
private val Panel = Color(0xFF102A36)
private val Aqua = Color(0xFF50DDD0)
private val Distance = Color(0xFF72BAFF)
private val Time = Color(0xFFFFB36A)
private val Stroke = Color(0xFF8DE09A)
private val Swolf = Color(0xFFD1A7FF)
private val Muted = Color(0xFFABC0C9)

@Composable fun MokkoriTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = darkColorScheme(
        primary = Aqua, onPrimary = Ink, background = Ink, surface = Ink,
        surfaceVariant = Panel, onSurface = Color(0xFFF2F7FA), onSurfaceVariant = Muted,
        secondary = Distance, secondaryContainer = Color(0xFF1C4A50), onSecondaryContainer = Aqua, error = Color(0xFFFFB4AB)
    ), content = content)
}

private fun clock(seconds: Double): String {
    val value = seconds.coerceAtLeast(0.0).roundToInt()
    return if (value >= 3600) "%d:%02d:%02d".format(Locale.US, value / 3600, value / 60 % 60, value % 60)
    else "%d:%02d".format(Locale.US, value / 60, value % 60)
}
private fun meters(value: Double) = NumberFormat.getIntegerInstance(Locale.JAPAN).format(value.roundToInt())

@OptIn(ExperimentalMaterial3Api::class)
@Composable fun MokkoriApp(model: DemoModel) {
    var tab by rememberSaveable { mutableStateOf("log") }
    var selectedId by rememberSaveable { mutableStateOf<String?>(null) }
    var page by rememberSaveable { mutableStateOf("report") }
    val session = model.sessions.firstOrNull { it.id == selectedId }
    val inDetail = tab == "log" && session != null
    fun back() { if (page != "report") page = "report" else selectedId = null }
    BackHandler(inDetail) { back() }
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Column {
                    Text(if (tab == "device") "Mokkori IQ" else if (!inDetail) "ログ" else when(page) {
                        "laps" -> "ラップを確認"; "strava" -> "Strava プレビュー"; else -> "プールスイム"
                    }, fontWeight = FontWeight.Bold)
                    if (!inDetail) Text("ANDROID PROTOTYPE  /  01", fontSize = 10.sp, color = Muted, letterSpacing = 1.sp)
                } },
                navigationIcon = { if (inDetail) IconButton(onClick = { back() }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "戻る") } },
                actions = { Text("DEMO", color = Aqua, fontSize = 11.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(end = 20.dp)) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Ink)
            )
        },
        bottomBar = {
            NavigationBar(containerColor = Panel) {
                NavigationBarItem(selected = tab == "device", onClick = { tab = "device" },
                    icon = { Icon(Icons.Default.Sensors, null) }, label = { Text("デバイス") }, modifier = Modifier.testTag("tab-device"))
                NavigationBarItem(selected = tab == "log", onClick = { tab = "log" },
                    icon = { Icon(Icons.Default.Pool, null) }, label = { Text("ログ") }, modifier = Modifier.testTag("tab-log"))
            }
        }
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            Text("デモモード · 架空のデータで画面を試せます", color = Aqua, fontSize = 12.sp,
                modifier = Modifier.fillMaxWidth().background(Aqua.copy(alpha = .08f)).padding(horizontal = 20.dp, vertical = 9.dp))
            when {
                tab == "device" -> DeviceScreen(model)
                session == null -> LogScreen(model.sessions) { selectedId = it.id; page = "report" }
                page == "laps" -> LapsScreen(session.report)
                page == "strava" -> StravaScreen(session)
                else -> ReportScreen(session, onLaps = { page = "laps" }, onStrava = { page = "strava" })
            }
        }
    }
    model.notice?.let { message ->
        AlertDialog(onDismissRequest = model::dismissNotice, title = { Text("デモの操作結果") },
            text = { Text(message) }, confirmButton = { TextButton(onClick = model::dismissNotice) { Text("閉じる") } })
    }
}

@Composable private fun LogScreen(sessions: List<DemoSession>, open: (DemoSession) -> Unit) {
    val totalDistance = sessions.sumOf { it.report.distance }
    val totalTime = sessions.sumOf { it.report.movingTime }
    LazyColumn(Modifier.fillMaxSize().testTag("log-screen"), contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        item {
            Column {
                Text("水の中の積み重ね。", fontSize = 27.sp, fontWeight = FontWeight.Bold)
                Text("泳いだ距離も、ひとつずつのラップも。", color = Muted, fontSize = 13.sp, modifier = Modifier.padding(top = 7.dp))
            }
        }
        item { SurfaceCard {
            Text("これまでの記録  /  DEMO", fontSize = 11.sp, color = Muted, letterSpacing = 1.sp)
            Spacer(Modifier.height(18.dp))
            Metric("累計距離", meters(totalDistance), "m", Distance, large = true)
            DividerLine()
            Row {
                Metric("累計タイム", clock(totalTime), "", Time, modifier = Modifier.weight(1f))
                Metric("平均ペース", if (totalDistance > 0) clock(totalTime / totalDistance * 100) else "—", "/100m", Aqua, modifier = Modifier.weight(1f))
            }
        } }
        item { SectionTitle("セッション", "${sessions.size} 件") }
        if (sessions.isEmpty()) item { Text("ログがありません。デバイスタブからデモログを取り込めます", color = Muted) }
        itemsIndexed(sessions, key = { _, s -> s.id }) { _, session ->
            Card(onClick = { open(session) }, colors = CardDefaults.cardColors(containerColor = Panel), shape = RoundedCornerShape(18.dp), modifier = Modifier.fillMaxWidth().testTag("session-${session.id}")) {
                Column(Modifier.padding(18.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Default.Pool, null, tint = Aqua, modifier = Modifier.size(23.dp))
                        Spacer(Modifier.width(10.dp))
                        Text(session.dateLabel, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                        Text("デモ", fontSize = 10.sp, color = Muted)
                        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = Muted)
                    }
                    Spacer(Modifier.height(16.dp))
                    Row(verticalAlignment = Alignment.Bottom) {
                        Text(meters(session.report.distance), fontSize = 28.sp, fontWeight = FontWeight.Bold, color = Distance)
                        Text(" m", color = Distance, modifier = Modifier.padding(bottom = 4.dp))
                        Spacer(Modifier.weight(1f))
                        Column(horizontalAlignment = Alignment.End) {
                            Text(clock(session.report.movingTime), fontWeight = FontWeight.Medium, color = Time)
                            Text("${clock(session.report.pace100)} /100m", fontSize = 12.sp, color = Aqua)
                        }
                    }
                    Text("${session.report.poolLength.toInt()}m プール · ${session.report.laps.size} ラップ · ${session.report.sets.size} セット", color = Muted, fontSize = 12.sp, modifier = Modifier.padding(top = 8.dp))
                }
            }
        }
        item { Note("ここにある記録はすべて架空のサンプルです。実データの取り込みと解析エンジンは次の移植段階です") }
    }
}

@Composable private fun ReportScreen(session: DemoSession, onLaps: () -> Unit, onStrava: () -> Unit) {
    val report = session.report
    LazyColumn(Modifier.fillMaxSize().testTag("report-screen"), contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        item { Text("${session.dateLabel} · ${report.poolLength.toInt()}m プール · デモ", color = Muted, fontSize = 13.sp) }
        item { SurfaceCard {
            Row {
                Metric("距離", meters(report.distance), "m", Distance, modifier = Modifier.weight(1f))
                Metric("タイム", clock(report.movingTime), "", Time, modifier = Modifier.weight(1f))
            }
            DividerLine()
            Row {
                Metric("平均ペース", clock(report.pace100), "/100m", Aqua, modifier = Modifier.weight(1f))
                Metric("経過時間", clock(report.elapsed), "", Muted, modifier = Modifier.weight(1f))
            }
            DividerLine()
            Row {
                Metric("ストローク", report.strokesTotal.toString(), "", Stroke, modifier = Modifier.weight(1f))
                Metric("平均 SWOLF", report.swolfAverage?.roundToInt()?.toString() ?: "—", "", Swolf, modifier = Modifier.weight(1f))
            }
        } }
        item { Button(onClick = onLaps, modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp)) { Icon(Icons.Default.Checklist, null); Spacer(Modifier.width(8.dp)); Text("ラップを確認") } }
        item { SectionTitle("ペースの推移", "1 ラップ = 25m") }
        item { SurfaceCard { PaceGraph(report) } }
        item { SectionTitle("セット", "大休憩で区切られた塊") }
        itemsIndexed(report.sets) { _, set ->
            SurfaceCard {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("${set.index}", color = Aqua, fontSize = 20.sp, fontWeight = FontWeight.Bold, modifier = Modifier.width(32.dp))
                    Text("${meters(set.distance)} m", color = Distance, modifier = Modifier.weight(1f))
                    Text(clock(set.movingTime), color = Time, modifier = Modifier.weight(1f))
                    Text("${clock(set.pace100)} /100m", color = Aqua, fontSize = 12.sp)
                }
            }
        }
        item { SectionTitle("インターバル", "レストで区切られた連続泳ぎ") }
        item { SurfaceCard {
            report.intervals.forEachIndexed { i, interval ->
                if (i > 0) DividerLine()
                Row {
                    Text("S${interval.setNumber}-${interval.number}", color = Muted, modifier = Modifier.width(52.dp))
                    Text("${interval.laps} ラップ", modifier = Modifier.weight(1f))
                    Text("${meters(interval.laps * report.poolLength)} m", color = Distance, modifier = Modifier.weight(1f))
                    Text(clock(interval.swimTime), color = Time)
                }
            }
        } }
        item { OutlinedButton(onClick = onStrava, modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp)) { Text("Strava の投稿プレビュー") } }
        item { Note("表示値は画面確認用です。Swift の壁検出・レポート集計・人手修正の移植はまだ含まれません") }
    }
}

@Composable private fun PaceGraph(report: SwimReport) {
    val values = report.laps.map { it.duration / report.poolLength * 100 }
    val lo = minOf(values.minOrNull() ?: report.pace100, report.pace100 - 10) - 1
    val hi = maxOf(values.maxOrNull() ?: report.pace100, report.pace100 + 10) + 1
    Text("横軸：ペース /100m · 上から泳いだ順", fontSize = 11.sp, color = Muted)
    Spacer(Modifier.height(14.dp))
    Canvas(Modifier.fillMaxWidth().height(220.dp).semantics {
        contentDescription = "${report.laps.size}ラップのペースグラフ。平均${clock(report.pace100)}毎100メートル。数値はラップ画面で確認できます"
    }) {
        val row = size.height / values.size.coerceAtLeast(1)
        values.forEachIndexed { i, value ->
            drawRoundRect(Aqua.copy(alpha = .75f), Offset(0f, i * row), Size(((value - lo) / (hi - lo)).toFloat() * size.width, (row - 2f).coerceAtLeast(1f)), androidx.compose.ui.geometry.CornerRadius(2f))
        }
        val x = ((report.pace100 - lo) / (hi - lo)).toFloat() * size.width
        drawLine(Time, Offset(x, 0f), Offset(x, size.height), strokeWidth = 2f)
    }
    Spacer(Modifier.height(9.dp))
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) { Text(clock(lo), fontSize = 11.sp, color = Muted); Text("平均 ${clock(report.pace100)}", fontSize = 11.sp, color = Time); Text(clock(hi), fontSize = 11.sp, color = Muted) }
    Text("軸は 0 始まりではありません。長いバーほど遅いペース", fontSize = 10.sp, color = Muted, modifier = Modifier.padding(top = 10.dp))
}

@Composable private fun LapsScreen(report: SwimReport) {
    LazyColumn(Modifier.fillMaxSize().testTag("laps-screen"), contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        item { Note("1ラップ = プールの片道 ${report.poolLength.toInt()}m。今回は確認用です。ターン修正は解析エンジン移植後に対応します") }
        item { Row { Text("ラップ", color = Muted, modifier = Modifier.weight(1f)); Text("タイム / ストローク / SWOLF", color = Muted, fontSize = 11.sp) } }
        itemsIndexed(report.laps) { i, lap ->
            SurfaceCard {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) { Text("${i + 1}", fontWeight = FontWeight.Bold); Text("S${lap.setNumber} · インターバル ${lap.interval}", fontSize = 10.sp, color = Muted) }
                    Text("%.1fs".format(Locale.US, lap.duration), color = Time, modifier = Modifier.width(64.dp))
                    Text(lap.strokes.toString(), color = Stroke, modifier = Modifier.width(40.dp))
                    Text("%.1f".format(Locale.US, lap.swolf), color = Swolf)
                }
            }
        }
    }
}

@Composable private fun StravaScreen(session: DemoSession) {
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
        item { Note("プレビュー専用です。このアプリにはネットワーク権限がなく、Strava に送信されません") }
        item { SurfaceCard {
            Text("投稿内容", fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(18.dp))
            Text("プールスイム（デモ）", fontSize = 22.sp, fontWeight = FontWeight.Bold)
            Text("${meters(session.report.distance)} m · ${clock(session.report.movingTime)} · ${clock(session.report.pace100)} /100m", color = Aqua, modifier = Modifier.padding(top = 12.dp))
            Text("時刻アンカー：未設定（架空の記録）", color = Muted, modifier = Modifier.padding(top = 18.dp))
        } }
        item { Button(onClick = {}, enabled = false, modifier = Modifier.fillMaxWidth()) { Text("Strava への送信は未対応") } }
    }
}

@Composable private fun DeviceScreen(model: DemoModel) {
    var eraseConfirmation by rememberSaveable { mutableStateOf(false) }
    var scenarioMenu by remember { mutableStateOf(false) }
    val connected = model.connection == DemoConnection.CONNECTED
    val status = DemoData.deviceStatus
    LazyColumn(Modifier.fillMaxSize().testTag("device-screen"), contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        item { SurfaceCard {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(if (connected) Icons.Default.Sensors else Icons.Default.BluetoothDisabled, null, tint = if (connected) Aqua else Muted, modifier = Modifier.size(32.dp))
                Spacer(Modifier.width(13.dp))
                Column(Modifier.weight(1f)) { Text(model.connection.label, fontWeight = FontWeight.SemiBold); Text(model.connection.detail, color = Muted, fontSize = 11.sp) }
            }
            Spacer(Modifier.height(8.dp))
            Box {
                TextButton(onClick = { scenarioMenu = true }, modifier = Modifier.testTag("connection-scenario")) { Text("接続状態を試す"); Icon(Icons.Default.ExpandMore, null) }
                DropdownMenu(expanded = scenarioMenu, onDismissRequest = { scenarioMenu = false }) {
                    DemoConnection.entries.forEach { state -> DropdownMenuItem(text = { Text(state.label) }, onClick = { model.updateConnection(state); scenarioMenu = false }) }
                }
            }
        } }
        item { SectionTitle("記録データ", "デモ本体") }
        item { SurfaceCard {
            Row {
                Metric("記録時間", if (!connected) "—" else if (model.memoryErased) "0:00" else clock(status.recordedSeconds ?: 0.0), "", Time, modifier = Modifier.weight(1f))
                Metric("バッテリー", if (connected) "${status.batteryPercent}" else "—", if (connected) "%" else "", Stroke, modifier = Modifier.weight(1f))
            }
            Spacer(Modifier.height(20.dp))
            Row { Text("メモリー使用量", fontSize = 12.sp, color = Muted, modifier = Modifier.weight(1f)); Text(if (!connected) "—" else if (model.memoryErased) "0%" else "${((status.usedFraction ?: 0.0) * 100).roundToInt()}%", color = Distance, fontSize = 12.sp) }
            Spacer(Modifier.height(8.dp))
            LinearProgressIndicator(progress = { if (!connected || model.memoryErased) 0f else (status.usedFraction ?: 0.0).toFloat() }, modifier = Modifier.fillMaxWidth(), color = Distance)
            Spacer(Modifier.height(20.dp))
            model.progress?.let { p ->
                Text("取り込み中 $p%", color = Aqua, modifier = Modifier.testTag("transfer-progress"))
                LinearProgressIndicator(progress = { p / 100f }, modifier = Modifier.fillMaxWidth().padding(top = 8.dp))
                TextButton(onClick = { model.cancelTransfer() }) { Text("取り込みを中止") }
            } ?: Button(onClick = model::importDemo, enabled = model.canUseDevice && !model.memoryErased, modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp).testTag("import-demo")) {
                Icon(Icons.Default.Download, null); Spacer(Modifier.width(8.dp)); Text("デモログを取り込む")
            }
            Text("取り込んでもメモリーは消えません", color = Muted, fontSize = 11.sp, modifier = Modifier.padding(top = 8.dp))
        } }
        item { SurfaceCard {
            ActionRow("いま合わせ直す", "デモの時刻合わせ", Icons.Default.Schedule, model.canUseDevice, model::syncClock)
            HorizontalDivider(color = Muted.copy(alpha = .14f))
            ActionRow("デモメモリーを消去", "取り込み済みのログは残ります", Icons.Default.DeleteOutline, model.canUseDevice, { eraseConfirmation = true })
            if (model.memoryErased) TextButton(onClick = model::restoreDemoMemory) { Text("デモ本体のデータを戻す") }
        } }
        item { Note("実機の BLE 接続・CSV 取り込み・時刻送信は未実装です。水上で使う元の iPhone 版の操作を、ここではデモで試せます") }
        item { SectionTitle("振動フィードバック", "3 パターン × 距離") }
        item { SurfaceCard {
            HapticPattern.entries.forEachIndexed { i, pattern ->
                if (i > 0) DividerLine()
                HapticRow(pattern.label, pattern.shape, model.triggers[i], model.canUseDevice,
                    onDistance = { model.setTrigger(i, it) }, onPreview = { model.previewHaptic(i) })
            }
            Spacer(Modifier.height(15.dp))
            Text("強さ ${model.strength}%", color = Muted, fontSize = 12.sp)
            Slider(value = model.strength.toFloat(), onValueChange = { model.updateStrength(it.roundToInt()) }, valueRange = 0f..100f, steps = 19)
            if (model.triggers.filter { it > 0 }.let { it.size != it.toSet().size }) Text("同じ距離が複数のパターンに割り当てられています", color = Time, fontSize = 12.sp)
            Text("設定はこのアプリに保存されます。デモ操作では本体にもスマホにも振動を送信しません", color = Muted, fontSize = 11.sp)
        } }
        item { SurfaceCard {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) { Text("転送エラーを試す", fontSize = 13.sp); Text("次の取り込みを途中で失敗させます", fontSize = 11.sp, color = Muted) }
                Switch(checked = model.failNextTransfer, onCheckedChange = model::failNext, enabled = model.progress == null, modifier = Modifier.testTag("fail-next-transfer"))
            }
        } }
    }
    if (eraseConfirmation) AlertDialog(onDismissRequest = { eraseConfirmation = false },
        title = { Text("デモメモリーを空にしますか？") }, text = { Text("架空の本体データだけを空にします。取り込み済みのログは残り、あとでデモデータを戻せます") },
        confirmButton = { TextButton(onClick = { model.eraseDemoMemory(); eraseConfirmation = false }) { Text("空にする") } },
        dismissButton = { TextButton(onClick = { eraseConfirmation = false }) { Text("やめる") } })
}

@Composable private fun HapticRow(label: String, shape: String, distance: Int, enabled: Boolean, onDistance: (Int) -> Unit, onPreview: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) { Text(label, fontSize = 13.sp, fontWeight = FontWeight.SemiBold); Text(shape, fontSize = 11.sp, color = Muted) }
        Box {
            TextButton(onClick = { menu = true }, modifier = Modifier.testTag("distance-$label")) { Text(if (distance == 0) "未設定" else "${distance}m ごと", fontSize = 12.sp) }
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                listOf(0,25,50,100,200,500,1000).forEach { m -> DropdownMenuItem(text = { Text(if (m == 0) "未設定" else "${m}m ごと") }, onClick = { onDistance(m); menu = false }) }
            }
        }
        IconButton(onClick = onPreview, enabled = enabled) { Icon(Icons.Default.PlayArrow, "$label をデモで試す") }
    }
}

@Composable private fun SurfaceCard(content: @Composable ColumnScope.() -> Unit) {
    Surface(shape = RoundedCornerShape(18.dp), color = Panel, modifier = Modifier.fillMaxWidth()) { Column(Modifier.padding(18.dp), content = content) }
}
@Composable private fun Metric(label: String, value: String, unit: String, color: Color, modifier: Modifier = Modifier, large: Boolean = false) {
    Column(modifier) {
        Text(label, color = Muted, fontSize = 12.sp)
        Row(verticalAlignment = Alignment.Bottom, modifier = Modifier.padding(top = 4.dp)) {
            Text(value, color = color, fontSize = if (large) 48.sp else 27.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
            if (unit.isNotEmpty()) Text(" $unit", color = color, fontSize = 11.sp, modifier = Modifier.padding(bottom = if (large) 9.dp else 5.dp))
        }
    }
}
@Composable private fun DividerLine() { HorizontalDivider(Modifier.padding(vertical = 16.dp), color = Muted.copy(alpha = .14f)) }
@Composable private fun SectionTitle(title: String, detail: String) { Column { Text(title, fontSize = 17.sp, fontWeight = FontWeight.Bold); if (detail.isNotEmpty()) Text(detail, color = Muted, fontSize = 11.sp, modifier = Modifier.padding(top = 4.dp)) } }
@Composable private fun Note(text: String) { Text(text, color = Muted, fontSize = 12.sp, lineHeight = 19.sp) }
@Composable private fun ActionRow(title: String, subtitle: String, icon: ImageVector, enabled: Boolean, action: () -> Unit) {
    TextButton(onClick = action, enabled = enabled, contentPadding = PaddingValues(vertical = 12.dp), modifier = Modifier.fillMaxWidth()) {
        Icon(icon, null, modifier = Modifier.size(22.dp)); Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f), horizontalAlignment = Alignment.Start) { Text(title); Text(subtitle, color = Muted, fontSize = 10.sp) }
    }
}
