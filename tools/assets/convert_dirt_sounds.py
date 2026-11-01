"""Decode pinned local original MC building and sword/bow events to PCM."""
import hashlib
import json
from pathlib import Path
import subprocess
from asset_paths import ROOT
ASSETS=(ROOT / 'inputs/assets')
FF=(ROOT / 'inputs/ffmpeg')
index=(ASSETS/'indexes/1.21.1-17.json').read_bytes();entries=json.loads(index)['objects']
out=ROOT/'assets/private/minecraft-1.21.1/sounds';out.mkdir(exist_ok=True)
def read(name):
    item=entries[name];path=ASSETS/'objects'/item['hash'][:2]/item['hash'];raw=path.read_bytes()
    assert len(raw)==item['size'] and hashlib.sha1(raw).hexdigest()==item['hash']
    return path,raw
_,raw=read('minecraft/sounds.json');catalogue=json.loads(raw)
events={};records={};variants={}
event_names={'place':'block.grass.place','hit':'block.grass.hit','break':'block.grass.break',
    'sword_strong':'entity.player.attack.strong','sword_weak':'entity.player.attack.weak',
    'sword_miss':'entity.player.attack.nodamage','bow_shoot':'entity.arrow.shoot','arrow_hit':'entity.arrow.hit',
    'shield_block':'item.shield.block','eat':'entity.generic.eat','burp':'entity.player.burp','totem':'item.totem.use',
    'pearl_throw':'entity.ender_pearl.throw','pearl_teleport':'entity.player.teleport'}
for key,event in event_names.items():
    events[key]=[]
    variants[key]=[]
    for source in catalogue[event]['sounds']:
        spec={'name':source} if isinstance(source,str) else source
        assert spec.get('type','sound')=='sound'
        source=spec['name'];name=source.replace('/','_');events[key].append(name)
        variants[key].append(dict(clip=name,volume=spec.get('volume',1),pitch=spec.get('pitch',1),weight=spec.get('weight',1)))
        if name in records: continue
        path,raw=read('minecraft/sounds/'+source+'.ogg')
        info=json.loads(subprocess.check_output([str(FF/'ffprobe.exe'),'-v','error','-show_streams','-of','json',str(path)]))
        assert len(info['streams'])==1 and info['streams'][0]['codec_type']=='audio'
        assert float(info['streams'][0]['duration'])<10
        output=out/(name+'.pcm')
        subprocess.run([str(FF/'ffmpeg.exe'),'-v','error','-y','-i',str(path),'-ac','2','-ar','44100','-f','s16le',str(output)],check=True)
        pcm=output.read_bytes();assert 0<len(pcm)<=10*44100*4 and len(pcm)%4==0
        records[name]=dict(name=name,file=output.name,bytes=len(pcm),sha256=hashlib.sha256(pcm).hexdigest(),
            source='minecraft/sounds/'+source+'.ogg',source_sha1=hashlib.sha1(raw).hexdigest(),
            source_sha256=hashlib.sha256(raw).hexdigest(),duration_seconds=len(pcm)/(44100*4))
manifest=dict(schema=1,version='1.21.1',format='s16le',channels=2,sample_rate=44100,events=events,
    event_names=event_names,variants=variants,sounds_json_sha256=hashlib.sha256(read('minecraft/sounds.json')[1]).hexdigest(),
    asset_index_sha256=hashlib.sha256(index).hexdigest(),clips=list(records.values()))
(out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n','utf-8')
header='// Generated from verified local Minecraft 1.21.1 audio. No audio bytes.\n'
header+='constexpr ClipSpec clips[] = {\n'
for r in records.values(): header+='    {"'+r['name']+'", "'+r['sha256']+'", '+str(r['bytes'])+'},\n'
header+='};\n'
(ROOT/'native/json_bridge/block_audio_catalogue.hpp').write_text(header,'utf-8')
print(json.dumps(dict(events=events,clips=len(records))))
