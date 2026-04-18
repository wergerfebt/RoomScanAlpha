#!/usr/bin/env python3
"""
GS Pipeline: ALIKED + LightGlue + GLOMAP + FastGS
Runs on Vertex AI Workbench with L4 GPU.

Produces a Gaussian splat aligned to ARKit world frame (Y-up, meters)
so measurement overlays from the existing viewer pipeline work correctly.

Usage:
    python3 run_pipeline.py --scan_id SCAN_ID --room_id ROOM_ID
    python3 run_pipeline.py  # uses defaults
"""

import os, json, glob, time, shutil, sys, sqlite3, struct, argparse
import numpy as np
import h5py
from pathlib import Path
from scipy.spatial import KDTree
import pycolmap
from PIL import Image
import subprocess
from google.cloud import storage

# Add hloc to path
sys.path.insert(0, os.environ.get('HLOC_DIR', '/opt/Hierarchical-Localization'))

# ============================================================
# Config
# ============================================================
SCAN_ID = os.environ.get('SCAN_ID', 'b069da20-8f00-4d9b-9d13-6a7b82bc52ba')
ROOM_ID = os.environ.get('ROOM_ID', '66abbeb4-d916-4e04-b735-ae67bceb9066')
GCS_BUCKET = 'roomscanalpha-scans'
GCS_PREFIX_TEMPLATE = 'scans/{scan_id}/{room_id}'

SHARPNESS_CULL_PERCENT = 20
FRAME_STRIDE = 4
SEQ_WINDOW = 10
NUM_NEIGHBORS = 30
FASTGS_ITERATIONS = 30000

WORK_DIR = os.environ.get('WORK_DIR', '/tmp/gs-pipeline/work')
FASTGS_DIR = os.environ.get('FASTGS_DIR', '/opt/FastGS')


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument('--scan_id', default=SCAN_ID)
    parser.add_argument('--room_id', default=ROOM_ID)
    parser.add_argument('--stride', type=int, default=FRAME_STRIDE)
    parser.add_argument('--iterations', type=int, default=FASTGS_ITERATIONS)
    return parser.parse_args()


def step(t0, msg):
    elapsed = time.time() - t0
    print(f'[{elapsed:.0f}s] {msg}', flush=True)
    return elapsed


# ============================================================
# Umeyama alignment (similarity transform: scale + rotation + translation)
# ============================================================
def umeyama_alignment(src, dst):
    """Compute similarity transform s*R*src + t that maps src → dst.

    Args:
        src: (N, 3) source points (GLOMAP camera centers)
        dst: (N, 3) target points (ARKit camera centers)

    Returns:
        scale, R (3x3), t (3,) such that dst ≈ scale * R @ src + t
    """
    assert src.shape == dst.shape
    n, d = src.shape

    mu_src = src.mean(axis=0)
    mu_dst = dst.mean(axis=0)

    src_c = src - mu_src
    dst_c = dst - mu_dst

    var_src = np.sum(src_c ** 2) / n

    # Cross-covariance
    Sigma = dst_c.T @ src_c / n

    U, D, Vt = np.linalg.svd(Sigma)

    # Handle reflection
    S = np.eye(d)
    if np.linalg.det(U) * np.linalg.det(Vt) < 0:
        S[d - 1, d - 1] = -1

    R = U @ S @ Vt
    scale = np.trace(np.diag(D) @ S) / var_src if var_src > 1e-10 else 1.0
    t = mu_dst - scale * R @ mu_src

    return scale, R, t


# ============================================================
# Step 1: Pull from GCS + extract HEVC
# ============================================================
def pull_and_extract(scan_id, room_id, stride):
    import cv2
    t0 = time.time()

    prefix = GCS_PREFIX_TEMPLATE.format(scan_id=scan_id, room_id=room_id)
    scan_raw = f'{WORK_DIR}/scan_raw'
    os.makedirs(scan_raw, exist_ok=True)

    client = storage.Client()
    bucket = client.bucket(GCS_BUCKET)
    n = 0
    for blob in bucket.list_blobs(prefix=prefix + '/'):
        rel = blob.name[len(prefix) + 1:]
        if not rel or rel.endswith('/'):
            continue
        dest = os.path.join(scan_raw, rel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        blob.download_to_filename(dest)
        n += 1
    step(t0, f'GCS pull done ({n} files)')

    # Extract zips
    import zipfile
    for zf in glob.glob(f'{scan_raw}/*.zip'):
        with zipfile.ZipFile(zf) as z:
            z.extractall(scan_raw)

    # Find scan dir
    scan_dir = [d for d in glob.glob(f'{scan_raw}/scan_*')
                if os.path.isdir(d) and os.path.exists(os.path.join(d, 'scan_video.mov'))][0]

    # Extract HEVC frames
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    ve_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'video_extract.py')
    if not os.path.exists(ve_path):
        raise FileNotFoundError(f'video_extract.py not found at {ve_path} — copy it to ~/gs-pipeline/')
    from video_extract import extract_frames_from_hevc
    result = extract_frames_from_hevc(scan_dir)
    step(t0, f'Extracted {result["frame_count"]} frames')

    # Sharpness filter
    keyframes_dir = os.path.join(scan_dir, 'keyframes')
    jpg_files = sorted(glob.glob(f'{keyframes_dir}/*.jpg'))

    scores = [(f, cv2.Laplacian(cv2.imread(f, 0), cv2.CV_64F).var()) for f in jpg_files]
    threshold = np.percentile([s for _, s in scores], SHARPNESS_CULL_PERCENT)
    for f, s in scores:
        if s < threshold:
            os.remove(f)

    # Stride
    jpg_files = sorted(glob.glob(f'{keyframes_dir}/*.jpg'))
    for i, f in enumerate(jpg_files):
        if i % stride != 0:
            os.remove(f)

    remaining = sorted(glob.glob(f'{keyframes_dir}/*.jpg'))
    step(t0, f'{len(remaining)} frames after filter+stride')

    # Copy to dataset dir
    data_path = f'{FASTGS_DIR}/datasets/gs_scan_data'
    img_dir = f'{data_path}/images'
    shutil.rmtree(data_path, ignore_errors=True)
    os.makedirs(img_dir)
    for f in remaining:
        shutil.copy2(f, img_dir)

    step(t0, f'Copied {len(remaining)} images to {img_dir}')
    return scan_dir, data_path, img_dir


# ============================================================
# Step 2: SfM — ALIKED + LightGlue + GLOMAP + ARKit alignment
# ============================================================
def run_sfm(scan_dir, data_path, img_dir):
    from hloc import extract_features, match_features

    t0 = time.time()
    image_dir = Path(img_dir)
    export_dir = Path(f'{data_path}/hloc_exports')
    export_dir.mkdir(exist_ok=True)

    # --- Load ARKit poses + intrinsics ---
    poses = [json.loads(l) for l in open(os.path.join(scan_dir, 'poses.jsonl')) if l.strip()]
    image_names = set(os.listdir(img_dir))

    name_to_pos = {}       # ARKit camera positions (world frame)
    arkit_intrinsics = []
    for p in poses:
        name = f"frame_{p['i']:04d}.jpg"
        if name in image_names:
            name_to_pos[name] = np.array([p['tx'][12], p['tx'][13], p['tx'][14]])
            if 'fx' in p:
                arkit_intrinsics.append((p['fx'], p['fy'], p['cx'], p['cy']))

    names = sorted(name_to_pos.keys())
    positions = np.array([name_to_pos[n] for n in names])

    # --- Pairs: sequential + spatial ---
    pairs_set = set()
    for i in range(len(names)):
        for j in range(max(0, i - SEQ_WINDOW), min(len(names), i + SEQ_WINDOW + 1)):
            if i != j:
                a, b = min(names[i], names[j]), max(names[i], names[j])
                pairs_set.add((a, b))
    n_seq = len(pairs_set)

    tree = KDTree(positions)
    for i, name in enumerate(names):
        _, indices = tree.query(positions[i], k=NUM_NEIGHBORS + 1)
        for j in indices[1:]:
            a, b = min(name, names[int(j)]), max(name, names[int(j)])
            pairs_set.add((a, b))

    pairs_path = Path(f'{data_path}/pairs.txt')
    with open(pairs_path, 'w') as f:
        for a, b in sorted(pairs_set):
            f.write(f'{a} {b}\n')

    step(t0, f'{len(pairs_set)} pairs ({n_seq} seq + {len(pairs_set)-n_seq} spatial) from {len(names)} images')

    # --- ALIKED features ---
    feature_conf = {
        'output': 'feats-aliked-n8192-r1600',
        'model': {'name': 'aliked', 'max_num_keypoints': 8192, 'model_name': 'aliked-n16'},
        'preprocessing': {'grayscale': False, 'resize_max': 1600},
    }
    feature_path = extract_features.main(feature_conf, image_dir, export_dir)
    step(t0, 'ALIKED features extracted (8192 kp, 1600px)')

    # --- LightGlue matching ---
    match_conf = match_features.confs['aliked+lightglue']
    match_path = match_features.main(
        match_conf, pairs_path,
        features=feature_conf['output'],
        export_dir=export_dir,
    )
    step(t0, 'LightGlue matching done')

    # --- Build COLMAP DB ---
    sfm_dir = Path(f'{data_path}/sfm')
    sfm_dir.mkdir(exist_ok=True)
    db_file = str(sfm_dir / 'database.db')
    if os.path.exists(db_file):
        os.remove(db_file)

    conn = sqlite3.connect(db_file)
    c = conn.cursor()
    c.executescript("""
    CREATE TABLE IF NOT EXISTS cameras (camera_id INTEGER PRIMARY KEY, model INTEGER, width INTEGER, height INTEGER, params BLOB, prior_focal_length INTEGER DEFAULT 0);
    CREATE TABLE IF NOT EXISTS images (image_id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, camera_id INTEGER NOT NULL, FOREIGN KEY(camera_id) REFERENCES cameras(camera_id));
    CREATE TABLE IF NOT EXISTS keypoints (image_id INTEGER PRIMARY KEY, rows INTEGER, cols INTEGER, data BLOB, FOREIGN KEY(image_id) REFERENCES images(image_id));
    CREATE TABLE IF NOT EXISTS matches (pair_id INTEGER PRIMARY KEY, rows INTEGER, cols INTEGER, data BLOB);
    CREATE TABLE IF NOT EXISTS two_view_geometries (pair_id INTEGER PRIMARY KEY, rows INTEGER, cols INTEGER, data BLOB, config INTEGER, F BLOB, E BLOB, H BLOB, qvec BLOB, tvec BLOB);
    CREATE TABLE IF NOT EXISTS descriptors (image_id INTEGER PRIMARY KEY, rows INTEGER, cols INTEGER, data BLOB, FOREIGN KEY(image_id) REFERENCES images(image_id));
    CREATE TABLE IF NOT EXISTS pose_priors (image_id INTEGER PRIMARY KEY, position BLOB, coordinate_system INTEGER DEFAULT 0);
    """)

    # Camera: use real ARKit intrinsics
    sample_img = Image.open(os.path.join(img_dir, names[0]))
    w, h = sample_img.size
    if arkit_intrinsics:
        fx = float(np.median([i[0] for i in arkit_intrinsics]))
        fy = float(np.median([i[1] for i in arkit_intrinsics]))
        cx = float(np.median([i[2] for i in arkit_intrinsics]))
        cy = float(np.median([i[3] for i in arkit_intrinsics]))
        print(f'Using ARKit intrinsics: fx={fx:.1f} fy={fy:.1f} cx={cx:.1f} cy={cy:.1f}')
    else:
        fx = fy = max(w, h) * 0.85
        cx, cy = w / 2, h / 2
        print(f'Estimating intrinsics: f={fx:.1f} cx={cx:.1f} cy={cy:.1f}')
    params = np.array([fx, fy, cx, cy], dtype=np.float64)
    c.execute("INSERT INTO cameras VALUES (?, ?, ?, ?, ?, ?)", (1, 1, w, h, params.tobytes(), 1))

    name_to_id = {}
    for idx, name in enumerate(sorted(os.listdir(img_dir)), 1):
        c.execute("INSERT INTO images VALUES (?, ?, ?)", (idx, name, 1))
        name_to_id[name] = idx

    # Inject ARKit positions as pose priors (helps GLOMAP converge near ARKit frame)
    n_priors = 0
    for name, img_id in name_to_id.items():
        if name in name_to_pos:
            pos = name_to_pos[name]
            pos_blob = struct.pack('<3d', float(pos[0]), float(pos[1]), float(pos[2]))
            c.execute("INSERT INTO pose_priors VALUES (?, ?, 1)", (img_id, pos_blob))
            n_priors += 1
    print(f'Injected {n_priors} ARKit pose priors')

    # Import keypoints
    features_h5 = h5py.File(str(feature_path), 'r')
    for name, img_id in name_to_id.items():
        kp = features_h5[name]['keypoints'][()].astype(np.float32) + 0.5
        c.execute("INSERT INTO keypoints VALUES (?, ?, ?, ?)",
                  (img_id, kp.shape[0], kp.shape[1], kp.tobytes()))
    features_h5.close()

    # Import matches
    matches_h5 = h5py.File(str(match_path), 'r')

    def pair_id_fn(id1, id2):
        if id1 > id2: id1, id2 = id2, id1
        return id1 * 2147483647 + id2

    n_matched = 0
    for a, b in pairs_set:
        key = None
        if a in matches_h5 and b in matches_h5[a]:
            key = f'{a}/{b}'
        elif b in matches_h5 and a in matches_h5[b]:
            key = f'{b}/{a}'
            a, b = b, a
        if key is None:
            continue
        m = matches_h5[key]['matches0'][()]
        valid = m > -1
        if valid.sum() == 0:
            continue
        match_idx = np.stack([np.where(valid)[0], m[valid]], axis=1).astype(np.uint32)
        pid = pair_id_fn(name_to_id[a], name_to_id[b])
        c.execute("INSERT OR IGNORE INTO matches VALUES (?, ?, ?, ?)",
                  (pid, match_idx.shape[0], match_idx.shape[1], match_idx.tobytes()))
        n_matched += 1

    matches_h5.close()
    conn.commit()
    conn.close()
    step(t0, f'COLMAP DB built ({len(name_to_id)} images, {n_matched} matched pairs, {n_priors} pose priors)')

    # --- Geometric verification ---
    pycolmap.verify_matches(database_path=db_file, pairs_path=str(pairs_path))
    step(t0, 'Geometric verification done')

    # --- GLOMAP global mapper ---
    sparse_dir = f'{data_path}/sparse'
    shutil.rmtree(sparse_dir, ignore_errors=True)
    os.makedirs(f'{sparse_dir}/0')

    print('\n=== GLOMAP global mapping ===')
    # Ensure all paths are absolute for Docker volume mount
    abs_db = os.path.abspath(db_file)
    abs_img = os.path.abspath(str(img_dir))
    abs_sparse = os.path.abspath(f'{sparse_dir}/0')
    print(f'  DB: {abs_db}')
    print(f'  Images: {abs_img}')
    print(f'  Output: {abs_sparse}')
    result = subprocess.run(
        f'glomap mapper --database_path {abs_db} --image_path {abs_img} --output_path {abs_sparse}',
        shell=True, capture_output=True, text=True
    )
    print(result.stdout[-500:] if result.stdout else '')
    if result.returncode != 0:
        print(f'GLOMAP stderr: {result.stderr[-500:]}', flush=True)
    step(t0, 'GLOMAP done')

    # Find output (GLOMAP nests in sparse/0/0/)
    cam_bins = glob.glob(f'{sparse_dir}/**/cameras.bin', recursive=True)
    if not cam_bins:
        print('ERROR: No reconstruction output')
        subprocess.run(f'find {sparse_dir} -type f', shell=True)
        return None

    # Move nested output to sparse/0
    src_dir = os.path.dirname(cam_bins[0])
    target = f'{sparse_dir}/0'
    if src_dir != target:
        for old_f in list(glob.glob(f'{target}/*')):
            if os.path.isfile(old_f):
                os.remove(old_f)
        for f_name in os.listdir(src_dir):
            shutil.copy2(os.path.join(src_dir, f_name), target)

    # Fix camera model to PINHOLE (pycolmap 3.13 API)
    recon = pycolmap.Reconstruction(target)
    for cam_id, cam in recon.cameras.items():
        model_str = str(cam.model)
        if 'PINHOLE' not in model_str:
            print(f'Converting camera {cam_id} from {model_str} to PINHOLE')
            p = cam.params
            cam.model_id = 1  # PINHOLE
            cam.params = [p[0], p[0], p[1], p[2]]
    recon.write(target)

    # Remove unregistered images (NO alignment — train in native SfM frame)
    registered = set(recon.images[i].name for i in recon.images)
    removed = 0
    for f in os.listdir(img_dir):
        if f not in registered:
            os.remove(os.path.join(img_dir, f))
            removed += 1

    print(f'\n=== SfM Result ===')
    print(f'Registered: {recon.num_reg_images()}/{len(names)} images ({removed} removed)')
    print(f'3D points:  {recon.num_points3D():,}')
    print(f'Reproj err: {recon.compute_mean_reprojection_error():.2f} px')
    print(f'Training set: {len(os.listdir(img_dir))} images')
    print(f'Coordinate frame: native SfM (alignment applied post-training)', flush=True)
    step(t0, 'SfM complete')
    return data_path, name_to_pos


# ============================================================
# Step 3: Patch + Train FastGS
# ============================================================
def patch_fastgs():
    """Apply rasterizer guard + color correction patches."""
    import torch
    import diff_gaussian_rasterization_fastgs as _pkg

    # Rasterizer backward guard
    p = os.path.join(os.path.dirname(_pkg.__file__), '__init__.py')
    with open(p) as f:
        src = f.read()
    if 'num_rendered == 0' not in src:
        src = src.replace(
            '        # Restructure args as C++ method expects them\n'
            '        args = (raster_settings.bg,',
            '        if num_rendered == 0:\n'
            '            return (\n'
            '                torch.zeros_like(means3D), torch.zeros(means3D.shape[0], 4, device=means3D.device),\n'
            '                None, None, torch.zeros_like(colors_precomp) if colors_precomp is not None else None,\n'
            '                None, torch.zeros_like(scales) if scales is not None else None,\n'
            '                torch.zeros_like(rotations) if rotations is not None else None,\n'
            '                None, None, None, None, None, None, None)\n'
            '\n'
            '        # Restructure args as C++ method expects them\n'
            '        args = (raster_settings.bg,'
        )
        with open(p, 'w') as f:
            f.write(src)
    print('[patch] rasterizer backward guard')

    # Color correction in train.py
    p = f'{FASTGS_DIR}/train.py'
    with open(p) as f:
        src = f.read()

    if 'ColorCorrector' not in src:
        color_corr = '''
class ColorCorrector:
    def __init__(self, cameras, lr=1e-3):
        n = len(cameras)
        self.uid_to_idx = {cam.uid: i for i, cam in enumerate(cameras)}
        self.w = torch.nn.Parameter(torch.ones(n, 3, device="cuda"))
        self.b = torch.nn.Parameter(torch.zeros(n, 3, device="cuda"))
        self.optimizer = torch.optim.Adam([self.w, self.b], lr=lr)
        print(f"ColorCorrector: {n} cameras, lr={lr}")

    def apply(self, rendered_image, cam):
        idx = self.uid_to_idx[cam.uid]
        return rendered_image * self.w[idx].view(3,1,1) + self.b[idx].view(3,1,1)

    def step(self):
        self.optimizer.step()
        self.optimizer.zero_grad(set_to_none=True)

'''
        src = src.replace(
            'from gaussian_renderer import render_fastgs, network_gui_ws\n',
            'from gaussian_renderer import render_fastgs, network_gui_ws\n' + color_corr
        )
        src = src.replace(
            '    bg = torch.rand((3), device="cuda") if opt.random_background else background',
            '    bg = torch.rand((3), device="cuda") if opt.random_background else background\n'
            '\n'
            '    color_corrector = ColorCorrector(scene.getTrainCameras())\n'
        )
        src = src.replace(
            '        # Loss\n'
            '        gt_image = viewpoint_cam.original_image.cuda()\n'
            '        Ll1 = l1_loss(image, gt_image)\n'
            '        ssim_value = fast_ssim(image.unsqueeze(0), gt_image.unsqueeze(0))\n'
            '        loss = (1.0 - opt.lambda_dssim) * Ll1 + opt.lambda_dssim * (1.0 - ssim_value)\n'
            '        loss.backward()',
            '        # Loss with per-frame color correction\n'
            '        gt_image = viewpoint_cam.original_image.cuda()\n'
            '        corrected = color_corrector.apply(image, viewpoint_cam)\n'
            '        Ll1 = l1_loss(corrected, gt_image)\n'
            '        ssim_value = fast_ssim(corrected.unsqueeze(0), gt_image.unsqueeze(0))\n'
            '        loss = (1.0 - opt.lambda_dssim) * Ll1 + opt.lambda_dssim * (1.0 - ssim_value)\n'
            '        loss.backward()'
        )
        src = src.replace(
            '                if opt.optimizer_type == "default":\n'
            '                    gaussians.optimizer_step(iteration)',
            '                if opt.optimizer_type == "default":\n'
            '                    gaussians.optimizer_step(iteration)\n'
            '                    color_corrector.step()'
        )
        with open(p, 'w') as f:
            f.write(src)
    print('[patch] color correction')

    # Flatten loss (LighthouseGS §3.2): penalize min-axis scale → disk-shaped Gaussians
    p = f'{FASTGS_DIR}/train.py'
    with open(p) as f:
        src = f.read()
    if 'L_flatten' not in src:
        src = src.replace(
            '        corrected = color_corrector.apply(image, viewpoint_cam)\n'
            '        Ll1 = l1_loss(corrected, gt_image)\n'
            '        ssim_value = fast_ssim(corrected.unsqueeze(0), gt_image.unsqueeze(0))\n'
            '        loss = (1.0 - opt.lambda_dssim) * Ll1 + opt.lambda_dssim * (1.0 - ssim_value)\n'
            '        loss.backward()',
            '        corrected = color_corrector.apply(image, viewpoint_cam)\n'
            '        Ll1 = l1_loss(corrected, gt_image)\n'
            '        ssim_value = fast_ssim(corrected.unsqueeze(0), gt_image.unsqueeze(0))\n'
            '        loss = (1.0 - opt.lambda_dssim) * Ll1 + opt.lambda_dssim * (1.0 - ssim_value)\n'
            '        L_flatten = gaussians.get_scaling.min(dim=1).values.mean()\n'
            '        loss = loss + 0.05 * L_flatten\n'
            '        loss.backward()'
        )
        with open(p, 'w') as f:
            f.write(src)
    print('[patch] flatten loss')

    # Stable pruning (LighthouseGS §3.2): retain oversized Gaussians with opacity > 0.5
    p = f'{FASTGS_DIR}/scene/gaussian_model.py'
    with open(p) as f:
        src = f.read()
    if 'stable pruning' not in src:
        src = src.replace(
            '            big_points_ws = self.get_scaling.max(dim=1).values > 0.1 * extent',
            '            # stable pruning: retain oversized Gaussians with opacity > 0.5\n'
            '            big_points_ws = (self.get_scaling.max(dim=1).values > 0.1 * extent) & (self.get_opacity.squeeze() < 0.5)'
        )
        with open(p, 'w') as f:
            f.write(src)
    print('[patch] stable pruning')


def train_fastgs(data_path, iterations):
    t0 = time.time()
    os.chdir(FASTGS_DIR)

    output_dir = f'{FASTGS_DIR}/output/room_scan'
    if os.path.exists(output_dir):
        shutil.rmtree(output_dir)

    cmd = (
        f'python3 train.py '
        f'-s {data_path} -i images -m output/room_scan '
        f'--iterations {iterations} '
        f'--save_iterations 7000 15000 {iterations} '
        f'--test_iterations 7000 15000 {iterations} '
        f'--densification_interval 500 '
        f'--optimizer_type default '
        f'--highfeature_lr 0.02 '
        f'--grad_abs_thresh 0.0008 '
        f'--sh_degree 3 '
        f'--resolution 2'
    )
    subprocess.run(cmd, shell=True, check=True)
    step(t0, 'Training complete')
    return output_dir


# ============================================================
# Step 4: Export .splat
# ============================================================
def export_splat(output_dir):
    from plyfile import PlyData
    pc_dirs = glob.glob(f'{output_dir}/point_cloud/iteration_*')
    pc_dirs.sort(key=lambda x: int(x.split('_')[-1]))
    ply_path = os.path.join(pc_dirs[-1], 'point_cloud.ply')
    print(f'Using: {ply_path}')

    ply = PlyData.read(ply_path)
    v = ply['vertex']
    n = len(v.data)
    print(f'Converting {n:,} Gaussians...')

    xyz = np.column_stack([v['x'], v['y'], v['z']]).astype(np.float32)
    scale = np.exp(np.column_stack([v['scale_0'], v['scale_1'], v['scale_2']])).astype(np.float32)
    C0 = 0.28209479177387814
    r = np.clip((0.5 + np.array(v['f_dc_0']) * C0) * 255, 0, 255).astype(np.uint8)
    g = np.clip((0.5 + np.array(v['f_dc_1']) * C0) * 255, 0, 255).astype(np.uint8)
    b = np.clip((0.5 + np.array(v['f_dc_2']) * C0) * 255, 0, 255).astype(np.uint8)
    a = np.clip(1.0 / (1.0 + np.exp(-np.array(v['opacity'], dtype=np.float64))) * 255, 0, 255).astype(np.uint8)
    rgba = np.column_stack([r, g, b, a])
    quat = np.column_stack([v['rot_0'], v['rot_1'], v['rot_2'], v['rot_3']]).astype(np.float64)
    norm = np.linalg.norm(quat, axis=1, keepdims=True)
    quat = quat / np.where(norm == 0, 1, norm)
    quat_u8 = np.clip(quat * 128 + 128, 0, 255).astype(np.uint8)

    buf = bytearray(n * 32)
    arr = np.frombuffer(buf, dtype=np.uint8).reshape(n, 32)
    arr[:, 0:12] = xyz.view(np.uint8).reshape(n, 12)
    arr[:, 12:24] = scale.view(np.uint8).reshape(n, 12)
    arr[:, 24:28] = rgba
    arr[:, 28:32] = quat_u8

    splat_path = os.path.expanduser('~/gs-pipeline/room_scan.splat')
    with open(splat_path, 'wb') as f:
        f.write(buf)
    print(f'Wrote {splat_path} ({n:,} Gaussians, {len(buf)/1e6:.1f} MB)')
    return splat_path


# ============================================================
# Step 5: Align splat to ARKit world frame (post-training)
# ============================================================
def align_splat_to_arkit(splat_path, data_path, name_to_pos):
    """Transform .splat from SfM frame to ARKit world frame.

    Computes Umeyama alignment from GLOMAP camera centers to ARKit positions,
    then applies scale*R*pos+t to all Gaussian positions and R to orientations.
    """
    print('\n=== Aligning splat to ARKit world frame ===', flush=True)

    # Load GLOMAP camera centers
    sparse_dir = f'{data_path}/sparse/0'
    recon = pycolmap.Reconstruction(sparse_dir)

    glomap_pts = []
    arkit_pts = []
    for img_id in recon.images:
        img = recon.images[img_id]
        name = img.name
        if name not in name_to_pos:
            continue
        cfw = img.cam_from_world()
        R = np.array(cfw.rotation.matrix())
        t = np.array(cfw.translation)
        glomap_center = -R.T @ t
        glomap_pts.append(glomap_center)
        arkit_pts.append(name_to_pos[name])

    glomap_pts = np.array(glomap_pts)
    arkit_pts = np.array(arkit_pts)

    scale, R_align, t_align = umeyama_alignment(glomap_pts, arkit_pts)

    # Check quality
    aligned = scale * (R_align @ glomap_pts.T).T + t_align
    residuals = np.linalg.norm(aligned - arkit_pts, axis=1)
    print(f'Alignment: scale={scale:.4f}, RMS={np.sqrt(np.mean(residuals**2)):.4f}m, '
          f'max={residuals.max():.4f}m, median={np.median(residuals):.4f}m', flush=True)

    # Read the .splat file (32 bytes per Gaussian)
    with open(splat_path, 'rb') as f:
        buf = bytearray(f.read())
    n = len(buf) // 32
    arr = np.frombuffer(buf, dtype=np.uint8).reshape(n, 32).copy()

    # Extract positions (bytes 0-12, float32 xyz)
    xyz = np.frombuffer(arr[:, 0:12].tobytes(), dtype=np.float32).reshape(n, 3).copy()

    # Extract scales (bytes 12-24, float32)
    scales = np.frombuffer(arr[:, 12:24].tobytes(), dtype=np.float32).reshape(n, 3).copy()

    # Extract quaternions (bytes 28-32, uint8 → float)
    quat_u8 = arr[:, 28:32].copy()
    quat = (quat_u8.astype(np.float64) - 128) / 128

    # Transform positions: new_xyz = scale * R @ xyz + t
    new_xyz = (scale * (R_align @ xyz.T).T + t_align).astype(np.float32)

    # Transform scales by the uniform scale factor
    new_scales = (scales * scale).astype(np.float32)

    # Transform quaternions: new_q = R_quat * old_q
    # Convert R_align to quaternion
    from scipy.spatial.transform import Rotation
    R_quat = Rotation.from_matrix(R_align).as_quat()  # [x, y, z, w]
    # .splat uses [w, x, y, z] order in the uint8 encoding
    # But the raw quat from splat is already [w,x,y,z] after decode
    # Actually splat quaternions are stored as [q0,q1,q2,q3] = [w,x,y,z]
    r_align = Rotation.from_matrix(R_align)
    r_old = Rotation.from_quat(np.column_stack([quat[:, 1], quat[:, 2], quat[:, 3], quat[:, 0]]))  # xyzw
    r_new = r_align * r_old
    new_quat_xyzw = r_new.as_quat()  # [x, y, z, w]
    new_quat = np.column_stack([new_quat_xyzw[:, 3], new_quat_xyzw[:, 0],
                                 new_quat_xyzw[:, 1], new_quat_xyzw[:, 2]])  # [w, x, y, z]
    new_quat_u8 = np.clip(new_quat * 128 + 128, 0, 255).astype(np.uint8)

    # Write back into buffer
    arr[:, 0:12] = new_xyz.view(np.uint8).reshape(n, 12)
    arr[:, 12:24] = new_scales.view(np.uint8).reshape(n, 12)
    arr[:, 28:32] = new_quat_u8

    aligned_path = splat_path.replace('.splat', '_arkit.splat')
    with open(aligned_path, 'wb') as f:
        f.write(arr.tobytes())

    print(f'Wrote {aligned_path} ({n:,} Gaussians, ARKit world frame)', flush=True)
    return aligned_path


# ============================================================
# Main
# ============================================================
if __name__ == '__main__':
    args = parse_args()
    t_total = time.time()

    print(f'=== GS Pipeline: {args.scan_id[:8]}.../{args.room_id[:8]}... ===')
    print(f'Stride: {args.stride}, Iterations: {args.iterations}\n')

    # Step 1: Data
    scan_dir, data_path, img_dir = pull_and_extract(args.scan_id, args.room_id, args.stride)

    # Step 2: SfM (ALIKED + LightGlue + GLOMAP, native frame)
    result = run_sfm(scan_dir, data_path, img_dir)
    if result is None:
        print('SfM failed — aborting')
        sys.exit(1)
    data_path, name_to_pos = result

    # Step 3: Train (in native SfM frame for best quality)
    patch_fastgs()
    output_dir = train_fastgs(data_path, args.iterations)

    # Step 4: Export .splat (native SfM frame)
    splat_path = export_splat(output_dir)

    # Step 5: Align to ARKit world frame (post-training)
    aligned_path = align_splat_to_arkit(splat_path, data_path, name_to_pos)

    elapsed = time.time() - t_total
    print(f'\n=== DONE in {elapsed:.0f}s ({elapsed/60:.1f} min) ===')
    print(f'Splat (native): {splat_path}')
    print(f'Splat (ARKit):  {aligned_path}')
    print(f'ARKit frame: Y-up, meters')
