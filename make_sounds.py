"""Synthesizes Hanadi Timer's chimes as soft bell tones (WAV, 44.1 kHz mono).

Usage: python3 make_sounds.py <output-dir>
"""
import math
import struct
import sys
import wave
from pathlib import Path

RATE = 44100
C5, D5, E5, G5, A5, C6, E6, G6 = 523.25, 587.33, 659.25, 783.99, 880.0, 1046.5, 1318.5, 1568.0


def bell(freq, start, length, amp=1.0, decay=4.0):
    """One bell note: a few soft partials with a quick attack and exponential fade."""
    partials = [(1.0, 1.0), (2.0, 0.35), (3.0, 0.15), (4.2, 0.06)]
    return [(start, freq * ratio, length, amp * a, decay * (1 + i * 0.6)) for i, (ratio, a) in enumerate(partials)]


def render(notes, total, gain=0.55):
    n = int(total * RATE)
    buf = [0.0] * n
    for start, freq, length, amp, decay in notes:
        s0 = int(start * RATE)
        for i in range(int(length * RATE)):
            j = s0 + i
            if j >= n:
                break
            t = i / RATE
            attack = min(1.0, t / 0.006)
            buf[j] += amp * attack * math.exp(-decay * t) * math.sin(2 * math.pi * freq * t)
    peak = max(abs(x) for x in buf) or 1.0
    return [x / peak * gain for x in buf]


def write(path, samples):
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, x)) * 32767)) for x in samples))


def seq(freqs, step, length, amp=1.0, decay=4.0, offset=0.0):
    out = []
    for k, f in enumerate(freqs):
        out += bell(f, offset + k * step, length, amp, decay)
    return out


SOUNDS = {
    # "Let's go": two bright rising notes.
    "start": (seq([G5, C6], 0.09, 0.6, decay=5), 0.75),
    # Back to work: a quick rising run.
    "back": (seq([C5, E5, G5, C6], 0.07, 0.55, decay=5), 0.8),
    # Break: slow, soft, falling. Time to relax.
    "break": (seq([G5, E5, C5], 0.18, 0.9, amp=0.8, decay=3.2), 1.4),
    # Milestone cheer: a sparkle on top of a bright chord.
    "milestone": (bell(E5, 0, 1.2, 0.7, 3) + bell(G5, 0, 1.2, 0.7, 3) + seq([C6, E6, G6], 0.08, 0.7, 0.6, 4, offset=0.12), 1.4),
    # Done: a level-up run that lands on a big chord.
    "done": (seq([C5, E5, G5, C6], 0.11, 0.6, decay=4) + bell(C6, 0.46, 1.6, 0.9, 2) + bell(G5, 0.46, 1.6, 0.6, 2)
             + bell(E6, 0.46, 1.6, 0.4, 2.4), 2.1),
}

if __name__ == "__main__":
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    for name, (notes, total) in SOUNDS.items():
        write(out / f"{name}.wav", render(notes, total))
        print(name)
