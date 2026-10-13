import json,sys
for tag in sys.argv[1:]:
    try: r=json.load(open(f'runs_stance/{tag}.json'))
    except Exception as e: print(tag,'missing',e); continue
    tl=r['tracker_timeline']
    print(tag,r['winner_method'],'desync',r['desync'],'err',len(r['lua_errors']),'last',round(max(x['frame'] for x in tl)/1800,1))
    for x in tl:
        if x['team']==0 and x['kind']=='eco' and x['frame']%3600==0 and x['frame']>=7200:
            u=[y for y in tl if y['team']==0 and y['kind']=='units' and y['frame']==x['frame']]
            u=u[0] if u else {}
            print(' %2dm minc=%5.0f mpull=%5.0f einc=%6.0f epull=%6.0f mfill=%.2f efill=%.2f flM=%.2f flE=%.2f stM=%.2f army=%6d fac_bp=%6s busy=%2s idle=%2s gfac=%2s units=%4d'%(x['frame']//1800,x["metal_inc_avg"],x["metal_pull_avg"],x["energy_inc_avg"],x['energy_pull_avg'],x['metal']/max(1,x['metal_cap']),x['energy']/max(1,x['energy_cap']),x['float_m'],x['float_e'],x['stall_m'],u.get('army_mv',0),u.get('fac_bp'),u.get('fac_busy'),u.get('fac_idle'),u.get('ground_fac'),x['units_total']))
