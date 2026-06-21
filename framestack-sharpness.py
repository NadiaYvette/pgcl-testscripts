#!/usr/bin/env python3
import cv2, numpy as np, glob, os

files = sorted(glob.glob('stack_src/f_*.png'))
imgs = [cv2.imread(f) for f in files]
grays = [cv2.cvtColor(i, cv2.COLOR_BGR2GRAY) for i in imgs]

# sharpness = variance of Laplacian
sharp = [cv2.Laplacian(g, cv2.CV_64F).var() for g in grays]
ref_idx = int(np.argmax(sharp))
print(f"frames={len(imgs)} ref={ref_idx} sharp_ref={sharp[ref_idx]:.0f} "
      f"sharp_med={np.median(sharp):.0f}")
cv2.imwrite('out_reference.png', imgs[ref_idx])

ref_g = grays[ref_idx]
H, W = ref_g.shape
orb = cv2.ORB_create(6000)
kp_ref, des_ref = orb.detectAndCompute(ref_g, None)
bf = cv2.BFMatcher(cv2.NORM_HAMMING, crossCheck=True)

acc = np.zeros((H, W, 3), np.float32)
n = 0
# only consider the sharper half to reject motion-blurred frames
thr = np.percentile(sharp, 45)
for i, (img, g) in enumerate(zip(imgs, grays)):
    if sharp[i] < thr:
        continue
    if i == ref_idx:
        warped = img
        inl = 9999
    else:
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
        if Hm is None:
            continue
        inl = int(mask.sum())
        if inl < 25:
            continue
        warped = cv2.warpPerspective(img, Hm, (W, H))
    acc += warped.astype(np.float32)
    n += 1

mean = (acc / max(n, 1)).clip(0, 255).astype(np.uint8)
print(f"stacked {n} frames")
cv2.imwrite('out_stack_mean.png', mean)

# readability: CLAHE on luminance + unsharp mask
lab = cv2.cvtColor(mean, cv2.COLOR_BGR2LAB)
l, a, b = cv2.split(lab)
l = cv2.createCLAHE(2.5, (8, 8)).apply(l)
sharp_img = cv2.cvtColor(cv2.merge([l, a, b]), cv2.COLOR_LAB2BGR)
blur = cv2.GaussianBlur(sharp_img, (0, 0), 2.0)
usm = cv2.addWeighted(sharp_img, 1.8, blur, -0.8, 0)
cv2.imwrite('out_stack_sharp.png', usm)
print("wrote out_reference.png out_stack_mean.png out_stack_sharp.png")
