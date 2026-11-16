"""Fabrique les bruitages du Videur (fichiers .wav), sans aucun fichier externe.
Usage : python3 make_sounds.py <dossier de sortie>"""
import math
import os
import random
import struct
import sys
import wave

SR = 44100
random.seed(3)


def write(path, x, level=0.8):
    peak = max(1e-9, max(abs(v) for v in x))
    g = level / peak
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1.0, min(1.0, v * g)) * 32767)) for v in x))


def stomp():
    # Pas lourd : un coup sourd qui descend.
    n, ph, out, y = int(SR * 0.35), 0.0, [], 0.0
    a = 1 - math.exp(-2 * math.pi * 500 / SR)
    for i in range(n):
        t = i / SR
        f = 35 + 95 * math.exp(-t / 0.05)
        ph += 2 * math.pi * f / SR
        y += a * (random.uniform(-1, 1) - y)
        out.append(math.sin(ph) * math.exp(-t / 0.09) + 0.6 * y * math.exp(-t / 0.02))
    return out


def buzzer():
    # « Refusé » : deux bzz graves, comme à l'entrée d'une boîte de nuit.
    def bzz(dur):
        n, out = int(SR * dur), []
        for i in range(n):
            t = i / SR
            v = (1.0 if math.sin(2 * math.pi * 150 * t) > 0 else -1.0) * 0.5 + \
                (1.0 if math.sin(2 * math.pi * 151.5 * t) > 0 else -1.0) * 0.5
            env = min(1.0, t / 0.01) * min(1.0, (dur - t) / 0.03)
            out.append(v * env)
        return out
    return bzz(0.26) + [0.0] * int(SR * 0.08) + bzz(0.42)


if __name__ == "__main__":
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(out_dir, exist_ok=True)
    write(os.path.join(out_dir, "stomp.wav"), stomp(), 0.9)
    write(os.path.join(out_dir, "buzzer.wav"), buzzer(), 0.35)
