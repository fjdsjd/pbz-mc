"""Generate numeric fire facts from ExportFire's pinned local MC registry."""
from pathlib import Path
import hashlib,json,zipfile
ROOT=Path(__file__).resolve().parents[2]
def main():
    ref=ROOT/'research/private/fire/26.3'
    rows=json.loads((ref/'registry.json').read_bytes())
    identity=json.loads((ref/'collection.json').read_bytes())
    jar=ROOT/'build/command-check/clean-enhanced/inputs/26.3.jar'
    with jar.open('rb') as source:
        if hashlib.file_digest(source,'sha256').hexdigest()!=identity['jar_sha256']:
            raise ValueError('Fire reference JAR no longer matches the collected registry')
    with zipfile.ZipFile(jar) as z:
        def tag(name):
            result=set()
            for v in json.loads(z.read('data/minecraft/tags/block/'+name+'.json'))['values']:
                v=(v if isinstance(v,str)else v['id']).replace('minecraft:','')
                result.update(tag(v[1:]))if v.startswith('#')else result.add(v)
            return result
        blockers=sorted(tag('blocks_lava_fire_spread'))
    result=dict(version='26.3',client_sha256=identity['jar_sha256'],
                columns=['ignite_odds','burn_odds','ignited_by_lava'],blocks=rows,lava_blockers=blockers)
    (ROOT/'src/content/fire_reference.json').write_text(json.dumps(result,indent=2)+'\n')
    fields=['-- Generated registry observations; see tools/reference/ExportFire.java.','return {version="26.3",blocks={']
    for name,values in sorted(rows.items()):
        fields.append('["pbzmc:%s"]={%d,%d,%s},'%(name,values[0],values[1],str(values[2]).lower()))
    fields.append('},lava_blockers={')
    fields.extend('["pbzmc:%s"]=true,'%name for name in blockers)
    fields.append('}}\n')
    (ROOT/'src/content/fire_reference.lua').write_text('\n'.join(fields))
    print(f'{len(rows)} fire / lava registry entries')
if __name__=='__main__': main()
