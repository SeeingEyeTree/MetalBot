import json,math,collections,statistics as st
names={1:"FMP",2:"CometCatcher",3:"Canis",4:"Canis30",5:"RedComet",6:"CapeViolet"}
def run(i,who):
    d=json.load(open(f"r{i}.json"))
    pn={o["playerNum"]:o["playerName"] for o in d if o["n"]=="PLAYERNAME"}
    sps={o["playerNum"]:(o["x"],o["z"]) for o in d if o["n"]=="STARTPOS"}
    me=sps[who]; en=[v for k,v in sps.items() if k!=who and math.hypot(v[0]-me[0],v[1]-me[1])>2000]
    if not en: return
    en=en[0]; ax=(en[0]-me[0],en[1]-me[1]);L=math.hypot(*ax)
    prog=lambda x,z:((x-me[0])*ax[0]+(z-me[1])*ax[1])/L**2
    lat=lambda x,z:((x-me[0])*(-ax[1])+(z-me[1])*ax[0])/L
    ev=[o for o in d if o.get("playerNum")==who and o["n"] in("COMMAND","SELECT")]
    sel=[];rows=[];dur=max(o["t"] for o in d)
    for o in ev:
        if o["n"]=="SELECT": sel=o["selectedUnitIds"];continue
        c=o["command"];n=c.get("cmdName","?");p=c["params"]
        if n not in("MOVE","FIGHT","ATTACK","PATROL","GUARD") or len(p)<3: continue
        rows.append(dict(t=o["t"],n=n,sel=len(sel),ids=frozenset(sel),sh=c["options"]["SHIFT_KEY"],p=p))
    orders=[];cur=[]
    for r in rows:
        if cur and (r['t']-cur[-1]['t']>3 or r['ids']!=cur[-1]['ids']): orders.append(cur);cur=[]
        cur.append(r)
    if cur: orders.append(cur)
    big=[o for o in orders if o[0]['sel']>=5]
    mid=[abs(lat(r['p'][0],r['p'][2])) for o in big for r in o if 0.3<=prog(r['p'][0],r['p'][2])<=0.8]
    multi=sum(1 for o in big if sum(r['n']=='FIGHT' for r in o)>=3 and any(r['sh'] for r in o))
    lines=[math.hypot(r['p'][0]-r['p'][3],r['p'][2]-r['p'][5]) for r in rows if r['n']=='MOVE' and len(r['p'])==6 and r['sel']>=3]
    cnt=collections.Counter(r['n'] for r in rows if r['sel']>=5)
    # single unit
    single=collections.Counter()
    for r in rows:
        if r['sel']==1: single[next(iter(r['ids']))]+=1
    print(f"{names[i]:12s} {pn.get(who,'?'):16s} {dur/60:4.0f}min | grp orders {len(big):3d} ({len(big)/(dur/60):.1f}/min) med size {st.median(o[0]['sel'] for o in big) if big else 0:.0f} | "
          f"MOVE/FIGHT/ATK {cnt['MOVE']}/{cnt['FIGHT']}/{cnt['ATTACK']} | mid-route |lat| med {st.median(mid) if mid else 0:.0f} | multi-leg FIGHT routes {multi} | "
          f"line moves {len(lines)} med w {st.median(lines) if lines else 0:.0f} | single-unit cmds {sum(single.values())} (units {len(single)}, top {single.most_common(1)[0][1] if single else 0})")
for i,w in [(1,0),(1,1),(2,0),(2,1),(3,0),(3,1),(4,0),(4,1),(5,0),(5,1),(6,0),(6,1)]:
    try: run(i,w)
    except Exception as e: print(i,w,"err",e)
