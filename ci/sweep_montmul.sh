#!/usr/bin/env bash
# Width sweep for rv64_montmul. Two passing widths is not proof of generality --
# this exists because W=1 and W=4 passed while W=2 and W=8 failed.
set -u
OCS=${OCS:-/scratch/work/ocs/oss-cad-suite/bin}
export PATH="$OCS:$PATH"
pass=0; fail=0; failed=""
for W in 1 2 3 4 8 16; do
  python3 - "$W" <<'PY'
import random, sys
W=int(sys.argv[1]); random.seed(11); M64=(1<<64)-1
N = random.getrandbits(64*W) | 1 | (1 << (64*W-1))
a = random.getrandbits(64*W) % N; b = random.getrandbits(64*W) % N
n0inv = (-pow(N,-1,1<<64)) % (1<<64)
def words(x): return [(x>>(64*i))&M64 for i in range(W)]
aw,bw,nw = words(a),words(b),words(N)
t=[0]*(W+1)
for i in range(W):
    c=0
    for j in range(W):
        acc=t[j]+aw[j]*bw[i]+c; t[j]=acc&M64; c=acc>>64
    t[W]=c
    m=(t[0]*n0inv)&M64
    c=0
    for j in range(W):
        acc=t[j]+m*nw[j]+c; t[j]=acc&M64; c=acc>>64
    t[W]=t[W]+c
    for j in range(W): t[j]=t[j+1]
    t[W]=0
raw=sum(t[k]<<(64*k) for k in range(W))
with open('vectors.hex','w') as f:
    for v in aw+bw+nw+[n0inv]: f.write(f"{v:016x}\n")
    for v in t: f.write(f"{v:016x}\n")
    for v in words(raw): f.write(f"{v:016x}\n")
PY
  sed -i "s/localparam int W = [0-9]*;/localparam int W = $W;/" tb_montmul.sv
  iverilog -g2012 -o /tmp/sw.vvp -s tb_montmul rv64_montmul.sv tb_montmul.sv 2>&1 | grep -v sorry | grep error | head -1
  r=$(timeout 40 vvp /tmp/sw.vvp 2>&1 | grep -oE "errors=[0-9]+" | tail -1)
  if [ "$r" = "errors=0" ]; then pass=$((pass+1)); echo "  W=$W  PASS";
  else fail=$((fail+1)); failed="$failed $W"; echo "  W=$W  FAIL ($r)"; fi
done
echo "sweep: $pass passed, $fail failed${failed:+ (failed widths:$failed)}"
