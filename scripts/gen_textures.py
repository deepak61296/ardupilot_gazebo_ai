#!/usr/bin/env python3
"""Generate the PBR albedo textures for the vendored sim models (grass, worn grass, road).
Deterministic (seeded) and tileable by construction, so re-running gives the same pixels and
tiles never show seams. Paths resolve relative to this file. Run after editing, then
scripts/gen_field_world.py to rebuild the world that uses them."""
import os

import cv2
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
MODELS = os.path.join(HERE, "..", "skills", "ardupilot-gazebo", "models")


def tileable_noise(size, cells, rng):
    """Value noise on a wrapped lattice -> float32 [0,1], seamless when tiled."""
    lattice = rng.random((cells, cells)).astype(np.float32)
    u = np.linspace(0.0, cells, size, endpoint=False)
    i0 = np.floor(u).astype(int) % cells
    i1 = (i0 + 1) % cells
    f = (u - np.floor(u)).astype(np.float32)
    f = f * f * (3.0 - 2.0 * f)  # smoothstep
    a = lattice[np.ix_(i0, i0)]
    b = lattice[np.ix_(i0, i1)]
    c = lattice[np.ix_(i1, i0)]
    d = lattice[np.ix_(i1, i1)]
    fx = f[np.newaxis, :]
    fy = f[:, np.newaxis]
    return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy


def fbm(size, rng, octaves=((4, 0.5), (9, 0.25), (23, 0.15), (61, 0.10))):
    out = np.zeros((size, size), np.float32)
    for cells, weight in octaves:
        out += weight * tileable_noise(size, cells, rng)
    out -= out.min()
    out /= max(out.max(), 1e-6)
    return out


def grass(size, seed, wear):
    """Grass albedo. wear in [0,1] mixes in dry patches and bare dirt."""
    rng = np.random.default_rng(seed)
    tone = fbm(size, rng)                                   # broad colour variation
    dry = fbm(size, rng, ((3, 0.6), (7, 0.4)))              # dry-patch mask
    fine = tileable_noise(size, 173, rng)                   # blade-scale detail

    green = np.zeros((size, size, 3), np.float32)           # BGR
    green[..., 0] = 0.10 + 0.10 * tone
    green[..., 1] = 0.30 + 0.22 * tone
    green[..., 2] = 0.13 + 0.14 * tone

    dry_col = np.zeros_like(green)                          # yellowed grass
    dry_col[..., 0] = 0.16 + 0.08 * tone
    dry_col[..., 1] = 0.40 + 0.16 * tone
    dry_col[..., 2] = 0.38 + 0.18 * tone

    dirt_col = np.zeros_like(green)                         # bare earth
    dirt_col[..., 0] = 0.16 + 0.06 * tone
    dirt_col[..., 1] = 0.25 + 0.08 * tone
    dirt_col[..., 2] = 0.30 + 0.10 * tone

    dry_m = np.clip((dry - (0.72 - 0.35 * wear)) * 6.0, 0, 1)[..., None]
    dirt_m = np.clip((dry - (0.88 - 0.38 * wear)) * 8.0, 0, 1)[..., None]
    img = green * (1 - dry_m) + dry_col * dry_m
    img = img * (1 - dirt_m) + dirt_col * dirt_m
    img *= (0.82 + 0.36 * fine)[..., None]
    return (np.clip(img, 0, 1) * 255).astype(np.uint8)


def road(w, h, seed, length_m=15.0, width_m=7.0):
    """Asphalt segment, road axis along x. Dash period divides length_m so tiles join."""
    rng = np.random.default_rng(seed)
    tone = fbm(max(w, h), rng)[:h, :w]
    speck = np.clip(np.random.default_rng(seed + 1).normal(0, 0.02, (h, w)), -0.05, 0.05)
    g = np.clip(0.16 + 0.07 * tone + speck, 0, 1)
    img = np.dstack([g * 1.02, g, g * 0.98]).astype(np.float32)

    px_m_y = h / width_m
    for lane_c in (width_m * 0.27, width_m * 0.73):         # tyre-wear bands
        for off in (-0.45, 0.45):
            y = int((lane_c + off) * px_m_y)
            band = max(2, int(0.30 * px_m_y))
            img[max(0, y - band):y + band, :, :] *= 0.93

    line = np.array([0.80, 0.82, 0.84], np.float32)         # slightly worn white
    lw = max(3, int(0.13 * px_m_y))
    for edge_m in (0.45, width_m - 0.45):
        y = int(edge_m * px_m_y)
        img[y - lw // 2:y + lw // 2 + 1, :, :] = line
    dash_period = w // 3                                    # 5 m: 3 m dash + 2 m gap
    dash_len = int(dash_period * 0.6)
    yc = h // 2
    for x0 in range(0, w, dash_period):
        img[yc - lw // 2:yc + lw // 2 + 1, x0:x0 + dash_len, :] = line
    fade = 0.85 + 0.15 * tone[..., None]                    # weather the paint
    return (np.clip(img * fade, 0, 1) * 255).astype(np.uint8)


def far_field(size, seed):
    """Distant-terrain albedo for the 2000 m base plane (~1 m/px): farmland patches in
    varied tones with soft borders + tree-line speckle. Only seen beyond the detailed tiles."""
    rng = np.random.default_rng(seed)
    patch = tileable_noise(size, 14, rng)               # coarse parcel layout
    levels = np.floor(patch * 5.0) / 5.0                # quantise into parcels
    levels = cv2.GaussianBlur(levels, (0, 0), 3)        # soften parcel borders
    tone = fbm(size, rng)

    img = np.zeros((size, size, 3), np.float32)         # BGR, tones bracket the grass mean
    img[..., 0] = 0.10 + 0.10 * levels + 0.05 * tone
    img[..., 1] = 0.28 + 0.20 * levels + 0.08 * tone
    img[..., 2] = 0.12 + 0.26 * levels + 0.08 * tone    # high parcels read dry/harvested

    speck = tileable_noise(size, 401, rng)              # distant trees / hedgerows
    trees = (speck > 0.85).astype(np.float32)[..., None]
    img = img * (1 - trees * 0.4)
    return (np.clip(img, 0, 1) * 255).astype(np.uint8)


def write(rel, img):
    path = os.path.join(MODELS, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    cv2.imwrite(path, img)
    print(f"wrote {rel} {img.shape[1]}x{img.shape[0]}")


if __name__ == "__main__":
    write("grass_tile/materials/textures/grass.png", grass(1024, seed=11, wear=0.15))
    write("grass_tile_worn/materials/textures/grass_worn.png", grass(1024, seed=29, wear=0.8))
    write("road_tile/materials/textures/road.png", road(1024, 512, seed=7))
    write("far_field/materials/textures/far_field.png", far_field(2048, seed=41))
