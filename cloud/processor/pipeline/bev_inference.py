"""
BEV Inference — run RoomFormer TorchScript model on a BEV density map.

Loads a TorchScript-exported RoomFormer model, runs inference on a BEV density
map, and post-processes the output into room polygon vertices.

The model outputs:
  - pred_logits: [1, 20, 40] — corner validity logits (before sigmoid)
  - pred_coords: [1, 20, 40, 2] — normalized corner coordinates in [0, 1]

Post-processing:
  1. Sigmoid on logits → confidence scores
  2. Filter corners by confidence threshold
  3. Scale coords from [0,1] to pixel coordinates [0, resolution-1]
  4. Reject rooms with < 4 valid corners
  5. Reject rooms with polygon area < min_area_px
  6. Reject self-intersecting polygons
  7. Select the room with the largest polygon area
  8. Ensure CCW winding order
"""

from dataclasses import dataclass
from pathlib import Path
from typing import Optional

import numpy as np

from .bev_projection import BEVProjection

# Lazy-import torch to avoid import cost when not using DNN path
_torch = None
_model_cache: dict = {}


def _get_torch():
    """Lazy import torch — only when actually needed."""
    global _torch
    if _torch is None:
        import torch
        _torch = torch
    return _torch


@dataclass
class DnnPolygonResult:
    """Result of DNN room polygon prediction.

    Attributes:
        corners_px: Kx2 array of (col, row) pixel coordinates, or empty if no room detected.
        confidence: K-length array of per-corner confidence scores (sigmoid of logits).
        num_corners: Number of valid corners detected.
        room_index: Which of the 20 room queries was selected (for debugging).
        success: Whether a valid polygon was found.
    """
    corners_px: np.ndarray
    confidence: np.ndarray
    num_corners: int
    room_index: int = -1
    success: bool = False


def predict_room_polygon(
    bev: BEVProjection,
    model_path: Optional[str] = None,
    confidence_threshold: float = 0.5,
    min_corners: int = 4,
    min_area_px: float = 100.0,
) -> DnnPolygonResult:
    """Run RoomFormer inference on a BEV density map and extract the room polygon.

    Args:
        bev: BEVProjection from project_to_bev().
        model_path: Path to TorchScript .pt model file. If None, uses default location.
        confidence_threshold: Minimum sigmoid(logit) to keep a corner.
        min_corners: Minimum corners for a valid room polygon.
        min_area_px: Minimum polygon area in sq pixels to accept a room.

    Returns:
        DnnPolygonResult with corners in pixel coordinates (col, row).
    """
    torch = _get_torch()

    # Load model (cached singleton)
    model = _load_model(model_path)

    # Prepare input tensor: [1, 1, H, W]
    density = bev.density_map
    input_tensor = torch.from_numpy(density).unsqueeze(0).unsqueeze(0).float()

    # Run inference
    with torch.no_grad():
        pred_logits, pred_coords = model(input_tensor)

    # Convert to numpy
    logits_np = pred_logits.numpy()   # [1, 20, 40]
    coords_np = pred_coords.numpy()   # [1, 20, 40, 2]

    # Post-process
    return _postprocess(
        logits_np, coords_np, bev.resolution,
        confidence_threshold, min_corners, min_area_px,
    )


def _load_model(model_path: Optional[str] = None):
    """Load TorchScript model with caching (singleton per path)."""
    torch = _get_torch()

    if model_path is None:
        # Default path relative to this file
        model_path = str(Path(__file__).parent.parent / "models" / "roomformer_s3d.pt")

    model_path = str(Path(model_path).resolve())

    if model_path not in _model_cache:
        if not Path(model_path).exists():
            raise FileNotFoundError(f"Model not found: {model_path}")
        _model_cache[model_path] = torch.jit.load(model_path, map_location="cpu")
        _model_cache[model_path].eval()

    return _model_cache[model_path]


def _postprocess(
    logits: np.ndarray,
    coords: np.ndarray,
    resolution: int,
    confidence_threshold: float,
    min_corners: int,
    min_area_px: float,
) -> DnnPolygonResult:
    """Post-process RoomFormer output into a single room polygon.

    Args:
        logits: [1, M, N] raw logits (M=20 rooms, N=40 corners per room)
        coords: [1, M, N, 2] normalized coordinates in [0, 1]
        resolution: BEV resolution (e.g. 256)
        confidence_threshold: sigmoid threshold for valid corners
        min_corners: minimum corners for a valid polygon
        min_area_px: minimum polygon area in sq pixels

    Returns:
        DnnPolygonResult
    """
    # Apply sigmoid to logits
    sigmoid = 1.0 / (1.0 + np.exp(-logits[0]))  # [20, 40]

    # Scale coords to pixel space
    pixel_coords = coords[0] * (resolution - 1)  # [20, 40, 2]

    best_result = _empty_result()
    best_area = -1.0

    for room_idx in range(sigmoid.shape[0]):
        # Filter corners by confidence
        valid_mask = sigmoid[room_idx] > confidence_threshold
        n_valid = valid_mask.sum()

        if n_valid < min_corners:
            continue

        corners = pixel_coords[room_idx, valid_mask]  # [K, 2] — (x, y) in pixel space
        conf = sigmoid[room_idx, valid_mask]

        # Order corners CCW by angle from centroid
        corners = _order_ccw(corners)

        # Check polygon area
        area = _polygon_area_signed(corners)
        if abs(area) < min_area_px:
            continue

        # Check for self-intersection via shapely if available
        if not _is_valid_polygon(corners):
            continue

        # Ensure CCW (positive signed area)
        if area < 0:
            corners = corners[::-1].copy()
            conf = conf[::-1].copy()

        if abs(area) > best_area:
            best_area = abs(area)
            best_result = DnnPolygonResult(
                corners_px=corners,  # (col, row) pixel coords
                confidence=conf,
                num_corners=int(n_valid),
                room_index=room_idx,
                success=True,
            )

    return best_result


def _order_ccw(corners: np.ndarray) -> np.ndarray:
    """Order 2D points counter-clockwise by angle from centroid."""
    centroid = corners.mean(axis=0)
    angles = np.arctan2(corners[:, 1] - centroid[1], corners[:, 0] - centroid[0])
    order = np.argsort(angles)
    return corners[order]


def _polygon_area_signed(corners: np.ndarray) -> float:
    """Compute signed area of a 2D polygon (positive = CCW)."""
    n = len(corners)
    if n < 3:
        return 0.0
    x = corners[:, 0]
    y = corners[:, 1]
    return 0.5 * float(np.dot(x, np.roll(y, -1)) - np.dot(y, np.roll(x, -1)))


def _is_valid_polygon(corners: np.ndarray) -> bool:
    """Check if polygon is valid (not self-intersecting) using shapely."""
    if len(corners) < 3:
        return False
    try:
        from shapely.geometry import Polygon
        poly = Polygon(corners)
        return poly.is_valid
    except ImportError:
        # shapely not available — skip validation
        return True
    except Exception:
        return False


def _empty_result() -> DnnPolygonResult:
    """Return an empty result when no valid polygon is found."""
    return DnnPolygonResult(
        corners_px=np.empty((0, 2), dtype=np.float64),
        confidence=np.empty(0, dtype=np.float64),
        num_corners=0,
        room_index=-1,
        success=False,
    )


def clear_model_cache():
    """Clear the loaded model cache (useful for testing)."""
    _model_cache.clear()
