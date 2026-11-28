import json, re, sys
try:
    tag=json.load(open(sys.argv[1], encoding='utf-8')).get('tag_name', '')
    if not re.fullmatch(r'20[0-9]{10}', tag): raise ValueError('non-versioned tag')
    print(tag)
except Exception: sys.exit(1)
