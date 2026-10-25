#!/usr/bin/env python3
"""Build test tape images for tb_uef.v.

img_a.hex  uncompressed UEF, 1200 baud: carrier, &0100 data, &0112 gap,
           &0111 carrier+dummy, &0116 float gap, &0104 data, &0102 explicit
           bits, unknown chunk (skipped)
img_b.hex  uncompressed UEF, 300 baud (&0117)
img_c.hex  Main_MiSTer bitstream (same algorithm as uef_reader.cpp)
img_d.hex  gzip-compressed UEF (decompressed in the core)
img_f.hex  corrupt gzip (must be refused)
exp_*.hex  bytes the ACIA should receive, in order
"""
import gzip, struct, os

HERE = os.path.dirname(os.path.abspath(__file__))

def chunk(cid, payload):
    return struct.pack('<HI', cid, len(payload)) + payload

def uef(chunks):
    return b'UEF File!\x00' + bytes([10, 0]) + b''.join(chunks)

def data(n, seed):
    out = bytearray([0x2A])                       # '*' sync byte
    for i in range(1, n):
        out.append((i * 37 + seed * 11 + (i >> 2)) & 0xFF)
    out[-1] = 0x00
    if n > 2: out[-2] = 0xFF
    return bytes(out)

def explicit_bits(bs):
    bits = []
    for b in bs:
        bits += [0] + [(b >> i) & 1 for i in range(8)] + [1]
    unused = (-len(bits)) % 8
    bits += [0] * unused
    packed = bytearray()
    for i in range(0, len(bits), 8):
        packed.append(sum(bits[i + k] << k for k in range(8)))
    return bytes([unused]) + bytes(packed)

def write_hex(name, bs):
    with open(os.path.join(HERE, name), 'w') as f:
        for b in bs:
            f.write('%02x\n' % b)

# ---------- image A ----------
d1, d2, d3, d4 = data(40, 1), data(12, 2), data(6, 3), data(3, 4)
img_a = uef([
    chunk(0x0000, b'test tape\x00'),                       # info: skipped
    chunk(0x0110, struct.pack('<H', 1500)),                # ~0.62s leader
    chunk(0x0100, d1),
    chunk(0x0110, struct.pack('<H', 300)),
    chunk(0x0112, struct.pack('<H', 600)),                 # 0.25s gap
    chunk(0x0111, struct.pack('<HH', 600, 300)),           # carrier, &AA, carrier
    chunk(0x0100, d2),
    chunk(0x0110, struct.pack('<H', 300)),
    chunk(0x0116, struct.pack('<f', 0.1)),                 # 0.1s gap
    chunk(0x0110, struct.pack('<H', 600)),
    chunk(0x0104, bytes([8, ord('N'), 1]) + d3),
    chunk(0x0110, struct.pack('<H', 300)),
    chunk(0x0102, explicit_bits(d4)),
    chunk(0x0123, b'\x11\x22\x33\x44'),                    # unknown: skipped
    chunk(0x0110, struct.pack('<H', 300)),
])
exp_a = d1 + b'\xAA' + d2 + d3 + d4

# ---------- image B: 300 baud ----------
d5 = data(8, 5)
img_b = uef([
    chunk(0x0117, struct.pack('<H', 300)),
    chunk(0x0110, struct.pack('<H', 1000)),
    chunk(0x0100, d5),
    chunk(0x0110, struct.pack('<H', 200)),
])
exp_b = d5

# ---------- image C: Main_MiSTer bitstream ----------
# uef_reader.cpp: carrier/gap lengths treated as ms at 1201.92 baud;
# &0100 = 10 bits per byte; &0111 = pre + 20 bits of 'A' 'A' framed + post;
# &0110 -> 1s, &0112 -> 0s. Bits packed MSB first.
UEF_BAUD = 1000000.0 / (16.0 * 52.0)
d6 = data(20, 6)
c_chunks = [(0x0110, 600), (0x0100, d6), (0x0111, (200, 100)), (0x0110, 200)]
bits = []
for cid, v in c_chunks:
    if cid == 0x0110:
        bits += [1] * int(v * (UEF_BAUD / 1000.0))
    elif cid == 0x0100:
        for b in v:
            bits += [0] + [(b >> i) & 1 for i in range(8)] + [1]
    elif cid == 0x0111:
        pre, post = int(v[0] * (UEF_BAUD / 1000.0)), int(v[1] * (UEF_BAUD / 1000.0))
        bits += [1] * pre
        for k in range(20):
            p = k % 10
            bits.append(0 if p == 0 else 1 if p == 9 else (ord('A') >> (p - 1)) & 1)
        bits += [1] * post
bits += [0] * ((-len(bits)) % 8)
img_c = bytes(sum(bits[i + k] << (7 - k) for k in range(8)) for i in range(0, len(bits), 8))
exp_c = d6 + b'AA'

# ---------- image D: gzip (decompressed in the core) ----------
img_d = gzip.compress(img_b)

# ---------- image F: corrupt gzip (must be refused) ----------
img_f = bytes([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 3]) + bytes((i * 73 + 5) & 0xFF for i in range(200))

for n, bs in [('img_a.hex', img_a), ('img_b.hex', img_b), ('img_c.hex', img_c),
              ('img_d.hex', img_d), ('img_f.hex', img_f), ('exp_a.hex', exp_a), ('exp_b.hex', exp_b),
              ('exp_c.hex', exp_c)]:
    write_hex(n, bs)
print('sizes: a=%d b=%d c=%d d=%d  expected bytes: a=%d b=%d c=%d'
      % (len(img_a), len(img_b), len(img_c), len(img_d), len(exp_a), len(exp_b), len(exp_c)))
