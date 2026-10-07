package com.ojimpo.mokkori.android

import android.os.Looper
import android.view.ViewGroup
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [23, 35])
class StartupTest {
    @Test fun actualMainActivityLaunches() {
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup().visible()
        shadowOf(Looper.getMainLooper()).idle()
        assertTrue(controller.get().findViewById<ViewGroup>(android.R.id.content).childCount > 0)
        controller.pause().stop().destroy()
    }
}
