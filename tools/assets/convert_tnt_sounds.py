"""Verify and decode local original TNT/fire audio; no native-code edits."""
from pathlib import Path
import hashlib
import json
import subprocess

from asset_paths import ROOT
ASSETS=(ROOT / 'inputs/assets')
FF=(ROOT / 'inputs/ffmpeg')
OUT=ROOT/'assets/private/tnt/sounds'
EVENTS={'fuse':'entity.tnt.primed','flint':'item.flintandsteel.use',
        'explosion':'entity.generic.explode','fire':'block.fire.ambient','extinguish':'block.fire.extinguish'}

def sha(raw): return hashlib.sha256(raw).hexdigest()

def main():
    index=(ASSETS/'indexes/1.21.1-17.json').read_bytes();entries=json.loads(index)['objects']
    def read(name):
        item=entries[name];path=ASSETS/'objects'/item['hash'][:2]/item['hash'];raw=path.read_bytes()
        assert len(raw)==item['size'] and hashlib.sha1(raw).hexdigest()==item['hash']
        return path,raw
    _,catalogue_raw=read('minecraft/sounds.json');catalogue=json.loads(catalogue_raw)
    OUT.mkdir(parents=True,exist_ok=True)
    records={};variants={};events={}
    for key,event in EVENTS.items():
        variants[key]=[];events[key]=[]
        for source in catalogue[event]['sounds']:
            spec={'name':source} if isinstance(source,str) else source
            assert spec.get('type','sound')=='sound'
            name=spec['name'].replace('/','_');events[key].append(name)
            variants[key].append(dict(clip=name,volume=spec.get('volume',1),pitch=spec.get('pitch',1),weight=spec.get('weight',1)))
            if name in records: continue
            member='minecraft/sounds/'+spec['name']+'.ogg';path,raw=read(member)
            info=json.loads(subprocess.check_output([str(FF/'ffprobe.exe'),'-v','error','-show_streams','-of','json',str(path)]))
            assert len(info['streams'])==1 and info['streams'][0]['codec_type']=='audio'
            assert float(info['streams'][0]['duration'])<60
            output=OUT/(name+'.pcm')
            subprocess.run([str(FF/'ffmpeg.exe'),'-v','error','-y','-i',str(path),'-ac','2','-ar','44100','-f','s16le',str(output)],check=True)
            pcm=output.read_bytes();assert 0<len(pcm)<=60*44100*4 and len(pcm)%4==0
            records[name]=dict(name=name,file=output.name,bytes=len(pcm),sha256=sha(pcm),source=member,
                               source_sha1=hashlib.sha1(raw).hexdigest(),source_sha256=sha(raw),
                               source_codec=info['streams'][0]['codec_name'],duration_seconds=len(pcm)/(44100*4))
    manifest=dict(schema=1,version='1.21.1',format='s16le',channels=2,sample_rate=44100,
        event_names=EVENTS,events=events,variants=variants,clips=list(records.values()),
        sounds_json_sha256=sha(catalogue_raw),asset_index_sha256=sha(index),
        asset_index=str(ASSETS/'indexes/1.21.1-17.json'),recipe_sha256=sha(Path(__file__).read_bytes()),
        encoder=dict(path=str(FF/'ffmpeg.exe'),sha256=sha((FF/'ffmpeg.exe').read_bytes())),
        native_audio_modified=False,deployed=False)
    (OUT/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf8')
    print(json.dumps(dict(clips=len(records),events=events,max_duration=max(r['duration_seconds'] for r in records.values()),
                         bytes=sum(r['bytes'] for r in records.values()),format='s16le stereo 44100Hz')))

if __name__=='__main__': main()
