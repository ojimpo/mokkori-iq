package com.ojimpo.mokkori.core

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Headerless raw.bin: signed little-endian int16, interleaved ax/ay/az/gx/gy/gz.
 * ODR belongs in metadata and is never inferred from the binary file. Firmware
 * decompresses flash records before BLE transmission; raw.bin is NOT flash format.
 */
class RawRecording(samples: ShortArray, val odr: Double) {
    private val storedSamples: ShortArray
    val samples: ShortArray get() = storedSamples.copyOf()
    val count: Int get() = storedSamples.size / AXES

    init {
        require(samples.size % AXES == 0) { "Raw samples must contain all six axes" }
        require(odr.isFinite() && odr > 0) { "Sample rate must be positive and finite" }
        storedSamples = samples.copyOf()
    }

    fun binaryData(): ByteArray = ByteBuffer.allocate(storedSamples.size * 2)
        .order(ByteOrder.LITTLE_ENDIAN).apply { storedSamples.forEach { putShort(it) } }.array()

    /**
     * Preserve iOS RawRecording.decode's CSV-equivalent rounding BEFORE SI conversion:
     * time to four decimal places, sensor values to five, ties to even. Calculations
     * use Double; accelerometer becomes m/s² and gyro becomes rad/s.
     */
    fun decode(): SwimSession {
        val t = DoubleArray(count) { roundDecimal(it / odr, 1e4) }
        val axes = Array(AXES) { axis ->
            DoubleArray(count) { row ->
                val sensitivity = if (axis < 3) ACC_SENS else GYRO_SENS
                val siFactor = if (axis < 3) SwimSession.G0 else SwimSession.DEG_TO_RAD
                roundDecimal(storedSamples[row * AXES + axis] * sensitivity, 1e5) * siFactor
            }
        }
        val fs = if (count > 1) {
            val dt = median((1 until count).map { t[it] - t[it - 1] })
            if (dt > 0) 1.0 / dt else 52.0
        } else 52.0
        return SwimSession(t, axes[0], axes[1], axes[2], axes[3], axes[4], axes[5], fs)
    }

    companion object {
        const val AXES = 6
        const val ACC_SENS = 8.0 / 32768.0
        const val GYRO_SENS = 70e-3

        fun fromBinary(bytes: ByteArray, odr: Double): RawRecording {
            require(bytes.size % BleProtocol.SAMPLE_BYTES == 0) { "raw.bin must be a multiple of 12 bytes" }
            require(odr.isFinite() && odr > 0) { "Sample rate must be positive and finite" }
            val data = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
            return RawRecording(ShortArray(bytes.size / 2) { data.short }, odr)
        }

        internal fun roundDecimal(value: Double, scale: Double): Double = Math.rint(value * scale) / scale
    }
}

/** SI-unit data suitable for a future detector port. No detector is implemented here. */
data class SwimSession(
    val t: DoubleArray,
    val ax: DoubleArray,
    val ay: DoubleArray,
    val az: DoubleArray,
    val gx: DoubleArray,
    val gy: DoubleArray,
    val gz: DoubleArray,
    val fs: Double,
) {
    val count: Int get() = t.size

    init {
        require(listOf(ax, ay, az, gx, gy, gz).all { it.size == t.size })
        require(fs.isFinite() && fs > 0)
    }

    companion object {
        const val G0 = 9.80665
        val DEG_TO_RAD: Double = Math.PI / 180.0
    }
}
