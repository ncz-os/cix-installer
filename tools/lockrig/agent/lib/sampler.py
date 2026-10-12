#!/usr/bin/env python3
# thermals sampler (portable, read-only). Usage: sampler.py OUT.csv INTERVAL DURATION [LABEL]
import sys, os, time, glob, subprocess

out, iv, dur, label = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), (sys.argv[4] if len(sys.argv) > 4 else "run")
try:
    open(out + ".pid", "w").write(str(os.getpid()))
except Exception:
    pass

def rd(p):
    try:
        with open(p) as f: return f.read().strip()
    except Exception: return None

# RAPL
rapl_pkg = rapl_dram = None
for d in glob.glob("/sys/class/powercap/intel-rapl:*"):
    n = rd(d + "/name")
    if n == "package-0": rapl_pkg = d + "/energy_uj"
    elif n == "dram": rapl_dram = d + "/energy_uj"
for d in glob.glob("/sys/class/powercap/intel-rapl:0:*"):
    if rd(d + "/name") == "dram": rapl_dram = d + "/energy_uj"

# hwmon discovery
amd = coretemp = acpitz = None
for h in sorted(glob.glob("/sys/class/hwmon/hwmon*")):
    n = rd(h + "/name")
    if n == "amdgpu": amd = h
    elif n == "coretemp": coretemp = h
    elif n == "acpitz": acpitz = h

amdcard = None
for c in sorted(glob.glob("/sys/class/drm/card[0-9]*")):
    if os.path.exists(c + "/device/pp_dpm_mclk"): amdcard = c + "/device"

def uj(p):
    v = rd(p); 
    try: return int(v)
    except Exception: return None
def fnum(p):
    v = rd(p)
    try: return float(v)
    except Exception: return None
def maxtemp(h):
    if not h: return None
    m = 0
    for f in glob.glob(h + "/temp*_input"):
        v = fnum(f)
        if v and v > m: m = v
    return m/1000.0 if m else None
def drm_star(p):
    v = rd(p) or ""
    for line in v.splitlines():
        if line.rstrip().endswith("*"):
            return line.split(":")[-1].replace("*","").strip()
    return ""
def topent():
    try:
        ps = subprocess.run(["ps","-eo","pcpu,comm","--sort=-pcpu"],capture_output=True,text=True,timeout=5)
        rows = [l.split(None,1) for l in ps.stdout.splitlines()[1:4]]
        return [ (r[1].strip()[:18], r[0]) for r in rows if len(r)==2 ]
    except Exception: return []
def nvid():
    try:
        q = subprocess.run(["nvidia-smi","--query-gpu=power.draw,temperature.gpu,utilization.gpu,clocks.current.memory,pstate","--format=csv,noheader,nounits"],capture_output=True,text=True,timeout=5)
        return [x.strip() for x in q.stdout.strip().splitlines()[0].split(",")]
    except Exception: return None

pv = uj(rapl_pkg); dv = uj(rapl_dram)
prev = time.time()
f = open(out, "w")
f.write("ts,label,pkgW,dramW,gpuW,gpuTemp,cpuTempMax,gpuBusy,mclk,sclk,fan,load1,top1,top2,top3\n"); f.flush()
end = time.time() + dur
while time.time() < end:
    time.sleep(iv)
    now = time.time(); dt = now - prev; prev = now
    pv2 = uj(rapl_pkg); dv2 = uj(rapl_dram)
    pkgW = round((pv2-pv)/1e6/dt, 2) if (pv2 and pv) else ""
    dramW = round((dv2-dv)/1e6/dt, 2) if (dv2 and dv) else ""
    pv, dv = pv2, dv2
    gpuW = gpuT = gpuB = fan = mclk = sclk = ""
    if amd:
        p = fnum(amd + "/power1_average"); gpuW = round(p/1e6,2) if p else ""
        t = fnum(amd + "/temp1_input"); gpuT = int(t/1000) if t else ""
        gpuB = rd(amd + "/gpu_busy_percent") or ""
        fan = rd(amd + "/fan1_input") or ""
    nv = nvid() if (os.path.exists("/usr/bin/nvidia-smi") or os.path.exists("/usr/local/bin/nvidia-smi")) else None
    if nv and len(nv) >= 5:
        gpuW, gpuT, gpuB, mclk, pstate = nv[0], nv[1], nv[2], nv[3], nv[4]
    if amdcard:
        mclk = drm_star(amdcard + "/pp_dpm_mclk") or mclk
        sclk = drm_star(amdcard + "/pp_dpm_sclk")
    cpuT = maxtemp(coretemp) or maxtemp(acpitz)
    try: load1 = rd("/proc/loadavg").split()[0]
    except Exception: load1 = ""
    t = topent()
    t = t + [("","")]*(3-len(t))
    row = [time.strftime("%H:%M:%S"), label, pkgW, dramW, gpuW, gpuT,
           (round(cpuT,1) if cpuT else ""), gpuB, mclk, sclk, fan, load1,
           "%s:%s"%(t[0][0],t[0][1]), "%s:%s"%(t[1][0],t[1][1]), "%s:%s"%(t[2][0],t[2][1])]
    f.write(",".join(str(x) for x in row) + "\n"); f.flush()
f.close()
