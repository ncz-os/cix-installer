import struct, sys, time, select
dev=sys.argv[1]; dur=float(sys.argv[2]) if len(sys.argv)>2 else 6.0
fmt="llHHi"; sz=struct.calcsize(fmt)
f=open(dev,"rb"); t0=time.time(); n=0
print("reading",dev,"for",dur,"s (untouched)")
while time.time()-t0<dur:
    r,_,_=select.select([f],[],[],0.5)
    if not r: continue
    data=f.read(sz)
    if not data: break
    sec,usec,typ,code,val=struct.unpack(fmt,data)
    print(f"  t=+{time.time()-t0:.2f}s type={typ} code={code} val={val}")
    n+=1
print("total events:",n)
