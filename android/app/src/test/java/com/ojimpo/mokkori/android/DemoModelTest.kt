package com.ojimpo.mokkori.android

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import com.ojimpo.mokkori.core.DemoData
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.*
import org.junit.*
import org.junit.Assert.*
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class DemoModelTest {
    private val scheduler = TestCoroutineScheduler()
    private val dispatcher = StandardTestDispatcher(scheduler)
    private lateinit var app: Application
    @Before fun before() {
        Dispatchers.setMain(dispatcher)
        app = ApplicationProvider.getApplicationContext()
        app.getSharedPreferences("mokkori_demo_v1", 0).edit().clear().commit()
    }
    @After fun after() { Dispatchers.resetMain() }
    @Test fun importIsAtomicDeduplicatedAndPersisted() {
        val model = DemoModel(app)
        assertEquals(2, model.sessions.size)
        model.importDemo()
        model.importDemo() // double tap cannot start another transfer
        scheduler.advanceTimeBy(1000)
        assertEquals(2, model.sessions.size)
        scheduler.advanceUntilIdle()
        assertEquals(3, model.sessions.size)
        assertFalse(model.memoryErased)
        model.importDemo()
        scheduler.advanceUntilIdle()
        assertEquals(3, model.sessions.size)
        assertEquals(model.sessionIds, DemoModel(app).sessionIds)
    }
    @Test fun cancelledTransferNeverAddsPartialSessionAndCanRetry() {
        val model = DemoModel(app)
        model.importDemo(); scheduler.advanceTimeBy(500)
        model.cancelTransfer(); scheduler.advanceUntilIdle()
        assertNull(model.progress); assertEquals(2, model.sessions.size)
        model.importDemo(); scheduler.advanceUntilIdle()
        assertEquals(3, model.sessions.size)
    }
    @Test fun disconnectAndFailureKeepStoreUntouched() {
        val model = DemoModel(app)
        model.importDemo(); scheduler.advanceTimeBy(500)
        model.updateConnection(DemoConnection.DISCONNECTED); scheduler.advanceUntilIdle()
        assertNull(model.progress); assertEquals(2, model.sessions.size)
        model.importDemo(); scheduler.advanceUntilIdle()
        assertEquals(2, model.sessions.size)
        model.updateConnection(DemoConnection.CONNECTED)
        model.failNext(true); model.importDemo(); scheduler.advanceUntilIdle()
        assertEquals(2, model.sessions.size); assertNull(model.progress)
        assertTrue(model.notice!!.contains("連続していません"))
        model.importDemo(); scheduler.advanceUntilIdle()
        assertEquals(3, model.sessions.size)
    }
    @Test fun eraseOnlyClearsDemoDeviceNotSavedLogs() {
        val model = DemoModel(app)
        model.eraseDemoMemory(); model.importDemo(); scheduler.advanceUntilIdle()
        assertEquals(2, model.sessions.size); assertTrue(model.memoryErased)
        model.restoreDemoMemory(); model.importDemo(); scheduler.advanceUntilIdle()
        assertEquals(3, model.sessions.size)
    }
    @Test fun settingsPersistAndRangesAreBounded() {
        val model = DemoModel(app)
        model.setTrigger(0, 100); model.setTrigger(2, 1000); model.updateStrength(65)
        val reopened = DemoModel(app)
        assertEquals(listOf(100,0,1000), reopened.triggers); assertEquals(65, reopened.strength)
        reopened.updateStrength(200); assertEquals(100, reopened.strength)
        assertThrows(IllegalArgumentException::class.java) { reopened.setTrigger(0, 37) }
    }
    @Test fun initialStoreOnlyContainsSyntheticIds() {
        val model = DemoModel(app)
        assertTrue(model.sessions.all { it.isDemo && it.id.startsWith("demo-") })
        assertEquals(DemoData.sessions.take(2).map { it.id }.toSet(), model.sessionIds)
    }
}
