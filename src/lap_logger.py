"""Turn timestamps -> lap log.

On the device, every detected turn closes a lap (one pool length). When a turn
fires we know the time since the previous turn, so we append a record:

    {lap_number, lap_time_ms, timestamp}

This mirrors the streaming reality: a small struct written to flash per turn.
build_lap_log() is the batch equivalent used in evaluation.

Lap-count note: K turns delimit K-1 fully-timed inter-turn laps. The number of
pool lengths swum is K+1 (start->turn1, ... , turnK->finish), so
    n_lengths = n_turns + 1
which is the "lap count" the evaluation checks (== turns + 1).
"""


class LapLogger:
    """Streaming lap logger. Feed turn timestamps (seconds) in order."""

    def __init__(self):
        self.prev_t = None
        self.lap_number = 0
        self.laps = []

    def on_turn(self, t_seconds):
        """Register a turn. Returns the new lap record, or None for the first
        turn (which only opens the first inter-turn interval)."""
        if self.prev_t is None:
            self.prev_t = t_seconds
            return None
        self.lap_number += 1
        rec = {
            "lap_number": self.lap_number,
            "lap_time_ms": int(round((t_seconds - self.prev_t) * 1000.0)),
            "timestamp": t_seconds,
        }
        self.prev_t = t_seconds
        self.laps.append(rec)
        return rec


def build_lap_log(turn_times_s):
    """Build a lap log (list of records) from sorted turn timestamps (seconds)."""
    ts = sorted(float(t) for t in turn_times_s)
    logger = LapLogger()
    for t in ts:
        logger.on_turn(t)
    return logger.laps


def n_lengths(n_turns):
    """Pool lengths implied by a turn count (turns + 1)."""
    return n_turns + 1 if n_turns > 0 else 0


def lap_times_ms(lap_log):
    """Extract the list of lap times (ms) from a lap log."""
    return [r["lap_time_ms"] for r in lap_log]
