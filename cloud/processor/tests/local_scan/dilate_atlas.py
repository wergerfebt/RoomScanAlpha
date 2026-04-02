#!/usr/bin/env python3
"""Dilate texture atlas to fill black gaps between UV patches.

Extends colored pixels into adjacent black (uninitialized) regions using
fast vectorized convolution. Eliminates black seam lines caused by bilinear
texture filtering sampling across patch boundaries.

Usage:
    python3 dilate_atlas.py <input.jpg> <output.jpg> [iterations]
"""

import sys
import numpy as np
from PIL import Image
from scipy.ndimage import uniform_filter, maximum_filter


def dilate_atlas(img_array, iterations=8):
    """Dilate non-black pixels into black regions using vectorized ops."""
    h, w, c = img_array.shape
    result = img_array.astype(np.float32)
    mask = np.any(img_array > 5, axis=2).astype(np.float32)

    for i in range(iterations):
        # Sum of filled neighbor colors (using 3x3 box filter)
        color_sum = np.zeros_like(result)
        count = np.zeros((h, w), dtype=np.float32)

        for channel in range(3):
            color_sum[:, :, channel] = uniform_filter(
                result[:, :, channel] * mask, size=3, mode='constant'
            ) * 9  # undo the /9 normalization
        count = uniform_filter(mask, size=3, mode='constant') * 9

        # Pixels to fill: currently black, have at least one filled neighbor
        expandable = (mask == 0) & (count > 0)
        if not np.any(expandable):
            break

        # Fill with average of neighbors
        for channel in range(3):
            result[:, :, channel] = np.where(
                expandable,
                color_sum[:, :, channel] / np.maximum(count, 1),
                result[:, :, channel]
            )
        mask = np.where(expandable, 1.0, mask)

        n_filled = np.sum(expandable)
        print(f"  Iteration {i+1}: {n_filled} pixels dilated")

    return np.clip(result, 0, 255).astype(np.uint8)


def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <input.jpg> <output.jpg> [iterations]")
        sys.exit(1)

    input_path = sys.argv[1]
    output_path = sys.argv[2]
    iterations = int(sys.argv[3]) if len(sys.argv) > 3 else 8

    print(f"Loading {input_path}...")
    img = Image.open(input_path)
    arr = np.array(img)
    print(f"  Size: {arr.shape[1]}x{arr.shape[0]}")

    black_pct = 100 * np.sum(np.all(arr < 5, axis=2)) / (arr.shape[0] * arr.shape[1])
    print(f"  Black pixels: {black_pct:.1f}%")

    print(f"Dilating ({iterations} iterations)...")
    result = dilate_atlas(arr, iterations)

    remaining_pct = 100 * np.sum(np.all(result < 5, axis=2)) / (arr.shape[0] * arr.shape[1])
    print(f"  Remaining black: {remaining_pct:.1f}%")

    Image.fromarray(result).save(output_path, quality=95)
    print(f"Saved to {output_path}")


if __name__ == '__main__':
    main()
