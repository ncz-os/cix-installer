#!/usr/bin/env python3
"""Inject keys via /dev/uinput (needs root). usage: kbd.py keys... e.g. shift  type:ncz  enter"""
import fcntl, os, struct, sys, time
K = {c: n for n, c in enumerate("_1234567890", 1)}
CODES = {"esc":1,"enter":28,"shift":42,"space":57,"backspace":14,"tab":15,"a":30,"b":48,"c":46,"d":32,"e":18,"f":33,"g":34,"h":35,"i":23,"j":36,"k":37,"l":38,"m":50,"n":49,"o":24,"p":25,"q":16,"r":19,"s":31,"t":20,"u":22,"v":47,"w":17,"x":45,"y":21,"z":44}
fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
fcntl.ioctl(fd, 0x40045564, 1)            # EV_KEY
fcntl.ioctl(fd, 0x40045564, 0)            # EV_SYN
for c in set(CODES.values()): fcntl.ioctl(fd, 0x40045565, c)
fcntl.ioctl(fd, 0x405c5503, struct.pack("HHHH80sI", 3, 0x1234, 0x5678, 1, b"ncz-test-kbd", 0))
fcntl.ioctl(fd, 0x5501)
time.sleep(1.5)                           # let labwc/libinput pick the device up
def ev(t, c, v): os.write(fd, struct.pack("llHHi", 0, 0, t, c, v))
def tap(code):
    ev(1, code, 1); ev(0, 0, 0); time.sleep(0.05); ev(1, code, 0); ev(0, 0, 0); time.sleep(0.08)
for a in sys.argv[1:]:
    if a.startswith("type:"):
        for ch in a[5:]: tap(CODES[ch])
    elif a.startswith("rep:"):
        n,_,k = a[4:].partition(":"); 
        for _ in range(int(n)): tap(CODES[k])
    else: tap(CODES[a])
time.sleep(0.3)
fcntl.ioctl(fd, 0x5502); os.close(fd)
