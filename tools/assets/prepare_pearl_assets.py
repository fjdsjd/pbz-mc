"""Pack original portal particle frames; never paint replacement textures."""
from pathlib import Path
import hashlib,io,json,zipfile
from PIL import Image
from asset_paths import ROOT
receipt={'inputs':[{}, {'path':str(ROOT/'inputs/1.21.1.jar'),'sha256':'499f6897d1837516680f3114072d8106e11c9adcd933fe5cf051b551089b0c99'}]}
jar=Path(receipt['inputs'][1]['path']);out=ROOT/'assets/private/effects';out.mkdir(parents=True,exist_ok=True)
def sha(b):return hashlib.sha256(b).hexdigest()
assert sha(jar.read_bytes())==receipt['inputs'][1]['sha256']
with zipfile.ZipFile(jar) as pack:
    spec=pack.read('assets/minecraft/particles/portal.json');frames=json.loads(spec)['textures'];records=[];images=[]
    for name in frames:
        path='assets/minecraft/textures/particle/'+name.split(':')[-1]+'.png';raw=pack.read(path)
        im=Image.open(io.BytesIO(raw)).convert('RGBA');images.append(im)
        records.append(dict(resource=path,sha256=sha(raw)))
    w,h=images[0].size;assert all(im.size==(w,h) for im in images)
    atlas=Image.new('RGBA',(w*len(images),h))
    for i,im in enumerate(images):atlas.paste(im,(i*w,0))
    target=out/'portal.png';atlas.save(target)
    meta=dict(schema=1,version='1.21.1',frames=len(images),width=w,height=h,
              sources=records,particle_json_sha256=sha(spec),atlas_sha256=sha(target.read_bytes()),operation='unchanged original frames concatenated horizontally')
    (out/'portal.json').write_text(json.dumps(meta,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(dict(frames=len(images),size=atlas.size,sha256=meta['atlas_sha256'])))
