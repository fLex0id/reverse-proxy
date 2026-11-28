import json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as f:
        conf = json.load(f)
    bal = next(b for b in conf.get('routing', {}).get('balancers', []) if b['tag'] == 'rev')
    sys.exit(0 if sys.argv[2] in bal.get('selector', []) else 1)
except (OSError, ValueError, TypeError, KeyError, StopIteration):
    sys.exit(1)
