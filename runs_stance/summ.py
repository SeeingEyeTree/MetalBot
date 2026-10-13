import json,sys
tag=sys.argv[1]
for slot in ('s0','s1'):
    r=json.load(open(f'runs_stance/{tag}_{slot}.json'))
    stance_team = 0 if slot=='s0' else 1
    d=r.get('draw_score') or {}
    print(tag,slot,'STANCE is team',stance_team,'| winner',r['winner'],r['winner_method'],'| desync',r['desync'],'luafail',r['lua_failure'])
    if d and 'score0' in d:
        a,b=d['score%d'%stance_team],d['score%d'%(1-stance_team)]
        print('   end score STANCE %.0f vs v16 %.0f  ratio %.2f ; army %.0f vs %.0f ; inc %.0f vs %.0f'%(a,b,a/b,d['mv%d'%stance_team],d['mv%d'%(1-stance_team)],d['metal_inc%d'%stance_team],d['metal_inc%d'%(1-stance_team)]))
