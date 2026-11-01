"""Original destruction PNGs and exact pixel masks for one bounded overlay.

MC crumbling multiplies the destination color. PBZ's cooked masked sprite
material does not, so the host clips its original colored quads to these
original 16x16 pixels and uses the retained MC blend equation explicitly.
"""
from pathlib import Path
import io
import json

from PIL import Image
from extend_original_item_icons import OriginalPack, ROOT, digest

OUT = ROOT / 'assets/private/mechanism-cracks'


def main():
    pack = OriginalPack('1.21.1')
    (OUT / 'textures').mkdir(parents=True, exist_ok=True)
    (OUT / 'samples').mkdir(parents=True, exist_ok=True)
    stages = []
    try:
        for stage in range(10):
            source = f'assets/minecraft/textures/block/destroy_stage_{stage}.png'
            raw = pack.read(source, {})
            picture = Image.open(io.BytesIO(raw)).convert('RGBA')
            assert picture.size == (16, 16), 'unexpected original destruction dimensions'
            alpha = sorted(set(picture.getchannel('A').tobytes()))
            # Vanilla's white background is alpha1, not0. Keep the PNG bytes;
            # crumbling.fsh discards it before the RGB blend operation.
            assert alpha[0] <= 1 and alpha[-1] == 255, 'original crack transparency required'
            pixels = list(picture.get_flattened_data())
            assert all(r == g == b for r, g, b, a in pixels)
            samples = bytes(r if a >= 26 else 0 for r, g, b, a in pixels)
            assert set(samples) <= {0, 61, 155}
            sample_path = f'samples/destroy_stage_{stage}.gray8'
            (OUT / sample_path).write_bytes(samples)
            output = f'textures/destroy_stage_{stage}.png'
            (OUT / output).write_bytes(raw)
            stages.append(dict(stage=stage, path=output, bytes=len(raw), sha256=digest(raw),
                               size=[16, 16], original_alpha_values=alpha, source=source,
                               source_sha256=digest(raw), operation='byte-copy',
                               samples=dict(path=sample_path, bytes=len(samples), sha256=digest(samples),
                                            format='gray8-row-major-alpha-discard', values=[0, 61, 155],
                                            operation='source-gray-if-alpha>=26-else-zero')))
        references = []
        manifest = dict(schema=1, private_local_assets=True, minecraft_version=pack.version,
                        namespace='minecraft', source_archive=pack.manifest['source_archive'],
                        archive_sha256=pack.manifest['archive_sha256'],
                        stages=stages,
                        outputs=[{k:r[k] for k in ('path','bytes','sha256')} for stage in stages
                                 for r in (stage,stage['samples'])],
                        references=[dict(path=p.relative_to(ROOT).as_posix(), sha256=digest(p.read_bytes())) for p in references],
                        recipe_sha256=digest(Path(__file__).read_bytes()),
                        render_contract=dict(material='/Engine/EngineMaterials/DefaultTextMaterialOpaque.DefaultTextMaterialOpaque',
                                             uv_white=[433.5/512, 139.5/256],
                                             projection='Original OverlayVertexConsumer dominant facing, 16x16 pixels per100cm, periodic',
                                             rgb='round(clamp(2 * original_srgb8 * crack_gray8 / 255,0,255)); convert to linear once',
                                             alpha_discard_below=.1, original_png_unchanged=True,
                                             pixel_sampling='clip source-color quads at original pixel boundaries; no texture filtering',
                                             max_active_overlays=1, max_stage_cache=3, native_texture_imports=0,
                                             stage_change='upload cached pixel geometry; source clipping only when target model changes',
                                             transparent_limit='Only opaque mechanisms use this overlay. Instant-break slime/honey do not.'))
        (OUT / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    finally:
        pack.archive.close()
    print(json.dumps(dict(stages=len(stages), bytes=sum(x['bytes'] for x in stages),
                          pixel_changes=False, sampled_bytes=2560, generated_state_meshes=0), ensure_ascii=False))


if __name__ == '__main__':
    main()
