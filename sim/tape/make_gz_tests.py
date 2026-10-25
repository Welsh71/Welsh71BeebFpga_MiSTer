#!/usr/bin/env python3
"""Build gzip test cases for tb_inflate.v (compared against zlib's own output).

gz_N.hex   compressed input
raw_N.hex  expected decompressed bytes
gz_cases.txt  number of cases
"""
import zlib, gzip, struct, random, os

HERE = os.path.dirname(os.path.abspath(__file__))
rnd = random.Random(1234)

def gz(data, level=6, strategy=zlib.Z_DEFAULT_STRATEGY):
    c = zlib.compressobj(level, zlib.DEFLATED, 31, 9, strategy)   # 31 = gzip wrapper
    return c.compress(data) + c.flush()

def gz_with_header(data, name=b'killer.uef', comment=b'a comment', extra=b'XY\x04\x00abcd'):
    # gzip with FEXTRA, FNAME, FCOMMENT and FHCRC set
    flg = 0x02 | 0x04 | 0x08 | 0x10
    hdr = bytes([0x1F, 0x8B, 8, flg]) + struct.pack('<I', 0) + bytes([0, 3])
    hdr += struct.pack('<H', len(extra)) + extra + name + b'\x00' + comment + b'\x00'
    hdr += struct.pack('<H', zlib.crc32(hdr) & 0xFFFF)
    c = zlib.compressobj(9, zlib.DEFLATED, -15)
    body = c.compress(data) + c.flush()
    return hdr + body + struct.pack('<II', zlib.crc32(data), len(data) & 0xFFFFFFFF)

def text(n):
    words = [b'the', b'BBC', b'Micro', b'tape', b'loading', b'Killer', b'Gorilla', b'*', b'CHAIN', b'\r\n']
    out = bytearray()
    while len(out) < n:
        out += rnd.choice(words) + b' '
    return bytes(out[:n])

def uef_like(n):
    # carrier chunks, data blocks with headers and filenames, like a real tape
    out = bytearray(b'UEF File!\x00\x0a\x00')
    blk = 0
    while len(out) < n:
        out += struct.pack('<HIH', 0x0110, 2, 1500 if blk == 0 else 300)
        payload = bytearray(b'*KILLER\x00') + struct.pack('<IIHHB', 0x1900, 0x8023, blk, 256, 0)
        payload += bytes(rnd.randrange(256) if rnd.random() < 0.3 else 0xEA for _ in range(256))
        out += struct.pack('<HI', 0x0100, len(payload)) + payload
        blk += 1
    return bytes(out)

far = bytes(rnd.randrange(256) for _ in range(40000))
cases = [
    ('text, level 9',               gz(text(3000), 9)),
    ('random 20KB, level 6',        gz(bytes(rnd.randrange(256) for _ in range(20000)), 6)),
    ('stored blocks (level 0)',     gz(text(70000), 0)),
    ('fixed Huffman (Z_FIXED)',     gz(text(8000), 9, zlib.Z_FIXED)),
    ('long runs (distance 1)',      gz(b'A' * 5000 + b'B' * 300 + bytes(range(256)) * 20, 9)),
    ('matches at ~32KB distance',   gz(far[:33000] + far[:7000] + far[100:3000], 9)),
    ('multi-block text 150KB',      gz(text(150000), 6)),
    ('UEF-like tape 60KB',          gz(uef_like(60000), 9)),
    ('header FEXTRA/FNAME/FHCRC',   gz_with_header(text(5000))),
    ('Z_HUFFMAN_ONLY',              gz(text(4000), 6, zlib.Z_HUFFMAN_ONLY)),
    ('Z_RLE',                       gz(b'\x00' * 2000 + text(2000) + b'\xff' * 3000, 6, zlib.Z_RLE)),
    ('empty file',                  gz(b'', 9)),
    ('matches at 32000-32768',      gz(far[:32760] + far[:3000] + far[8:2000], 9)),
]

# fuzz: literals mixed with copies at random distances and lengths
for n in range(20):
    buf = bytearray(rnd.randrange(256) for _ in range(rnd.randrange(1, 64)))
    target = rnd.choice([500, 5000, 40000, 90000])
    while len(buf) < target:
        r = rnd.random()
        if r < 0.4:
            buf += bytes(rnd.randrange(rnd.choice([4, 16, 256])) for _ in range(rnd.randrange(1, 40)))
        else:
            d = rnd.randrange(1, min(len(buf), 32768) + 1)
            l = rnd.randrange(3, 300)
            for _ in range(l):
                buf.append(buf[-d])
    level = rnd.choice([1, 3, 6, 9])
    strat = rnd.choice([zlib.Z_DEFAULT_STRATEGY, zlib.Z_DEFAULT_STRATEGY, zlib.Z_FIXED, zlib.Z_FILTERED])
    cases.append(('fuzz %d (level %d)' % (n, level), gz(bytes(buf), level, strat)))

for i, (name, g) in enumerate(cases):
    raw = gzip.decompress(g)
    with open(os.path.join(HERE, 'gz_%d.hex' % i), 'w') as f:
        f.write(''.join('%02x\n' % b for b in g))
    with open(os.path.join(HERE, 'raw_%d.hex' % i), 'w') as f:
        f.write(''.join('%02x\n' % b for b in raw))
    print('%2d %-28s %7d -> %7d' % (i, name, len(g), len(raw)))
with open(os.path.join(HERE, 'gz_count.hex'), 'w') as f:
    f.write('%02x\n' % len(cases))
with open(os.path.join(HERE, 'gz_cases.txt'), 'w') as f:
    f.write('%d\n' % len(cases))
    for name, _ in cases:
        f.write(name + '\n')
