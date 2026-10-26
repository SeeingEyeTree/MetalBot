import json,math,collections,statistics as st
def run(i,who):
    d=json.load(open(f"r{i}.json"))
    sps={o["playerNum"]:(o["x"],o["z"]) for o in d if o["n"]=="STARTPOS"}
    me=sps[who]; en=[v for k,v in sps.items() if k!=who and math.hypot(v[0]-me[0],v[1]-me[1])>2000][0]
    ax=(en[0]-me[0],en[1]-me[1]);L=math.hypot(*ax);ux=(ax[0]/L,ax[1]/L)
    ev=[o for o in d if o.get("playerNum")==who and o["n"] in("COMMAND","SELECT")]
    sel=[];tracks=collections.defaultdict(list)
    for o in ev:
        if o["n"]=="SELECT": sel=o["selectedUnitIds"];continue
        c=o["command"]
        if c.get("cmdName") not in("MOVE","FIGHT") or len(c["params"])<3 or len(sel)!=1 : continue
        tracks[sel[0]].append((o["t"],c["cmdName"],c["params"][0],c["params"][2],c["options"]["SHIFT_KEY"]))
    print(f"\n=== replay {i}: single-unit selections, {len(tracks)} distinct units")
    tot=sorted(tracks.items(),key=lambda kv:-len(kv[1]))[:6]
    for u,tr in tot:
        gaps=[b[0]-a[0] for a,b in zip(tr,tr[1:])]
        hops=[math.hypot(b[2]-a[2],b[3]-a[3]) for a,b in zip(tr,tr[1:]) if b[0]-a[0]<6]
        # direction reversal vs previous hop
        rev=0;n=0;prev=None;towards=0;away=0
        for a,b in zip(tr,tr[1:]):
            if b[0]-a[0]>=6: prev=None;continue
            v=(b[2]-a[2],b[3]-a[3]); m=math.hypot(*v)
            if m<1: continue
            proj=(v[0]*ux[0]+v[1]*ux[1])/m
            if proj>0.5: towards+=1
            elif proj<-0.5: away+=1
            if prev:
                cos=(v[0]*prev[0]+v[1]*prev[1])/(m*math.hypot(*prev)); n+=1
                if cos<-0.3: rev+=1
            prev=v
        print(f" unit {u}: {len(tr)} cmds, t {tr[0][0]:.0f}-{tr[-1][0]:.0f}, fight {sum(x[1]=='FIGHT' for x in tr)}, median gap {st.median(gaps):.1f}s, median hop(<6s) {st.median(hops) if hops else 0:.0f}, reversals {rev}/{n}, hops toward enemy {towards} away {away}")
    # show one burst of the busiest unit
    u,tr=tot[0]
    print(" sample:", " ".join(f"{t:.1f}{n[0]}({x:.0f},{z:.0f})" for t,n,x,z,s in tr[40:56]))
for i,w in [(2,0),(3,1),(4,0)]: run(i,w)
