#!/usr/bin/env python3
"""
Visual Parity Comparison Tool
Compares two PPM/PNG images, computing MSE, PSNR, and max channel delta.
Can generate an amplified difference heatmap if differences are detected.
"""

import sys
import numpy as np
from PIL import Image

def compare_images(img1_path, img2_path, heatmap_path=None, threshold_mse=0.5):
    im1 = Image.open(img1_path).convert("RGB")
    im2 = Image.open(img2_path).convert("RGB")

    if im1.size != im2.size:
        print(f"FAIL: Size mismatch! {im1.size} vs {im2.size}")
        return False, float("inf"), float("inf"), 255

    arr1 = np.asarray(im1, dtype=np.float32)
    arr2 = np.asarray(im2, dtype=np.float32)

    diff = np.abs(arr1 - arr2)
    max_delta = np.max(diff)
    mse = np.mean((arr1 - arr2) ** 2)

    if mse == 0.0:
        psnr = float("inf")
    else:
        psnr = 20.0 * np.log10(255.0 / np.sqrt(mse))

    passed = mse <= threshold_mse

    print(f"Comparison: {img1_path} vs {img2_path}")
    print(f"  MSE: {mse:.4f} (Threshold: {threshold_mse})")
    print(f"  PSNR: {psnr:.2f} dB")
    print(f"  Max Delta: {max_delta:.1f}")
    print(f"  Result: {'PASS' if passed else 'FAIL'}")

    if heatmap_path and not passed:
        # Amplify difference 10x for visual inspection
        heatmap_arr = np.clip(diff * 10.0, 0, 255).astype(np.uint8)
        heatmap_img = Image.fromarray(heatmap_arr)
        heatmap_img.save(heatmap_path)
        print(f"  Diff heatmap saved to: {heatmap_path}")

    return passed, mse, psnr, max_delta

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python3 diff_images.py <img1> <img2> [heatmap_out] [threshold_mse]")
        sys.exit(1)

    img1 = sys.argv[1]
    img2 = sys.argv[2]
    heatmap = sys.argv[3] if len(sys.argv) > 3 else None
    thresh = float(sys.argv[4]) if len(sys.argv) > 4 else 0.5

    ok, _, _, _ = compare_images(img1, img2, heatmap, thresh)
    sys.exit(0 if ok else 1)
