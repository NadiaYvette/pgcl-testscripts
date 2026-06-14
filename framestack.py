#!/usr/bin/env python3
"""
framestack.py - recover legible text from a phone video of a *frozen* screen.

When a machine hangs, its framebuffer freezes, so a hand-held video of the
screen is really dozens-to-hundreds of independent, noisy photographs of one
identical image.  Register them to a common reference and stack them: the
random sensor noise and per-frame camera shake average out while the real
glyphs reinforce.  It is astrophotography applied to a console hang, and it
turns an unreadable single frame into something an OCR pass - or a human - can
read.

Hard requirement: the on-screen content must be STATIC across the window you
feed it (a hang, a panic, a stuck progress screen).  It does nothing for
scrolling boot text, and nothing for a blank/dark screen - there is no signal
there to reinforce.

Pairs well with closed-set matching: kernel log lines are literal printk
format strings present in the source tree, device UUIDs come from blkid, GRUB
entries are the installed kernels.  So a noisy read off the stacked image can be
snapped by edit-distance to the unique valid candidate (and, for kernel lines,
back to the emitting file:line).  That matcher is a separate tool; this one
just produces the cleanest possible image to read.

Examples:
  # from a video, stacking the 11s window starting at t=147s
  framestack.py boot.mp4 --start 147 --dur 11 --fps 12 -o hang

  # from a directory of already-extracted PNG/JPG frames
  framestack.py --frames ./stack_src -o hang --median

Outputs (prefix from -o, default "stack"):
  <prefix>_reference.png  the single sharpest input frame (for comparison)
  <prefix>_mean.png       registered mean (or median) stack
  <prefix>_sharp.png      stack + CLAHE + unsharp mask, tuned for reading

Dependencies: opencv-python (cv2), numpy, and ffmpeg on PATH for video input.
"""
import argparse
import glob
import os
import subprocess
import sys
import tempfile

import cv2
import numpy as np


def extract_frames(video, start, dur, fps, dst):
    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error"]
    if start is not None:
        cmd += ["-ss", str(start)]
    cmd += ["-i", video]
    if dur is not None:
        cmd += ["-t", str(dur)]
    cmd += ["-vf", f"fps={fps}", os.path.join(dst, "f_%04d.png")]
    subprocess.run(cmd, check=True)
    return sorted(glob.glob(os.path.join(dst, "f_*.png")))


def sharpness(gray):
    return cv2.Laplacian(gray, cv2.CV_64F).var()


def stack(files, pct, max_feat, min_inliers, use_median):
    imgs = [cv2.imread(f) for f in files]
    imgs = [im for im in imgs if im is not None]
    if not imgs:
        sys.exit("no readable frames")
    grays = [cv2.cvtColor(im, cv2.COLOR_BGR2GRAY) for im in imgs]
    sh = [sharpness(g) for g in grays]
    ref = int(np.argmax(sh))
    print(f"frames={len(imgs)} ref={ref} sharp_ref={sh[ref]:.0f} "
          f"sharp_median={np.median(sh):.0f}")

    H, W = grays[ref].shape
    orb = cv2.ORB_create(max_feat)
    kp_ref, des_ref = orb.detectAndCompute(grays[ref], None)
    bf = cv2.BFMatcher(cv2.NORM_HAMMING, crossCheck=True)
    thr = np.percentile(sh, pct)

    aligned = []
    for i, (im, g) in enumerate(zip(imgs, grays)):
        if sh[i] < thr:
            continue
        if i == ref:
            aligned.append(im)
            continue
        kp, des = orb.detectAndCompute(g, None)
        if des is None or len(kp) < 30:
            continue
        m = bf.match(des, des_ref)
        if len(m) < 30:
            continue
        m = sorted(m, key=lambda x: x.distance)[:200]
        src = np.float32([kp[x.queryIdx].pt for x in m]).reshape(-1, 1, 2)
        dst = np.float32([kp_ref[x.trainIdx].pt for x in m]).reshape(-1, 1, 2)
        Hm, mask = cv2.findHomography(src, dst, cv2.RANSAC, 3.0)
        if Hm is None or int(mask.sum()) < min_inliers:
            continue
        aligned.append(cv2.warpPerspective(im, Hm, (W, H)))

    print(f"stacked {len(aligned)} frames "
          f"({'median' if use_median else 'mean'})")
    if not aligned:
        sys.exit("no frames survived registration; widen --pct or the window")
    if use_median:
        out = np.median(np.stack(aligned), axis=0)
    else:
        acc = np.zeros((H, W, 3), np.float32)
        for a in aligned:
            acc += a
        out = acc / len(aligned)
    return imgs[ref], out.clip(0, 255).astype(np.uint8)


def readability(img):
    lab = cv2.cvtColor(img, cv2.COLOR_BGR2LAB)
    l, a, b = cv2.split(lab)
    l = cv2.createCLAHE(2.5, (8, 8)).apply(l)
    base = cv2.cvtColor(cv2.merge([l, a, b]), cv2.COLOR_LAB2BGR)
    blur = cv2.GaussianBlur(base, (0, 0), 2.0)
    return cv2.addWeighted(base, 1.8, blur, -0.8, 0)


def main():
    ap = argparse.ArgumentParser(
        description="Stack frames of a frozen screen to recover legible text.")
    ap.add_argument("video", nargs="?", help="input video (or use --frames)")
    ap.add_argument("--frames", help="directory of pre-extracted frames")
    ap.add_argument("--start", type=float, help="video start time (s)")
    ap.add_argument("--dur", type=float, help="window length (s)")
    ap.add_argument("--fps", type=float, default=12, help="sampling fps")
    ap.add_argument("--pct", type=float, default=45,
                    help="drop frames below this sharpness percentile")
    ap.add_argument("--max-feat", type=int, default=6000, help="ORB features")
    ap.add_argument("--min-inliers", type=int, default=25,
                    help="min RANSAC inliers to accept a frame")
    ap.add_argument("--median", action="store_true",
                    help="median stack (robust to blur) instead of mean")
    ap.add_argument("-o", "--out", default="stack", help="output prefix")
    args = ap.parse_args()

    tmp = None
    if args.frames:
        files = sorted(glob.glob(os.path.join(args.frames, "*.png")) +
                       glob.glob(os.path.join(args.frames, "*.jpg")))
    elif args.video:
        tmp = tempfile.mkdtemp(prefix="framestack_")
        files = extract_frames(args.video, args.start, args.dur, args.fps, tmp)
    else:
        ap.error("give a video or --frames")
    if not files:
        sys.exit("no input frames found")

    ref, stacked = stack(files, args.pct, args.max_feat,
                         args.min_inliers, args.median)
    cv2.imwrite(f"{args.out}_reference.png", ref)
    cv2.imwrite(f"{args.out}_mean.png", stacked)
    cv2.imwrite(f"{args.out}_sharp.png", readability(stacked))
    print(f"wrote {args.out}_reference.png {args.out}_mean.png "
          f"{args.out}_sharp.png")
    if tmp:
        for f in files:
            os.unlink(f)
        os.rmdir(tmp)


if __name__ == "__main__":
    main()
