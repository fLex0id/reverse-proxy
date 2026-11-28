import json,sys
try:
    x=json.load(open(sys.argv[1]))
    bals={b['tag']: b for b in x.get('routing',{}).get('balancers',[])}
    target=sys.argv[2]
    assert target in bals['exit']['selector']
    ctl=sys.argv[3]
    if ctl!='to-exit' and 'rev' in bals:
        assert ctl in bals['rev']['selector']
except (OSError,ValueError,KeyError,TypeError,AssertionError):
    sys.exit(1)
