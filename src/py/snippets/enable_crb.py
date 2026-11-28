import glob, os, re, tempfile
rid = re.compile(r'^\[crb\]\s*$')
for path in glob.glob('/etc/yum.repos.d/*.repo'):
    try:
        with open(path, encoding='utf-8') as f: lines = f.readlines()
    except OSError:
        continue
    for i, line in enumerate(lines):
        if rid.match(line.strip()):
            j = i + 1
            while j < len(lines) and not lines[j].lstrip().startswith('['): j += 1
            section = ''.join(lines[i+1:j])
            if re.search(r'(?m)^\s*enabled\s*=', section):
                section = re.sub(r'(?m)^(\s*enabled\s*=\s*)\S+', r'\g<1>1', section)
            else:
                section = 'enabled=1\n' + section
            lines[i+1:j] = [section]
            fd, tmp = tempfile.mkstemp(prefix='.rp-crb-', dir=os.path.dirname(path))
            with os.fdopen(fd, 'w', encoding='utf-8') as f: f.writelines(lines)
            os.chmod(tmp, os.stat(path).st_mode & 0o777)
            os.replace(tmp, path)
            raise SystemExit(0)
raise SystemExit(1)
