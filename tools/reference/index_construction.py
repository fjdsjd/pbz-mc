"""Update the public hash recipes from a completed private vanilla conversion."""
from collections import Counter
from hashlib import sha256, sha1
from pathlib import Path
import json
import sys
import zipfile
from PIL import Image

root=Path(__file__).resolve().parents[2]
work=Path(sys.argv[1]).resolve()
private=work/'assets/private'
recipes=root/'distribution/asset-recipes'
def read(p):return json.loads(p.read_bytes())
def digest(p):return sha256(p.read_bytes()).hexdigest()
def write(p,v):p.write_bytes((json.dumps(v,ensure_ascii=False,indent=2)+'\n').encode())
idx=read(recipes/'runtime-files.json')
def index(key,file):idx[key]=dict(bytes=file.stat().st_size,sha256=digest(file))
catalog=read(private/'construction/manifest.json');ui=private/'minecraft-1.21.1/ui'
template=recipes/'manifests/ui/manifest.json';u=read(template)
outputs={r['path']:r for r in u['outputs']}
for file in sorted((private/'construction').rglob('*')):
    if file.is_file():
        key=('sounds/'+file.name) if file.suffix=='.pcm' else file.relative_to(private).as_posix()
        index(key,file)
bank=private/'construction/sounds/manifest.json'
if bank.exists():
    spec=read(bank)
    header=root/'native/json_bridge/construction_sounds.inc'
    header.write_text(''.join('    {"%s", "%s", %d},\n'%(r['name'],r['sha256'],r['bytes']) for r in spec['clips']),encoding='ascii')
lang=private/'minecraft-original/26.3/indexed-assets/minecraft/lang/zh_cn.json'
zh_sha=digest(lang);zh_sha1=sha1(lang.read_bytes()).hexdigest()
for name,record in catalog['blocks'].items():
    id='pbzmc:'+name;rel=record['icon'];file=ui/rel
    if id in u['item_icons'] and u['item_icons'][id]!=rel:continue
    u['item_icons'][id]=rel;u['labels'][id]=record['label']
    u['item_icon_sources'][id]=dict(minecraft_version='26.3',resource='minecraft:'+name,geometry='original-model',conditions=[])
    u['label_sources'][id]=dict(kind='minecraft-translation',key='block.minecraft.'+name,minecraft_version='26.3',
        source='assets/private/minecraft-original/26.3/indexed-assets/minecraft/lang/zh_cn.json',sha256=zh_sha,asset_sha1=zh_sha1)
    outputs[rel]=dict(path=rel,sha256=digest(file),bytes=file.stat().st_size,size=list(Image.open(file).size),
        operation='original-block-model-gui-render',source='minecraft-original:26.3:assets/minecraft/items/'+name+'.json')
    index('ui/'+rel,file)
fonts=ui/'original/font/unifont.zip';needed=set(''.join(u['labels'].values()))-set(u['glyphs'])
with zipfile.ZipFile(fonts) as z:
    for member in z.namelist():
        if not member.endswith('.hex') or not needed:continue
        for line in z.read(member).decode('ascii').splitlines():
            code,data=line.split(':');pt=int(code,16);ch=chr(pt)
            if ch not in needed:continue
            bits=bytes.fromhex(data);w=len(bits)//2;bmp=Image.frombytes('1',(w,16),bits)
            bbox=bmp.getbbox()
            if not bbox:continue
            crop=(bbox[0],0,bbox[2],16);im=Image.new('RGBA',(w,16),(255,255,255,0));im.putalpha(bmp.convert('L'))
            rel=f'glyphs/{pt:06x}.png';im.crop(crop).save(ui/rel)
            outputs[rel]=dict(path=rel,sha256=digest(ui/rel),source='asset:minecraft/font/unifont.zip#'+member+':'+code,
                              source_sha256=digest(fonts),operation='decode-original-unihex-bits',crop=list(crop))
            u['glyphs'][ch]=dict(path=rel,width=(crop[2]-crop[0])/2,height=8,advance=(crop[2]-crop[0])/2+1,ascent=7)
            index('ui/'+rel,ui/rel);needed.remove(ch)
assert not (needed-set(' ')), needed
u['outputs']=list(outputs.values())
u['label_coverage'].update(definitions=len(u['labels']),covered=len(u['label_sources']),
    by_source=dict(Counter(s['kind'] for s in u['label_sources'].values())),definitions_sha256=digest(root/'src/content/items.lua'))
write(template,u)
idx['ui/manifest.json']=dict(template='ui/manifest.json',sha256=digest(template))
write(recipes/'runtime-files.json',idx)
