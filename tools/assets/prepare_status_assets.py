"""Original MC effect icons/fonts, particle frames and enchanted apple resource."""
from pathlib import Path
import io,json,zipfile,json5,copy,math,struct
from PIL import Image,ImageDraw
from extend_original_item_icons import OriginalPack,OUTPUT,ROOT,digest
pack=OriginalPack('1.21.1');manifest=json.loads((OUTPUT/'manifest.json').read_text(encoding='utf-8'))
outputs={e['path']:e for e in manifest['outputs']}
def save(path,raw,source,original,operation,**meta):
 p=OUTPUT/path;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(raw)
 outputs[path]=dict(path=path,sha256=digest(raw),source=source,source_sha256=digest(original),operation=operation,**meta)
 return path
def retain(resource):
 source='assets/minecraft/'+resource;raw=pack.read(source,{})
 return save('original/minecraft/1.21.1/'+resource,raw,'minecraft-original:1.21.1:'+source,raw,'byte-copy')
effects={id:retain('textures/mob_effect/'+id+'.png') for id in ['regeneration','absorption','resistance','fire_resistance']}
effects['background']=retain('textures/gui/sprites/container/inventory/effect_background_large.png')
manifest['status_effects']=effects
lang=json.loads((OUTPUT/'original/lang/zh_cn.json').read_text(encoding='utf-8'))
labels=[lang['effect.minecraft.'+id] for id in effects if id!='background']
labels.append(lang['item.minecraft.enchanted_golden_apple'])
manifest['labels']['pbzmc:enchanted_golden_apple']=labels[-1]
needed={ord(c):c for c in ''.join(labels) if c not in manifest['glyphs']}
uni=(OUTPUT/'original/font/unifont.zip').read_bytes()
config=next(p for p in json5.loads((OUTPUT/'original/font/include/unifont.json').read_text(encoding='utf-8'))['providers'] if p.get('hex_file')=='minecraft:font/unifont.zip')
with zipfile.ZipFile(io.BytesIO(uni)) as font:
 for member in font.namelist():
  if not member.endswith('.hex'):continue
  for line in font.read(member).decode('ascii').splitlines():
   code,bits=line.split(':',1);point=int(code,16)
   if point not in needed:continue
   char=needed.pop(point);packed=bytes.fromhex(bits);width=len(packed)//2
   bitmap=Image.frombytes('1',(width,16),packed);bbox=bitmap.getbbox();left,right=(bbox[0],bbox[2]-1) if bbox else (0,width-1)
   for override in config.get('size_overrides',[]):
    if ord(override['from'])<=point<=ord(override['to']):left,right=override['left'],override['right'];break
   rgba=Image.new('RGBA',(width,16),(255,255,255,0));rgba.putalpha(bitmap.convert('L'));glyph=rgba.crop((left,0,right+1,16))
   b=io.BytesIO();glyph.save(b,format='PNG');p=save(f'glyphs/{point:06x}.png',b.getvalue(),'asset:minecraft/font/unifont.zip#'+member+':'+code,uni,'decode-original-unihex-bits',crop=[left,0,right+1,16])
   manifest['glyphs'][char]=dict(path=p,width=glyph.width/2,height=8,advance=glyph.width/2+1,ascent=7)
assert not needed,needed
# The enchanted apple's vanilla model inherits golden_apple; keep identity distinct.
manifest['item_icons']['pbzmc:enchanted_golden_apple']=manifest['item_icons']['pbzmc:golden_apple']
manifest['item_icon_sources']['pbzmc:enchanted_golden_apple']=dict(minecraft_version='1.21.1',resource='minecraft:enchanted_golden_apple',glint=True)
glint=retain('textures/misc/enchanted_glint_item.png')
manifest['enchantment_glint']=glint
glint_raw=pack.read('assets/minecraft/textures/misc/enchanted_glint_item.png',{})
glint_image=Image.open(io.BytesIO(glint_raw)).convert('RGBA')
apple_raw=pack.read('assets/minecraft/textures/item/golden_apple.png',{})
apple=Image.open(io.BytesIO(apple_raw)).convert('RGBA')
glint_atlas=Image.new('RGBA',(apple.width*4,apple.height*3))
for frame in range(12):
 enchanted=apple.copy()
 for y in range(apple.height):
  for x in range(apple.width):
   c=apple.getpixel((x,y))
   if c[3]:
    intensity=glint_image.getpixel(((x*3+y+frame*7)%glint_image.width,(y*3-x+frame*3)%glint_image.height))[0]/255
    enchanted.putpixel((x,y),tuple(min(255,round(c[i]+intensity*[85,45,150][i])) for i in range(3))+(c[3],))
 glint_atlas.paste(enchanted,((frame%4)*apple.width,(frame//4)*apple.height))
b=io.BytesIO();glint_atlas.save(b,format='PNG')
manifest['enchanted_apple_animation']=save('animations/enchanted_golden_apple.png',b.getvalue(),
 'minecraft-original:1.21.1:golden_apple+enchanted_glint_item',apple_raw,'pinned-wukong-12-frame-glint',glint_sha256=digest(glint_raw))
manifest['stamina_bar']={key:retain('textures/gui/sprites/hud/experience_bar_'+key+'.png') for key in ('background','progress')}
# Pinned ExtractMinecraftItems.totem_activation: the original generated model,
# 120 FIXED-view rotation frames. A single atlas avoids imports during activation.
from mc_generated_geometry import generated_mesh
apple_mesh,_=generated_mesh(apple,'1.21.1')
data=bytearray(b'PBZGLNT1'+struct.pack('<II',len(apple_mesh['positions']),12))
def linear(v):return v/12.92 if v<=.04045 else ((v+.055)/1.055)**2.4
for frame in range(12):
 for uv,c in zip(apple_mesh['uv'],apple_mesh['colors']):
  x,y=int(uv[0]*32),int(uv[1]*32)
  intensity=glint_image.getpixel(((x*3+y+frame*7)%glint_image.width,(y*3-x+frame*3)%glint_image.height))[0]/255
  data.extend(struct.pack('<4f',*[linear(min(1,c[i]+intensity*[.333,.176,.588][i])) for i in range(3)],c[3]))
effects_root=ROOT/'assets/private/effects';effects_root.mkdir(parents=True,exist_ok=True)
(effects_root/'enchanted_apple_glint.bin').write_bytes(data)
(effects_root/'enchanted_apple_glint.json').write_text(json.dumps(dict(sha256=digest(data),vertices=len(apple_mesh['positions']),frames=12,
 texture_sha256=digest(apple_raw),glint_sha256=digest(glint_raw),recipe='pinned-MinecraftGlint.cs'),indent=2),encoding='utf-8')
resource='assets/minecraft/textures/item/totem_of_undying.png';original=pack.read(resource,{})
mesh,_=generated_mesh(Image.open(io.BytesIO(original)),'1.21.1')
atlas=Image.new('RGBA',(256*15,256*8))
for frame in range(120):
 f=frame/120;k=(10.25*f**5-24.95*f**4+25.5*f**3-13.8*f*f+4*f)*math.pi
 angles=[6*math.cos(f*8),900*abs(math.sin(k)),6*math.cos(f*8)]
 def rotate(p):
  x,y,z=-p[0]/16,-p[1]/16,-p[2]/16
  for axis in (2,0,1):
   c,s=math.cos(math.radians(angles[axis])),math.sin(math.radians(angles[axis]))
   if axis==2:x,y=x*c-y*s,x*s+y*c
   elif axis==0:y,z=y*c-z*s,y*s+z*c
   else:x,z=x*c+z*s,-x*s+z*c
  return x,y,z
 vertices=[rotate(p) for p in mesh['positions']]
 im=Image.new('RGBA',(256,256));draw=ImageDraw.Draw(im)
 faces=sorted(range(0,len(vertices),4),key=lambda i:sum(vertices[j][2] for j in range(i,i+4)))
 for i in faces:
  draw.polygon([(128+vertices[j][0]*224,128-vertices[j][1]*224) for j in range(i,i+4)],fill=tuple(round(v*255) for v in mesh['colors'][i]))
 atlas.paste(im,((frame%15)*256,(frame//15)*256))
b=io.BytesIO();atlas.save(b,format='PNG')
path=save('animations/totem_activation.png',b.getvalue(),'minecraft-original:1.21.1:'+resource,original,
 'original-generated-model-fixed-view-120-frames',frames=120,columns=15,frame_size=256,
 recipe='wukong-steve:9f213556519dca4498fd46f02af6236ae121ecae:ExtractMinecraftItems.totem_activation')
manifest['totem_activation']={'path':path,'columns':15,'rows':8,'frames':120}
manifest['outputs']=list(outputs.values());(OUTPUT/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')
effects_root=ROOT/'assets/private/effects';atlas=Image.new('RGBA',(64,16));sources=[]
for row,kind in enumerate(['effect','glitter']):
 for col,index in enumerate(range(7,-1,-1)):
  resource=f'assets/minecraft/textures/particle/{kind}_{index}.png';raw=pack.read(resource,{})
  im=Image.open(io.BytesIO(raw)).convert('RGBA');assert im.size==(8,8)
  atlas.paste(im,(col*8,row*8));sources.append(dict(resource=resource,sha256=digest(raw),rect=[col*8,row*8,8,8]))
b=io.BytesIO();atlas.save(b,format='PNG');raw=b.getvalue();(effects_root/'status_particles.png').write_bytes(raw)
(effects_root/'status_particles.json').write_text(json.dumps(dict(schema=1,source_version='1.21.1',width=64,height=16,sha256=digest(raw),sources=sources),indent=2),encoding='utf-8')
modelpath=ROOT/'assets/private/item-models/manifest.json';models=json.loads(modelpath.read_text(encoding='utf-8'))
models['items']['pbzmc:enchanted_golden_apple']=copy.deepcopy(models['items']['pbzmc:golden_apple'])
models['items']['pbzmc:enchanted_golden_apple'].update(resource='minecraft:enchanted_golden_apple',enchantment_glint=True)
modelpath.write_text(json.dumps(models,ensure_ascii=False,indent=2),encoding='utf-8')
pack.archive.close();print('Original status icons, labels, glyphs and 16 particle frames prepared.')
