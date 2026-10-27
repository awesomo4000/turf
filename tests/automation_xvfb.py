#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 awesomo4000
"""Run the real Linux socket suite on a private X display and D-Bus session."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def main():
    for tool in ('xvfb-run', 'Xvfb', 'xauth', 'dbus-run-session'):
        if not shutil.which(tool):
            raise SystemExit(f'Missing test dependency: {tool}')
    script = Path(__file__).resolve()
    if '--inside-xvfb' not in sys.argv:
        env = os.environ.copy()
        for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'DBUS_SESSION_BUS_ADDRESS'):
            env.pop(key, None)
        env['GDK_BACKEND'] = 'x11'
        env['LIBGL_ALWAYS_SOFTWARE'] = '1'
        with tempfile.TemporaryDirectory(prefix='turf-xvfb-', dir='/tmp') as runtime:
            env['XDG_RUNTIME_DIR'] = runtime
            try:
                return subprocess.call(['xvfb-run', '-a', '-s', '-screen 0 1280x1024x24 -nolisten tcp',
                                        'dbus-run-session', '--', sys.executable, str(script),
                                        '--inside-xvfb', *sys.argv[1:]], env=env)
            finally:
                # Desktop portals can create FUSE mounts in our private runtime.
                # Detach only those mounts before TemporaryDirectory removes it.
                for name in ('doc', 'gvfs'):
                    mount = Path(runtime) / name
                    if os.path.ismount(mount):
                        unmount = shutil.which('fusermount3') or shutil.which('fusermount')
                        if not unmount:
                            raise RuntimeError(f'Cannot unmount test runtime: {mount}')
                        result = subprocess.run([unmount, '-u', '-z', str(mount)], capture_output=True)
                        if result.returncode and os.path.ismount(mount):
                            raise RuntimeError(f'Cannot unmount test runtime: {mount}')
    # A private display needs no window manager. X11 input targets Turf directly.
    import automation_linux
    import automation_macos as suite
    sys.argv.remove('--inside-xvfb')
    print(f'Running Turf tests on private display {os.environ["DISPLAY"]}', flush=True)
    def stage(pid, name):
        print(f'Private-display check: {name}', flush=True)
    suite.run_checks(stage, engine='WebKitGTK')
    automation_linux.lifecycle_checks()
    suite.run_checks(stage, engine='WebKitGTK', background=False)
    return 0


if __name__ == '__main__':
    sys.exit(main())
