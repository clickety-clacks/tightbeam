"""Fill a scratch database with synthetic rows sized like a large organization. No real data."""
import json, random, sqlite3, sys, time
path, mode = sys.argv[1], sys.argv[2]
R = random.Random(42)
NOW = int(time.time()*1000); DAY = 86400000
c = sqlite3.connect(path); c.isolation_level=None
c.execute("PRAGMA foreign_keys=OFF"); c.execute("PRAGMA synchronous=OFF")
trig=c.execute("SELECT name,sql FROM sqlite_master WHERE type='trigger'").fetchall()
for n,_ in trig: c.execute(f'DROP TRIGGER "{n}"')
def hexid(p,i): return f"{p}_{i:08x}-0000-4000-8000-{i:012x}"
def txt(n): return ("synthetic text block number %d " % R.randrange(10**9)) .ljust(n,'x')
def skew(n,a): return min(n-1,int(n*R.random()**a))
if mode=="unrelated":
    n=int(sys.argv[3]); c.execute("BEGIN")
    hold=[r[0] for r in c.execute("SELECT sessionKey FROM sessions LIMIT 400 OFFSET 100")]
    for i in range(n):
        k=i%4; due=NOW+DAY+i
        c.execute("INSERT INTO wakes(wakeId,sessionKey,origin,prompt,consumer,dueAt,state,createdAt,creatorSessionKey,conditionKind,conditionScope,assignmentId) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
          (f"w_unrelated_{i}",hold[i%len(hold)],"process:bench",txt(200),"prompt",due,"pending",NOW-1000,hold[i%len(hold)],
           "bench-unrelated" if k==1 else None, f"scope-{i}" if k==1 else None, None))
    c.execute("COMMIT")
else:
    NS,NI,NA,NT,NATT,NW,ND,NF=6000,2700,40800,580000,250000,450000,12000,80000
    S=[f"agent:main:clawline:bench:main s_{i:08x}" for i in range(NS)]
    I=[hexid("wi",i) for i in range(NI)]; A=[hexid("asg",i) for i in range(NA)]
    c.execute("BEGIN")
    c.execute("INSERT OR IGNORE INTO users(userId,isAdmin,createdAt) VALUES('bench',1,1)")
    c.executemany("INSERT INTO sessions(sessionKey,displayName,ownerUserId,origin,archetype,harness,provider,model,host,state,createdAt,updatedAt,mechanicalStatus) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
      [(S[i],f"Bench {i}","bench","user:bench","default","claude","anthropic","m","local","active" if i<500 else "retired",NOW-120*DAY+i,NOW,"idle") for i in range(NS)])
    # item 0.. old to new; creators skewed so session 0 is the busiest
    IT=[]
    for i in range(NI):
        x=R.random(); st="open" if i%100<16 else ("closed" if x<.82 else "failed" if x<.93 else "iceboxed")
        cr=S[0] if R.random()<.20 else S[skew(60,2)]
        IT.append(st)
        c.execute("INSERT INTO work_items(id,title,ownerUserId,state,createdBySession,createdAt,isBug) VALUES(?,?,?,?,?,?,?)",(I[i],txt(90),"bench",st,cr,NOW-120*DAY+i*3800000,i%5==0))
        c.execute("INSERT INTO work_item_versions VALUES(?,?)",(I[i],NOW-i))
    w=[R.lognormvariate(0,1.1) for _ in range(NI)]
    started=[i for i in range(NI) if i%12!=0]   # about 8% never started
    picks=R.choices(started,[w[i] for i in started],k=NA)
    AH=[];AI=[];AS=[];OPEN=[]
    team={}
    att_close=[]
    for a in range(NA):
        it=picks[a] if R.random()>.04 else None
        if it is None: h=S[skew(NS,2)]
        else:
            t=team.setdefault(it,[0 if R.random()<.16 else skew(80,2)]+[skew(NS,1.5) for _ in range(5)])
            h=S[t[skew(6,1.6)]]
        op = it is not None and IT[it]=="open" and R.random()<.14
        AH.append(h);AI.append(it);AS.append(op)
        if op: OPEN.append(a)
        at=NOW-120*DAY+a*250000
        done=hexid("att",10**7+a)
        c.execute("INSERT INTO assignments(id,subject,holderKey,openedBySession,openedAt,state,outcome,closedAt,closedBySession,closingAttestId,workItemId) VALUES(?,?,?,?,?,?,?,?,?,?,?)",
          (A[a],txt(140),h,S[0] if R.random()<.15 else S[skew(80,2)],at,"open" if op else "closed",None if op else "completed",None if op else at+10**7,None if op else h,None if op else done,I[it] if it is not None else None))
        if not op: att_close.append((done,A[a],"completion",None,txt(300),h,None,at+10**7))
    c.executemany("INSERT INTO assignment_effects VALUES(?,?)",[(A[a],"code" if a%3 else "coordination") for a in range(NA)])
    sql="INSERT INTO attests(id,assignmentId,kind,verdictKind,note,bySession,commitRefs,ts) VALUES(?,?,?,?,?,?,?,?)"
    c.executemany(sql,att_close)
    rows=[]
    for k in range(NATT-len(att_close)):
        a=R.randrange(NA) if R.random()<.5 else skew(NA,1)
        v=R.random()<.25
        refs=json.dumps([{"repo":"bench/repo","commit":f"{R.randrange(9000):040x}"}]) if R.random()<.2 else None
        rows.append((hexid("att",k),A[a],"verdict" if v else "progress",R.choice(["passed","changes-requested","verified"]) if v else None,txt(400),AH[a],refs,NOW-120*DAY+a*250000+k))
    c.executemany(sql,rows)
    # wakes: history, plus 123 pending of which 57 name no item or card
    ws="INSERT INTO wakes(wakeId,sessionKey,origin,prompt,consumer,dueAt,state,createdAt,firedAt,creatorSessionKey,assignmentId,work_item_id,conditionKind,conditionScope,waitMode,predicate,resolverKind,resolverId,originatingTurnSeq) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
    rows=[]
    for k in range(NW):
        a=R.randrange(NA) if R.random()<.6 else None
        cr=NOW-120*DAY+k*23000
        rows.append((f"w_{k:08x}",AH[a] if a is not None else S[skew(NS,2)],"process:bench",txt(500),"prompt",cr+(0 if k%3 else 60000),"fired",cr,cr+60000,S[skew(NS,2)],A[a] if a is not None else None,I[AI[a]] if a is not None and AI[a] is not None and k%6==0 else None,None,None,None,None,None,None,None))
        if len(rows)==50000: c.executemany(ws,rows); rows=[]
    c.executemany(ws,rows)
    R.shuffle(OPEN); linked=OPEN[:66]
    rows=[]
    for k in range(123):
        a=linked[k] if k<66 else None; h=AH[a] if a is not None else S[k]
        aid=A[a] if a is not None else None
        cr=NOW-3600000; due=NOW+10800000; m=k%5; tgt=A[OPEN[(k*7)%len(OPEN)]]
        f=dict(ck=None,cs=None,wm=None,pr=None,rk=None,ri=None,ot=None)
        if m==1: f.update(wm="dependency",rk="assignment",ri=tgt,pr=json.dumps({"conditions":[{"fact":"assignment.outcome","op":"eq","value":"completed"}],"bindings":{"assignmentId":tgt}}))
        if m==2: f.update(ck="bench-release",cs=f"scope-{k}")
        if m==3: f.update(wm="after-turn",ot=1+k)
        if m==4 and k%2: f.update(ck="assignment-landed",cs=tgt)
        rows.append((f"w_pending_{k}",h,"session:"+h,txt(500),"prompt",due,"pending",cr,None,h,aid,None,f["ck"],f["cs"],f["wm"],f["pr"],f["rk"],f["ri"],f["ot"]))
    c.executemany(ws,rows)
    try: c.executemany("INSERT INTO wake_wait_reasons(wakeId,reason) VALUES(?,?)",[(f"w_pending_{k}","Waiting for the bench dependency") for k in range(0,123,2)])
    except sqlite3.OperationalError as e: print("no reasons table",e)
    rows=[]; ts="INSERT INTO turns(sessionKey,messageId,origin,prompt,assignmentId,jobRef,status,createdAt,startedAt,endedAt,publishedAt) VALUES(?,?,?,?,?,?,?,?,?,?,?)"
    for k in range(NT):
        a=R.randrange(NA) if R.random()<.6 else None
        cr=NOW-120*DAY+k*17000; it=AI[a] if a is not None else None
        rows.append((AH[a] if a is not None else S[skew(NS,2)],f"m_{k}","process:bench",txt(600),A[a] if a is not None else None,I[it] if it is not None and k%3 else None,"delivered",cr,cr,cr+9000,cr+9000))
        if len(rows)==50000: c.executemany(ts,rows); rows=[]
    c.executemany(ts,rows)
    rows=[];seen=set()
    for k in range(40):   # running turns: half tied to a card, half an open holder with no recorded tie
        a=OPEN[100+k]; h=AH[a]
        if h in seen: continue
        seen.add(h); t=k%2==0
        rows.append((h,f"mr_{k}","process:bench",txt(600),A[a] if t else None,I[AI[a]] if t else None,"running",NOW-60000,NOW-60000,None,None))
    c.executemany(ts,rows)
    # An idle holder with a long finished history must not pay for that history.
    c.executemany(ts,[(S[-1],f"idle-history-{k}","process:bench","Synthetic history",None,None,"delivered",NOW-k-1000,NOW-k-1000,NOW-k,NOW-k) for k in range(20000)])
    ds="INSERT INTO decision_requests(id,kind,raiserId,raiserSessionKey,ownerUserId,assignmentId,expecterSessionKey,expecterUserId,raisedAt,question,options,context,status,actionKey,answer,answeredBy,answeredAt) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
    rows=[]
    for k in range(ND):
        op=k<60; a=OPEN[200+k] if op else R.randrange(NA); h=AH[a]
        if k%3==0: rows.append((hexid("dr",k),"operator","session:"+h,h,"bench",A[a] if k%2 else None,None,None,NOW-k,txt(400),'[{"label":"yes"},{"label":"no"}]',json.dumps({"workItemId":I[AI[a]]} if AI[a] is not None else {}),"open" if op else "withdrawn",f"ask-{k}",None,None,None))
        else: rows.append((hexid("dr",k),"agent","session:"+h,h,"bench",A[a],S[k%50],"bench",NOW-k,txt(400),None,'{}',"open" if op else "answered",None,None if op else "ok",None if op else "session:x",None if op else NOW))
    c.executemany(ds,rows)
    rows=[]
    for k in range(NF):
        if k%25==0: rows.append((NOW-k,"landing.observed-merge",f"bench/repo#{k+1}","process:bench","bench",json.dumps({"branch":"main","commit":f"{10000+R.randrange(9000):040x}","headCommit":f"{10000+R.randrange(9000):040x}"})))
        else: rows.append((NOW-k,R.choice(["assignment-reviewed","bench-release","custom"]),f"scope-{k}","process:bench","bench",None))
    c.executemany("INSERT INTO condition_facts(ts,kind,scope,origin,ownerUserId,payload) VALUES(?,?,?,?,?,?)",rows)
    if c.execute("SELECT 1 FROM sqlite_master WHERE name='row_reaction_actions'").fetchone():
        c.executemany("INSERT INTO row_reaction_actions(id,org,eventId,family,slot,plan,payloadDigest,status,result,updatedAt) VALUES(?,?,?,?,?,?,?,?,?,?)",
          ((f"rra_{k}","org",f"ev_{k}","f","s",'{"value":{"reference":{"resource":"work_item","field":"routingWakeId"}}}',"d","accepted",json.dumps({"wake_id":f"w_{k:08x}"}),NOW) for k in range(60000)))
    c.executemany("INSERT INTO row_reaction_events(org,eventId,version,event,facts,admittedAt) VALUES('synthetic',?,1,'{}','{}',?)",[(f"scale-event-{k}",NOW) for k in range(12000)])
    c.executemany("INSERT INTO row_reaction_actions(id,org,eventId,family,slot,plan,payloadDigest,status,result,updatedAt) VALUES(?,'synthetic',?,'work-item','routing',?,'synthetic','accepted',?,?)",
      [(f"scale-action-{k}",f"scale-event-{k}",json.dumps({"value":{"reference":{"resource":"work_item","field":"routingWakeId"}}}),json.dumps({"wake_id":f"w_{k:08x}"}),NOW) for k in range(12000)])
    # Retained blocks exercise the assignment-scoped block index at scale.
    blocks=c.execute("SELECT id,assignmentId FROM attests WHERE kind='completion' LIMIT 12000").fetchall()
    c.executemany("INSERT INTO assignment_cannot_proceed(id,assignmentId,attestId,decisionRequestId,decisionWakeId,openerRef,disposerRef,reason,state,createdAt,settledAt,settlementKind,settledBy) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
      [(f"cp_scale_{k}",aid,att,hexid("dr",k),f"w_{k:08x}","user:bench","user:bench","Synthetic resolved block","settled",NOW-1000,NOW,"disposed","user:bench") for k,(att,aid) in enumerate(blocks)])
    c.execute("COMMIT")
for n,s in trig: c.execute(s)
c.execute("PRAGMA wal_checkpoint(TRUNCATE)")
q=lambda s:c.execute(s).fetchall()
print(json.dumps({"counts":{t:q(f"SELECT count(*) FROM {t}")[0][0] for t in("work_items","assignments","sessions","turns","attests","wakes","decision_requests","condition_facts","assignment_cannot_proceed","row_reaction_actions")},
 "idle_session":S[-1] if mode!="unrelated" else None,"open_items":q("SELECT count(*) FROM work_items WHERE state='open'")[0][0],"open_cards":q("SELECT count(*) FROM assignments WHERE state='open'")[0][0],
 "pending":q("SELECT count(*) FROM wakes WHERE state='pending'")[0][0],"running":q("SELECT count(*) FROM turns WHERE status='running'")[0][0],
 "max_cards_item":q("SELECT max(n) FROM (SELECT count(*) n FROM assignments WHERE workItemId IS NOT NULL GROUP BY workItemId)")[0][0],
 "busy_creator":q("SELECT createdBySession,count(*) n FROM work_items GROUP BY 1 ORDER BY n DESC LIMIT 1"),
 "typical_creator":q("SELECT createdBySession,count(*) n FROM work_items GROUP BY 1 HAVING n>=50 ORDER BY n LIMIT 1"),
 "busy_holder":q("SELECT holderKey,count(DISTINCT workItemId) n FROM assignments a JOIN work_items w ON w.id=a.workItemId WHERE w.state='open' GROUP BY 1 ORDER BY n DESC LIMIT 1"),
 "typical_holder":q("SELECT holderKey,count(DISTINCT workItemId) n FROM assignments a JOIN work_items w ON w.id=a.workItemId WHERE w.state='open' GROUP BY 1 HAVING n BETWEEN 10 AND 14 ORDER BY n LIMIT 1"),
 "triggers":len(trig)}))
