"""Compact vanilla registry observations for the release converter and Lua rules."""
import argparse
import json
from functools import lru_cache
from pathlib import Path
from zipfile import ZipFile


def encoded(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'))


def generate(export, jar, target):
    data = json.loads(export.read_bytes())
    profiles, shape_sets, blocks = {}, [], []
    with ZipFile(jar) as archive:
        @lru_cache(None)
        def tag(name):
            values = json.loads(archive.read('data/minecraft/tags/block/' + name + '.json'))['values']
            result = set()
            for v in values:
                v = (v if isinstance(v, str) else v['id']).replace('minecraft:', '')
                result.update(tag(v[1:])) if v.startswith('#') else result.add(v)
            return result

        for name, row in data['blocks'].items():
            profile = encoded([row['default'],row['states']])
            if profile not in profiles:
                profiles[profile] = len(shape_sets)
                shape_sets.append([row['default'],row['states']])
            tools = [tool for tool in ('pickaxe','shovel','axe','hoe') if name in tag('mineable/' + tool)]
            tier = next((t for t in ('diamond','iron','stone') if name in tag('needs_'+t+'_tool')), '')
            blocks.append([name,row['class'],profiles[profile],row['hardness'],row['resistance'],row['requires_tool'],
                           tools,tier,row['push'],row['sound'][0].split('.')[1]])
    facts = dict(schema=1, version='26.3', tabs=data['tabs'], blocks=blocks, profiles=shape_sets, shapes=data['shapes'])
    target.write_text(encoded(facts)+'\n',encoding='utf-8')


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    for name in ('export','jar','target'):
        ap.add_argument(name,type=Path)
    args = ap.parse_args()
    generate(args.export,args.jar,args.target)
