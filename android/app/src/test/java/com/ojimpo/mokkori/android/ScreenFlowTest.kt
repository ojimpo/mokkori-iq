package com.ojimpo.mokkori.android

import android.app.Application
import android.graphics.Bitmap
import android.graphics.Canvas
import androidx.activity.ComponentActivity
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.core.app.ApplicationProvider
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.File

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w412dp-h892dp-xhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class ScreenFlowTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private lateinit var model: DemoModel
    @Before fun before() {
        val app = ApplicationProvider.getApplicationContext<Application>()
        app.getSharedPreferences("mokkori_demo_v1", 0).edit().clear().commit()
        model = DemoModel(app)
        compose.setContent { MokkoriTheme { MokkoriApp(model) } }
    }
    @Test fun logReportLapsAndDeviceNavigation() {
        compose.onNodeWithTag("log-screen").assertExists()
        screenshot("01-log")
        compose.onNodeWithTag("session-demo-1000").performClick()
        compose.onNodeWithTag("report-screen").assertExists()
        screenshot("02-report")
        compose.onNodeWithText("ラップを確認").performClick()
        compose.onNodeWithTag("laps-screen").assertExists()
        screenshot("03-laps")
        compose.onNodeWithContentDescription("戻る").performClick()
        compose.onNodeWithTag("report-screen").assertExists()
        compose.onNodeWithContentDescription("戻る").performClick()
        compose.onNodeWithTag("log-screen").assertExists()
        compose.onNodeWithTag("tab-device").performClick()
        compose.onNodeWithTag("device-screen").assertExists()
        screenshot("04-device")
    }
    @Test fun disconnectedControlsDisableAndReconnect() {
        compose.onNodeWithTag("tab-device").performClick()
        compose.onNodeWithTag("connection-scenario").performClick()
        compose.onNodeWithText("Bluetooth がオフです").performClick()
        compose.onNodeWithTag("import-demo").assertIsNotEnabled()
        compose.onNodeWithTag("connection-scenario").performClick()
        compose.onNodeWithText("デモ本体に接続中").performClick()
        compose.onNodeWithTag("import-demo").assertIsEnabled()
    }
    @Test fun cancelEraseDialogDoesNotErase() {
        compose.onNodeWithTag("tab-device").performClick()
        compose.onNodeWithTag("device-screen").performScrollToNode(hasText("デモメモリーを消去"))
        compose.onNodeWithText("デモメモリーを消去").performClick()
        compose.onNodeWithText("やめる").performClick()
        compose.runOnIdle { org.junit.Assert.assertFalse(model.memoryErased) }
    }
    @Test fun hapticAssignmentFromUiPersists() {
        compose.onNodeWithTag("tab-device").performClick()
        compose.onNodeWithTag("device-screen").performScrollToNode(hasText("振動パターン1"))
        compose.onNodeWithTag("distance-振動パターン1").performClick()
        compose.onNodeWithText("100m ごと").performClick()
        compose.runOnIdle {
            org.junit.Assert.assertEquals(100, model.triggers[0])
            org.junit.Assert.assertEquals(100, DemoModel(ApplicationProvider.getApplicationContext()).triggers[0])
        }
        screenshot("05-haptics")
    }
    @Test fun stravaPreviewCannotPublishAndBackReturnsToReport() {
        compose.onNodeWithTag("session-demo-1000").performClick()
        compose.onNodeWithTag("report-screen").performScrollToNode(hasText("Strava の投稿プレビュー"))
        compose.onNodeWithText("Strava の投稿プレビュー").performClick()
        compose.onNodeWithText("Strava への送信は未対応").assertIsNotEnabled()
        screenshot("06-strava-preview")
        compose.onNodeWithContentDescription("戻る").performClick()
        compose.onNodeWithTag("report-screen").assertExists()
    }
    private fun screenshot(name: String) {
        compose.waitForIdle()
        val directory = File("build/screenshots").apply { mkdirs() }
        compose.runOnIdle {
            val view = compose.activity.window.decorView
            val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
            view.draw(Canvas(bitmap))
            File(directory, "$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        }
    }
}
