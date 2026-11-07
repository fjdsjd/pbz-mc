"""Extract numeric potion registry data from the private, pinned 26.3 reference.

Decompiled classes are input only; neither Java nor Mojang assets are published.
"""
import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
REF = ROOT / 'research/private/potions/26.3/decompiled/net/minecraft'
JAR = ROOT / 'build/command-check/clean-enhanced/inputs/26.3.jar'


def lua(v):
    if isinstance(v, dict):
        return '{' + ','.join('[' + lua(k) + ']=' + lua(x) for k, x in v.items()) + '}'
    if isinstance(v, list):
        return '{' + ','.join(lua(x) for x in v) + '}'
    return json.dumps(v, ensure_ascii=False)


def main():
    lang_path = ROOT/'build/command-check/clean-enhanced/assets/private/minecraft-original/26.3/indexed-assets/minecraft/lang/zh_cn.json'
    lang = json.loads(lang_path.read_text(encoding='utf8'))
    raw = (REF / 'world/item/alchemy/Potions.java').read_text()
    effects_raw = (REF / 'world/effect/MobEffects.java').read_text()
    effects = {}
    for name, body in re.findall(r'Holder<MobEffect> (\w+) = register\((.*?)(?=;\s*\n)', effects_raw, re.S):
        color = re.search(r'MobEffectCategory\.\w+, (\d+)', body)
        if color:
            id = name.lower()
            effects[id] = dict(name=lang['effect.minecraft.'+id], color=int(color[1]))
    potions = {}
    for name, body in re.findall(r'Holder<Potion> (\w+) = register\((.*?)(?=;\s*\n)', raw, re.S):
        base = re.search(r'new Potion\("([^"]+)"', body)[1]
        values = []
        for effect, ticks, amp in re.findall(r'new MobEffectInstance\(MobEffects\.(\w+), (\d+)(?:, (\d+))?\)', body):
            values.append(dict(id=effect.lower(), ticks=int(ticks), amplifier=int(amp or 0)))
        # PotionContents#getColor weights the RGB components by amplifier + 1.
        total = sum(x['amplifier']+1 for x in values)
        rgb = [sum(((effects[x['id']]['color'] >> shift) & 255)*(x['amplifier']+1) for x in values)//total
               if total else (3694022 >> shift) & 255 for shift in (16, 8, 0)]
        names = {form: lang[f'item.minecraft.{form}.effect.{base}'] for form in ('potion','splash_potion','lingering_potion')}
        potions[name.lower()] = dict(effects=values, color=rgb[0]*65536+rgb[1]*256+rgb[2], names=names)
    result = dict(version='26.3', client_sha256=hashlib.sha256(JAR.read_bytes()).hexdigest(), effects=effects, potions=potions)
    (ROOT/'src/content/potion_reference.json').write_text(json.dumps(result, ensure_ascii=False, indent=2)+'\n', encoding='utf8')
    (ROOT/'src/content/potion_reference.lua').write_text('-- Generated numeric registry data; see tools/reference/potion_rules.py.\nreturn '+lua(result)+'\n', encoding='utf8')
    print(f'{len(potions)} potions; {len(effects)} effect definitions')


if __name__ == '__main__':
    main()
