package com.ojimpo.mokkori.core

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Strict, ordered full-dump reassembly. Capture expectedSamples and odr from the
 * status before DUMP_START(0). This is not a resumable transfer/persistence API.
 *
 * A recording is returned only after both the exact sample count and a standalone
 * 0xffffffff terminator arrive. Any invalid frame poisons the transfer permanently.
 * Call abort() on disconnect, notification error, or timeout; cancel() on user cancel.
 * Instances are single-use and must be called serially (not thread-safe).
 */
class DumpAssembler(val expectedSamples: Int, val odr: Double) {
    enum class State { RECEIVING, COMPLETE, FAILED, CANCELLED }

    var state: State = State.RECEIVING
        private set
    var receivedSamples: Int = 0
        private set
    val fraction: Double get() = receivedSamples.toDouble() / expectedSamples

    private var buffer: ByteArray?

    init {
        // Bound allocation before trusting a device's uint32 sample count.
        require(expectedSamples in 1..MAX_SAMPLES) { "Expected sample count must be 1..$MAX_SAMPLES" }
        require(odr.isFinite() && odr > 0) { "Sample rate must be positive and finite" }
        buffer = ByteArray(expectedSamples * BleProtocol.SAMPLE_BYTES)
    }

    /** Null means a valid in-progress frame. Never returns a partial recording. */
    fun accept(frame: ByteArray): RawRecording? {
        check(state == State.RECEIVING) { "Transfer is already $state" }
        if (frame.size < 4) fail("Dump frame is shorter than the sample index")
        val index = ByteBuffer.wrap(frame).order(ByteOrder.LITTLE_ENDIAN).int.toLong() and BleProtocol.END_OF_DUMP
        if (index == BleProtocol.END_OF_DUMP) {
            if (frame.size != 4) fail("Dump terminator must not contain sample data")
            if (receivedSamples != expectedSamples) fail("Incomplete dump: received $receivedSamples of $expectedSamples samples")
            val recording = RawRecording.fromBinary(checkNotNull(buffer), odr)
            buffer = null
            state = State.COMPLETE
            return recording
        }

        val bodySize = frame.size - 4
        if (bodySize == 0 || bodySize % BleProtocol.SAMPLE_BYTES != 0) {
            fail("Dump payload must contain complete 12-byte samples")
        }
        if (index != receivedSamples.toLong()) fail("Gap or duplicate at sample $receivedSamples; received index $index")
        val count = bodySize / BleProtocol.SAMPLE_BYTES
        if (count > expectedSamples - receivedSamples) fail("Dump contains more samples than the status promised")
        frame.copyInto(checkNotNull(buffer), receivedSamples * BleProtocol.SAMPLE_BYTES, 4, frame.size)
        receivedSamples += count
        return null
    }

    fun cancel() {
        if (state == State.RECEIVING) {
            buffer = null
            state = State.CANCELLED
        }
    }

    fun abort() {
        if (state == State.RECEIVING) {
            buffer = null
            state = State.FAILED
        }
    }

    private fun fail(message: String): Nothing {
        abort()
        throw BleProtocolException(message)
    }

    companion object {
        /** 12 MB of raw payload, well above the current logger's capacity. */
        const val MAX_SAMPLES = 1_000_000
    }
}
