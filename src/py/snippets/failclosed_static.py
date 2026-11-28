import json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as f: x=json.load(f)
    out={a['tag']: a for a in x['outbounds']}
    assert out['block']['protocol']=='blackhole'
    route=x['routing']
    bal={a['tag']: a for a in route.get('balancers', [])}
    for b in bal.values():
        assert b.get('fallbackTag')=='block'
    if 'exit' in bal:
        assert any(r.get('balancerTag')=='exit' and
                   (set(r.get('inboundTag', [])) & {'wg-tp', 'socks-in'})
                   for r in route['rules'])
    else:
        assert any(a.get('tag')=='to-exit' and a.get('protocol')=='freedom' and
                   a.get('streamSettings',{}).get('sockopt',{}).get('mark')==255
                   for a in x['outbounds'])
except (OSError, ValueError, KeyError, AssertionError, TypeError):
    sys.exit(1)
