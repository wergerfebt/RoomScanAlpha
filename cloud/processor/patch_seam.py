#!/usr/bin/env python3
"""Patch OpenMVS SceneTexture.cpp to fix seam leveling crash.

The crash: vertpatch2row.at(idxPatch) throws std::out_of_range when a face
has no assigned texture patch. Fix: guard with .count() checks.
"""
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    src = f.read()

original = src

# Patch 1: line ~1473 — guard vertpatch2row.at(idxPatch0)
old1 = 'const MatIdx col0(vertpatch2row.at(idxPatch0));'
new1 = 'if (vertpatch2row.count(idxPatch0) == 0) continue;\n\t\t\tconst MatIdx col0(vertpatch2row.at(idxPatch0));'
src = src.replace(old1, new1)

# Patch 2: line ~1477 — guard vertpatch2row.at(idxPatch1)
old2 = 'const MatIdx col1(vertpatch2row.at(idxPatch1));'
new2 = 'if (vertpatch2row.count(idxPatch1) == 0) continue;\n\t\t\t\tconst MatIdx col1(vertpatch2row.at(idxPatch1));'
src = src.replace(old2, new2)

# Patch 3: line ~1553 — guard vertpatch2rows[face[v]].at(idxPatch)
old3 = 'data.colors[v] = colorAdjustments.row(vertpatch2rows[face[v]].at(idxPatch));'
new3 = '{ const auto& vp2r = vertpatch2rows[face[v]]; if (vp2r.count(idxPatch)) data.colors[v] = colorAdjustments.row(vp2r.at(idxPatch)); else data.colors[v] = Color::ZERO; }'
src = src.replace(old3, new3)

if src == original:
    print("WARNING: No patches applied — source may have changed")
    sys.exit(1)

with open(path, 'w') as f:
    f.write(src)

patches = 3 - [old1 in original, old2 in original, old3 in original].count(False)
print(f"Patched {patches}/3 crash sites in {path}")
