package com.ojimpo.mokkori.core

/** Seconds relative to the beginning of a recording, matching MokkoriCore.Span. */
data class Span(val start: Double, val end: Double) {
    init {
        require(start.isFinite() && end.isFinite() && end >= start)
    }

    val duration: Double get() = end - start
    val mid: Double get() = (start + end) / 2.0
}

/**
 * iOS-compatible report vocabulary and units, not a port of the analysis engine.
 * Lap = one pool length; interval = continuous swimming; set = a group between long rests.
 * All durations are seconds and distances are meters. Stroke count 0 means unavailable.
 */
data class SwimReport(
    val typicalLapTime: Double,
    val poolLength: Double,
    val intervals: List<Interval>,
    val sets: List<SetSummary>,
    val laps: List<Lap>,
    val distance: Double,
    val movingTime: Double,
    val elapsed: Double,
) {
    data class Interval(
        val setNumber: Int,
        val number: Int,
        val span: Span,
        val swimTime: Double,
        val wallCount: Int,
        val paceCount: Int,
        val laps: Int,
    ) {
        val crossCheck: Boolean get() = wallCount != paceCount
    }

    data class SetSummary(
        val index: Int,
        val distance: Double,
        val movingTime: Double,
        val pace100: Double,
    )

    data class Lap(
        val setNumber: Int,
        val interval: Int,
        val number: Int,
        val span: Span,
        val strokes: Int,
    ) {
        val duration: Double get() = span.duration
        val swolf: Double get() = duration + strokes
    }

    val pace100: Double get() = if (distance > 0) movingTime / distance * 100 else 0.0
    val strokedLaps: List<Lap> get() = laps.filter { it.strokes > 0 }
    val strokesTotal: Int get() = laps.sumOf { it.strokes }
    val strokesPerLapMedian: Double?
        get() = strokedLaps.takeIf { it.isNotEmpty() }?.let { median(it.map { lap -> lap.strokes.toDouble() }) }
    val swolfAverage: Double? get() = strokedLaps.takeIf { it.isNotEmpty() }?.map { it.swolf }?.average()
    val swolfBest: Double? get() = strokedLaps.minOfOrNull { it.swolf }
    val bestLap: Lap? get() = strokedLaps.minByOrNull { it.duration }
    val dps: Double? get() = strokesPerLapMedian?.takeIf { it > 0 }?.let { poolLength / it }
}

internal fun median(values: List<Double>): Double {
    require(values.isNotEmpty())
    val sorted = values.sorted()
    val middle = sorted.size / 2
    return if (sorted.size % 2 == 0) (sorted[middle - 1] + sorted[middle]) / 2.0 else sorted[middle]
}
