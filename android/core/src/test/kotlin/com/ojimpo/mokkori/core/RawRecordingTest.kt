package com.ojimpo.mokkori.core

import org.junit.Assert.*
import org.junit.Test

class RawRecordingTest {
    @Test fun binaryIsHeaderlessSignedInt16LittleEndianInSixAxisOrder() {
        val values = shortArrayOf(Short.MIN_VALUE, -1, 0, 1, 256, Short.MAX_VALUE)
        val expected = byteArrayOf(0, -128, -1, -1, 0, 0, 1, 0, 0, 1, -1, 127)
        val raw = RawRecording(values, 52.0)
        assertArrayEquals(expected, raw.binaryData())
        assertArrayEquals(values, RawRecording.fromBinary(expected, 52.0).samples)
        assertEquals(1, raw.count)
    }

    @Test fun partialSampleOrInvalidOdrIsNeverSilentlyTruncated() {
        listOf(1, 2, 11, 13).forEach { size ->
            assertThrows(IllegalArgumentException::class.java) { RawRecording.fromBinary(ByteArray(size), 52.0) }
        }
        assertThrows(IllegalArgumentException::class.java) { RawRecording(ShortArray(5), 52.0) }
        listOf(0.0, -1.0, Double.NaN, Double.POSITIVE_INFINITY).forEach {
            assertThrows(IllegalArgumentException::class.java) { RawRecording(ShortArray(6), it) }
        }
    }

    @Test fun inputAndOutputArraysCannotMutateStoredRawData() {
        val input = ShortArray(6) { it.toShort() }
        val raw = RawRecording(input, 52.0)
        input[0] = 999
        raw.samples[1] = 999
        val bytes = raw.binaryData()
        bytes[4] = 99
        assertArrayEquals(shortArrayOf(0, 1, 2, 3, 4, 5), raw.samples)
    }

    @Test fun decodeMatchesGoldenFlashDumpCsvValuesBeforeSiConversion() {
        // Golden synthetic values; no real recording is needed for unit/rounding parity.
        val sample = shortArrayOf(1, -1, 4096, 1, -1, 100)
        val raw = RawRecording(sample + sample + sample, 52.0)
        val session = raw.decode()
        assertArrayEquals(doubleArrayOf(0.0, 0.0192, 0.0385), session.t, 0.0)
        assertEquals(0.00024 * 9.80665, session.ax[0], 0.0)
        assertEquals(-0.00024 * 9.80665, session.ay[0], 0.0)
        assertEquals(9.80665, session.az[0], 0.0)
        assertEquals(0.07 * (Math.PI / 180.0), session.gx[0], 0.0)
        assertEquals(-0.07 * (Math.PI / 180.0), session.gy[0], 0.0)
        assertEquals(7.0 * (Math.PI / 180.0), session.gz[0], 0.0)
        assertEquals(1.0 / 0.01925, session.fs, 1e-12)
    }

    @Test fun decimalRoundingUsesTiesToEvenIncludingNegativeValues() {
        assertEquals(2.0, RawRecording.roundDecimal(2.5, 1.0), 0.0)
        assertEquals(4.0, RawRecording.roundDecimal(3.5, 1.0), 0.0)
        assertEquals(-2.0, RawRecording.roundDecimal(-2.5, 1.0), 0.0)
        assertEquals(-4.0, RawRecording.roundDecimal(-3.5, 1.0), 0.0)
        assertEquals(1.12, RawRecording.roundDecimal(1.125, 100.0), 0.0)
    }

    @Test fun emptyAndSingleSampleUseIosFallbackFrequency() {
        assertEquals(52.0, RawRecording(ShortArray(0), 104.0).decode().fs, 0.0)
        assertEquals(52.0, RawRecording(ShortArray(6), 104.0).decode().fs, 0.0)
        assertArrayEquals(ByteArray(0), RawRecording.fromBinary(ByteArray(0), 52.0).binaryData())
    }

    @Test fun everySignedInt16ValueSurvivesBinaryRoundTrip() {
        val sample = ShortArray(65_536 * 6) { ((it / 6) - 32_768).toShort() }
        assertArrayEquals(sample, RawRecording.fromBinary(RawRecording(sample, 52.0).binaryData(), 52.0).samples)
    }
}
