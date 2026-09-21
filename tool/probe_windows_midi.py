"""Read-only WinMM open/close probe, isolated from Flutter and time bounded.

Never sends MIDI data. The parent terminates only its own stalled probe process.
"""
import argparse
import ctypes as c
import subprocess
import sys
import time


def probe(name):
    winmm = c.WinDLL('winmm')

    class InCaps(c.Structure):
        _fields_ = [('mid', c.c_ushort), ('pid', c.c_ushort),
                    ('version', c.c_uint32), ('name', c.c_wchar * 32),
                    ('support', c.c_uint32)]

    class OutCaps(c.Structure):
        _fields_ = [('mid', c.c_ushort), ('pid', c.c_ushort),
                    ('version', c.c_uint32), ('name', c.c_wchar * 32),
                    ('technology', c.c_ushort), ('voices', c.c_ushort),
                    ('notes', c.c_ushort), ('mask', c.c_ushort),
                    ('support', c.c_uint32)]

    for direction, caps_type in [('In', InCaps), ('Out', OutCaps)]:
        caps_fn = getattr(winmm, f'midi{direction}GetDevCapsW')
        caps_fn.argtypes = [c.c_size_t, c.c_void_p, c.c_uint]
        open_fn = getattr(winmm, f'midi{direction}Open')
        open_fn.argtypes = [c.POINTER(c.c_void_p), c.c_uint,
                           c.c_size_t, c.c_size_t, c.c_uint]
        close_fn = getattr(winmm, f'midi{direction}Close')
        close_fn.argtypes = [c.c_void_p]
        found = False
        for index in range(getattr(winmm, f'midi{direction}GetNumDevs')()):
            caps = caps_type()
            if caps_fn(index, c.byref(caps), c.sizeof(caps)):
                continue
            print(f'{direction} {index}: {caps.name}', flush=True)
            if caps.name != name:
                continue
            found = True
            handle = c.c_void_p()
            start = time.monotonic()
            print(f'{direction} open starting', flush=True)
            result = open_fn(c.byref(handle), index, 0, 0, 0)
            print(f'{direction} open result={result} elapsed={time.monotonic()-start:.3f}s', flush=True)
            if result:
                raise RuntimeError(f'{direction} open failed: {result}')
            print(f'{direction} close starting', flush=True)
            result = close_fn(handle)
            print(f'{direction} close result={result}', flush=True)
            if result:
                raise RuntimeError(f'{direction} close failed: {result}')
        if not found:
            raise RuntimeError(f'{direction} device not found: {name}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', default='SINCO-MIDI')
    parser.add_argument('--child', action='store_true', help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.child:
        probe(args.device)
    else:
        try:
            completed = subprocess.run(
                [sys.executable, '-u', __file__, '--child', '--device', args.device],
                timeout=12, check=False)
            sys.exit(completed.returncode)
        except subprocess.TimeoutExpired:
            print('WinMM probe timed out after 12s; its child process was terminated.', flush=True)
            sys.exit(2)
