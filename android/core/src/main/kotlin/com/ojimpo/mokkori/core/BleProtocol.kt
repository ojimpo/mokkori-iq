package com.ojimpo.mokkori.core

import java.nio.ByteBuffer
import java.nio.ByteOrder

class BleProtocolException(message: String) : IllegalArgumentException(message)

/** Byte codecs only. This object does not scan, connect, or write to a BLE device. */
object BleProtocol {
    const val SERVICE_UUID = "6D6B6F69-A55A-4000-8000-000000000001"
    const val TIME_UUID = "6D6B6F69-A55A-4000-8000-000000000002"
    const val STATUS_UUID = "6D6B6F69-A55A-4000-8000-000000000003"
    const val DATA_UUID = "6D6B6F69-A55A-4000-8000-000000000004"
    const val CONTROL_UUID = "6D6B6F69-A55A-4000-8000-000000000005"

    const val STATUS_VERSION = 1
    const val STATUS_BYTES = 36
    const val SAMPLE_BYTES = 12
    const val END_OF_DUMP = 0xffff_ffffL

    /** Write these eight bytes to TIME_UUID, with response. Nonnegative Unix ms. */
    fun timeAnchor(epochMillis: Long): ByteArray {
        require(epochMillis >= 0) { "Unix milliseconds must be nonnegative" }
        return littleEndianBuffer(8).putLong(epochMillis).array()
    }

    /** Destructive device action: callers must obtain confirmation before a real write. */
    fun erase(): ByteArray = byteArrayOf(0x01)

    fun vibrate(pattern: HapticPattern, strengthPercent: Int): ByteArray =
        vibrate(pattern.pulsesMs, strengthPercent)

    fun vibrate(pulsesMs: List<Int>, strengthPercent: Int): ByteArray {
        val pulses = pulsesMs.toList()
        require(strengthPercent in 0..100)
        require(pulses.size in 1..6) { "Firmware accepts at most six ON/OFF pulse durations" }
        require(pulses.all { it in 1..65_535 }) { "Pulse durations must fit uint16 milliseconds" }
        return littleEndianBuffer(3 + pulses.size * 2).apply {
            put(0x02.toByte())
            put(strengthPercent.toByte())
            put(pulses.size.toByte())
            pulses.forEach { putShort(it.toShort()) }
        }.array()
    }

    fun setHaptics(settings: HapticSettings): ByteArray {
        // Kotlin List is read-only, not necessarily immutable. Revalidate a snapshot
        // at the wire boundary in case a caller retained and mutated its backing list.
        val snapshot = HapticSettings(settings.triggers.toList(), settings.strengthPercent)
        require(!snapshot.hasDuplicateDistance) { "Patterns cannot use the same trigger distance" }
        return littleEndianBuffer(8).apply {
            put(0x03.toByte())
            put(snapshot.strengthPercent.toByte())
            snapshot.triggers.forEach { putShort((it ?: 0).toShort()) }
        }.array()
    }

    fun dumpStart(fromSample: Long = 0): ByteArray {
        require(fromSample in 0 until END_OF_DUMP) { "Sample index must fit uint32 and cannot be the end marker" }
        return littleEndianBuffer(5).put(0x10.toByte()).putInt(fromSample.toInt()).array()
    }

    fun dumpStop(): ByteArray = byteArrayOf(0x11)

    /**
     * Decode the v1 prefix in firmware/flash_logger/flash_logger.ino. Additional
     * trailing fields are ignored. A different prefix version is rejected explicitly.
     * uint32 fields use Long so signed Int overflow cannot make a full device negative.
     */
    fun decodeStatus(bytes: ByteArray): DeviceStatus {
        if (bytes.size < STATUS_BYTES) throw BleProtocolException("Status needs at least 36 bytes; got ${bytes.size}")
        val data = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        val version = data.get().toInt() and 0xff
        if (version != STATUS_VERSION) throw BleProtocolException("Unsupported status version: $version")
        val flags = data.get().toInt() and 0xff
        val odr = data.short.toInt() and 0xffff
        val samples = data.int.toLong() and END_OF_DUMP
        val capacity = data.int.toLong() and END_OF_DUMP
        val millivolts = data.short.toInt() and 0xffff
        val percent = data.get().toInt() and 0xff
        val strength = data.get().toInt() and 0xff
        val epoch = data.long
        // Android dates cannot represent the upper half of uint64; do not wrap it.
        if (epoch < 0) throw BleProtocolException("Anchor epoch exceeds supported signed 64-bit range")
        val anchorIndex = data.int.toLong() and END_OF_DUMP
        val uptime = data.int.toLong() and END_OF_DUMP
        val progress = data.int.toLong() and END_OF_DUMP
        return DeviceStatus(
            version = version,
            batteryPercent = percent,
            batteryMillivolts = millivolts,
            charging = flags and 0x04 != 0,
            samples = samples,
            capacitySamples = capacity,
            sampleRate = if (odr > 0) odr.toDouble() else 52.0,
            isLogging = flags and 0x01 != 0,
            isUsbConnected = flags and 0x02 != 0,
            isFull = flags and 0x08 != 0,
            isErasing = flags and 0x10 != 0,
            isDumping = flags and 0x20 != 0,
            isImuOk = flags and 0x40 != 0,
            isFlashOk = flags and 0x80 != 0,
            hapticStrengthPercent = strength,
            lastAnchorEpochMillis = epoch.takeIf { it > 0 },
            lastAnchorIndex = anchorIndex.takeIf { epoch > 0 },
            uptimeMillis = uptime,
            dumpProgressSamples = progress,
        )
    }

    private fun littleEndianBuffer(size: Int): ByteBuffer = ByteBuffer.allocate(size).order(ByteOrder.LITTLE_ENDIAN)
}
