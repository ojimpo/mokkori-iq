package com.ojimpo.mokkori.core

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import org.junit.Assert.*
import org.junit.Test

class BleProtocolTest {
    @Test fun uuidsMatchFirmwareAndAreDistinct() {
        val uuids = listOf(BleProtocol.SERVICE_UUID, BleProtocol.TIME_UUID, BleProtocol.STATUS_UUID,
            BleProtocol.DATA_UUID, BleProtocol.CONTROL_UUID)
        assertEquals(5, uuids.toSet().size)
        uuids.forEachIndexed { index, uuid ->
            assertEquals("6d6b6f69-a55a-4000-8000-00000000000${index + 1}", UUID.fromString(uuid).toString())
        }
    }

    @Test fun commandBytesMatchFirmware() {
        assertArrayEquals(byteArrayOf(1), BleProtocol.erase())
        assertArrayEquals(byteArrayOf(0x11), BleProtocol.dumpStop())
        assertArrayEquals(bytes(0x10, 0x78, 0x56, 0x34, 0x12), BleProtocol.dumpStart(0x12345678))
        assertArrayEquals(bytes(0x10, 0, 0, 0, 0), BleProtocol.dumpStart())
        assertArrayEquals(bytes(8, 7, 6, 5, 4, 3, 2, 1), BleProtocol.timeAnchor(0x0102030405060708))
        assertArrayEquals(bytes(2, 100, 1, 180, 0), BleProtocol.vibrate(HapticPattern.ONE, 100))
        assertArrayEquals(bytes(2, 75, 3, 180, 0, 140, 0, 180, 0), BleProtocol.vibrate(HapticPattern.TWO, 75))
        assertArrayEquals(bytes(2, 50, 1, 0xbc, 2), BleProtocol.vibrate(HapticPattern.THREE, 50))
        assertArrayEquals(bytes(3, 80, 100, 0, 0, 0, 0xe8, 3),
            BleProtocol.setHaptics(HapticSettings(listOf(100, null, 1000), 80)))
        assertArrayEquals(bytes(3, 100, 0, 0, 0, 0, 0, 0), BleProtocol.setHaptics(HapticSettings()))
    }

    @Test fun invalidCommandParametersNeverWrapSilently() {
        assertThrows(IllegalArgumentException::class.java) { BleProtocol.timeAnchor(-1) }
        assertThrows(IllegalArgumentException::class.java) { BleProtocol.dumpStart(-1) }
        assertThrows(IllegalArgumentException::class.java) { BleProtocol.dumpStart(0xffff_ffff) }
        assertThrows(IllegalArgumentException::class.java) { BleProtocol.vibrate(HapticPattern.ONE, 101) }
        assertThrows(IllegalArgumentException::class.java) { BleProtocol.vibrate(emptyList(), 10) }
        assertThrows(IllegalArgumentException::class.java) { BleProtocol.vibrate(List(7) { 100 }, 10) }
        assertThrows(IllegalArgumentException::class.java) { BleProtocol.vibrate(listOf(65_536), 10) }
        assertThrows(IllegalArgumentException::class.java) { HapticSettings(listOf(100)) }
        assertThrows(IllegalArgumentException::class.java) { HapticSettings(listOf(0, null, null)) }
        assertThrows(IllegalArgumentException::class.java) {
            BleProtocol.setHaptics(HapticSettings(listOf(100, 100, null)))
        }
    }

    @Test fun changedBackingListCannotBypassHapticWireValidation() {
        val triggers = mutableListOf<Int?>(100, null, 500)
        val settings = HapticSettings(triggers)
        triggers[0] = 65_536
        assertThrows(IllegalArgumentException::class.java) { BleProtocol.setHaptics(settings) }
        triggers[0] = 100
        triggers.removeAt(1)
        assertThrows(IllegalArgumentException::class.java) { BleProtocol.setHaptics(settings) }
    }

    @Test fun decodesEveryFieldAndAllFlags() {
        val status = BleProtocol.decodeStatus(statusBytes(flags = 0xff))
        assertEquals(1, status.version)
        assertEquals(52.0, status.sampleRate, 0.0)
        assertEquals(5200L, status.samples)
        assertEquals(10400L, status.capacitySamples)
        assertEquals(4015, status.batteryMillivolts)
        assertEquals(82, status.batteryPercent)
        assertEquals(80, status.hapticStrengthPercent)
        assertEquals(1_700_000_000_000L, status.lastAnchorEpochMillis)
        assertEquals(5200L, status.lastAnchorIndex)
        assertEquals(123456L, status.uptimeMillis)
        assertEquals(2600L, status.dumpProgressSamples)
        assertTrue(status.isKnown)
        assertEquals(true, status.charging)
        assertTrue(status.isLogging && status.isUsbConnected && status.isFull && status.isErasing)
        assertTrue(status.isDumping && status.isImuOk && status.isFlashOk)
        assertEquals(0.5, status.usedFraction!!, 0.0)
        assertEquals(100.0, status.recordedSeconds!!, 0.0)
        assertEquals(100.0, status.remainingSeconds!!, 0.0)
        assertEquals(1_699_999_900.0, status.startEpoch!!, 0.0)
    }

    @Test fun statusToleratesExtraTailAndAbsentAnchorAndZeroOdr() {
        val original = statusBytes(flags = 0, odr = 0, epoch = 0)
        val status = BleProtocol.decodeStatus(original + bytes(9, 8, 7, 6))
        assertEquals(BleProtocol.decodeStatus(original), status)
        assertEquals(52.0, status.sampleRate, 0.0)
        assertNull(status.lastAnchorEpochMillis)
        assertNull(status.lastAnchorIndex)
        assertNull(status.startEpoch)
        assertFalse(status.isLogging || status.isUsbConnected || status.isFull || status.isErasing)
        assertFalse(status.isDumping || status.isImuOk || status.isFlashOk)
        assertEquals(false, status.charging)
    }

    @Test fun eachStatusFlagHasItsOwnBit() {
        (0..7).forEach { bit ->
            val status = BleProtocol.decodeStatus(statusBytes(flags = 1 shl bit))
            val decoded = listOf(status.isLogging, status.isUsbConnected, status.charging == true,
                status.isFull, status.isErasing, status.isDumping, status.isImuOk, status.isFlashOk)
            assertEquals((0..7).map { it == bit }, decoded)
        }
    }

    @Test fun statusRejectsTruncationAndUnknownPrefixVersion() {
        assertThrows(BleProtocolException::class.java) { BleProtocol.decodeStatus(ByteArray(35)) }
        assertThrows(BleProtocolException::class.java) {
            BleProtocol.decodeStatus(statusBytes().apply { this[0] = 2 })
        }
        assertThrows(BleProtocolException::class.java) { BleProtocol.decodeStatus(statusBytes(epoch = -1)) }
    }

    @Test fun unsignedCountsAreNotInterpretedAsNegative() {
        val data = statusBytes().apply {
            val buffer = ByteBuffer.wrap(this).order(ByteOrder.LITTLE_ENDIAN)
            buffer.putInt(4, -1)
            buffer.putInt(8, -2)
            buffer.putInt(24, -1)
            buffer.putInt(28, -1)
            buffer.putInt(32, -1)
        }
        val status = BleProtocol.decodeStatus(data)
        assertEquals(4_294_967_295L, status.samples)
        assertEquals(4_294_967_294L, status.capacitySamples)
        assertEquals(4_294_967_295L, status.lastAnchorIndex)
        assertEquals(4_294_967_295L, status.uptimeMillis)
        assertEquals(4_294_967_295L, status.dumpProgressSamples)
        assertEquals(1.0, status.usedFraction!!, 0.0)
        assertEquals(0.0, status.remainingSeconds!!, 0.0)
    }

    @Test fun disconnectedStatusRemainsUnknown() {
        val status = DeviceStatus()
        assertFalse(status.isKnown)
        assertNull(status.batteryPercent)
        assertNull(status.usedFraction)
        assertNull(status.remainingSeconds)
        assertNull(status.recordedSeconds)
        assertNull(status.startEpoch)
        assertNull(DeviceStatus(samples = 0, capacitySamples = 0).usedFraction)
    }

    private fun statusBytes(flags: Int = 0xc0, odr: Int = 52, epoch: Long = 1_700_000_000_000): ByteArray =
        ByteBuffer.allocate(36).order(ByteOrder.LITTLE_ENDIAN)
            .put(1.toByte()).put(flags.toByte()).putShort(odr.toShort())
            .putInt(5200).putInt(10400).putShort(4015.toShort()).put(82.toByte()).put(80.toByte())
            .putLong(epoch).putInt(5200).putInt(123456).putInt(2600).array()

    private fun bytes(vararg values: Int): ByteArray = ByteArray(values.size) { values[it].toByte() }
}
