package com.ojimpo.mokkori.core

/** A presentation-only fixture. It is never a measured or imported swim session. */
data class DemoSession(
    val id: String,
    val title: String,
    val dateLabel: String,
    val report: SwimReport,
    val isDemo: Boolean = true,
)

/**
 * Fixed, invented examples. No data/swim recordings, personal timestamps, or user logs
 * are read or bundled. Reports are generated from made-up lap durations, not a detector.
 */
object DemoData {
    const val disclosure = "デモデータです。実際の泳ぎの記録ではありません"

    val sessions: List<DemoSession> = listOf(
        session("demo-1000", "プールスイム", "2026/10/04", listOf(20, 20), 28.0),
        session("demo-750", "プールスイム", "2026/10/02", listOf(10, 20), 29.5),
        session("demo-500", "プールスイム", "2026/09/29", listOf(20), 30.0),
    )

    /** Only use inside an explicitly labeled demo. Never present as connected hardware. */
    val deviceStatus = DeviceStatus(
        version = 1,
        batteryPercent = 82,
        batteryMillivolts = 4015,
        charging = false,
        samples = 83_200,
        capacitySamples = 374_400,
        sampleRate = 52.0,
        isImuOk = true,
        isFlashOk = true,
    )

    private fun session(
        id: String,
        title: String,
        date: String,
        setLengths: List<Int>,
        baseDuration: Double,
    ): DemoSession {
        val laps = mutableListOf<SwimReport.Lap>()
        val intervals = mutableListOf<SwimReport.Interval>()
        val sets = mutableListOf<SwimReport.SetSummary>()
        var time = 0.0
        setLengths.forEachIndexed { setIndex, lapCount ->
            val setStart = time
            var remaining = lapCount
            var intervalNumber = 1
            var setMovingTime = 0.0
            while (remaining > 0) {
                val length = minOf(10, remaining)
                val intervalStart = time
                repeat(length) { lapIndex ->
                    // Deterministic wave that cannot encode an actual recorded swim.
                    val duration = baseDuration + ((laps.size * 7) % 9 - 4) * 0.5
                    laps += SwimReport.Lap(
                        setNumber = setIndex + 1,
                        interval = intervalNumber,
                        number = lapIndex + 1,
                        span = Span(time, time + duration),
                        strokes = 12 + (laps.size * 3) % 5,
                    )
                    time += duration
                }
                val swimTime = time - intervalStart
                setMovingTime += swimTime
                intervals += SwimReport.Interval(
                    setNumber = setIndex + 1,
                    number = intervalNumber,
                    span = Span(intervalStart, time),
                    swimTime = swimTime,
                    wallCount = length,
                    paceCount = length,
                    laps = length,
                )
                remaining -= length
                intervalNumber++
                if (remaining > 0) time += 25.0
            }
            val distance = lapCount * 25.0
            sets += SwimReport.SetSummary(setIndex + 1, distance, setMovingTime, setMovingTime / distance * 100)
            check(time > setStart)
            if (setIndex < setLengths.lastIndex) time += 90.0
        }
        return DemoSession(
            id = id,
            title = title,
            dateLabel = date,
            report = SwimReport(
                typicalLapTime = median(laps.map { it.duration }),
                poolLength = 25.0,
                intervals = intervals.toList(),
                sets = sets.toList(),
                laps = laps.toList(),
                distance = laps.size * 25.0,
                movingTime = laps.sumOf { it.duration },
                elapsed = time,
            ),
        )
    }
}
