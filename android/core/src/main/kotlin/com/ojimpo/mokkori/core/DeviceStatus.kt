package com.ojimpo.mokkori.core

/** Unknown values stay null until a real status read (or explicit demo fixture). */
data class DeviceStatus(
    val version: Int? = null,
    val batteryPercent: Int? = null,
    val batteryMillivolts: Int? = null,
    val charging: Boolean? = null,
    val samples: Long? = null,
    val capacitySamples: Long? = null,
    val sampleRate: Double = 52.0,
    val isLogging: Boolean = false,
    val isUsbConnected: Boolean = false,
    val isFull: Boolean = false,
    val isErasing: Boolean = false,
    val isDumping: Boolean = false,
    val isImuOk: Boolean = false,
    val isFlashOk: Boolean = false,
    val hapticStrengthPercent: Int? = null,
    val lastAnchorEpochMillis: Long? = null,
    val lastAnchorIndex: Long? = null,
    val uptimeMillis: Long? = null,
    val dumpProgressSamples: Long? = null,
) {
    val isKnown: Boolean get() = batteryPercent != null || samples != null
    /** Fractional Unix seconds at sample zero. Keep Double precision, as on iOS. */
    val startEpoch: Double?
        get() {
            val epoch = lastAnchorEpochMillis ?: return null
            val index = lastAnchorIndex ?: return null
            return if (sampleRate > 0) epoch / 1000.0 - index / sampleRate else null
        }
    val usedFraction: Double?
        get() {
            val count = samples ?: return null
            val capacity = capacitySamples ?: return null
            return if (capacity > 0) (count.toDouble() / capacity).coerceIn(0.0, 1.0) else null
        }
    val remainingSeconds: Double?
        get() {
            val count = samples ?: return null
            val capacity = capacitySamples ?: return null
            return if (sampleRate > 0) (capacity - count).coerceAtLeast(0).toDouble() / sampleRate else null
        }
    val recordedSeconds: Double?
        get() = samples?.takeIf { sampleRate > 0 }?.let { it / sampleRate }
}

enum class HapticPattern(val number: Int, val label: String, val shape: String, val pulsesMs: List<Int>) {
    ONE(1, "振動パターン1", "短く1回", listOf(180)),
    TWO(2, "振動パターン2", "短く2回", listOf(180, 140, 180)),
    THREE(3, "振動パターン3", "長く1回", listOf(700)),
}

data class HapticSettings(
    val triggers: List<Int?> = listOf(null, null, null),
    val strengthPercent: Int = 100,
) {
    init {
        require(triggers.size == 3) { "Exactly three haptic patterns are required" }
        require(triggers.all { it == null || it in 1..65_535 }) { "Trigger distances must fit uint16; null disables" }
        require(strengthPercent in 0..100) { "Haptic strength must be 0..100%" }
    }

    fun trigger(pattern: HapticPattern): Int? = triggers[pattern.number - 1]
    val isActive: Boolean get() = triggers.any { it != null }
    val hasDuplicateDistance: Boolean
        get() = triggers.filterNotNull().let { it.size != it.toSet().size }

    companion object {
        val distanceChoices = listOf(25, 50, 100, 200, 500, 1000)
    }
}
