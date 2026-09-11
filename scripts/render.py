"""Render {{ placeholders }} in .sql files from config/environments/<env>.yml.

    python scripts/render.py sandbox ingestion/sql/*.sql > deploy_sandbox.sql

Exits non-zero naming any placeholder that is missing or still TBD, so a
half-configured environment fails here instead of deploying a broken object.

ponytail: no PyYAML -- the env files are flat `key: value`. Switch to yaml if
they ever need nesting, lists, or multi-line values.
"""
import pathlib
import re
import sys

env, sql_files = sys.argv[1], sys.argv[2:]

cfg = {}
for line in pathlib.Path(f'config/environments/{env}.yml').read_text().splitlines():
    line = line.split('#', 1)[0].strip()          # drop comments, keep `key: value`
    if ':' in line:
        key, value = line.split(':', 1)
        cfg[key.strip()] = value.strip()

unset = set()


def lookup(match):
    value = cfg.get(match.group(1), 'TBD')
    if value == 'TBD':
        unset.add(match.group(1))
        return match.group(0)                     # leave it visible in the diff
    return value


sql = '\n\n'.join(pathlib.Path(f).read_text(encoding='utf-8') for f in sql_files)
rendered = re.sub(r'\{\{\s*(\w+)\s*\}\}', lookup, sql)

if unset:
    sys.exit(f'render: missing or TBD in {env}.yml: {", ".join(sorted(unset))}')

sys.stdout.reconfigure(encoding='utf-8')          # SQL comments contain box chars
print(rendered)
