#!/usr/bin/env python3
"""Pack BeebEm's disc drive and relay samples into sounds.rom for the core.

Usage:  python make_sounds_rom.py <BeebEm folder> [sounds.rom]

The samples come with BeebEm (GPL v2, https://github.com/stardot/beebem-windows):
raw 8-bit unsigned mono at 44.1 kHz. The core loads sounds.rom from the menu
("Drive Sounds file"), keeps it in DDR3 and plays the samples as BeebEm does.

Layout (all numbers little-endian):
  0   "BSND"
  4   version (1)
  5   number of samples (7)
  6   sample rate (44100)
  8   7 x { offset u32, length u32 }, in BeebEm's order:
        RelayOn, RelayOff, DriveMotor, HeadLoad, HeadUnload, HeadSeek, HeadStep
  64  sample data
The whole file must stay under 128 KB (the core's DDR3 area for it).
"""
import os
import struct
import sys

NAMES = ["RelayOn", "RelayOff", "DriveMotor", "HeadLoad",
         "HeadUnload", "HeadSeek", "HeadStep"]
HEADER = 64
LIMIT = 128 * 1024


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    src = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else "sounds.rom"

    data = []
    for n in NAMES:
        with open(os.path.join(src, n + ".snd"), "rb") as f:
            data.append(f.read())

    hdr = bytearray(b"BSND" + bytes([1, len(NAMES)]) + struct.pack("<H", 44100))
    off = HEADER
    for d in data:
        hdr += struct.pack("<II", off, len(d))
        off += len(d)
    hdr += bytes(HEADER - len(hdr))
    rom = bytes(hdr) + b"".join(data)
    if len(rom) > LIMIT:
        sys.exit("sounds.rom would be %d bytes; the core allows %d" % (len(rom), LIMIT))

    with open(out, "wb") as f:
        f.write(rom)
    for n, d in zip(NAMES, data):
        print("%-11s %6d bytes  %5.0f ms" % (n, len(d), len(d) / 44.1))
    print("%s: %d bytes" % (out, len(rom)))


if __name__ == "__main__":
    main()
