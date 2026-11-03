"""Build local runtime resources from pinned upstream downloads.

The source repository and release archive contain conversion code and hashes,
not Minecraft textures, sounds, fonts or client binaries. Run once per release.
"""
from __future__ import annotations
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import zipfile
from resource_download import fetch

SOURCE=Path(__file__).resolve().parents[1]
RECIPE=SOURCE/'distribution/asset-recipes'
def load(p):return json.loads(p.read_text('utf-8-sig'))
def write(p,d):
    p.parent.mkdir(parents=True,exist_ok=True)
    p.write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n','utf-8')
def digest(p,algorithm='sha256'):
    h=hashlib.new(algorithm)
    with p.open('rb') as f:
        for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
    return h.hexdigest()
def inputs(work,cache,local_cache=None):
    lock=load(RECIPE/'sources.lock.json')
    for version,spec in lock['versions'].items():
        print(f'Indexing verified Minecraft {version} resource archive...',flush=True)
        jar=work/'inputs'/f'{version}.jar'
        cached=cache/f'{version}.jar'
        if not cached.exists() and local_cache and (local_cache/f'{version}.jar').is_file():
            shutil.copy2(local_cache/f'{version}.jar',cached)
        fetch(spec['client']['url'],cached,spec['sha256'])
        jar.parent.mkdir(parents=True,exist_ok=True)
        if not jar.exists() or digest(jar)!=spec['sha256']:shutil.copy2(cached,jar)
        assert digest(jar)==spec['sha256']
        write(jar.with_suffix('.json'),{'assetIndex':spec['assetIndex']})
        index=work/'inputs/assets/indexes'/f'{version}-{spec["assetIndex"]["id"]}.json'
        fetch(spec['assetIndex']['url'],index,spec['assetIndex']['sha1'],'sha1')
        shutil.copy2(index,index.with_name(spec['assetIndex']['id']+'.json'))
        root=work/'assets/private/minecraft-original'/version
        root.mkdir(parents=True,exist_ok=True)
        entries=[]
        with zipfile.ZipFile(jar) as z:
            for name in z.namelist():
                if not name.startswith(('assets/minecraft/','data/minecraft/')) or name.endswith('/'):continue
                if '..' in Path(name).parts:raise ValueError('Unsafe resource path')
                # Converters read the verified archive directly. Avoid creating
                # tens of thousands of unused files on the first launch.
                raw=z.read(name)
                entries.append(dict(path=name,archive_entry=name,sha256=hashlib.sha256(raw).hexdigest(),bytes=len(raw)))
        write(root/'IMPORT_MANIFEST.json',dict(schema=1,version=version,source_archive=str(jar),
              archive_sha256=spec['sha256'],files=entries))

    def one(row):
        sha=row['hash'];target=work/'inputs/assets/objects'/sha[:2]/sha
        if not target.exists() and local_cache:
            local=local_cache/'assets/objects'/sha[:2]/sha
            if local.is_file():target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(local,target)
        fetch('https://resources.download.minecraft.net/'+sha[:2]+'/'+sha,target,sha,'sha1')
        return row,target
    print('Preparing indexed sounds, font and catalogue resources...',flush=True)
    with ThreadPoolExecutor(max_workers=6) as pool:
        for row,path in pool.map(one,lock['objects'].values()):
            if row['name'] not in lock['versions'][row['version']]['external_names']:continue
            root=work/'assets/private/minecraft-original'/row['version'];rel='indexed-assets/'+row['name']
            dest=root/rel;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(path,dest)
            manifest=load(root/'IMPORT_MANIFEST.json')
            manifest['files'].append(dict(path=rel,bytes=path.stat().st_size,sha256=digest(path),
                asset_index_key=row['name'],asset_sha1=row['hash'],resource_path='assets/'+row['name']))
            write(root/'IMPORT_MANIFEST.json',manifest)
    for rel,spec in lock['bedrock'].items():
        fetch(spec['url'],work/'assets/private/bedrock-catalogue/ui'/rel,spec['sha256'])
    shutil.copy2(RECIPE/'bedrock-manifest.json',work/'assets/private/bedrock-catalogue/ui/bedrock_catalogue/manifest.json')
    for name,spec in lock.get('extra',{}).items():fetch(spec['url'],work/'inputs'/name,spec['sha256'])

def complete_ui(work):
    """Reproduce retained crops and individual glyphs, including late UI labels."""
    import io
    from PIL import Image
    ui=work/'assets/private/minecraft-1.21.1/ui'
    manifest=load(RECIPE/'manifests/ui/manifest.json')
    font=zipfile.ZipFile(ui/'original/font/unifont.zip')
    bits={}
    for name in font.namelist():
        if name.endswith('.hex'):
            for line in font.read(name).decode('ascii').splitlines():
                code,data=line.split(':',1);bits[int(code,16)]=bytes.fromhex(data)
    archives={v:zipfile.ZipFile(work/'inputs'/f'{v}.jar')for v in ('1.21.1','26.3')}
    for row in manifest['outputs']:
        dest=ui/row['path']
        if dest.exists() and digest(dest)==row['sha256']:continue
        source=row.get('source','');operation=row.get('operation')
        raw=None
        if source.startswith('minecraft-original:'):
            _,version,entry=source.split(':',2)
            if entry in archives[version].namelist():raw=archives[version].read(entry)
        elif source.startswith('client:'):raw=archives['1.21.1'].read(source[7:])
        if row['path']=='original/lang/zh_cn.json':raw=(work/'inputs/ui-legacy-lang.json').read_bytes()
        if operation=='decode-original-unihex-bits':
            point=int(Path(row['path']).stem,16);packed=bits[point];width=len(packed)//2
            bitmap=Image.frombytes('1',(width,16),packed)
            image=Image.new('RGBA',(width,16),(255,255,255,0));image.putalpha(bitmap.convert('L'))
            image=image.crop(tuple(row['crop']));stream=io.BytesIO();image.save(stream,format='PNG');raw=stream.getvalue()
        elif raw is not None and operation=='lossless-crop':
            image=Image.open(io.BytesIO(raw)).convert('RGBA').crop(tuple(row['crop']));stream=io.BytesIO();image.save(stream,format='PNG');raw=stream.getvalue()
        if raw is not None and hashlib.sha256(raw).hexdigest()==row['sha256']:
            dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(raw)
    for archive in archives.values():archive.close()
    font.close()

STEPS=[
 ('extract_local_assets',['--client','{jar}']),
 ('extract_item_ui_assets',['--client','{jar}','--assets','{assets}']),
 ('extend_original_item_icons',[]),('extend_original_item_labels',[]),
 ('convert_original_item_models',[]),('convert_original_shield',[]),
 ('convert_arrow_projectile',[]),('convert_original_dirt',[]),
 ('extend_item_ui_feedback',[]),('extend_camera_ui',[]),('extend_item_ui_status',[]),
 ('convert_dirt_sounds',[]),('convert_critical_particle',[]),('prepare_status_assets',[]),
 ('prepare_pearl_assets',[]),('convert_original_boat',[]),('convert_original_tnt',[]),
 ('convert_tnt_item',[]),('convert_tnt_sounds',[]),('build_unicode_font_atlas',[]),
 ('convert_chorus_item',[]),('convert_original_armor',[]),('convert_building_blocks',[]),
 ('collect_building_sounds',[]),('convert_mechanism_blocks',[]),
 ('integrate_mechanism_resources',[]),('convert_mechanism_cracks',[]),
 ('convert_elytra_firework_resources',[]),('integrate_elytra_firework_resources',['--apply']),
 ('integrate_trash_slot',[]),
]

def build(work,ffmpeg,resume):
    for name in ('tools','src/content','third_party/wukong-steve','native/json_bridge','recipes','conversion-reports'):
        (work/name).mkdir(parents=True,exist_ok=True)
    for p in (SOURCE/'tools/assets').glob('*.py'):shutil.copy2(p,work/'tools'/p.name)
    shutil.copytree(SOURCE/'src/content',work/'src/content',dirs_exist_ok=True)
    shutil.copytree(SOURCE/'third_party/wukong-steve',work/'third_party/wukong-steve',dirs_exist_ok=True)
    for p in RECIPE.glob('*.json'):shutil.copy2(p,work/'recipes'/p.name)
    shutil.copy2(SOURCE/'native/json_bridge/block_audio_catalogue.hpp',work/'native/json_bridge/block_audio_catalogue.hpp')
    (work/'inputs/ffmpeg').mkdir(parents=True,exist_ok=True)
    for name in ('ffmpeg.exe','ffprobe.exe'):
        target=work/'inputs/ffmpeg'/name
        if not target.exists() or digest(target)!=digest(ffmpeg/name):shutil.copy2(ffmpeg/name,target)
    env={**os.environ,'PBZMC_ASSET_WORK':str(work),'PYTHONUTF8':'1'}
    fingerprint=hashlib.sha256()
    roots=('tools/assets','src/content','distribution/asset-recipes','third_party/wukong-steve')
    sources=[Path(__file__).resolve(),SOURCE/'native/json_bridge/block_audio_catalogue.hpp']
    sources+=sorted(p for name in roots for p in (SOURCE/name).rglob('*')
                    if p.is_file() and '__pycache__' not in p.parts and p.suffix!='.pyc')
    for source in sources:
        fingerprint.update(source.relative_to(SOURCE).as_posix().encode())
        fingerprint.update(digest(source).encode())
    fingerprint.update(digest(ffmpeg/'ffmpeg.exe').encode())
    recipe=fingerprint.hexdigest()
    receipt=work/'completed-steps.json';previous=load(receipt) if resume and receipt.exists() else {}
    completed=previous.get('steps',[]) if isinstance(previous,dict) and previous.get('recipe')==recipe else []
    values={'jar':str(work/'inputs/1.21.1.jar'),'assets':str(work/'inputs/assets')}
    for i,(name,args) in enumerate(STEPS,1):
        if name in completed:continue
        print(f'[{i}/{len(STEPS)}] {name}',flush=True)
        with (work/(name+'.log')).open('w',encoding='utf8') as log:
            runner="import sys,runpy;from pathlib import Path;p=sys.argv.pop(1);sys.path.insert(0,str(Path(p).parent));sys.argv[0]=p;runpy.run_path(p,run_name='__main__')"
            result=subprocess.run([sys.executable,'-c',runner,str(work/'tools'/(name+'.py')),*[a.format(**values) for a in args]],env=env,stdout=log,stderr=subprocess.STDOUT)
        if result.returncode:
            print((work/(name+'.log')).read_text('utf8')[-5000:],flush=True)
            raise RuntimeError('Conversion failed: '+name)
        completed.append(name);write(receipt,{'recipe':recipe,'steps':completed})

def assemble(work,output,release):
    """Select only runtime files. Match all resource bytes against the baseline."""
    expected=load(RECIPE/'runtime-files.json')
    private=work/'assets/private'
    missing=[];different=[]
    output.mkdir(parents=True,exist_ok=True)
    for relative,record in expected.items():
        dest=output/relative;dest.parent.mkdir(parents=True,exist_ok=True)
        if 'template' in record:
            source=RECIPE/'manifests'/record['template']
            if digest(source)!=record['sha256']:raise RuntimeError('Metadata recipe checksum mismatch: '+relative)
            shutil.copy2(source,dest);continue
        prefix,*parts=relative.split('/')
        if prefix=='ui':
            sources=[private/'minecraft-1.21.1'/relative,private/'bedrock-catalogue'/relative]
        elif prefix=='sounds':
            sources=[private/folder/relative for folder in ('minecraft-1.21.1','tnt','building-blocks','mechanism-blocks','elytra-firework')]
        elif len(parts)==0:sources=[private/'minecraft-1.21.1'/relative]
        else:sources=[private/relative]
        source=next((p for p in sources if p.is_file() and digest(p)==record['sha256']),None)
        if source:shutil.copy2(source,dest)
        elif any(p.is_file() for p in sources):different.append(relative)
        else:missing.append(relative)
    write(work/'runtime-comparison.json',{'missing':missing,'different':different})
    if missing or different:
        raise RuntimeError(f'Runtime resource verification: {len(missing)} missing, {len(different)} different; see runtime-comparison.json')
    files=[dict(path=rel,sha256=digest(output/rel))for rel in expected]
    write(output/'ready.json',dict(schema=1,release=release,recipe=digest(RECIPE/'runtime-files.json'),files=files))
    print(f'Runtime resources verified: {len(files)} files',flush=True)

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--work',type=Path,required=True)
    ap.add_argument('--cache',type=Path,required=True)
    ap.add_argument('--ffmpeg-bin',type=Path,required=True)
    ap.add_argument('--local-cache',type=Path)
    ap.add_argument('--resume',action='store_true')
    ap.add_argument('--skip-inputs',action='store_true')
    ap.add_argument('--output',type=Path)
    ap.add_argument('--release',default='0.1.0-alpha.4')
    args=ap.parse_args();work=args.work.resolve();cache=args.cache.resolve()
    work.mkdir(parents=True,exist_ok=True);cache.mkdir(parents=True,exist_ok=True)
    if not args.skip_inputs:inputs(work,cache,args.local_cache)
    build(work,args.ffmpeg_bin.resolve(),args.resume)
    if args.output:
        for name,spec in load(RECIPE/'sources.lock.json').get('extra',{}).items():fetch(spec['url'],work/'inputs'/name,spec['sha256'])
        complete_ui(work)
        assemble(work,args.output.resolve(),args.release)
    print('Conversion stages complete.',flush=True)
if __name__=='__main__':main()
