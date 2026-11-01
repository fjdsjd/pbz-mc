"""Versioned MC generated-item geometry, without display/holder transforms.

See docs/MC_ITEM_TRANSFORMS_REFERENCE.md. Static hard-alpha layer0 only.
Per-texel subdivision preserves the original colors and silhouette; MC atlas
filtering, UV shrink, lighting and animation are separate renderer concerns.
"""
from __future__ import annotations
import struct


def generated_mesh(texture, version):
    if version not in ('1.21.1', '26.3'):
        raise ValueError('unsupported generated-item version')
    texture = texture.convert('RGBA')
    width, height = texture.size
    if not 0 < width <= 256 or not 0 < height <= 256:
        raise ValueError('unexpected texture dimensions')
    if any(a not in (0, 255) for a in texture.getchannel('A').getdata()):
        raise ValueError('soft alpha requires a different material')
    sx, sy = 16 / width, 16 / height
    mesh = {key: [] for key in ('positions', 'normals', 'uv', 'colors', 'triangles')}
    stats = {'opaque_texels': 0, 'front_back_quads': 0, 'side_quads': 0}

    def opaque(x, y):
        return 0 <= x < width and 0 <= y < height and texture.getpixel((x, y))[3] != 0

    def quad(points, normal, x, y, side=False):
        # Center MC then use recipe(x,-y,-z). Existing mesh_bundle.lua maps
        # recipe to UE(-z,-x,-y), giving UE(MCz,-MCx,MCy).
        points = [(px-8, -(py-8), -(pz-8)) for px, py, pz in points]
        normal = (normal[0], -normal[1], -normal[2])
        a = [points[1][j]-points[0][j] for j in range(3)]
        b = [points[2][j]-points[0][j] for j in range(3)]
        cross = (a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0])
        forward = sum(c*n for c, n in zip(cross, normal)) > 0
        start = len(mesh['positions'])
        mesh['positions'].extend(points)
        mesh['normals'].extend([normal]*4)
        # Texel-center UV retained; runtime's verified vertex-color material
        # replaces it with its white texel, as for existing Steve/block meshes.
        mesh['uv'].extend([((x+.5)/width, (y+.5)/height)]*4)
        mesh['colors'].extend([tuple(c/255 for c in texture.getpixel((x, y)))]*4)
        order = (0,1,2,0,2,3) if forward else (0,2,1,0,3,2)
        mesh['triangles'].extend(start+i for i in order)
        stats['side_quads' if side else 'front_back_quads'] += 1

    edges = []
    for y in range(height):
        for x in range(width):
            if not opaque(x, y):
                continue
            stats['opaque_texels'] += 1
            left, right, top, bottom = x*sx, (x+1)*sx, 16-y*sy, 16-(y+1)*sy
            for z, normal in ((8.5,(0,0,1)), (7.5,(0,0,-1))):
                quad([(left,bottom,z),(right,bottom,z),(right,top,z),(left,top,z)], normal, x, y)
            for side, dx, dy in (('up',0,-1),('down',0,1),('left',-1,0),('right',1,0)):
                if not opaque(x+dx, y+dy):
                    edges.append((side,x,y))
    if version == '1.21.1':
        # Old client merges min..max even across disconnected spans. Keeping
        # only exposed per-pixel edges would silently change this geometry.
        spans = {}
        for side, x, y in edges:
            horizontal = side in ('up','down')
            key, index = (side, y if horizontal else x), x if horizontal else y
            lo, hi = spans.get(key, (index,index))
            spans[key] = min(lo,index), max(hi,index)
        edges = []
        for (side,anchor), (lo,hi) in sorted(spans.items()):
            for index in range(lo, hi+1):
                x, y = (index,anchor) if side in ('up','down') else (anchor,index)
                if opaque(x,y):
                    edges.append((side,x,y))
    for side, x, y in edges:
        left, right, top, bottom = x*sx, (x+1)*sx, 16-y*sy, 16-(y+1)*sy
        if side in ('up','down'):
            h = top if side == 'up' else bottom
            points = [(left,h,7.5),(right,h,7.5),(right,h,8.5),(left,h,8.5)]
            normal = (0, 1 if side == 'up' else -1, 0)
        else:
            h = left if side == 'left' else right
            points = [(h,bottom,7.5),(h,top,7.5),(h,top,8.5),(h,bottom,8.5)]
            normal = (-1 if side == 'left' else 1, 0, 0)
        quad(points, normal, x, y, True)
    if not mesh['positions']:
        raise ValueError('empty generated item')
    if len(mesh['positions']) > 100000:
        raise ValueError('mesh exceeds runtime vertex limit')
    return mesh, stats


def mesh_bytes(mesh):
    """Established STEVEM01 format: one untransformed, zero-pivot item part."""
    raw = bytearray(b'STEVEM01')
    raw.extend(struct.pack('<II', 1, 4))
    raw.extend(b'item')
    raw.extend(struct.pack('<3fII', 0,0,0,len(mesh['positions']),len(mesh['triangles'])))
    for p,n,uv,color in zip(mesh['positions'],mesh['normals'],mesh['uv'],mesh['colors']):
        raw.extend(struct.pack('<12f', *(tuple(p)+tuple(n)+tuple(uv)+tuple(color))))
    raw.extend(struct.pack('<'+'I'*len(mesh['triangles']), *mesh['triangles']))
    return bytes(raw)
