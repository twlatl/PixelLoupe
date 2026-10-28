import bpy, sys, numpy as np
src, out = sys.argv[-2], sys.argv[-1]
img = bpy.data.images.load(src)
w, h = img.size
px = np.array(img.pixels[:]).reshape(h, w, 4)
yy, xx = np.mgrid[0:h, 0:w]
checker = np.where(((xx // 30 + yy // 30) % 2)[..., None], 0.55, 0.85)
a = px[..., 3:4]
rgb = px[..., :3] * a + checker * (1 - a) if not img.alpha_mode == 'PREMUL' else px[..., :3] + checker * (1 - a)
print("alpha min/max:", a.min(), a.max(), "fully transparent %:", round(float((a < 0.01).mean() * 100), 1))
res = bpy.data.images.new("c", w, h)
res.pixels[:] = np.dstack([rgb, np.ones((h, w, 1))]).ravel()
res.filepath_raw = out; res.file_format = 'PNG'; res.save()
