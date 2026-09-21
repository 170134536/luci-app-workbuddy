#!/usr/bin/env python3
"""
Package the luci-app-workbuddy tree into an installable OpenWrt APK v3 file.

Runs anywhere Python 3 runs, including Windows — no Linux, no container.

    python make-package.py
    python make-package.py --arch aarch64_cortex-a53 --debug
"""

import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mkapk import ApkBuilder

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, 'src')

# Executables must keep the execute bit; everything else is 0644.
EXECUTABLE = {
    'etc/init.d/workbuddy',
    'usr/bin/workbuddy-server',
    'usr/bin/workbuddy-ctl',
}

POSTINST = """#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] || {
	chmod 755 /usr/bin/workbuddy-server 2>/dev/null
	chmod 755 /usr/bin/workbuddy-ctl 2>/dev/null
	/etc/init.d/workbuddy enable 2>/dev/null
}
exit 0
"""

PREDEINSTALL = """#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] || {
	/etc/init.d/workbuddy stop 2>/dev/null
	/etc/init.d/workbuddy disable 2>/dev/null
	rm -f /var/run/workbuddy-login.state /tmp/workbuddy-req.json 2>/dev/null
}
exit 0
"""


def enumerate_files(root):
    """
    Yield (install_path, absolute_path) for every file under `root`.

    The source tree mirrors the OpenWrt buildroot convention:

        src/root/...    installs at /...        (etc, usr)
        src/htdocs/...  installs at /www/...    (LuCI static assets)

    The two prefixes are stripped rather than kept, so files land where the
    package manager expects them.
    """
    for dirpath, _, filenames in os.walk(root):
        for fn in sorted(filenames):
            ap = os.path.join(dirpath, fn)
            rp = os.path.relpath(ap, root).replace(os.sep, '/')

            if rp.startswith('root/'):
                target = rp[len('root/'):]
            elif rp.startswith('htdocs/'):
                target = 'www/' + rp[len('htdocs/'):]
            else:
                raise SystemExit(
                    'unmapped source path %r: put it under src/root/ or '
                    'src/htdocs/' % rp)

            yield target, ap


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--name', default='luci-app-workbuddy')
    ap.add_argument('--version', default='1.0.0')
    ap.add_argument('--release', default='1')
    ap.add_argument('--arch', default='aarch64_cortex-a53',
                    help='OpenWrt arch tuple; IPQ6000 is aarch64_cortex-a53')
    ap.add_argument('--debug', action='store_true',
                    help='leave the payload uncompressed for inspection')
    ap.add_argument('--outdir', default=os.path.join(HERE, 'dist'))
    args = ap.parse_args()

    if not os.path.isdir(SRC):
        sys.exit('source tree not found: %s' % SRC)

    os.makedirs(args.outdir, exist_ok=True)

    builder = ApkBuilder(
        name=args.name,
        version='%s-r%s' % (args.version, args.release),
        arch=args.arch,
        description='WorkBuddy relay: share free WorkBuddy models over an '
                    'OpenAI-compatible endpoint',
        url='https://github.com/zero-dream/zerowrt-firmware',
        license_='MIT',
        origin=args.name,
        maintainer='ZeroWrt user',
        depends=[
            'ucode',
            'ucode-mod-uloop',
            'ucode-mod-socket',
            'curl',
            'luci-base',
        ],
    )

    # A fixed timestamp keeps builds reproducible.
    mtime = int(os.environ.get('SOURCE_DATE_EPOCH', time.time()))

    count = 0
    for rel, apath in enumerate_files(SRC):
        with open(apath, 'rb') as fh:
            content = fh.read()

        # Guard against a BOM or CRLF sneaking in from a Windows editor:
        # both break the shell and ucode interpreters on the router.
        changed = False
        if content.startswith(b'\xef\xbb\xbf') and not rel.endswith('.ps1'):
            content = content[3:]
            changed = True
        if b'\r\n' in content:
            content = content.replace(b'\r\n', b'\n')
            changed = True

        mode = 0o755 if rel in EXECUTABLE else 0o644
        builder.add_file('/' + rel, content, mode=mode, mtime=mtime)
        count += 1
        mark = ' (normalized)' if changed else ''
        print('    + %-58s %6d B%s' % (rel, len(content), mark))

    # Directories that must exist even though they hold no packaged files.
    for d in ('etc/config', 'usr/bin', 'usr/share/workbuddy',
              'usr/share/luci/menu.d', 'usr/share/rpcd/acl.d',
              'www/luci-static/resources/view/workbuddy'):
        builder.add_dir_entry(d, mtime=mtime)

    builder.add_script('postinst', POSTINST)
    builder.add_script('predeinstall', PREDEINSTALL)

    blob = builder.build(compress=not args.debug)

    out = os.path.join(
        args.outdir,
        '%s-%s-r%s.apk' % (args.name, args.version, args.release))
    with open(out, 'wb') as fh:
        fh.write(blob)

    print()
    print('==> %d files, %d bytes' % (count, len(blob)))
    print('==> %s' % out)
    print()
    print('Install on the router:')
    print('    scp "%s" root@<router>:/tmp/' % out)
    print("    ssh root@<router> 'apk add --allow-untrusted "
          "/tmp/%s'" % os.path.basename(out))
    return 0


if __name__ == '__main__':
    sys.exit(main())
