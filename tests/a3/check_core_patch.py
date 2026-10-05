#!/usr/bin/env python3
"""Host checks of the hash-pinned private core patch; never uses hardware.
Usage: python3 tests/a3/check_core_patch.py /path/to/private/nrf52/1.1.13
"""
from pathlib import Path
import hashlib, subprocess, sys, tempfile
repo = Path(__file__).resolve().parents[2]
core = Path(sys.argv[1])
paths = ['cores/nRF5/wiring.c',
         'variants/Seeed_XIAO_nRF52840_Sense/variant.cpp',
         'variants/Seeed_XIAO_nRF52840_Sense/variant.h']
with tempfile.TemporaryDirectory() as d:
    root = Path(d)
    for name in paths:
        p = core/name
        orig = p.with_suffix(p.suffix+'.a3-original')
        data = (orig if orig.exists() else p).read_bytes()
        target = root/name
        target.parent.mkdir(parents=True,exist_ok=True)
        target.write_bytes(data)
    cmd = [sys.executable,str(repo/'tools/prepare_a3_core.py'),str(root)]
    subprocess.run(cmd,check=True,stdout=subprocess.DEVNULL)
    first = [hashlib.sha256((root/p).read_bytes()).hexdigest() for p in paths]
    subprocess.run(cmd,check=True,stdout=subprocess.DEVNULL)
    assert first == [hashlib.sha256((root/p).read_bytes()).hexdigest() for p in paths]
    # Even if the patched marker is present, an unknown original is rejected.
    original = (root/paths[0]).with_suffix('.c.a3-original')
    original.write_bytes(original.read_bytes()+b'\nunknown upstream revision\n')
    refused = subprocess.run(cmd,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    assert refused.returncode and b'Refusing unexpected core source' in refused.stderr
    stubs = root/'stubs'; stubs.mkdir()
    for h in ('Arduino.h','nrf_gpio.h','HardwarePWM.h'): (stubs/h).write_text('')
    preprocess = subprocess.run(['g++','-E','-x','c++','-DARDUINO_Seeed_XIAO_nRF52840_Sense',
        '-I'+str(stubs),str(repo/'firmware/flash_logger/a3_hardware.h')],
        stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    assert preprocess.returncode and b'A3 requires the patched' in preprocess.stderr
print('PASS: exact-core patch idempotence, unknown-revision refusal, stock-core preprocessing guard')
