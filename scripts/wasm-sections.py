#!/usr/bin/env python3
"""Print one line per WebAssembly section: id, name, size, sha256 prefix.

Exists so a source/ledger divergence can be located rather than just reported.
Soroban embeds doc comments in `contractspecv0`, so editing a comment above a
public entry point changes the module hash while the code section stays byte for
byte identical. That is a very different fact from the code having changed, and
a check that cannot tell them apart has to treat both as the worse one.
"""
import hashlib
import sys


def sections(path):
    b = open(path, 'rb').read()
    if b[:4] != b'\x00asm':
        raise SystemExit('not a wasm module: %s' % path)
    i, out = 8, []
    while i < len(b):
        sid = b[i]
        i += 1
        size = shift = 0
        while True:
            byte = b[i]
            i += 1
            size |= (byte & 0x7F) << shift
            shift += 7
            if not byte & 0x80:
                break
        payload = b[i:i + size]
        i += size
        name = ''
        if sid == 0:                      # custom section: length-prefixed name
            n = sh = j = 0
            while True:
                byte = payload[j]
                j += 1
                n |= (byte & 0x7F) << sh
                sh += 7
                if not byte & 0x80:
                    break
            name = payload[j:j + n].decode('utf-8', 'replace')
        out.append((sid, name, len(payload), hashlib.sha256(payload).hexdigest()))
    return out


if __name__ == '__main__':
    for sid, name, size, digest in sections(sys.argv[1]):
        print('%d|%s|%d|%s' % (sid, name, size, digest))
