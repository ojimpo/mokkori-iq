"""Quick structural inspection of one Brunner session CSV."""
import sys
import numpy as np
import pandas as pd

default = "data/brunner/data/processed_30hz_relabeled/0/Freestyle_1527873200322.csv"
path = sys.argv[1] if len(sys.argv) > 1 else default

df = pd.read_csv(path)
print("path:", path)
print("shape:", df.shape)
print("columns:", list(df.columns))
print("dtypes head:", dict(df.dtypes.astype(str)))
print()

print("label value counts:")
print(df["label"].value_counts().sort_index())
print()

ts = df["timestamp"].to_numpy(dtype=np.float64)
dt = np.diff(ts)
dt_ms = dt / 1e6
print("duration (s):", (ts[-1] - ts[0]) / 1e9)
print("dt median (ms):", float(np.median(dt_ms)))
print("implied Hz from median dt:", 1000.0 / float(np.median(dt_ms)))
print("n rows:", len(df))
print()

acc = df[["ACC_0", "ACC_1", "ACC_2"]].to_numpy(dtype=np.float64)
norm_computed = np.sqrt(np.square(acc).sum(axis=1))
print("ACC_012 precomputed range:", float(df["ACC_012"].min()), float(df["ACC_012"].max()))
print("norm computed range:", float(norm_computed.min()), float(norm_computed.max()))
print("max abs diff precomputed-vs-computed:", float(np.max(np.abs(df["ACC_012"].to_numpy() - norm_computed))))
print()

lab = df["label"].to_numpy()
turns = []
i = 0
n = len(lab)
while i < n:
    if lab[i] == 5:
        j = i
        while j < n and lab[j] == 5:
            j += 1
        turns.append((i, j - 1, j - i))
        i = j
    else:
        i += 1
print("num turn segments:", len(turns))
if turns:
    lens = np.array([t[2] for t in turns])
    print("turn seg length samples min/median/max:", int(lens.min()), int(np.median(lens)), int(lens.max()))
    print("turn seg length seconds median:", float(np.median(lens)) / 30.0)
    print("first 5 turn segments:", turns[:5])
