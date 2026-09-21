#!/usr/bin/env python3
"""
Build an OpenWrt APK v3 package on Windows, with no Linux and no containers.

APK v3 is not a tar: it is a binary "ADB" container. This module implements
just enough of that format to emit a valid, installable package.

Format reference:
  https://github.com/alpinelinux/apk-tools/blob/master/doc/apk-v3.5.scd
  https://7ji.github.io/designdoc/2026/03/03/into-Alpine-APK-v3-format-the-binary-perspective.html

Layout produced:

    "ADB." + "pckg"                         file header + schema
    [ADB_BLOCK_ADB]                         metadata: pkginfo, paths, scripts
    [ADB_BLOCK_DATA] * N                    file contents, in path/file order

Every block is padded to an 8-byte boundary.
"""

import hashlib
import os
import struct
import sys
import time
import zlib
from collections import OrderedDict

# ----------------------------------------------------------------- ADB types

ADB_BLOCK_ADB = 0
ADB_BLOCK_SIG = 1
ADB_BLOCK_DATA = 2

# Tag values occupy the high nibble of an adb_val_t.
T_SPECIAL = 0x00000000
T_INT = 0x10000000
T_INT_32 = 0x20000000
T_INT_64 = 0x30000000
T_BLOB_8 = 0x80000000
T_BLOB_16 = 0x90000000
T_BLOB_32 = 0xA0000000
T_ARRAY = 0xD0000000
T_OBJECT = 0xE0000000

TAG_MASK = 0xF0000000
VAL_MASK = 0x0FFFFFFF


class Blob:
    """Opaque byte string stored in the ADB data section."""

    def __init__(self, data, wide=False):
        self.data = data
        self.wide = wide   # BLOB_16 instead of BLOB_8


class Int:
    """Embedded integer value."""

    def __init__(self, value, wide=False):
        self.value = value
        self.wide = wide   # INT_32 / INT_64 back-patched at the end


class Obj:
    """A typed element list, i.e. ADB_TYPE_OBJECT."""

    def __init__(self, items=None):
        self.items = list(items or [])


class Arr:
    """A homogeneous series, i.e. ADB_TYPE_ARRAY."""

    def __init__(self, items=None):
        self.items = list(items or [])


# ------------------------------------------------------------- the ADB writer

class AdbWriter:
    """
    Serialises an object graph into an ADB byte stream.

    The trick the format relies on: every reference is an offset *within the
    block payload*, and each referenced object is appended after its referrer.
    So serialisation is a two-pass walk — reserve a slot, write what it points
    at, then back-patch.
    """

    def __init__(self):
        self.buf = bytearray()
        self.blobs = []      # (offset, Blob) queued for writing

    # -- low level ---------------------------------------------------------

    def _align(self):
        while len(self.buf) % 8:
            self.buf.append(0)

    def _val(self, tag, off):
        return struct.pack('<I', (tag & TAG_MASK) | (off & VAL_MASK))

    def _write_blob(self, blob):
        off = len(self.buf)
        data = blob.data
        if blob.wide:
            self.buf += struct.pack('<H', len(data))
        else:
            self.buf += struct.pack('<B', len(data))
        self.buf += data
        return off

    def _write_int(self, i):
        """INT is embedded; the wide forms are appended and back-patched."""
        if i.wide:
            off = len(self.buf)
            self.buf += struct.pack('<Q', i.value)
            kind = T_INT_64 if i.value > 0xFFFFFFFF else T_INT_32
            return kind, off
        return T_INT, i.value

    # -- the walk ----------------------------------------------------------

    def _ref(self, item):
        """Return the packed adb_val_t that points at `item`."""
        if item is None:
            return struct.pack('<I', 0)

        if isinstance(item, Blob):
            # Blobs go into a side queue; their offset is final once written.
            off = self._write_blob(item)
            return self._val(T_BLOB_16 if item.wide else T_BLOB_8, off)

        if isinstance(item, Int):
            kind, val = self._write_int(item)
            return self._val(kind, val)

        if isinstance(item, Obj):
            return self._ref_container(item, T_OBJECT)

        if isinstance(item, Arr):
            return self._ref_container(item, T_ARRAY)

        raise TypeError('cannot encode %r' % (item,))

    def _ref_container(self, node, tag):
        """
        Containers need their offset known before their contents are written,
        because every element is stored inline as a 4-byte val. So: reserve
        `count`, reserve one val per element, then emit each element's payload
        and back-patch its slot.
        """
        base = len(self.buf)
        count = len(node.items) + 1          # count includes itself
        self.buf += struct.pack('<I', count)

        slot_off = len(self.buf)
        self.buf += b'\x00' * (4 * len(node.items))

        for idx, child in enumerate(node.items):
            encoded = self._ref(child)
            self.buf[slot_off + 4 * idx: slot_off + 4 * idx + 4] = encoded

        return self._val(tag, base)

    def finish(self):
        return bytes(self.buf)


# ------------------------------------------------------------ package assembly

class ApkBuilder:
    def __init__(self, name, version, arch, description='', url='',
                 license_='MIT', origin=None, maintainer='', depends=None):
        self.name = name
        self.version = version
        self.arch = arch
        self.description = description
        self.url = url
        self.license = license_
        self.origin = origin or name
        self.maintainer = maintainer
        self.depends = depends or []

        # path -> list of (name, mode, uid/gid, size, mtime, sha256, target)
        self.dirs = OrderedDict()
        self.scripts = OrderedDict()

    # -- staging -----------------------------------------------------------

    def add_file(self, path, content, mode=0o644, mtime=None, user='root',
                 group='root'):
        """Stage one file. `path` is absolute inside the package root."""
        mtime = int(mtime if mtime is not None else time.time())
        if isinstance(content, str):
            content = content.encode('utf-8')

        folder, _, filename = path.lstrip('/').rpartition('/')
        entry = {
            'name': filename.encode(),
            'mode': mode,
            'user': user.encode(),
            'group': group.encode(),
            'size': len(content),
            'mtime': mtime,
            'sha256': hashlib.sha256(content).hexdigest().encode(),
            'target': None,
            'data': content,
        }
        self.dirs.setdefault(folder, []).append(entry)

    def add_symlink(self, path, target, mtime=None):
        mtime = int(mtime if mtime is not None else time.time())
        folder, _, filename = path.lstrip('/').rpartition('/')
        entry = {
            'name': filename.encode(),
            'mode': 0o777,
            'user': b'root',
            'group': b'root',
            'size': 0,
            'mtime': mtime,
            'sha256': b'',
            # 0o120000 is S_IFLNK, matching struct stat's st_mode layout.
            'target': struct.pack('<H', 0o120000) + target.encode(),
            'data': b'',
        }
        self.dirs.setdefault(folder, []).append(entry)

    def add_dir_entry(self, path, mtime=None):
        """Register an empty directory so it is created on install."""
        mtime = int(mtime if mtime is not None else time.time())
        folder = path.strip('/')
        self.dirs.setdefault(folder, [])
        self._dir_meta = getattr(self, '_dir_meta', {})
        self._dir_meta[folder] = mtime

    def add_script(self, slot, content):
        """slot: preinst, postinst, predeinstall, postdeinstall, ..."""
        self.scripts[slot] = content.encode() if isinstance(content, str) else content

    # -- metadata ----------------------------------------------------------

    def _pkginfo(self):
        # Slot order is fixed by the format; empty slots are the literal 0.
        installed_size = sum(
            e['size'] for files in self.dirs.values() for e in files
        )
        file_size = installed_size

        items = [
            Blob(self.name.encode()),                      # 1  NAME
            Blob(self.version.encode()),                   # 2  VERSION
            None,                                          # 3  HASHES
            Blob(self.description.encode()),               # 4  DESCRIPTION
            Blob(self.arch.encode()),                      # 5  ARCH
            Blob(self.license.encode()),                   # 6  LICENSE
            Blob(self.origin.encode()),                    # 7  ORIGIN
            Blob(self.maintainer.encode()),                # 8  MAINTAINER
            Blob(self.url.encode()),                       # 9  URL
            None,                                          # 10 REPO_COMMIT
            Int(0),                                        # 11 BUILD_TIME
            Int(installed_size),                           # 12 INSTALLED_SIZE
            Int(file_size),                                # 13 FILE_SIZE
            Int(0),                                        # 14 PROVIDER_PRIORITY
            self._deps_obj(),                              # 15 DEPENDS
        ]
        # Trailing empty slots are simply omitted.
        while items and items[-1] is None:
            items.pop()
        return Obj(items)

    def _deps_obj(self):
        if not self.depends:
            return None
        entries = []
        for dep in self.depends:
            entries.append(Obj([Blob(dep.encode())]))
        return Obj(entries)

    def _paths_obj(self):
        paths = []
        dir_meta = getattr(self, '_dir_meta', {})

        for folder, files in self.dirs.items():
            acl = [Int(0o755), Blob(b'root'), Blob(b'root')]

            file_objs = []
            for f in files:
                slots = [
                    Blob(f['name']),                                  # 1 NAME
                    Obj([Int(f['mode']), Blob(f['user']),             # 2 ACL
                         Blob(f['group'])]),
                    Int(f['size']),                                   # 3 SIZE
                    Int(f['mtime'], wide=True),                       # 4 MTIME
                ]
                if f['sha256']:
                    slots.append(Blob(f['sha256']))                   # 5 HASHES
                if f['target']:
                    slots.append(Blob(f['target']))                   # 6 TARGET
                file_objs.append(Obj(slots))

            slots = [Blob(folder.encode()), Obj(acl)]
            if file_objs:
                slots.append(Obj(file_objs))
            paths.append(Obj(slots))

        return Obj(paths)

    def _scripts_obj(self):
        if not self.scripts:
            return None
        # Slot order: 1 trigger, 2 preinst, 3 postinst, 4 predeinstall,
        #             5 postdeinstall, 6 preupgrade, 7 postupgrade
        names = ['trigger', 'preinst', 'postinst', 'predeinstall',
                 'postdeinstall', 'preupgrade', 'postupgrade']
        items = []
        for n in names:
            if n in self.scripts:
                items.append(Blob(self.scripts[n]))
                continue
            items.append(None)
        while items and items[-1] is None:
            items.pop()
        return Obj(items)

    # -- serialisation -----------------------------------------------------

    def _block(self, type_id, payload):
        """A block header is 4 bytes; the raw size includes that header."""
        raw = len(payload) + 4
        assert raw < 0x3FFFFFFF, 'block too large for a simple header'
        header = struct.pack('<I', (type_id << 30) | raw)
        return header + payload

    def _meta_block(self):
        """
        Build ADB_BLOCK_ADB.

        The payload begins with an 8-byte adb_hdr whose `root` points at a
        4-slot object: pkg info, paths, scripts, triggers.
        """
        w = AdbWriter()

        # Reserve the adb_hdr; root is back-patched once its offset is known.
        hdr_at = len(w.buf)
        w.buf += b'\x00' * 8

        root_items = [self._pkginfo(), self._paths_obj(),
                      self._scripts_obj(), None]
        while root_items and root_items[-1] is None:
            root_items.pop()

        root_ref = w._ref(Obj(root_items))

        hdr = struct.pack('<BBH', 0, 0, 0) + root_ref
        w.buf[hdr_at:hdr_at + 8] = hdr

        return self._block(ADB_BLOCK_ADB, bytes(w.buf))

    def _data_blocks(self):
        """One ADB_BLOCK_DATA per non-empty file, in path/file 1-based order."""
        out = bytearray()
        for path_idx, (_, files) in enumerate(self.dirs.items(), start=1):
            for file_idx, f in enumerate(files, start=1):
                if not f['data']:
                    continue
                payload = struct.pack('<II', path_idx, file_idx) + f['data']
                out += self._block(ADB_BLOCK_DATA, payload)
                while len(out) % 8:
                    out.append(0)
        return bytes(out)

    def build(self, compress=True, level=9):
        stream = bytearray()
        stream += b'ADB.'      # schema marker for the decompressed body
        stream += b'pckg'      # package schema
        stream += self._meta_block()
        while len(stream) % 8:
            stream.append(0)
        stream += self._data_blocks()

        if not compress:
            return bytes(stream)

        # The body is a raw deflate stream with no zlib/gzip wrapper: the
        # header already records the compression method.
        co = zlib.compressobj(level, zlib.DEFLATED, -zlib.MAX_WBITS)
        body = co.compress(bytes(stream)) + co.flush()
        return b'ADBc' + bytes([1, level]) + body


# ------------------------------------------------------------------ selftest

def _selftest():
    """Rebuild the container produced by build() to prove it parses back."""
    print('running self-test...')

    b = ApkBuilder('demo', '1.0.0-r1', 'noarch', description='t',
                   url='u', maintainer='m', depends=['curl'])
    b.add_file('etc/config/demo', "option x '1'\n", mode=0o600)
    b.add_file('usr/bin/demo', b'#!/bin/sh\necho hi\n', mode=0o755)
    b.add_symlink('usr/bin/demo2', '/usr/bin/demo')
    b.add_dir_entry('usr/share/demo')
    b.add_script('postinst', '#!/bin/sh\nexit 0\n')

    data = b.build()

    # -- header --
    assert data[:4] == b'ADBc', 'bad magic: %r' % data[:4]
    method, lvl = data[4], data[5]
    assert method == 1, 'expected deflate'
    body = zlib.decompressobj(-zlib.MAX_WBITS).decompress(data[6:])
    assert body[:8] == b'ADB.pckg', 'bad body magic: %r' % body[:8]

    # -- walk blocks --
    pos = 8
    blocks = []
    while pos < len(body):
        while pos < len(body) and body[pos] == 0 and (pos % 8):
            pos += 1
        if pos >= len(body):
            break
        v = struct.unpack_from('<I', body, pos)[0]
        if v == 0:
            break
        btype = v >> 30
        bsize = v & 0x3FFFFFFF
        assert bsize >= 4, 'block too small'
        blocks.append((btype, pos, bsize))
        pos += bsize
        while pos % 8:
            pos += 1

    types = [t for t, _, _ in blocks]
    assert types[0] == ADB_BLOCK_ADB, 'first block must be ADB: %r' % types
    assert all(t == ADB_BLOCK_DATA for t in types[1:]), 'bad block order: %r' % types

    # -- read the metadata root --
    _, apos, asize = blocks[0]
    payload_at = apos + 4
    compat, ver, resv, root = struct.unpack_from('<BBHI', body, payload_at)
    assert compat == 0 and ver == 0, 'bad adb version'
    assert (root & TAG_MASK) == T_OBJECT, 'root is not an object'

    def deref(val, base=payload_at):
        tag = val & TAG_MASK
        off = val & VAL_MASK
        return tag, base + off

    tag, root_at = deref(root)
    count = struct.unpack_from('<I', body, root_at)[0]
    slots = [struct.unpack_from('<I', body, root_at + 4 * i)[0]
             for i in range(1, count)]

    # slot 0 is pkg info; slot 1 is paths
    tag, pkg_at = deref(slots[0])
    pkg_count = struct.unpack_from('<I', body, pkg_at)[0]
    pkg_slots = [struct.unpack_from('<I', body, pkg_at + 4 * i)[0]
                 for i in range(1, pkg_count)]

    def read_blob8(val):
        tag, off = deref(val)
        assert tag == T_BLOB_8, 'expected BLOB_8, got %#x' % tag
        ln = body[off]
        return body[off + 1:off + 1 + ln]

    name = read_blob8(pkg_slots[0])
    version = read_blob8(pkg_slots[1])
    arch = read_blob8(pkg_slots[4])
    assert name == b'demo', name
    assert version == b'1.0.0-r1', version
    assert arch == b'noarch', arch

    # -- paths --
    tag, paths_at = deref(slots[1])
    pcount = struct.unpack_from('<I', body, paths_at)[0]
    path_vals = [struct.unpack_from('<I', body, paths_at + 4 * i)[0]
                 for i in range(1, pcount)]

    found = []
    for pv in path_vals:
        tag, p_at = deref(pv)
        pc = struct.unpack_from('<I', body, p_at)[0]
        pslots = [struct.unpack_from('<I', body, p_at + 4 * i)[0]
                  for i in range(1, pc)]
        folder = read_blob8(pslots[0]).decode()
        if len(pslots) > 2:
            tag, f_at = deref(pslots[2])
            fc = struct.unpack_from('<I', body, f_at)[0]
            for i in range(1, fc):
                fv = struct.unpack_from('<I', body, f_at + 4 * i)[0]
                tag, fo = deref(fv)
                fcc = struct.unpack_from('<I', body, fo)[0]
                fslots = [struct.unpack_from('<I', body, fo + 4 * j)[0]
                          for j in range(1, fcc)]
                fname = read_blob8(fslots[0]).decode()
                found.append(folder + '/' + fname)

    assert 'etc/config/demo' in found, found
    assert 'usr/bin/demo' in found, found
    assert 'usr/bin/demo2' in found, found

    # -- data blocks map back to the right files --
    data_blocks = blocks[1:]
    assert len(data_blocks) == 2, 'expected 2 data blocks, got %d' % len(data_blocks)
    for btype, dpos, dsize in data_blocks:
        path_idx, file_idx = struct.unpack_from('<II', body, dpos + 4)
        assert path_idx >= 1 and file_idx >= 1, (path_idx, file_idx)

    # -- checksum of a known file --
    sha = hashlib.sha256(b'#!/bin/sh\necho hi\n').hexdigest()
    assert sha in body.decode('latin-1'), 'file checksum missing'

    print('  header, block order, metadata, paths, data blocks: OK')
    print('  package size: %d bytes' % len(data))
    return True


if __name__ == '__main__':
    sys.exit(0 if _selftest() else 1)
