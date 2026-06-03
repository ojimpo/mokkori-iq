"""Causal, threshold-based freestyle turn detector.

Algorithm (finite state machine), derived from Step 2 exploration:

  - Compute the accelerometer norm, optionally low-pass it (precomputed biquad).
  - Track an "activity envelope" = trailing rolling std of the norm (motion
    energy). Steady swimming -> high activity; a touch turn shows a brief
    LOW-ACTIVITY VALLEY (wall touch / glide) flanked by swimming, usually with
    an acceleration spike at push-off.
  - A peak-follower estimates "recent swimming activity" so thresholds are
    relative (robust to swimmer / sensor-position scale -> Phase 1).

FSM:
  SWIM  --activity<thr_low-->            DIP
  DIP   --activity>thr_high & valid-->   CONFIRM      (candidate turn)
  DIP   --dip too long-->                REST
  CONFIRM --sustained swimming-->        emit turn, SWIM
  CONFIRM --activity dips again-->       DIP          (was end-of-set, discard)
  REST  --activity>thr_high-->           SWIM

The CONFIRM state is what separates a real turn (swim -> wall -> swim again)
from the end of a set (swim -> wall -> rest): a turn is only emitted once
swimming actually resumes for confirm_swim seconds. An optional push-off spike
check adds further precision. Everything is causal (a small fixed latency) and
uses O(W) memory; update() is plain scalar arithmetic -> direct C port.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import preprocessing as pp  # noqa: E402

SWIM = 0
DIP = 1
REST = 2
CONFIRM = 3

STATE_NAMES = {SWIM: "swim", DIP: "dip", REST: "rest", CONFIRM: "confirm"}


class TurnDetector:
    def __init__(self, config):
        self.cfg = config
        self.fs = float(config["fs_hz"])
        pre = config["preprocess"]
        det = config["detector"]

        self.lp_enabled = bool(pre["lowpass_enabled"])
        self._lp_b = pre["lowpass_b"]
        self._lp_a = pre["lowpass_a"]
        self.win = max(2, int(round(pre["activity_window_s"] * self.fs)))

        self.attack = float(det["swim_ref_attack"])
        self.release = float(det["swim_ref_release"])
        self.ref_init = float(det["swim_ref_init"])
        self.ref_min = float(det["swim_ref_min"])
        self.enter_ratio = float(det["dip_enter_ratio"])
        self.exit_ratio = float(det["dip_exit_ratio"])
        self.abs_floor = float(det["dip_abs_floor"])
        self.min_still = int(round(det["min_still_s"] * self.fs))
        self.max_still = int(round(det["max_still_s"] * self.fs))
        self.require_spike = bool(det["require_spike"])
        self.spike_abs = float(det["spike_abs"])
        self.refractory = int(round(det["refractory_s"] * self.fs))
        # post-dip swim confirmation (0 -> emit immediately at dip exit)
        self.confirm_swim = int(round(float(det.get("confirm_swim_s", 0.0)) * self.fs))
        self.confirm_timeout = int(round(float(det.get("confirm_timeout_s", 1.5)) * self.fs))

        self.debug = False  # set True to record per-sample trace for plotting
        self.reset()

    def reset(self):
        self.i = -1
        self.lp = pp.Biquad(self._lp_b, self._lp_a) if self.lp_enabled else None
        self.rs = pp.RollingStd(self.win)
        self.swim_ref = self.ref_init
        self.state = SWIM
        self.dip_start = 0
        self.dip_min_val = 0.0
        self.dip_min_i = 0
        self.dip_max_acc = 0.0
        # candidate (stashed when a dip qualifies and we move to CONFIRM)
        self.cand_start = 0
        self.cand_min_val = 0.0
        self.cand_min_i = 0
        self.cand_max_acc = 0.0
        self.confirm_count = 0
        self.confirm_start = 0
        self.last_emit = -10 ** 9
        self._lp_init = False
        self.trace = {"activity": [], "swim_ref": [], "thr_low": [],
                      "thr_high": [], "state": []} if self.debug else None

    # -- streaming core ----------------------------------------------------
    def update(self, ax, ay, az, gx=0.0, gy=0.0, gz=0.0):
        """Feed one IMU sample. Returns a detection dict or None.

        idx in the dict is the sample index of the stillest point (estimated
        wall contact); emission happens a little later (after confirmation).
        """
        self.i += 1
        i = self.i

        an = (ax * ax + ay * ay + az * az) ** 0.5
        if self.lp is not None:
            if not self._lp_init:
                self.lp.reset(an)
                self._lp_init = True
            an = self.lp.step(an)

        activity = self.rs.update(an)

        # peak-follower for recent swimming activity
        if activity > self.swim_ref:
            self.swim_ref += self.attack * (activity - self.swim_ref)
        else:
            self.swim_ref += self.release * (activity - self.swim_ref)
        if self.swim_ref < self.ref_min:
            self.swim_ref = self.ref_min

        thr_low = self.enter_ratio * self.swim_ref
        if thr_low < self.abs_floor:
            thr_low = self.abs_floor
        thr_high = self.exit_ratio * self.swim_ref
        if thr_high < self.abs_floor * 1.5:
            thr_high = self.abs_floor * 1.5

        out = None

        if self.state == SWIM:
            if activity < thr_low:
                self._enter_dip(i, activity, an)

        elif self.state == DIP:
            if activity < self.dip_min_val:
                self.dip_min_val = activity
                self.dip_min_i = i
            if an > self.dip_max_acc:
                self.dip_max_acc = an
            dip_len = i - self.dip_start
            if dip_len > self.max_still:
                self.state = REST  # too long -> rest, never a turn
            elif activity > thr_high:
                valid = (dip_len >= self.min_still and
                         (i - self.last_emit) >= self.refractory)
                if valid:
                    self._stash_candidate()
                    if self.confirm_swim <= 0:
                        out = self._try_emit(i)
                        self.state = SWIM
                    else:
                        self.state = CONFIRM
                        self.confirm_count = 1
                        self.confirm_start = i
                else:
                    self.state = SWIM

        elif self.state == CONFIRM:
            if an > self.cand_max_acc:
                self.cand_max_acc = an  # push-off spike often peaks here
            if activity > thr_high:
                self.confirm_count += 1
                if self.confirm_count >= self.confirm_swim:
                    out = self._try_emit(i)
                    self.state = SWIM
            elif activity < thr_low:
                # dipped again without sustained swimming -> end of set / rest.
                # discard the candidate and begin a fresh dip here.
                self._enter_dip(i, activity, an)
            elif (i - self.confirm_start) > self.confirm_timeout:
                self.state = SWIM  # ambiguous resumption -> drop candidate

        else:  # REST
            if activity > thr_high:
                self.state = SWIM

        if self.trace is not None:
            self.trace["activity"].append(activity)
            self.trace["swim_ref"].append(self.swim_ref)
            self.trace["thr_low"].append(thr_low)
            self.trace["thr_high"].append(thr_high)
            self.trace["state"].append(self.state)
        return out

    def _enter_dip(self, i, activity, an):
        self.state = DIP
        self.dip_start = i
        self.dip_min_val = activity
        self.dip_min_i = i
        self.dip_max_acc = an

    def _stash_candidate(self):
        self.cand_start = self.dip_start
        self.cand_min_val = self.dip_min_val
        self.cand_min_i = self.dip_min_i
        self.cand_max_acc = self.dip_max_acc

    def _try_emit(self, i):
        """Apply the spike gate, then emit. Returns dict or None."""
        if self.require_spike and self.cand_max_acc < self.spike_abs:
            return None
        self.last_emit = i
        ref = self.swim_ref if self.swim_ref > 1e-6 else 1e-6
        depth = 1.0 - self.cand_min_val / ref
        if depth < 0.0:
            depth = 0.0
        if depth > 1.0:
            depth = 1.0
        spike_conf = self.cand_max_acc / self.spike_abs
        if spike_conf > 1.0:
            spike_conf = 1.0
        confidence = 0.7 * depth + 0.3 * spike_conf
        return {
            "idx": self.cand_min_i,
            "t": self.cand_min_i / self.fs,
            "activity_min": self.cand_min_val,
            "spike": self.cand_max_acc,
            "dip_len_s": (i - self.cand_start) / self.fs,
            "confidence": confidence,
        }

    # -- batch convenience -------------------------------------------------
    def process(self, session):
        """Run over a loaded session dict (from dataio.load_session).

        Returns a list of detections. The 't' field uses the session's real
        timestamp array when available (else idx/fs).
        """
        self.reset()
        acc = session["acc"]
        t = session.get("t")
        n = len(acc)
        dets = []
        for k in range(n):
            d = self.update(acc[k, 0], acc[k, 1], acc[k, 2])
            if d is not None:
                if t is not None and 0 <= d["idx"] < n:
                    d["t"] = float(t[d["idx"]])
                dets.append(d)
        return dets


def detect_turns(session, config):
    """Functional wrapper: returns list of detection dicts for a session."""
    return TurnDetector(config).process(session)
