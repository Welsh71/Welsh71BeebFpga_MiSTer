#!/usr/bin/env python3
"""Write rom.hex and rom_len.hex from sounds.rom for tb_drive_sound.v."""
import sys
d = open(sys.argv[1] if len(sys.argv) > 1 else "sounds.rom", "rb").read()
open("rom.hex", "w").write("\n".join("%02x" % b for b in d) + "\n")
open("rom_len.hex", "w").write("%08x\n" % len(d))
