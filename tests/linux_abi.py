#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 awesomo4000
"""Check Turf's hand-declared Linux ABI against the installed C headers."""
import os
from pathlib import Path
import re
import shlex
import subprocess

root = Path(__file__).resolve().parents[1]
source = (root / 'src/platforms/linux/bindings.zig').read_text()
callbacks = re.findall(r'pub const (\w+) = \*const fn \((.*?)\) callconv\(\.c\) (\w+);', source)
callback_names = {name for name, _, _ in callbacks}


def c_type(zig):
    zig = zig.strip().removeprefix('?')
    scalars = {'void': 'void', 'c_int': 'int', 'c_uint': 'unsigned int',
               'c_ulong': 'unsigned long', 'isize': 'ptrdiff_t', 'gboolean': 'int',
               '[*:0]const u8': 'const char *', '[*:0]u8': 'char *',
               '[*]const [*:0]const u8': 'const char * const *', '*anyopaque': 'void *'}
    if zig in scalars:
        return scalars[zig]
    if zig.startswith('*'):
        return zig[1:] + ' *'
    if zig in callback_names:
        return 'Turf_' + zig
    raise ValueError(f'Unrecognized ABI type: {zig}')


def args(types):
    return ', '.join(c_type(t) for t in types.split(',')) if types else 'void'


lines = ['#include <stddef.h>', '#include <gtk/gtk.h>',
         '#include <webkit/webkit.h>', '#include <jsc/jsc.h>']
for name, parameters, result in callbacks:
    lines.append(f'typedef {c_type(result)} (*Turf_{name})({args(parameters)});')
    lines.append(f'_Static_assert(__builtin_types_compatible_p(Turf_{name}, {name}), "{name}");')
functions = re.findall(r'pub extern fn (\w+)\((.*?)\) ([^;]+);', source)
for name, parameters, result in functions:
    lines.append(f'_Static_assert(__builtin_types_compatible_p(__typeof__(&{name}), '
                 f'{c_type(result)} (*)({args(parameters)})), "{name}");')
for name, value in re.findall(r'pub const (\w+): c_(?:u?int) = (\d+);', source):
    lines.append(f'_Static_assert({name} == {value}, "{name}");')
flags = shlex.split(subprocess.check_output(
    ['pkg-config', '--cflags', 'gtk4', 'webkitgtk-6.0', 'javascriptcoregtk-6.0'], text=True))
subprocess.run([*shlex.split(os.environ.get('CC', 'cc')), '-x', 'c', '-std=c11',
                '-fsyntax-only', *flags, '-'], input='\n'.join(lines), text=True, check=True)
print(f'Checked {len(functions)} Linux function signatures, callbacks, and constants against system headers.')
