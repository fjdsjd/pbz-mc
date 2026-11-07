"""Compile pinned vanilla Bedrock client animations, controllers and Molang.

The runtime consumes validated expression trees, never executes downloaded code.
"""
import json
from hashlib import sha256
from asset_paths import ROOT
from molang_compile import parse,read_json

# These retained native wolf channels precede relative animation offsets:
# their absolute model Y is measured from 24, as in AdultWolfModel's PartPose.
# Keep original expressions intact; record the coordinate convention only.
LEGACY_POSITION_CHANNELS={
    'animation.wolf.setup': {'body','leg0','leg1','leg2','leg3','tail','upperbody'},
    'animation.wolf.sitting': {'body','leg0','leg1','leg2','leg3','tail','upperbody'},
    'animation.wolf.baby_sitting': {'upperbody'},
}

def render(root=ROOT):
    index=json.loads((root/'src/content/mob_visual_reference.json').read_bytes())
    source=root/'inputs/undead';expressions=[];ids={};animations={};controllers={};entities={}
    def expr(value):
        if isinstance(value,(int,float,bool)):return value
        if value not in ids:
            ids[value]=len(expressions)+1
            try:expressions.append(parse(value))
            except Exception as e:raise ValueError('Molang: '+value)from e
        return {'e':ids[value]}
    def scripts(values):return expr(' '.join(values)) if values else 0
    def weighted(rows):return [v if isinstance(v,str)else {k:expr(x)for k,x in v.items()}for v in rows]
    def channel(value):
        if isinstance(value,list)and any(isinstance(v,dict)for v in value):
            return {'ordered':[[k,expr(x)]for row in value for k,x in row.items()]}
        if isinstance(value,list):return [expr(v)for v in value]
        if isinstance(value,dict):
            if 'pre'in value or 'post'in value:
                return {k:channel(v)if k in ('pre','post')else v for k,v in value.items()}
            return {k:channel(v)for k,v in value.items()}
        return expr(value)
    documents=[];raw_animations={};raw_controllers={};raw_renderers={}
    for relative,record in index['files'].items():
        raw=(source/relative).read_bytes();assert sha256(raw).hexdigest()==record['sha256'],relative
        data=read_json(raw)
        documents.append(data);raw_animations.update(data.get('animations',{}));raw_controllers.update(data.get('animation_controllers',{}))
        raw_renderers.update(data.get('render_controllers',{}))
    needed=set()
    for name,row in index['mobs'].items():
        data=read_json((source/row['client']).read_bytes())['minecraft:client_entity']['description']
        aliases=dict(data.get('animations',{}));script=data.get('scripts',{})
        run=weighted(script.get('animate',[]))
        for entry in data.get('animation_controllers',[]):
            for k,v in entry.items():run.append(v)
        entities[name]={'aliases':aliases,'run':run,'initialize':scripts(script.get('initialize',[])),
                        'pre':scripts(script.get('pre_animation',[]))}
        entities[name]['scale']=[expr(script.get('scale'+axis,script.get('scale',1)))for axis in ('X','Y','Z')]
        visibility=[]
        for entry in data.get('render_controllers',[]):
            for key,condition in ({entry:1}if isinstance(entry,str)else entry).items():
                renderer=raw_renderers.get(key,{})
                geometry=renderer.get('geometry','').lower()
                # Visibility belongs to the matching body geometry. Separate
                # glowing/armor layers must not hide the base body's bones.
                if geometry=='geometry.default' or geometry.startswith('array.'):
                    for rule in renderer.get('part_visibility',[]):
                        for part,value in rule.items():visibility.append([part.lower(),expr(value),expr(condition)])
        entities[name]['visibility']=visibility
        seen=set()
        def follow(key):
            key=aliases.get(key,key)
            if key in seen:return
            seen.add(key);needed.add(key)
            if key in raw_controllers:
                for state in raw_controllers[key]['states'].values():
                    for entry in state.get('animations',[]):
                        for child in ([entry]if isinstance(entry,str)else entry):follow(child)
            else:assert key in raw_animations,'missing animation '+name+':'+key
        for row in run:
            for key in ([row]if isinstance(row,str)else row):follow(key)
    for data in documents:
        for key,value in data.get('animations',{}).items():
            if key not in needed:continue
            a={k:v for k,v in value.items()if k in ('animation_length','loop','override_previous_animation')}
            for k in ('anim_time_update','blend_weight','start_delay','loop_delay'):
                if k in value:a[k]=expr(value[k])
            a['bones']={name.lower():{k:channel(v)for k,v in bone.items()if k in ('rotation','position','scale')}
                        for name,bone in value.get('bones',{}).items()}
            for name,bone in value.get('bones',{}).items():
                if bone.get('relative_to',{}).get('rotation')=='entity':a['bones'][name.lower()]['entity_rotation']=True
                if name.lower() in LEGACY_POSITION_CHANNELS.get(key,set()):
                    a['bones'][name.lower()]['position_origin']=[0,24,0]
            animations[key]=a
        for key,value in data.get('animation_controllers',{}).items():
            if key not in needed:continue
            c={'initial_state':value.get('initial_state','default'),'states':{}}
            for name,state in value['states'].items():
                out={k:v for k,v in state.items()if k in ('blend_transition','blend_via_shortest_path')}
                for k in ('animations','transitions'):out[k]=weighted(state.get(k,[]))
                for k in ('on_entry','on_exit'):out[k]=scripts([s for s in state.get(k,[])if not s.startswith(('/', '@'))])
                out['variables']={k:{**v,'input':expr(v.get('input',0))}if isinstance(v,dict)else expr(v)
                                  for k,v in state.get('variables',{}).items()}
                c['states'][name]=out
            controllers[key]=c
    output=root/'assets/private/undead/animations.json';output.parent.mkdir(parents=True,exist_ok=True)
    output.write_text(json.dumps(dict(schema=1,source_commit=index['source_commit'],expressions=expressions,
        animations=animations,controllers=controllers,entities=entities),separators=(',',':'))+'\n',encoding='utf8')
    print('Vanilla animation expressions:',len(expressions),'animations:',len(animations),'controllers:',len(controllers))

if __name__=='__main__':render()
