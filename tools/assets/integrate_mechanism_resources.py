"""Merge the private mechanism bundle into the existing production manifests."""
import hashlib
import json
from pathlib import Path

from asset_paths import ROOT
BUNDLE=ROOT/'assets/private/mechanism-blocks'
UI=ROOT/'assets/private/minecraft-1.21.1/ui'
ITEMS=ROOT/'assets/private/item-models'

def load(p):return json.loads(p.read_text(encoding='utf-8'))
def write(p,v):p.write_text(json.dumps(v,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
def sha(raw):return hashlib.sha256(raw).hexdigest()
def retained(root,source,path,expected):
    raw=(BUNDLE/source).read_bytes();assert sha(raw)==expected
    dest=root/path;dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(raw)
    return dict(path=path,sha256=sha(raw),bytes=len(raw))

def main():
    f=load(BUNDLE/'integration-fragments.json');im=load(ITEMS/'manifest.json');ui=load(UI/'manifest.json')
    outputs={row['path']:row for row in im['outputs']};images={row['path']:row for row in ui['outputs']}
    for key,entry in f['models'].items():
        row=dict(entry);path='minecraft/1.21.1/mechanism/'+Path(row['path']).name
        if row.get('palette'):
            palette=dict(row['palette']);texture_path='mechanisms/'+palette['path']
            outputs[texture_path]=dict(retained(ITEMS,palette['path'],texture_path,palette['sha256']),
                                       size=palette['size'],operation='lossless-vertex-rgba-palette')
            palette['path']=texture_path;row['palette']=palette
        outputs[path]=retained(ITEMS,row['path'],path,row['sha256']);row['path']=path;im['models'][key]=row
    im['items'].update(f['items']);im['outputs']=list(outputs.values())
    for id,entry in f['icons'].items():
        path='mechanisms/'+Path(entry['path']).name
        images[path]=dict(retained(UI,entry['path'],path,entry['sha256']),size=entry['size'],
                          source='mechanism-blocks/'+entry['path'],operation=entry['operation'])
        ui['item_icons'][id]=path;ui['labels'][id]=entry['label'];ui['label_sources'][id]=dict(entry['label_source'],kind='minecraft-translation')
        ui.setdefault('item_visual_sources',{})[id]=dict(minecraft_version='1.21.1',manifest='mechanism-blocks/manifest.json',
            original_model=entry['original_model'],item_model=entry['item_model'],source_dependencies=entry['dependencies'])
        if id in ui.get('missing_item_icons',[]):ui['missing_item_icons'].remove(id)
        ui.get('incomplete_item_visuals',{}).pop(id,None)
    ui['outputs']=list(images.values())
    if 'missing_item_labels'in ui:ui['missing_item_labels']=[r for r in ui['missing_item_labels']if (r.get('id')if isinstance(r,dict)else r)not in f['icons']]
    extensions=load(ROOT/'src/content/extension_items.json');upstream=load(ROOT/'src/content/upstream_ids.json')['items']
    existing=set(upstream.values())|{r['id']for r in extensions['items']}
    for id in f['items']:
        if id not in existing:extensions['items'].append(dict(id=id,stack_limit=64,visual_version='1.21.1',source='PBZ mechanisms requirement 2026-11-01'))
    write(ROOT/'src/content/extension_items.json',extensions);write(ITEMS/'manifest.json',im);write(UI/'manifest.json',ui)
    print(json.dumps(dict(items=len(f['items']),models=len(f['models']),icons=len(f['icons']),original_labels=True)))

if __name__=='__main__':main()
