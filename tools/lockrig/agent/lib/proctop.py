#!/usr/bin/env python3
# detailed per-process sampler. Usage: proctop.py OUT.csv INTERVAL DURATION [LABEL]
import sys, time, subprocess
out, iv, dur, label = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), (sys.argv[4] if len(sys.argv)>4 else "run")
f = open(out,"w")
f.write("ts,label,cpu_user_sys,procs_top8\n"); f.flush()
end=time.time()+dur
while time.time()<end:
    try:
        ps=subprocess.run(["ps","-eo","pcpu,pmem,rss,comm,args","--sort=-pcpu"],capture_output=True,text=True,timeout=6)
        rows=[l for l in ps.stdout.splitlines()[1:9]]
        st=subprocess.run(["sh","-c","grep '^cpu ' /proc/stat"],capture_output=True,text=True)
        f.write("%s,%s,%s,%s\n"%(time.strftime("%H:%M:%S"),label,st.stdout.strip().replace(' ','_')," || ".join(r.strip()[:110] for r in rows)))
    except Exception as e:
        f.write("%s,%s,ERR,%s\n"%(time.strftime("%H:%M:%S"),label,e))
    f.flush(); time.sleep(iv)
f.close()
