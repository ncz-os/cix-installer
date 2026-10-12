#!/usr/bin/env python3
"""Inject a RELATIVE pointer motion via /dev/uinput (needs root).
usage: ptr.py DX DY [DX2 DY2 ...]   e.g. ptr.py 60 0
Creates a virtual mouse, emits relative moves (real cursor motion on the compositor)."""
import fcntl, os, struct, sys, time

fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
# enable event types: EV_KEY(1), EV_REL(2), EV_SYN(0)
for evt in (1, 2, 0):
    fcntl.ioctl(fd, 0x40045564, evt)
# enable relative axes REL_X(0), REL_Y(1)
for rel in (0, 1):
    fcntl.ioctl(fd, 0x40045566, rel)
# enable BTN_LEFT(272)
fcntl.ioctl(fd, 0x40045565, 272)
# UI_DEV_SETUP: bustype, vendor, product, version, name
fcntl.ioctl(fd, 0x405c5503, struct.pack("HHHH80sI", 3, 0x1234, 0xabcd, 1, b"ncz-test-ptr", 0))
fcntl.ioctl(fd, 0x5501)  # UI_DEV_CREATE
time.sleep(1.5)          # let labwc/libinput pick the device up

def ev(t, c, v): os.write(fd, struct.pack("llHHi", 0, 0, t, c, v))

args = sys.argv[1:]
pairs = [(int(args[i]), int(args[i+1])) for i in range(0, len(args) - 1, 2)] or [(40, 0)]
for (dx, dy) in pairs:
    ev(2, 0, dx); ev(2, 1, dy); ev(0, 0, 0)
    time.sleep(0.15)
time.sleep(0.3)
fcntl.ioctl(fd, 0x5502)  # UI_DEV_DESTROY
os.close(fd)
