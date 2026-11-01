"""Original MC 1.21.1 crit sprite -> exact opaque horizontal pixel runs."""
from pathlib import Path
import hashlib,io,json,zipfile
from PIL import Image
from asset_paths import ROOT
receipt={'inputs':[{}, {'path':str(ROOT/'inputs/1.21.1.jar'),'sha256':'499f6897d1837516680f3114072d8106e11c9adcd933fe5cf051b551089b0c99'}]}
original=Path(receipt['inputs'][1]['path'])
assert hashlib.sha256(original.read_bytes()).hexdigest()==receipt['inputs'][1]['sha256']
member='assets/minecraft/textures/particle/critical_hit.png'
with zipfile.ZipFile(original) as z: raw=z.read(member);definition=z.read('assets/minecraft/particles/crit.json')
im=Image.open(io.BytesIO(raw)).convert('RGBA');assert im.size==(8,8)
assert set(im.getchannel('A').getdata())<={0,255}
runs=[]
for y in range(8):
 x=0
 while x<8:
  color=im.getpixel((x,y));end=x+1
  while end<8 and im.getpixel((end,y))==color:end+=1
  if color[3]:runs.append([x,y,end-x,*color[:3]])
  x=end
data={'schema':1,'version':'1.21.1','source':member,'source_sha256':hashlib.sha256(raw).hexdigest(),
 'definition_sha256':hashlib.sha256(definition).hexdigest(),'width':8,'height':8,'runs':runs}
out=ROOT/'assets/private/effects';out.mkdir(exist_ok=True)
(out/'critical_hit.png').write_bytes(raw)
encoded=json.dumps(data,separators=(',',':')).encode();(out/'critical_hit.json').write_bytes(encoded)
manifest={'schema':1,'files':[{'path':'critical_hit.json','sha256':hashlib.sha256(encoded).hexdigest()},
 {'path':'critical_hit.png','sha256':hashlib.sha256(raw).hexdigest()}],'origin':str(original),'origin_sha256':receipt['inputs'][1]['sha256']}
(out/'manifest.json').write_text(json.dumps(manifest,indent=2),encoding='utf8')
print(json.dumps({'sprite':im.size,'opaque_pixels':sum(1 for p in im.getdata() if p[3]),'runs':len(runs),'json_sha256':manifest['files'][0]['sha256']}))
