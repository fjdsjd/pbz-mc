"""Convert original 26.3 creature events; aliases keep vanilla shared voices.

No downloads here: inputs come from the hash-pinned release asset index.
Empty original events remain silent. Event references preserve their weights,
volume and pitch instead of substituting a sound from an unrelated creature.
"""
from concurrent.futures import ThreadPoolExecutor
from hashlib import sha1, sha256
import json
import subprocess
from asset_paths import ROOT

ALIASES = dict(cave_spider='spider', giant='zombie', killer_bunny='rabbit',
               mooshroom='cow', trader_llama='llama', pufferfish='puffer_fish')
EVENTS = {
    'ambient': ('ambient', 'ambient_without_item', 'idle_air', 'idle', 'ambient_land', 'loop'),
    'ambient_water': ('ambient_water', 'idle_water'),
    'hurt': ('hurt',), 'hurt_water': ('hurt_water',), 'death': ('death',), 'death_water': ('death_water',),
    'attack': ('attack', 'attack_impact', 'bite', 'sting', 'ram_impact', 'tongue'),
    'shoot': ('shoot', 'sonic_boom', 'cast_spell', 'spit', 'throw', 'attack'),
    'charge': ('sonic_charge', 'charge', 'prepare_attack', 'prepare_ram'),
    'jump': ('jump', 'long_jump'), 'flop': ('flop',), 'step': ('step', 'shamble'),
    'teleport': ('teleport',), 'spawn': ('spawn',),
    'open': ('open',), 'close': ('close',),
}


def catalogue(root=ROOT):
    bank=root/'inputs/assets'
    raw_index=(bank/'indexes/26.3-34.json').read_bytes()
    objects=json.loads(raw_index)['objects']
    spec=objects['minecraft/sounds.json']
    raw=(bank/'objects'/spec['hash'][:2]/spec['hash']).read_bytes()
    assert sha1(raw).hexdigest()==spec['hash'] and len(raw)==spec['size'], 'mob-sound-index'
    sounds=json.loads(raw)
    names=json.loads((root/'src/content/mob_behavior_reference.json').read_bytes())['mobs']
    clips={}
    def flatten(event,volume=1,pitch=1,weight=1,trail=()):
        assert event not in trail and len(trail)<8, 'cyclic-sound-event'
        rows=[]
        for entry in sounds[event]['sounds']:
            row={'name':entry} if isinstance(entry,str) else entry
            name=row['name'].removeprefix('minecraft:')
            vol=volume*row.get('volume',1);speed=pitch*row.get('pitch',1)
            probability=weight*row.get('weight',1)
            if row.get('type','sound')=='event':
                nested=flatten(name,vol,speed,1,trail+(event,))
                total=sum(r['weight'] for r in nested)
                for child in nested:child['weight']=probability*child['weight']/total
                rows.extend(nested)
            else:
                resource='minecraft/sounds/'+name+'.ogg';spec=objects[resource]
                key='mob_'+spec['hash'][:20]
                assert key not in clips or clips[key][1]['hash']==spec['hash']
                clips[key]=(resource,spec,bank/'objects'/spec['hash'][:2]/spec['hash'])
                rows.append(dict(clip=key,volume=vol,pitch=speed,weight=probability))
        return rows
    species={}
    for name in names:
        family=ALIASES.get(name,name);selected={}
        for action,choices in EVENTS.items():
            event=next((f'entity.{family}.{part}' for part in choices if f'entity.{family}.{part}' in sounds),None)
            if action=='shoot' and event is None and name in ('stray','bogged','parched','illusioner','pillager'):
                event='entity.skeleton.shoot'
            if action=='shoot' and name=='elder_guardian':event='entity.guardian.attack'
            if event:
                selected[action]=dict(event=event,variants=flatten(event))
        assert 'death' in selected and ('hurt' in selected or name=='creaking'), 'missing-creature-voice:'+name
        species[name]=dict(events=selected,ambient_delay=8,ambient_range=16)
    return clips,dict(schema=1,version='26.3',format='s16le',channels=2,sample_rate=44100,
        species=species,asset_index_sha256=sha256(raw_index).hexdigest(),sounds_json_sha256=sha256(raw).hexdigest())


def convert(root=ROOT):
    clips,manifest=catalogue(root)
    output=root/'assets/private/mob-sounds';bank=output/'sounds';bank.mkdir(parents=True,exist_ok=True)
    def one(entry):
        key,(name,spec,path)=entry
        raw=path.read_bytes();assert len(raw)==spec['size'] and sha1(raw).hexdigest()==spec['hash'],name
        pcm=subprocess.check_output([str(root/'inputs/ffmpeg/ffmpeg.exe'),'-nostdin','-v','error','-i',str(path),
            '-ac','2','-ar','44100','-f','s16le','-'])
        assert 0<len(pcm)<=44100*4*30 and len(pcm)%4==0, name
        (bank/(key+'.pcm')).write_bytes(pcm)
        return dict(name=key,file=key+'.pcm',bytes=len(pcm),sha256=sha256(pcm).hexdigest(),
            source=name,source_sha1=spec['hash'],source_sha256=sha256(raw).hexdigest(),duration=len(pcm)/176400)
    with ThreadPoolExecutor(max_workers=4)as pool:manifest['clips']=list(pool.map(one,sorted(clips.items())))
    (output/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,sort_keys=True,separators=(',',':'))+'\n',encoding='utf8')
    print(json.dumps(dict(species=len(manifest['species']),clips=len(clips),bytes=sum(c['bytes']for c in manifest['clips']))))
    return manifest


if __name__=='__main__':convert()
