#!/usr/bin/env python3
"""Verify the built .apk: format, and that the audit fixes are inside it."""

import io
import struct
import sys
import zlib

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

path = sys.argv[1]

with open(path, 'rb') as fh:
    data = fh.read()

assert data[:3] == b'ADB', 'bad magic %r' % data[:4]
body = zlib.decompressobj(-zlib.MAX_WBITS).decompress(data[6:])
assert body[:8] == b'ADB.pckg', 'bad body %r' % body[:8]

print('  magic      : %s' % data[:4].decode())
print('  body magic : %s' % body[:8].decode())
print('  size       : %d bytes' % len(data))

pos = 8
order = []
while pos < len(body):
    while pos < len(body) and pos % 8 and body[pos] == 0:
        pos += 1
    if pos >= len(body):
        break
    v = struct.unpack_from('<I', body, pos)[0]
    if v == 0:
        break
    order.append(v >> 30)
    pos += (v & 0x3FFFFFFF)
    while pos % 8:
        pos += 1

assert order and order[0] == 0, 'first block must be ADB'
assert all(t == 2 for t in order[1:]), 'remaining blocks must be DATA'
print('  blocks     : ADB + %d DATA' % (len(order) - 1))

checks = [
    ('now() reads clock() array', b'const c = clock();', True),
    ('toJson via render()',       b'render(function (x)', True),
    ('printf for errors',         b'cannot bind', True),
    ('ucode script arg',          b'exec ucode ', True),
    ('no sprintf call',           b"sprintf('%J'", False),
    ('no fprintf call',           b'fprintf(', False),
    ('no clock(1) monotonic',     b'clock(1)', False),
    ('no ucode -L misuse',        b'ucode -L ', False),
]

print()
ok = True
for label, needle, want in checks:
    present = needle in body
    good = (present == want)
    ok = ok and good
    print('  %-26s %s  (present=%s want=%s)'
          % (label, 'OK' if good else 'FAIL', present, want))

print()
print('  RESULT: %s' % ('all checks passed' if ok else 'FAILED'))
sys.exit(0 if ok else 1)
