package com.ojimpo.mokkori.core

import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.*
import org.junit.Test

class DumpAssemblerTest {
    private val first = shortArrayOf(-32768, -1, 0, 1, 256, 32767)
    private val second = shortArrayOf(20, -20, 40, -40, 60, -60)
    private val end = byteArrayOf(-1, -1, -1, -1)

    @Test fun exactOrderedDumpOnlyReturnsRecordingAtTerminator() {
        val assembler = DumpAssembler(2, 52.0)
        assertNull(assembler.accept(frame(0, first)))
        assertEquals(1, assembler.receivedSamples)
        assertEquals(0.5, assembler.fraction, 0.0)
        assertNull(assembler.accept(frame(1, second)))
        assertEquals(DumpAssembler.State.RECEIVING, assembler.state)
        val raw = assembler.accept(end)!!
        assertArrayEquals(first + second, raw.samples)
        assertArrayEquals(frame(0, first + second).copyOfRange(4, 28), raw.binaryData())
        assertEquals(52.0, raw.odr, 0.0)
        assertEquals(DumpAssembler.State.COMPLETE, assembler.state)
        assertThrows(IllegalStateException::class.java) { assembler.accept(end) }
    }

    @Test fun frameMayCarryMultipleSamples() {
        val assembler = DumpAssembler(2, 104.0)
        assembler.accept(frame(0, first + second))
        assertEquals(2, assembler.accept(end)!!.count)
    }

    @Test fun gapAndDuplicatePermanentlyPoisonTransfer() {
        val gap = DumpAssembler(2, 52.0)
        assertThrows(BleProtocolException::class.java) { gap.accept(frame(1, second)) }
        assertEquals(DumpAssembler.State.FAILED, gap.state)
        assertThrows(IllegalStateException::class.java) { gap.accept(frame(0, first)) }

        val duplicate = DumpAssembler(2, 52.0)
        duplicate.accept(frame(0, first))
        assertThrows(BleProtocolException::class.java) { duplicate.accept(frame(0, first)) }
        assertEquals(DumpAssembler.State.FAILED, duplicate.state)
    }

    @Test fun incompleteTransferFailsRatherThanSavingPlausibleShortSession() {
        val assembler = DumpAssembler(2, 52.0)
        assembler.accept(frame(0, first))
        assertThrows(BleProtocolException::class.java) { assembler.accept(end) }
        assertEquals(DumpAssembler.State.FAILED, assembler.state)
    }

    @Test fun truncatedPayloadAndIndexAndExtraTerminatorDataAreRejected() {
        listOf(ByteArray(3), frame(0, first).dropLast(1).toByteArray(), ByteArray(4), end + firstByte()).forEach {
            val assembler = DumpAssembler(1, 52.0)
            assertThrows(BleProtocolException::class.java) { assembler.accept(it) }
            assertEquals(DumpAssembler.State.FAILED, assembler.state)
        }
    }

    @Test fun overrunAndUnsignedForeignIndexAreRejected() {
        assertThrows(BleProtocolException::class.java) { DumpAssembler(1, 52.0).accept(frame(0, first + second)) }
        assertThrows(BleProtocolException::class.java) { DumpAssembler(1, 52.0).accept(frame(-2, first)) }
    }

    @Test fun disconnectAndCancelDiscardEvenFullyReceivedDataWithoutTerminator() {
        val disconnected = DumpAssembler(1, 52.0)
        disconnected.accept(frame(0, first))
        disconnected.abort()
        assertEquals(DumpAssembler.State.FAILED, disconnected.state)
        assertThrows(IllegalStateException::class.java) { disconnected.accept(end) }

        val cancelled = DumpAssembler(1, 52.0)
        cancelled.accept(frame(0, first))
        cancelled.cancel()
        assertEquals(DumpAssembler.State.CANCELLED, cancelled.state)
        assertThrows(IllegalStateException::class.java) { cancelled.accept(end) }
    }

    @Test fun untrustedSampleCountsAndInvalidRatesFailBeforeAllocation() {
        listOf(0, -1, Int.MAX_VALUE, DumpAssembler.MAX_SAMPLES + 1).forEach {
            assertThrows(IllegalArgumentException::class.java) { DumpAssembler(it, 52.0) }
        }
        listOf(0.0, -52.0, Double.NaN, Double.POSITIVE_INFINITY).forEach {
            assertThrows(IllegalArgumentException::class.java) { DumpAssembler(1, it) }
        }
    }

    private fun frame(index: Int, samples: ShortArray): ByteArray =
        ByteBuffer.allocate(4 + samples.size * 2).order(ByteOrder.LITTLE_ENDIAN).apply {
            putInt(index)
            samples.forEach { putShort(it) }
        }.array()

    private fun firstByte() = byteArrayOf(0)
}
