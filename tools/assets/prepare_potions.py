"""Vanilla potion layers, tint values, display transforms, effects and sounds."""
import io
import json
import re
import zipfile
from pathlib import Path
from PIL import Image
from asset_paths import ROOT
from extend_original_item_icons import OriginalPack, digest, OUTPUT
from convert_original_item_models import CONTEXTS, display_transform
from mc_generated_geometry import generated_mesh, mesh_bytes
from convert_spear_sounds import convert


def main():
    reference=json.loads((ROOT/'src/content/potion_reference.json').read_text(encoding='utf8'))
    pack=OriginalPack('26.3')
    ui=json.loads((OUTPUT/'manifest.json').read_text(encoding='utf8'))
    model_root=ROOT/'assets/private/item-models'
    models=json.loads((model_root/'manifest.json').read_text(encoding='utf8'))
    images={e['path']:e for e in ui['outputs']}
    # The runtime's legacy Chinese table is separately pinned; early converters
    # also inspect the newer client table. Keep the final index on the shipped copy.
    legacy=(ROOT/'inputs/ui-legacy-lang.json').read_bytes()
    locked=json.loads((ROOT/'recipes/sources.lock.json').read_text(encoding='utf8'))['extra']['ui-legacy-lang.json']
    assert digest(legacy)==locked['sha256']
    (OUTPUT/'original/lang/zh_cn.json').write_bytes(legacy)
    images['original/lang/zh_cn.json'].update(sha256=digest(legacy),source_sha256=digest(legacy),bytes=len(legacy))
    outputs={e['path']:e for e in models['outputs']}
    sources={}
    def original(path):
        raw=pack.read('assets/minecraft/'+path,{})
        sources[path]=dict(sha256=digest(raw),bytes=len(raw))
        return raw
    def png(image):
        out=io.BytesIO();image.save(out,format='PNG');return out.getvalue()
    def write(path,raw,source,operation):
        target=OUTPUT/path;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(raw)
        images[path]=dict(path=path,bytes=len(raw),sha256=digest(raw),source=source,
                         operation=operation,minecraft_version='26.3',namespace='minecraft')
        return path
    parent=json.loads(original('models/item/generated.json'))['display']
    display={c:display_transform(parent.get(c,parent.get(c.replace('_lefthand','_righthand'),{}))) for c in CONTEXTS}
    overlay=Image.open(io.BytesIO(original('textures/item/potion_overlay.png'))).convert('RGBA')
    for form in ('potion','splash_potion','lingering_potion'):
        model_source='models/item/'+form+'.json';spec=json.loads(original(model_source))
        assert spec['textures']==dict(layer0='minecraft:item/potion_overlay',layer1='minecraft:item/'+form)
        bottle=Image.open(io.BytesIO(original('textures/item/'+form+'.png'))).convert('RGBA')
        for name,potion in reference['potions'].items():
            color=potion['color'];rgb=tuple((color>>shift)&255 for shift in (16,8,0))
            colored=overlay.copy()
            colored.putdata([tuple(v*rgb[i]//255 for i,v in enumerate(pixel[:3]))+(pixel[3],) for pixel in overlay.getdata()])
            colored.alpha_composite(bottle)
            key=f'potions/{form}_{color:06x}'
            icon=write(key+'.png',png(colored),'minecraft-original:26.3:'+model_source,'vanilla-potion-layer-tint')
            mesh_path=key+'.mesh';mesh_id='26.3/'+key
            if mesh_path not in outputs:
                mesh,stats=generated_mesh(colored,'26.3');raw=mesh_bytes(mesh)
                target=model_root/mesh_path;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(raw)
                outputs[mesh_path]=dict(path=mesh_path,sha256=digest(raw),bytes=len(raw))
                models['models'][mesh_id]=dict(path=mesh_path,minecraft_version='26.3',model='minecraft:item/'+form,
                    display=display,gui_light='front',texture_size=[16,16],overrides=[],geometry=stats,
                    vertices=len(mesh['positions']),indices=len(mesh['triangles']),tint=color)
            id=f'pbzmc:{form}_{name}'
            ui['item_icons'][id]=icon
            level=max((e['amplifier'] for e in potion['effects']),default=0)
            suffix=(' '+{1:'II',2:'III',3:'IV',4:'V',5:'VI'}.get(level,str(level+1))) if level else ''
            seconds=max((e['ticks'] for e in potion['effects']),default=0)//20
            label=potion['names'][form]+suffix+(f' ({seconds//60}:{seconds%60:02d})' if seconds else '')
            ui['labels'][id]=label
            ui['label_sources'][id]=dict(kind='minecraft-translation',key='item.minecraft.'+form+'.effect.'+name.removeprefix('long_').removeprefix('strong_'),minecraft_version='26.3',duration_from='Potions')
            ui['item_icon_sources'][id]=dict(minecraft_version='26.3',resource='minecraft:'+form,tint=color)
            models['items'][id]=dict(resource='minecraft:'+form,minecraft_version='26.3',contexts={c:dict(model=mesh_id,conditions=[]) for c in CONTEXTS},variants=[])
            models['unavailable'].pop(id,None);ui.get('incomplete_item_visuals',{}).pop(id,None)
    for name in ('milk_bucket','glass_bottle'):
        raw=original('textures/item/'+name+'.png');image=Image.open(io.BytesIO(raw)).convert('RGBA')
        id='pbzmc:'+name;ui['item_icons'][id]=write('potions/'+name+'.png',png(image),'minecraft-original:26.3:textures/item/'+name+'.png','rgba-pixel-copy')
        language=json.loads((ROOT/'assets/private/minecraft-original/26.3/indexed-assets/minecraft/lang/zh_cn.json').read_text(encoding='utf8'))
        ui['labels'][id]=language['item.minecraft.'+name]
        ui['label_sources'][id]=dict(kind='minecraft-translation',key='item.minecraft.'+name,minecraft_version='26.3')
        mesh,stats=generated_mesh(image,'26.3');mesh_path='potions/'+name+'.mesh';data=mesh_bytes(mesh)
        (model_root/mesh_path).write_bytes(data);outputs[mesh_path]=dict(path=mesh_path,sha256=digest(data),bytes=len(data))
        key='26.3/potions/'+name
        models['models'][key]=dict(path=mesh_path,minecraft_version='26.3',display=display,vertices=len(mesh['positions']),indices=len(mesh['triangles']))
        models['items'][id]=dict(resource='minecraft:'+name,minecraft_version='26.3',contexts={c:dict(model=key,conditions=[]) for c in CONTEXTS},variants=[])
        models['unavailable'].pop(id,None)
    for name,effect in reference['effects'].items():
        source='textures/mob_effect/'+name+'.png';raw=original(source)
        image=Image.open(io.BytesIO(raw)).convert('RGBA')
        ui['status_effects'][name]=write('potions/effects/'+name+'.png',png(image),'minecraft-original:26.3:'+source,'rgba-pixel-copy')
    help_lines=re.findall(r"'([^']+)'",(ROOT/'src/content/quick_help.lua').read_text(encoding='utf8'))
    words='药水VI'+''.join(e['name']for e in reference['effects'].values())+''.join(ui['labels'].values())+''.join(help_lines)
    needed={ord(c):c for c in words if c not in ui['glyphs']}
    uni=(OUTPUT/'original/font/unifont.zip').read_bytes()
    with zipfile.ZipFile(io.BytesIO(uni))as font:
        for member in font.namelist():
            if not member.endswith('.hex'):continue
            for line in font.read(member).decode('ascii').splitlines():
                code,bits=line.split(':',1);point=int(code,16)
                if point not in needed:continue
                char=needed.pop(point);packed=bytes.fromhex(bits);width=len(packed)//2
                bitmap=Image.frombytes('1',(width,16),packed);box=bitmap.getbbox() or (0,0,width,16)
                left,right=box[0],box[2]
                rgba=Image.new('RGBA',(width,16),(255,255,255,0));rgba.putalpha(bitmap.convert('L'));glyph=rgba.crop((left,0,right,16))
                path=write(f'glyphs/{point:06x}.png',png(glyph),'asset:minecraft/font/unifont.zip#'+member+':'+code,'decode-original-unihex-bits')
                images[path].update(source_sha256=digest(uni),crop=[left,0,right,16])
                ui['glyphs'][char]=dict(path=path,width=glyph.width/2,height=8,advance=glyph.width/2+1,ascent=7)
    assert not needed,needed
    added={id for id in models['items'] if ':potion_' in id or ':splash_potion_' in id or ':lingering_potion_' in id}
    added.update(('pbzmc:milk_bucket','pbzmc:glass_bottle'))
    for key in ('missing_item_icons','missing_item_labels'):
        ui[key]=[r for r in ui.get(key,[])if (r.get('id')if isinstance(r,dict)else r)not in added]
    ui['outputs']=list(images.values());models['outputs']=list(outputs.values())
    (OUTPUT/'manifest.json').write_text(json.dumps(ui,ensure_ascii=False,indent=2)+'\n',encoding='utf8')
    (model_root/'manifest.json').write_text(json.dumps(models,ensure_ascii=False,indent=2)+'\n',encoding='utf8')
    (ROOT/'assets/private/potions').mkdir(parents=True,exist_ok=True)
    (ROOT/'assets/private/potions/sources.json').write_text(json.dumps(dict(client=reference['client_sha256'],sources=sources),indent=2)+'\n')
    convert(ROOT/'inputs/assets',ROOT/'inputs/ffmpeg',ROOT/'assets/private/potions/sounds',
        {'drink':'entity.generic.drink','throw':'entity.splash_potion.throw','splash':'entity.splash_potion.break','linger':'entity.lingering_potion.throw'},clip_prefix='potion26_')
    print('Potion layers/models/effect icons/fonts/sounds converted from vanilla 26.3')


if __name__=='__main__':main()
