"""Replay captured SELECTs against the scratch database with SQLite scan status; sum rows visited per statement."""
import ctypes as C, json, sys, collections
L=C.CDLL(sys.argv[1]); db=C.c_void_p()
L.sqlite3_open_v2.argtypes=[C.c_char_p,C.POINTER(C.c_void_p),C.c_int,C.c_char_p]
L.sqlite3_prepare_v2.argtypes=[C.c_void_p,C.c_char_p,C.c_int,C.POINTER(C.c_void_p),C.c_void_p]
for f in("step","finalize"): getattr(L,"sqlite3_"+f).argtypes=[C.c_void_p]
L.sqlite3_bind_text.argtypes=[C.c_void_p,C.c_int,C.c_char_p,C.c_int,C.c_void_p]
L.sqlite3_bind_int64.argtypes=[C.c_void_p,C.c_int,C.c_int64]; L.sqlite3_bind_null.argtypes=[C.c_void_p,C.c_int]
L.sqlite3_stmt_scanstatus_v2.argtypes=[C.c_void_p,C.c_int,C.c_int,C.c_int,C.c_void_p]
L.sqlite3_stmt_status.argtypes=[C.c_void_p,C.c_int,C.c_int]
L.sqlite3_errmsg.restype=C.c_char_p; L.sqlite3_errmsg.argtypes=[C.c_void_p]
assert L.sqlite3_open_v2(sys.argv[2].encode(),C.byref(db),1,None)==0
out=collections.OrderedDict(); plans={}
import sqlite3
meta=sqlite3.connect(f"file:{sys.argv[2]}?mode=ro",uri=True)
base_tables={"wakes","assignments","turns","decision_requests","assignment_cannot_proceed","row_reaction_actions"}
base_names=base_tables|{r[0] for r in meta.execute("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name IN ('wakes','assignments','turns','decision_requests','assignment_cannot_proceed','row_reaction_actions')")}
failures=[]
for line in open(sys.argv[3]):
    d=json.loads(line)
    if not d["sql"].lstrip().upper().startswith(("SELECT","WITH")): continue
    st=C.c_void_p()
    if L.sqlite3_prepare_v2(db,d["sql"].encode(),-1,C.byref(st),None): raise RuntimeError((L.sqlite3_errmsg(db),d["sql"]))
    for i,p in enumerate(d["params"],1):
        if p is None: L.sqlite3_bind_null(st,i)
        elif isinstance(p,(int,bool)): L.sqlite3_bind_int64(st,i,int(p))
        else: b=str(p).encode(); L.sqlite3_bind_text(st,i,b,len(b),C.c_void_p(-1))
    n=0
    while True:
        status=L.sqlite3_step(st)
        if status==100: n+=1
        elif status==101: break
        else: raise RuntimeError(L.sqlite3_errmsg(db))
    tot=0; loops=[]; i=0; base_seeks=0; decision_visits=0; wake_visits=0
    while True:
        v=C.c_int64(-1); 
        if L.sqlite3_stmt_scanstatus_v2(st,i,1,0,C.byref(v)): break
        e=C.c_char_p(); L.sqlite3_stmt_scanstatus_v2(st,i,4,0,C.byref(e))
        name=C.c_char_p(); L.sqlite3_stmt_scanstatus_v2(st,i,3,0,C.byref(name))
        detail=(e.value or b"").decode()
        index_name=(name.value or b"").decode()
        if d["scenario"] == "review-item-page" and "'decision' type" in d["sql"] and index_name.startswith("decision_requests"):
            assert index_name == "decision_requests_wait_item", (index_name,detail)
            decision_visits += max(0,v.value)
        if d["scenario"] in ("review-item-page","review-busy-session") and "'wake' type" in d["sql"] and index_name.startswith("wakes"):
            assert index_name.startswith("wakes_wait_pending_"), (index_name,detail)
            wake_visits += max(0,v.value)
        if (name.value or b"").decode() in base_names and detail.startswith("SEARCH "): base_seeks+=1
        if (name.value or b"").decode() in base_names and detail.startswith("SCAN "):
            failures.append((d["scenario"],detail))
        if v.value>0: tot+=v.value; loops.append((v.value,detail))
        i+=1
    if "SELECT seq,startedAt FROM turns" in d["sql"]:
        assert "INDEXED BY turns_pending" in d["sql"], d["sql"]
        assert tot <= 10, ("running-turn lookup visits history",tot,loops)
    if d["scenario"] == "review-item-page":
        assert decision_visits <= 10, (decision_visits,loops)
    if d["scenario"] == "review-busy-session":
        assert wake_visits <= 123, (wake_visits,loops)
    vm=L.sqlite3_stmt_status(st,4,0)
    s=out.setdefault(d["scenario"],dict(statements=0,rows_visited=0,rows_returned=0,vm_steps=0,base_seeks=0))
    s["base_seeks"]+=base_seeks; s["statements"]+=1; s["rows_visited"]+=tot; s["rows_returned"]+=n; s["vm_steps"]+=vm
    plans.setdefault(d["scenario"],[]).append((tot,d["sql"].strip()[:110],loops))
    L.sqlite3_finalize(st)
json.dump(out,open(sys.argv[4],"w"),indent=1)
with open(sys.argv[4]+".plans.txt","w") as f:
    for k,v in plans.items():
        f.write(f"== {k}\n")
        seen=collections.Counter()
        for tot,sql,loops in v:
            seen[sql]+=1
            if seen[sql]>1: continue
            f.write(f"  [{tot} rows] {' '.join(sql.split())}\n"); 
            for n,e in loops: f.write(f"      {n:>8}  {e}\n")

for scenario, metrics in out.items():
    assert metrics["base_seeks"] > 0, (scenario,metrics)
    assert metrics["rows_visited"] < 100_000, (scenario,metrics)
assert not failures, failures
print(json.dumps(out))
