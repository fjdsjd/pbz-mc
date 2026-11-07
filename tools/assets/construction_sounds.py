"""Read vanilla sound events and decode the 26.3 construction bank from verified local inputs."""
from concurrent.futures import ThreadPoolExecutor
from hashlib import sha1, sha256
import json
from pathlib import Path
import subprocess
from asset_paths import ROOT


def sources():
    bank=ROOT/'inputs/assets'
    idx=json.loads(next((bank/'indexes').glob('26.3-*.json')).read_bytes())['objects']
    def object_path(key):
        h=idx[key]['hash'];return bank/'objects'/h[:2]/h
    events=json.loads(object_path('minecraft/sounds.json').read_bytes())
    defs=json.loads((ROOT/'src/content/construction_reference.json').read_bytes())
    groups={};clips={}
    for group in sorted({r[-1] for r in defs['blocks']}):
        choices={}
        for action in ('place','hit','break'):
            event=f'block.{group}.{action}';variants=[]
            for variant in events[event]['sounds']:
                v={'name':variant} if isinstance(variant,str) else variant
                assert v.get('type','sound')=='sound',event
                name='minecraft/sounds/'+v['name'].removeprefix('minecraft:')+'.ogg'
                key='build_'+idx[name]['hash'][:20]
                assert key not in clips or clips[key][0]==name or clips[key][1]['hash']==idx[name]['hash']
                clips[key]=(name,idx[name],object_path(name))
                variants.append(dict(clip=key,volume=v.get('volume',1),pitch=v.get('pitch',1),weight=v.get('weight',1)))
            choices[action]=dict(event=event,variants=variants)
        groups[group]=dict(volume=1,pitch=1,events=choices)
    return clips,groups


def main():
    clips,groups=sources();out=ROOT/'assets/private/construction/sounds';out.mkdir(parents=True,exist_ok=True)
    def convert(entry):
        key,(name,spec,source)=entry
        data=source.read_bytes();assert len(data)==spec['size'] and sha1(data).hexdigest()==spec['hash'],name
        dest=out/(key+'.pcm')
        subprocess.run([str(ROOT/'inputs/ffmpeg/ffmpeg.exe'),'-v','error','-y','-i',str(source),
                        '-ac','2','-ar','44100','-f','s16le',str(dest)],check=True)
        raw=dest.read_bytes();assert 0<len(raw)<1764000 and len(raw)%4==0
        return dict(name=key,bytes=len(raw),sha256=sha256(raw).hexdigest(),source=name,source_sha1=spec['hash'])
    with ThreadPoolExecutor(max_workers=5) as pool:records=list(pool.map(convert,sorted(clips.items())))
    (out/'manifest.json').write_text(json.dumps(dict(groups=groups,clips=records),separators=(',',':')),encoding='utf8')
    print(len(groups),'vanilla sound groups;',len(records),'distinct sound files')


if __name__=='__main__':main()
