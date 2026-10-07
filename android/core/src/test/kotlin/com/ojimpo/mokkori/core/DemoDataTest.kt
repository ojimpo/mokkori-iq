package com.ojimpo.mokkori.core

import org.junit.Assert.*
import org.junit.Test

class DemoDataTest {
    @Test fun threeFixturesHaveStableUniqueIdsAndExplicitDemoLabels() {
        assertEquals(listOf("demo-1000", "demo-750", "demo-500"), DemoData.sessions.map { it.id })
        assertTrue(DemoData.sessions.all { it.isDemo })
        assertTrue(DemoData.disclosure.contains("デモ"))
        assertEquals(listOf(1000.0, 750.0, 500.0), DemoData.sessions.map { it.report.distance })
    }

    @Test fun syntheticReportsAreInternallyConsistent() {
        DemoData.sessions.forEach { session ->
            val report = session.report
            assertEquals(report.laps.size * report.poolLength, report.distance, 0.0)
            assertEquals(report.laps.sumOf { it.duration }, report.movingTime, 0.0)
            assertEquals(report.intervals.sumOf { it.swimTime }, report.movingTime, 0.0)
            assertEquals(report.sets.sumOf { it.distance }, report.distance, 0.0)
            assertEquals(report.sets.sumOf { it.movingTime }, report.movingTime, 0.0)
            assertTrue(report.elapsed >= report.movingTime)
            assertEquals(report.laps.last().span.end, report.elapsed, 0.0)
            assertEquals(report.movingTime / report.distance * 100, report.pace100, 0.0)
            assertEquals(report.sets.indices.map { it + 1 }, report.sets.map { it.index })
            report.intervals.forEach { interval ->
                val laps = report.laps.filter { it.setNumber == interval.setNumber && it.interval == interval.number }
                assertEquals(interval.laps, laps.size)
                assertEquals(laps.indices.map { it + 1 }, laps.map { it.number })
                assertFalse(interval.crossCheck)
            }
        }
    }

    @Test fun zeroStrokeLapsAreExcludedFromStrokeBasedMetricsAsOnIos() {
        val laps = listOf(
            SwimReport.Lap(1, 1, 1, Span(0.0, 20.0), 0),
            SwimReport.Lap(1, 1, 2, Span(20.0, 50.0), 10),
            SwimReport.Lap(1, 1, 3, Span(50.0, 84.0), 14),
        )
        val report = SwimReport(30.0, 25.0, emptyList(), emptyList(), laps, 75.0, 84.0, 84.0)
        assertEquals(24, report.strokesTotal)
        assertEquals(12.0, report.strokesPerLapMedian!!, 0.0)
        assertEquals(44.0, report.swolfAverage!!, 0.0)
        assertEquals(40.0, report.swolfBest!!, 0.0)
        assertEquals(laps[1], report.bestLap)
        assertEquals(25.0 / 12, report.dps!!, 0.0)
    }

    @Test fun missingStrokeMeasurementsRemainNull() {
        val report = DemoData.sessions.first().report.copy(laps = emptyList())
        assertNull(report.strokesPerLapMedian)
        assertNull(report.swolfAverage)
        assertNull(report.swolfBest)
        assertNull(report.bestLap)
        assertNull(report.dps)
    }

    @Test fun hapticChoicesAndDuplicateDetectionMatchIosVocabulary() {
        assertEquals(listOf(25, 50, 100, 200, 500, 1000), HapticSettings.distanceChoices)
        assertFalse(HapticSettings().isActive)
        val settings = HapticSettings(listOf(100, null, 500), 75)
        assertTrue(settings.isActive)
        assertEquals(100, settings.trigger(HapticPattern.ONE))
        assertNull(settings.trigger(HapticPattern.TWO))
        assertEquals(500, settings.trigger(HapticPattern.THREE))
        assertFalse(settings.hasDuplicateDistance)
        assertTrue(HapticSettings(listOf(100, 100, null)).hasDuplicateDistance)
    }
}
