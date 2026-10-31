#!/usr/bin/env bash
# Width sweep for rv64_modexp. The multiplier needed one to expose a width bug;
# the engine had only ever been run at W=2.
set -u
OCS=${OCS:-/scratch/work/ocs/oss-cad-suite/bin}
export PATH="$OCS:$PATH"
pass=0; fail=0; failed=""
for W in 1 2 3 4; do
  sed -i "s/localparam int W = [0-9]*;/localparam int W = $W;/" tb_modexp.sv
  python3 - "$W" <<'PY'
import sys, random
sys.path.insert(0,'.')
from modexp_model import modexp_model
W=int(sys.argv[1]); random.seed(7)
M64=(1<<64)-1
N = random.getrandbits(64*W) | 1 | (1 << (64*W-1))
R = 1 << (64*W); R2 = (R*R) % N; R1 = R % N
base = random.getrandbits(64*W) % N
exp  = random.getrandbits(8) | 1
ebits = 8
n0inv = (-pow(N,-1,1<<64)) % (1<<64)
ops, trace, res = modexp_model(base, exp, N, R2, R1, W, ebits)
assert res == pow(base, exp, N), "model wrong"
def words(x): return [(x>>(64*i))&M64 for i in range(W)]
L=[f"{n0inv:016x}"]
for v in words(base): L.append(f"{v:016x}")
for v in words(R2):   L.append(f"{v:016x}")
for v in words(N):    L.append(f"{v:016x}")
for v in words(R1):   L.append(f"{v:016x}")
for v in words(exp):  L.append(f"{v:016x}")
L.append(f"{ebits:016x}")
for v in words(res):  L.append(f"{v:016x}")
open('vectors_exp.hex','w').write("\n".join(L)+"\n")
PY
  iverilog -g2012 -o /tmp/sx.vvp -s tb_modexp rv64_montmul.sv rv64_modexp.sv tb_modexp.sv 2>&1 | grep -v sorry | grep error | head -1
  r=$(timeout 60 vvp /tmp/sx.vvp 2>&1 | grep -oE "errors=[0-9]+" | tail -1)
  if [ "$r" = "errors=0" ]; then pass=$((pass+1)); echo "  W=$W  PASS";
  else fail=$((fail+1)); failed="$failed $W"; echo "  W=$W  FAIL ($r)"; fi
done
echo "modexp sweep: $pass passed, $fail failed${failed:+ (failed widths:$failed)}"
