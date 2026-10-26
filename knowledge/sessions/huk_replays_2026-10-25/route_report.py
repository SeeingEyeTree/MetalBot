import json,math,collections
def run(i,who):
    d=json.load(open(f"r{i}.json"))
    sps={o["playerNum"]:(o["x"],o["z"]) for o in d if o["n"]=="STARTPOS"}
    me=sps[who]; en=[v for k,v in sps.items() if k!=who and math.hypot(v[0]-me[0],v[1]-me[1])>2000]
    en=en[0] if en else None
    print(f"\n=== replay {i} me={me} enemy={en} dist={math.hypot(me[0]-en[0],me[1]-en[1]):.0f}")
    ev=[o for o in d if o.get("playerNum")==who and o["n"] in("COMMAND","SELECT")]
    sel=[];rows=[]
    for o in ev:
        if o["n"]=="SELECT": sel=o["selectedUnitIds"]; continue
        c=o["command"];n=c.get("cmdName","?");p=c["params"]
        if n not in("MOVE","FIGHT","ATTACK") or len(p)<3: continue
        rows.append(dict(t=o["t"],n=n,sel=len(sel),ids=frozenset(sel),sh=c["options"]["SHIFT_KEY"],x=p[0],z=p[2],line=len(p)==6))
    D=lambda a,b:math.hypot(a[0]-b[0],a[1]-b[1])
    # progress along base->enemy axis: 0 = my base, 1 = enemy base
    ax=(en[0]-me[0],en[1]-me[1]);L2=ax[0]**2+ax[1]**2
    def prog(x,z): return ((x-me[0])*ax[0]+(z-me[1])*ax[1])/L2
    def lat(x,z): # signed lateral offset in units
        return ((x-me[0])*(-ax[1])+(z-me[1])*ax[0])/math.sqrt(L2)
    # group commands by (ids, time<3s) => "orders"
    orders=[];cur=[]
    for r in rows:
        if cur and (r['t']-cur[-1]['t']>3 or r['ids']!=cur[-1]['ids']): orders.append(cur);cur=[]
        cur.append(r)
    orders.append(cur)
    big=[o for o in orders if o[0]['sel']>=5]
    print("orders(sel>=5):",len(big))
    # Route shapes: multi-waypoint queues
    for o in big:
        if len(o)>=3:
            pr=[f"{prog(x['x'],x['z']):.2f}/{lat(x['x'],x['z']):+.0f}" for x in o[:6]]
            print(f"  t={o[0]['t']:5.0f} sel={o[0]['sel']:3d} {''.join(x['n'][0]+('q' if x['sh'] else '') +' ' for x in o[:6])}| prog/lat: {' '.join(pr)}")
    # hit and run: same ids alternating MOVE toward base after FIGHT forward
    hr=0;seq=[]
    last={}
    for r in rows:
        if r['sel']<3: continue
        k=r['ids']
        if k in last:
            pr0,t0,n0=last[k]
            pr1=prog(r['x'],r['z'])
            if r['t']-t0<20 and n0=='FIGHT' and r['n']=='MOVE' and pr1<pr0-0.05: hr+=1;seq.append((round(r['t']),r['sel'],round(pr0,2),round(pr1,2),round(r['t']-t0,1)))
        last[k]=(prog(r['x'],r['z']),r['t'],r['n'])
    print("fight->retreat-move pairs (<20s, sel>=3):",hr, seq[:15])
    # single/small selections micro: repeated MOVEs same ids within 2 s
    small=[r for r in rows if r['sel']<=2]
    cnt=collections.Counter()
    pl=None
    print("small-sel (<=2) cmds",len(small),"; of which MOVE",sum(r['n']=='MOVE' for r in small))
run(2,0);run(3,1);run(4,0)
