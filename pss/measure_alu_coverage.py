import json, subprocess, collections

def gen(action, seed):
    r = subprocess.run(["satya","gen","pss/rv64_alu_matrix.pss","--backend","json",
                        "--action",action,"--seed",str(seed)], capture_output=True, text=True)
    try:
        d = json.loads(r.stdout)
    except Exception:
        return None
    return d.get("fields") or (d.get("steps") or [{}])[0].get("fields") or {}

SEEDS = 120
# alu_pair: (op_index, a_class, b_class) triples
triples = set(); pairs_op_a = set(); same_class_seen = set()
for s in range(1, SEEDS+1):
    f = gen("alu_pair", s)
    if not f: continue
    triples.add((f["op_index"], f["a_class"], f["b_class"]))
    pairs_op_a.add((f["op_index"], f["a_class"]))
    same_class_seen.add(f["same_class"])

total_triples = 7*15*15
total_pairs = 7*15
print(f"alu_pair over {SEEDS} seeds:")
print(f"  (op,a,b) triples : {len(triples)}/{total_triples} = {100*len(triples)//total_triples}%")
print(f"  (op,a) pairs     : {len(pairs_op_a)}/{total_pairs} = {100*len(pairs_op_a)//total_pairs}%")
print(f"  same_class values seen: {sorted(same_class_seen)}")

# alu_imm: (op, a_class, imm_class)
ti = set()
for s in range(1, SEEDS+1):
    f = gen("alu_imm", s)
    if f: ti.add((f["op_index"], f["a_class"], f["imm_class"]))
tot = 6*15*8
print(f"alu_imm: (op,a,imm) triples {len(ti)}/{tot} = {100*len(ti)//tot}%")

# sign boundary
sb = set()
for s in range(1, SEEDS+1):
    f = gen("alu_sign_boundary", s)
    if f: sb.add((f["op_index"], f["a_is_negative"], f["b_is_negative"], f["magnitude_class"]))
tots = 2*2*2*4
print(f"alu_sign_boundary: {len(sb)}/{tots} = {100*len(sb)//tots}%")
