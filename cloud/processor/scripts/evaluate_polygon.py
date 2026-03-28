#!/usr/bin/env python3
"""
Evaluate room polygon accuracy — compare predicted polygon to ground truth.

Computes:
  - Floor Polygon IoU (rasterized to 1cm grid)
  - Corner Count Accuracy
  - Mean Corner Position Error (CPE) via Hungarian matching
  - Floor Area Error %
  - Perimeter Error %

Usage:
    python scripts/evaluate_polygon.py <predicted.json> <ground_truth.json>
    python scripts/evaluate_polygon.py --baseline <scan_ply> --debug-ply <gt_simplified_ply>

For EVAL.H1 / EVAL.H2 human-in-the-loop tests.
"""

import json
import sys
from pathlib import Path

import numpy as np
from scipy.optimize import linear_sum_assignment

# Add parent dir to path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))


def polygon_area(vertices: np.ndarray) -> float:
    """Compute signed area of a 2D polygon using the shoelace formula.

    Args:
        vertices: Nx2 array of (x, z) vertices in order.

    Returns:
        Signed area (positive = CCW, negative = CW).
    """
    x = vertices[:, 0]
    z = vertices[:, 1]
    return 0.5 * float(np.abs(np.dot(x, np.roll(z, -1)) - np.dot(z, np.roll(x, -1))))


def polygon_perimeter(vertices: np.ndarray) -> float:
    """Compute perimeter of a 2D polygon.

    Args:
        vertices: Nx2 array of (x, z) vertices in order.

    Returns:
        Perimeter length.
    """
    rolled = np.roll(vertices, -1, axis=0)
    return float(np.sum(np.linalg.norm(rolled - vertices, axis=1)))


def polygon_iou(poly_a: np.ndarray, poly_b: np.ndarray, cell_size: float = 0.01) -> float:
    """Compute IoU between two 2D polygons by rasterization.

    Rasterizes both polygons to a grid and counts intersection/union pixels.

    Args:
        poly_a, poly_b: Nx2 arrays of polygon vertices.
        cell_size: Grid cell size in meters (default 1cm).

    Returns:
        IoU value in [0, 1].
    """
    # Compute combined bounding box
    all_pts = np.vstack([poly_a, poly_b])
    xmin, zmin = all_pts.min(axis=0) - cell_size
    xmax, zmax = all_pts.max(axis=0) + cell_size

    nx = int(np.ceil((xmax - xmin) / cell_size))
    nz = int(np.ceil((zmax - zmin) / cell_size))

    # Cap grid size to prevent OOM on large rooms.
    # 2000x2000 = 4M cells — fits in ~32MB of RAM. Larger rooms get coarser cells.
    max_grid = 2000
    if nx > max_grid or nz > max_grid:
        scale = max(nx, nz) / max_grid
        cell_size = cell_size * scale
        nx = int(np.ceil((xmax - xmin) / cell_size))
        nz = int(np.ceil((zmax - zmin) / cell_size))

    # Create grid coordinates
    xs = np.linspace(xmin + cell_size / 2, xmax - cell_size / 2, nx)
    zs = np.linspace(zmin + cell_size / 2, zmax - cell_size / 2, nz)
    grid_x, grid_z = np.meshgrid(xs, zs)
    grid_pts = np.column_stack([grid_x.ravel(), grid_z.ravel()])

    mask_a = _points_in_polygon(grid_pts, poly_a)
    mask_b = _points_in_polygon(grid_pts, poly_b)

    intersection = np.sum(mask_a & mask_b)
    union = np.sum(mask_a | mask_b)

    if union == 0:
        return 0.0
    return float(intersection / union)


def _points_in_polygon(points: np.ndarray, polygon: np.ndarray) -> np.ndarray:
    """Ray-casting point-in-polygon test for Nx2 points against a polygon.

    Args:
        points: Nx2 array of test points.
        polygon: Mx2 array of polygon vertices (closed loop assumed).

    Returns:
        Boolean array of length N.
    """
    n = len(polygon)
    inside = np.zeros(len(points), dtype=bool)

    px, pz = points[:, 0], points[:, 1]

    j = n - 1
    for i in range(n):
        xi, zi = polygon[i]
        xj, zj = polygon[j]

        # Check if the ray from point going in +X crosses the edge (i, j)
        cond1 = (zi > pz) != (zj > pz)
        if np.any(cond1):
            slope = (xj - xi) / (zj - zi + 1e-30)
            x_intersect = xi + slope * (pz - zi)
            cross = cond1 & (px < x_intersect)
            inside ^= cross

        j = i

    return inside


def corner_position_error(pred: np.ndarray, truth: np.ndarray) -> dict:
    """Compute corner position error via Hungarian matching.

    Args:
        pred: Kx2 predicted corner positions.
        truth: Mx2 ground truth corner positions.

    Returns:
        Dict with mean_cpe, max_cpe, matched_count, and per-corner errors.
    """
    if len(pred) == 0 or len(truth) == 0:
        return {"mean_cpe": float("inf"), "max_cpe": float("inf"),
                "matched_count": 0, "per_corner_errors": []}

    # Build cost matrix: distance from each pred to each truth corner
    cost = np.linalg.norm(pred[:, None, :] - truth[None, :, :], axis=2)

    # Hungarian matching
    row_ind, col_ind = linear_sum_assignment(cost)

    errors = cost[row_ind, col_ind]

    return {
        "mean_cpe": float(np.mean(errors)),
        "max_cpe": float(np.max(errors)),
        "matched_count": len(row_ind),
        "per_corner_errors": errors.tolist(),
    }


def corner_count_accuracy(pred_count: int, truth_count: int) -> float:
    """Score for corner count accuracy.

    exact match = 1.0, off by 1 = 0.8, off by 2 = 0.5, off by 3+ = 0.0
    """
    diff = abs(pred_count - truth_count)
    if diff == 0:
        return 1.0
    elif diff == 1:
        return 0.8
    elif diff == 2:
        return 0.5
    else:
        return 0.0


def evaluate_polygons(pred: np.ndarray, truth: np.ndarray) -> dict:
    """Run all evaluation metrics between predicted and ground truth polygons.

    Args:
        pred: Kx2 predicted polygon vertices (meters, XZ plane).
        truth: Mx2 ground truth polygon vertices (meters, XZ plane).

    Returns:
        Dict with all metrics.
    """
    pred_area = polygon_area(pred)
    truth_area = polygon_area(truth)
    pred_perim = polygon_perimeter(pred)
    truth_perim = polygon_perimeter(truth)

    iou = polygon_iou(pred, truth)
    cpe = corner_position_error(pred, truth)
    count_acc = corner_count_accuracy(len(pred), len(truth))

    area_error_pct = abs(pred_area - truth_area) / truth_area * 100 if truth_area > 0 else float("inf")
    perim_error_pct = abs(pred_perim - truth_perim) / truth_perim * 100 if truth_perim > 0 else float("inf")

    return {
        "iou": iou,
        "corner_count_pred": len(pred),
        "corner_count_truth": len(truth),
        "corner_count_accuracy": count_acc,
        "mean_cpe_m": cpe["mean_cpe"],
        "max_cpe_m": cpe["max_cpe"],
        "pred_area_m2": pred_area,
        "truth_area_m2": truth_area,
        "area_error_pct": area_error_pct,
        "pred_perimeter_m": pred_perim,
        "truth_perimeter_m": truth_perim,
        "perimeter_error_pct": perim_error_pct,
        "per_corner_errors_m": cpe["per_corner_errors"],
    }


def print_evaluation(results: dict, label: str = ""):
    """Pretty-print evaluation results."""
    if label:
        print(f"\n=== {label} ===")
    print(f"  IoU:                    {results['iou']:.4f}")
    print(f"  Corner count:           {results['corner_count_pred']} pred / {results['corner_count_truth']} truth "
          f"(accuracy: {results['corner_count_accuracy']:.1f})")
    print(f"  Mean CPE:               {results['mean_cpe_m']:.4f} m")
    print(f"  Max CPE:                {results['max_cpe_m']:.4f} m")
    print(f"  Floor area:             {results['pred_area_m2']:.3f} m² pred / {results['truth_area_m2']:.3f} m² truth "
          f"({results['area_error_pct']:.1f}% error)")
    print(f"  Perimeter:              {results['pred_perimeter_m']:.3f} m pred / {results['truth_perimeter_m']:.3f} m truth "
          f"({results['perimeter_error_pct']:.1f}% error)")


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Evaluate polygon accuracy")
    parser.add_argument("--pred-json", help="Predicted polygon JSON (list of [x, z] vertices)")
    parser.add_argument("--truth-json", help="Ground truth polygon JSON")
    parser.add_argument("--output", "-o", help="Output results JSON path")
    args = parser.parse_args()

    if args.pred_json and args.truth_json:
        with open(args.pred_json) as f:
            pred = np.array(json.load(f))
        with open(args.truth_json) as f:
            truth = np.array(json.load(f))

        results = evaluate_polygons(pred, truth)
        print_evaluation(results)

        if args.output:
            with open(args.output, "w") as f:
                json.dump(results, f, indent=2)
            print(f"\nSaved results to {args.output}")
    else:
        print("Usage: python evaluate_polygon.py --pred-json pred.json --truth-json truth.json")
        sys.exit(1)
