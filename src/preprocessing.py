"""Preprocessing: normalization, low-pass filtering, activity envelope.

Two flavors are provided:

* Causal / streaming primitives (Biquad, RollingStd) that use only past samples
  and O(1)-O(W) memory. These mirror what will run on the Cortex-M4 and are what
  the detector uses.
* Batch, possibly non-causal helpers (zero_phase_lowpass, centered_rolling_std)
  used only for offline analysis/plots. They are clearly marked NON-CAUSAL.

Filter coefficients are precomputed offline (see config/default.json) so the MCU
never has to design a filter; it just runs the biquad difference equation.
"""
import json
import os

import numpy as np


# --------------------------------------------------------------------------
# config
# --------------------------------------------------------------------------
def load_config(path=None):
    if path is None:
        path = os.path.join(os.path.dirname(__file__), "..", "config", "default.json")
    with open(path, "r") as f:
        return json.load(f)


# --------------------------------------------------------------------------
# normalization
# --------------------------------------------------------------------------
def acc_norm(acc):
    """L2 norm of an (N,3) accelerometer array -> (N,)."""
    return np.sqrt(np.square(acc).sum(axis=1))


# --------------------------------------------------------------------------
# causal biquad (Direct Form II transposed), second order
# --------------------------------------------------------------------------
class Biquad:
    """Single second-order section, causal. a[0] is assumed 1.0.

    Difference equation (DF2T):
        y = b0*x + z1
        z1 = b1*x - a1*y + z2
        z2 = b2*x - a2*y
    Holds two state floats -> trivial on an MCU.
    """

    def __init__(self, b, a):
        self.b0, self.b1, self.b2 = float(b[0]), float(b[1]), float(b[2])
        self.a1, self.a2 = float(a[1]), float(a[2])
        self.z1 = 0.0
        self.z2 = 0.0

    def reset(self, x0=0.0):
        # Initialise state so a constant input x0 passes through with no step
        # transient. Steady state (DC gain 1):
        #   z2 = (b2 - a2) * x0 ;  z1 = (b1 - a1) * x0 + z2
        self.z2 = (self.b2 - self.a2) * x0
        self.z1 = (self.b1 - self.a1) * x0 + self.z2

    def step(self, x):
        y = self.b0 * x + self.z1
        self.z1 = self.b1 * x - self.a1 * y + self.z2
        self.z2 = self.b2 * x - self.a2 * y
        return y


def biquad_filter(x, b, a, init_steady=True):
    """Apply a causal biquad over a 1-D array (batch convenience wrapper)."""
    bq = Biquad(b, a)
    if init_steady and len(x) > 0:
        bq.reset(float(x[0]))
    out = np.empty(len(x), dtype=np.float64)
    for i in range(len(x)):
        out[i] = bq.step(float(x[i]))
    return out


# --------------------------------------------------------------------------
# causal rolling std (activity envelope) -- streaming
# --------------------------------------------------------------------------
class RollingStd:
    """Trailing-window standard deviation over the last W samples.

    Keeps a ring buffer plus running sum / sum-of-squares -> O(W) memory, O(1)
    per sample. This is the "activity" / motion-energy envelope.
    """

    def __init__(self, window):
        self.w = int(window)
        self.buf = [0.0] * self.w
        self.idx = 0
        self.count = 0
        self.s1 = 0.0
        self.s2 = 0.0

    def update(self, x):
        x = float(x)
        if self.count == self.w:
            old = self.buf[self.idx]
            self.s1 -= old
            self.s2 -= old * old
        else:
            self.count += 1
        self.buf[self.idx] = x
        self.s1 += x
        self.s2 += x * x
        self.idx += 1
        if self.idx == self.w:
            self.idx = 0
        mean = self.s1 / self.count
        var = self.s2 / self.count - mean * mean
        return np.sqrt(var) if var > 0.0 else 0.0


def causal_rolling_std(x, window):
    """Batch wrapper around RollingStd (still causal)."""
    rs = RollingStd(window)
    out = np.empty(len(x), dtype=np.float64)
    for i in range(len(x)):
        out[i] = rs.update(x[i])
    return out


# --------------------------------------------------------------------------
# NON-CAUSAL batch helpers (analysis / plotting only)
# --------------------------------------------------------------------------
def zero_phase_lowpass(x, b, a):
    """NON-CAUSAL zero-phase filter (scipy filtfilt). Analysis only."""
    from scipy.signal import filtfilt
    return filtfilt(b, a, x)


def centered_rolling_std(x, window):
    """NON-CAUSAL centered rolling std via cumulative sums. Analysis only."""
    n = len(x)
    if window < 2:
        return np.zeros(n)
    c1 = np.cumsum(np.insert(x, 0, 0.0))
    c2 = np.cumsum(np.insert(np.square(x), 0, 0.0))
    half = window // 2
    out = np.zeros(n)
    for i in range(n):
        a = max(0, i - half)
        b = min(n, i + half + 1)
        cnt = b - a
        mean = (c1[b] - c1[a]) / cnt
        var = (c2[b] - c2[a]) / cnt - mean * mean
        out[i] = np.sqrt(var) if var > 0.0 else 0.0
    return out
