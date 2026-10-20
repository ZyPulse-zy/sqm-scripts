#!/usr/bin/env python3
"""Verify that the review revision changes only the two requested indentations."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

source, output = Path(sys.argv[1]), Path(sys.argv[2])
before = 'b79b4447ca210594895dc4e8e41ed826f909c87b'
after = '2e581cd032fef269b4964188e58b774739dd8939'
def git(*args):
    return subprocess.check_output(['git', '-C', str(source), *args])
assert git('rev-parse', 'HEAD').decode().strip() == after
assert git('diff', '--name-only', before, after).decode().splitlines() == ['src/functions.sh']
old = git('show', before + ':src/functions.sh')
expected = old
for direction in ['egress', 'ingress']:
    line = ('\tif fn_exists ' + direction + '; then').encode()
    assert expected.count(line) == 1
    expected = expected.replace(line, b'        ' + line[1:])
new = git('show', after + ':src/functions.sh')
assert new == expected
assert not git('diff', '--ignore-all-space', before, after)
assert git('show', '-s', '--format=%B', before) == git('show', '-s', '--format=%B', after)
files = {}
for name in ['src/start-sqm', 'src/run-openwrt.sh', 'platform/linux/sqm-bin']:
    content = git('show', before + ':' + name)
    assert content == git('show', after + ':' + name)
    files[name] = hashlib.sha256(content).hexdigest()
output.write_text(json.dumps({'before': before, 'after': after, 'only_change': 'two leading tabs replaced with eight spaces', 'functions_before_sha256': hashlib.sha256(old).hexdigest(), 'functions_after_sha256': hashlib.sha256(new).hexdigest(), 'other_files_unchanged': files, 'commit_message_unchanged': True}, indent=2) + '\n')
