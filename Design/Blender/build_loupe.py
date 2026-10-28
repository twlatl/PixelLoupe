"""Build the PixelLoupe photo loupe model.

Run headless:
    /Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup \
        -P Design/Blender/build_loupe.py -- <output_dir> [--render]

Every part is a lathe (a 2D profile spun around Z). Profiles are in
millimetres as (radius, height) pairs and are converted to metres, so the
model is real size: about 41 mm across the base and 40 mm tall.

Renders PhotoLoupe.png (wide hero shot) plus two square icon variants; set
LOUPE_SHOTS=Camera,Camera_IconFront to render only some of SHOTS, and
LOUPE_NO_LAYERS=1 to skip the compositing layers, and LOUPE_BACKGROUNDS=Dark
to render only some backgrounds.

The loupe stands on a 35 mm negative strip whose frames come from the images
in frames/ (sorted by name, up to five fit); the composited strip texture is
written to FilmStrip.png.
"""

import math
import os
import sys

import bmesh
import bpy
from mathutils import Vector

MM = 0.001
SEGMENTS = 192


def args():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    out = argv[0] if argv else os.path.dirname(os.path.abspath(__file__))
    return os.path.abspath(out), "--render" in argv


# ---------------------------------------------------------------- profiles

def base_profile():
    """Clear acrylic skirt: flares out to the bottom, with a lip that sits inside the cap."""
    outer = [(20.2, 0.0), (20.4, 0.2)]
    for i in range(1, 21):
        z = 0.2 + (20.5 - 0.2) * i / 20
        r = 17.0 + 3.4 * (1 - z / 20.5) ** 3
        outer.append((r, z))
    outer += [(16.6, 20.8), (16.6, 27.0)]
    inner = [(15.0, 27.0), (15.0, 20.5), (15.4, 20.0)]
    for i in range(1, 20):
        z = 20.0 - 20.0 * i / 20
        r = 17.0 + 3.4 * (1 - z / 20.5) ** 3 - 1.6
        inner.append((r, z))
    inner.append((18.8, 0.0))
    return outer + inner


CAP_BOTTOM = 21.3
CAP_TOP = 40.1      # 18.8 mm tall
LENS_CENTRE = CAP_TOP - 10.5


def cap_profile():
    """Black cap: tapers in toward the top, ribbed eyepiece well, and a seat that holds the lens."""
    top_z, seat = CAP_TOP, CAP_TOP - 8.9
    pts = [(17.8, CAP_BOTTOM), (16.0, top_z - 0.6), (15.9, top_z - 0.2),
           (15.65, top_z), (14.8, top_z), (14.6, top_z - 0.2)]
    top, bottom = (14.6, top_z - 0.2), (13.8, seat)
    ribs = 16
    for i in range(1, ribs * 2):
        t = i / (ribs * 2)
        r = top[0] + (bottom[0] - top[0]) * t
        z = top[1] + (bottom[1] - top[1]) * t
        pts.append((r - (0.15 if i % 2 else 0.0), z))
    lens_bottom = LENS_CENTRE - 0.75
    pts += [bottom, (12.9, seat), (12.9, seat - 0.6), (13.4, seat - 0.6),
            (13.4, lens_bottom), (12.6, lens_bottom), (12.6, lens_bottom - 1.25),
            (16.65, lens_bottom - 1.25), (16.65, CAP_BOTTOM)]
    return pts


def lens_profile(focal=55.0, ior=1.52):
    """Biconvex lens, 26.6 mm across, with spherical faces giving roughly `focal` mm focal length.

    The film sits inside the focal length, so the lens shows it magnified (about 2x).
    """
    radius, centre, edge = 13.3, LENS_CENTRE, 0.75
    curvature = 2 * focal * (ior - 1)

    def sag(r):
        return curvature - math.sqrt(curvature ** 2 - r ** 2)

    half = edge + sag(radius)
    steps = 32
    top = [(radius * i / steps, centre + half - sag(radius * i / steps))
           for i in range(steps + 1)]
    bottom = [(r, 2 * centre - z) for r, z in reversed(top)]
    return top + bottom


# ---------------------------------------------------------------- film strip

FILM_LENGTH, FILM_WIDTH, FILM_THICKNESS = 200.0, 35.0, 0.13
FRAME_W, FRAME_H, FRAME_PITCH = 36.0, 24.0, 38.0
PERF_W, PERF_H, PERF_PITCH, PERF_EDGE = 2.8, 1.98, 4.75, 2.01
PX_PER_MM = 24
LENS_VIEW_Y = 4.0   # point on the middle frame (mm above its centre) the lens should show: the face
FILM_MASK = (1.0, 0.62, 0.36)    # orange-amber cast of colour-negative base
FILM_BASE = tuple(0.66 * c for c in FILM_MASK)
FRAME_MASK = 0.2                  # how much of that cast carries into the frames


def frame_centres(count):
    first = (FILM_LENGTH - FRAME_PITCH * (count - 1)) / 2
    return [first + FRAME_PITCH * i for i in range(count)]


def film_texture(frame_paths, out_path):
    """Composite the frames, perforations and base into one RGBA texture."""
    import numpy as np

    w, h = int(FILM_LENGTH * PX_PER_MM), int(FILM_WIDTH * PX_PER_MM)
    canvas = np.ones((h, w, 4), dtype=np.float32)
    canvas[..., :3] = FILM_BASE

    def px(mm):
        return int(round(mm * PX_PER_MM))

    fw, fh = px(FRAME_W), px(FRAME_H)
    y0 = px((FILM_WIDTH - FRAME_H) / 2)
    for centre, path in zip(frame_centres(len(frame_paths)), frame_paths):
        img = bpy.data.images.load(path)
        img.scale(fw, fh)
        pixels = np.empty(fw * fh * 4, dtype=np.float32)
        img.pixels.foreach_get(pixels)
        x0 = px(centre - FRAME_W / 2)
        frame = pixels.reshape(fh, fw, 4)
        frame[..., :3] *= 1 - FRAME_MASK * (1 - np.array(FILM_MASK, dtype=np.float32))
        canvas[y0:y0 + fh, x0:x0 + fw] = frame
        bpy.data.images.remove(img)

    # Kodak-style perforations: rounded rectangles cut through the film (alpha 0).
    ys = np.arange(h)[:, None] / PX_PER_MM
    xs = np.arange(w)[None, :] / PX_PER_MM
    holes = np.zeros((h, w), dtype=bool)
    corner = 0.5
    rows = [PERF_EDGE + PERF_H / 2, FILM_WIDTH - PERF_EDGE - PERF_H / 2]
    x = (FILM_LENGTH - FRAME_PITCH * 5) / 2 + PERF_PITCH / 2
    while x + PERF_W / 2 < FILM_LENGTH:
        for y in rows:
            dx = np.maximum(np.abs(xs - x) - (PERF_W / 2 - corner), 0)
            dy = np.maximum(np.abs(ys - y) - (PERF_H / 2 - corner), 0)
            holes |= dx ** 2 + dy ** 2 <= corner ** 2
        x += PERF_PITCH
    canvas[holes] = (0, 0, 0, 0)

    tex = bpy.data.images.new("FilmStrip", w, h, alpha=True)
    tex.pixels.foreach_set(canvas.ravel())
    tex.filepath_raw = out_path
    tex.file_format = "PNG"
    tex.save()
    return tex


def film_material(tex):
    mat = bpy.data.materials.new("Film")
    mat.use_nodes = True
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    bsdf = nodes["Principled BSDF"]
    bsdf.inputs["Roughness"].default_value = 0.25
    bsdf.inputs["Specular IOR Level"].default_value = 0.15
    image = nodes.new("ShaderNodeTexImage")
    image.image = tex
    image.extension = "CLIP"
    links.new(image.outputs["Color"], bsdf.inputs["Base Color"])
    links.new(image.outputs["Alpha"], bsdf.inputs["Alpha"])
    return mat


def edge_print(strip, count, collection, mat):
    """Brand name along the top rebate and frame numbers along the bottom, like real negatives."""
    size = 1.15
    labels = []
    for i, centre in enumerate(frame_centres(count)):
        n = 12 + i
        labels += [("PIXELLOUPE 400", centre - 6, FILM_WIDTH - 1.0),
                   (str(n), centre, 1.0), (f"{n}A", centre + FRAME_PITCH / 2, 1.0)]
    for i, (text, x, y) in enumerate(labels):
        curve = bpy.data.curves.new(f"EdgePrint.{i:02d}", "FONT")
        curve.body = text
        curve.size = size * MM
        curve.align_x = "CENTER"
        curve.align_y = "CENTER"
        obj = bpy.data.objects.new(curve.name, curve)
        obj.location = ((x - FILM_LENGTH / 2) * MM, (y - FILM_WIDTH / 2) * MM,
                        FILM_THICKNESS * 0.5 * MM)
        obj.data.materials.append(mat)
        obj.parent = strip
        collection.objects.link(obj)
    # Flatten to meshes so the edge print survives glTF/USD export.
    for o in bpy.context.selected_objects:
        o.select_set(False)
    texts = [o for o in strip.children if o.type == "FONT"]
    for o in texts:
        o.select_set(True)
    bpy.context.view_layer.objects.active = texts[0]
    bpy.ops.object.convert(target="MESH")


def film_strip(scene, out_dir):
    frames_dir = os.path.join(out_dir, "frames")
    paths = sorted(os.path.join(frames_dir, f) for f in os.listdir(frames_dir)
                   if f.lower().endswith((".jpg", ".jpeg", ".png")))
    tex_path = os.path.join(out_dir, "FilmStrip.png")
    bpy.data.images.remove(film_texture(paths, tex_path))
    tex = bpy.data.images.load(tex_path)

    col = bpy.data.collections.new("FilmStrip")
    scene.collection.children.link(col)

    mesh = bpy.data.meshes.new("FilmStrip")
    hl, hw = FILM_LENGTH / 2 * MM, FILM_WIDTH / 2 * MM
    mesh.from_pydata([(-hl, -hw, 0), (hl, -hw, 0), (hl, hw, 0), (-hl, hw, 0)], [],
                     [(0, 1, 2, 3)])
    uv = mesh.uv_layers.new(name="UVMap")
    for loop, co in zip(uv.data, [(0, 0), (1, 0), (1, 1), (0, 1)]):
        loop.uv = co
    strip = bpy.data.objects.new("FilmStrip", mesh)
    strip.location.z = FILM_THICKNESS * MM
    strip.rotation_euler.z = math.radians(-5)
    strip.data.materials.append(film_material(tex))
    col.objects.link(strip)

    ink = principled("Edge Print", **{"Base Color": (0.09, 0.06, 0.035, 1),
                                      "Roughness": 0.3})
    edge_print(strip, len(paths), col, ink)
    return strip


# ---------------------------------------------------------------- geometry

def lathe(name, profile, closed=True):
    mesh = bpy.data.meshes.new(name)
    bm = bmesh.new()
    verts = [bm.verts.new((r * MM, 0.0, z * MM)) for r, z in profile]
    edges = [bm.edges.new((verts[i], verts[i + 1])) for i in range(len(verts) - 1)]
    if closed:
        edges.append(bm.edges.new((verts[-1], verts[0])))
    bmesh.ops.spin(bm, geom=verts + edges, cent=(0, 0, 0), axis=(0, 0, 1),
                   angle=math.tau, steps=SEGMENTS, use_merge=True)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-7)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(mesh)
    bm.free()
    obj = bpy.data.objects.new(name, mesh)
    return obj


def smooth(obj, angle=35):
    for o in bpy.context.selected_objects:
        o.select_set(False)
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.shade_smooth_by_angle(angle=math.radians(angle))


# ---------------------------------------------------------------- materials

def principled(name, **inputs):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    for key, value in inputs.items():
        bsdf.inputs[key].default_value = value
    return mat


def clear_shadows(mat, amount=0.8):
    """Let most light pass straight through this glass when Cycles traces shadows.

    Otherwise the skirt and lens shade the floor and film inside the loupe,
    and the clear acrylic reads as smoky grey.
    """
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    bsdf, out = nodes["Principled BSDF"], nodes["Material Output"]
    path = nodes.new("ShaderNodeLightPath")
    clear = nodes.new("ShaderNodeBsdfTransparent")
    mix = nodes.new("ShaderNodeMixShader")
    scale = nodes.new("ShaderNodeMath")
    scale.operation = "MULTIPLY"
    scale.inputs[1].default_value = amount
    links.new(path.outputs["Is Shadow Ray"], scale.inputs[0])
    links.new(scale.outputs["Value"], mix.inputs["Fac"])
    links.new(bsdf.outputs["BSDF"], mix.inputs[1])
    links.new(clear.outputs["BSDF"], mix.inputs[2])
    links.new(mix.outputs["Shader"], out.inputs["Surface"])


def materials():
    return {
        "silver": principled("Silver Metal", **{
            "Base Color": (0.78, 0.79, 0.81, 1), "Metallic": 1.0, "Roughness": 0.28}),
        "plastic": principled("Black Plastic", **{
            "Base Color": (0.005, 0.005, 0.006, 1), "Roughness": 0.3,
            "Specular IOR Level": 0.2}),
        "acrylic": principled("Clear Acrylic", **{
            "Base Color": (0.97, 0.99, 1.0, 1), "Roughness": 0.03,
            "Transmission Weight": 1.0, "IOR": 1.49}),
        "glass": principled("Lens Glass", **{
            "Base Color": (0.95, 0.97, 0.96, 1), "Roughness": 0.0,
            "Transmission Weight": 1.0, "IOR": 1.52}),
        "backdrop": principled("Backdrop", **{
            "Base Color": (0.9, 0.9, 0.9, 1), "Roughness": 0.6,
            "Specular IOR Level": 0.0}),   # matte, so a black backdrop stays black
    }


# ---------------------------------------------------------------- studio

def studio(scene):
    backdrop = bpy.data.collections.new("Studio")
    scene.collection.children.link(backdrop)

    # Seamless sweep: floor curving up into a wall behind the loupe.
    mesh = bpy.data.meshes.new("Backdrop")
    bm = bmesh.new()
    profile = [(-0.3, 0.0)]
    for i in range(13):
        a = math.pi / 2 * i / 12
        profile.append((0.08 + 0.1 * math.sin(a), 0.1 - 0.1 * math.cos(a)))
    profile.append((0.18, 0.4))
    row = [bm.verts.new((-0.4, y, z)) for y, z in profile]
    edges = [bm.edges.new((row[i], row[i + 1])) for i in range(len(row) - 1)]
    bmesh.ops.extrude_edge_only(bm, edges=edges)
    for v in bm.verts:
        if v not in row:
            v.co.x = 0.4
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(mesh)
    bm.free()
    floor = bpy.data.objects.new("Backdrop", mesh)
    for p in floor.data.polygons:
        p.use_smooth = True
    # Normals must face up/toward the loupe.
    if floor.data.polygons[0].normal.z < 0:
        floor.data.flip_normals()
    backdrop.objects.link(floor)

    def area(name, loc, size, energy, color=(1, 1, 1), target=(0, 0, 0.025),
             reflected=True):
        light = bpy.data.lights.new(name, "AREA")
        light.shape = "DISK"
        light.size = size
        light.energy = energy
        light.color = color
        obj = bpy.data.objects.new(name, light)
        obj.location = loc
        direction = Vector(target) - Vector(loc)
        obj.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()
        # The overhead sweep light would otherwise show as a white disc in the lens.
        obj.visible_glossy = reflected
        backdrop.objects.link(obj)

    area("Key", (-0.1, -0.05, 0.3), 0.15, 1.1)
    area("Fill", (0.22, 0.0, 0.05), 0.15, 0.8)
    area("RimLeft", (-0.16, 0.12, 0.1), 0.08, 1.5)
    area("RimRight", (0.16, 0.12, 0.1), 0.08, 1.5)
    area("Sweep", (0.0, 0.05, 0.25), 0.4, 3, target=(0, 0.2, 0.08),
         reflected=False)

    for shot in SHOTS:
        shot["camera"] = shot_camera(shot, backdrop)
    scene.camera = SHOTS[0]["camera"]
    return floor


# Backdrop colours as (top, bottom) of the frame, linear RGB; a gradient runs
# between them in screen space. "White" is the default studio sweep.
BACKGROUNDS = {
    "White": ((0.9, 0.9, 0.9), (0.9, 0.9, 0.9)),
    "Black": ((0.0004, 0.0004, 0.0004), (0.0004, 0.0004, 0.0004)),
    "Blue": ((0.012, 0.09, 0.42), (0.012, 0.09, 0.42)),
    "BlueGradient": ((0.25, 0.55, 0.95), (0.004, 0.012, 0.07)),
    "WhiteGray": ((0.9, 0.9, 0.9), (0.18, 0.18, 0.19)),
}
BACKGROUNDS["Dark"] = BACKGROUNDS["Black"]

# Cap finish per background; anything not listed keeps the black plastic.
CAP_FINISH = {"Dark": "Silver Metal"}


# Each shot is one camera and one render (one per background, if it lists any).
# strip_shift slides the film strip to the right on screen (mm) after the loupe
# is placed, to change what the lens shows. Azimuth is degrees clockwise (seen
# from above) from straight in front of the strip; elevation is degrees above
# the floor. Targets and distances are in metres.
SHOTS = [
    {"name": "Camera", "file": "PhotoLoupe.png", "size": (1800, 900),
     "azimuth": 0, "elevation": 70, "distance": 0.36, "target": (0, -0.003, 0.01)},
    {"name": "Camera_IconRotated", "file": "PhotoLoupe_Icon_Rotated.png", "size": (1024, 1024),
     "azimuth": 25, "elevation": 70, "distance": 0.17, "target": (0, -0.008, 0.016),
     "strip_shift": 2.5, "lens_view": 5.2,
     "backgrounds": ["White", "Black", "Blue", "BlueGradient", "WhiteGray", "Dark"]},
    {"name": "Camera_IconFront", "file": "PhotoLoupe_Icon_Front.png", "size": (1024, 1024),
     "azimuth": 0, "elevation": 60, "distance": 0.17, "target": (0, -0.01, 0.016)},
]


def loupe_position(cam, strip, view_y=LENS_VIEW_Y):
    """Where to stand the loupe so its lens shows the face on the middle frame.

    A ray through the centre of a symmetric lens leaves parallel to how it
    entered, so the lens shows whatever lies on the camera's line through
    the lens centre. Slide the loupe toward the camera until that line lands
    on the face.
    """
    view = strip.matrix_world @ Vector((0, view_y * MM, 0))
    height = (LENS_CENTRE + FILM_THICKNESS) * MM
    cam_xy = cam.location.xy
    loupe = view.xy.copy()
    for _ in range(20):
        toward = cam_xy - loupe
        run = toward.length * height / (cam.location.z - height)
        loupe = view.xy + toward.normalized() * run
    return (loupe.x, loupe.y, FILM_THICKNESS * MM)


def shot_lights(scene, cap):
    """Lights that follow each shot's camera: one for the eyepiece ribs, three for the glass base."""
    studio = scene.collection.children["Studio"]

    # A narrow spot into the eyepiece, linked to the cap only so it adds no glare
    # to the lens and leaves the outside of the cap black.
    receivers = bpy.data.collections.new("RidgeLightReceivers")
    receivers.objects.link(cap)
    spot = bpy.data.lights.new("RidgeLight", "SPOT")
    spot.energy = 20
    spot.shadow_soft_size = 0.003
    spot.spot_size = math.radians(16)
    spot.spot_blend = 0.15
    ridge = bpy.data.objects.new("RidgeLight", spot)
    ridge.light_linking.receiver_collection = receivers
    studio.objects.link(ridge)

    # Low lights behind and beside the loupe shine through the acrylic, lighting
    # the floor and film inside it and edging the skirt with highlights, so it
    # reads as clear glass rather than smoky grey.
    glass = []
    for name, energy in (("GlassBack", 0.12), ("GlassLeft", 0.04), ("GlassRight", 0.04)):
        light = bpy.data.lights.new(name, "AREA")
        light.shape = "DISK"
        light.size = 0.06
        light.energy = energy
        obj = bpy.data.objects.new(name, light)
        studio.objects.link(obj)
        glass.append(obj)
    return ridge, glass


def aim_shot_lights(lights, cam, root):
    ridge, (back, left, right) = lights
    toward = cam.location.xy - root.location.xy
    toward.normalize()
    side = Vector((-toward.y, toward.x))

    # Ridge spot hangs nearly straight over the eyepiece, a touch toward the
    # camera: it catches the top of each rib while the rib above shades the
    # underside, so the ribs read as light and dark bands.
    eyepiece = root.location + Vector((0, 0, (CAP_TOP - 4) * MM))
    ridge.location = eyepiece + Vector((toward.x * 0.012, toward.y * 0.012, 0.1))
    ridge.rotation_euler = (eyepiece - ridge.location).to_track_quat("-Z", "Y").to_euler()

    skirt = root.location + Vector((0, 0, 0.008))
    for obj, direction in ((back, -toward), (left, side), (right, -side)):
        obj.location = skirt + Vector((direction.x * 0.12, direction.y * 0.12, 0.03))
        obj.rotation_euler = (skirt - obj.location).to_track_quat("-Z", "Y").to_euler()


def shot_camera(shot, collection):
    data = bpy.data.cameras.new(shot["name"])
    data.lens = 63
    data.sensor_fit = "AUTO"
    data.clip_start = 0.005
    cam = bpy.data.objects.new(shot["name"], data)
    az, el = math.radians(shot["azimuth"]), math.radians(shot["elevation"])
    toward = Vector((-math.sin(az) * math.cos(el), -math.cos(az) * math.cos(el),
                     math.sin(el)))
    target = Vector(shot["target"])
    cam.location = target + toward * shot["distance"]
    cam.rotation_euler = (target - cam.location).to_track_quat("-Z", "Y").to_euler()
    collection.objects.link(cam)
    return cam


def world(scene):
    w = bpy.data.worlds.new("Studio White")
    w.use_nodes = True
    bg = w.node_tree.nodes["Background"]
    bg.inputs["Color"].default_value = (1, 1, 1, 1)
    bg.inputs["Strength"].default_value = 0.02
    scene.world = w


def render_settings(scene):
    scene.render.engine = "CYCLES"
    scene.cycles.samples = int(os.environ.get("LOUPE_SAMPLES", 256))
    scene.cycles.use_denoising = True
    scene.cycles.max_bounces = 16
    scene.cycles.transmission_bounces = 16
    scene.cycles.glossy_bounces = 8
    scene.cycles.caustics_reflective = False
    scene.cycles.caustics_refractive = True
    scene.cycles.blur_glossy = 1.0
    scene.render.resolution_x = 1800
    scene.render.resolution_y = 900
    scene.render.film_transparent = False
    scene.view_settings.view_transform = "Standard"
    scene.view_settings.look = "None"
    scene.view_settings.exposure = -2.6
    scene.unit_settings.length_unit = "MILLIMETERS"
    prefs = bpy.context.preferences.addons["cycles"].preferences
    try:
        prefs.compute_device_type = "METAL"
        prefs.get_devices()
        for d in prefs.devices:
            d.use = True
        scene.cycles.device = "GPU"
    except Exception:
        scene.cycles.device = "CPU"


# ---------------------------------------------------------------- main

def main():
    out_dir, do_render = args()
    os.makedirs(out_dir, exist_ok=True)

    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.name = "Loupe"

    mats = materials()
    mats["silver"].use_fake_user = True   # only used by the Dark variant; keep it in the .blend
    loupe = bpy.data.collections.new("Loupe")
    scene.collection.children.link(loupe)

    root = bpy.data.objects.new("PhotoLoupe", None)
    root.empty_display_type = "PLAIN_AXES"
    root.empty_display_size = 0.01
    loupe.objects.link(root)

    parts = [
        ("Loupe_Base", base_profile(), mats["acrylic"], 40),
        ("Loupe_Cap", cap_profile(), mats["plastic"], 40),
        ("Loupe_Lens", lens_profile(), mats["glass"], 60),
    ]
    for name, profile, mat, angle in parts:
        obj = lathe(name, profile)
        obj.data.materials.append(mat)
        obj.parent = root
        loupe.objects.link(obj)
        smooth(obj, angle)

    strip = film_strip(scene, out_dir)

    floor = studio(scene)
    floor.data.materials.append(mats["backdrop"])
    world(scene)
    render_settings(scene)
    root.location = loupe_position(SHOTS[0]["camera"], strip)
    lights = shot_lights(scene, bpy.data.objects["Loupe_Cap"])
    aim_shot_lights(lights, SHOTS[0]["camera"], root)

    # Export the loupe and film strip (no studio) for use outside Blender,
    # before the render-only glass tweak below, so the exports keep plain materials.
    keep = {root, strip, *root.children, *strip.children}
    for o in bpy.data.objects:
        o.select_set(o in keep)
    bpy.ops.export_scene.gltf(filepath=os.path.join(out_dir, "PhotoLoupe.glb"),
                              use_selection=True, export_format="GLB")
    bpy.ops.wm.usd_export(filepath=os.path.join(out_dir, "PhotoLoupe.usdz"),
                          selected_objects_only=True)

    clear_shadows(bpy.data.materials["Clear Acrylic"], 0.8)
    # Less light through the lens keeps the magnified frame from blowing out.
    clear_shadows(bpy.data.materials["Lens Glass"], 0.35)

    blend = os.path.join(out_dir, "PhotoLoupe.blend")
    bpy.ops.wm.save_as_mainfile(filepath=blend, compress=True)

    if do_render:
        only = os.environ.get("LOUPE_SHOTS")
        for shot in SHOTS:
            if only and shot["name"] not in only.split(","):
                continue
            cam = shot["camera"]
            scene.camera = cam
            strip.location.xy = (0, 0)
            root.location = loupe_position(cam, strip, shot.get("lens_view", LENS_VIEW_Y))
            aim_shot_lights(lights, cam, root)
            right = (cam.matrix_world.to_3x3() @ Vector((1, 0, 0))).xy.normalized()
            strip.location.xy = right * shot.get("strip_shift", 0.0) * MM
            scene.render.resolution_x, scene.render.resolution_y = shot["size"]
            stem = os.path.splitext(shot["file"])[0]
            cap = bpy.data.objects["Loupe_Cap"]
            for i, bg in enumerate(shot.get("backgrounds", ["White"])):
                wanted = os.environ.get("LOUPE_BACKGROUNDS")
                if wanted and bg not in wanted.split(","):
                    continue
                set_background(floor.active_material, *BACKGROUNDS[bg])
                cap.data.materials[0] = bpy.data.materials[CAP_FINISH.get(bg, "Black Plastic")]
                name = stem if bg == "White" else f"{stem}_{bg}"
                scene.render.filepath = os.path.join(out_dir, name + ".png")
                bpy.ops.render.render(write_still=True)
                if not os.environ.get("LOUPE_NO_LAYERS"):
                    render_layers(scene, name, out_dir, root, strip, floor, film_layer=i == 0)
            set_background(floor.active_material, *BACKGROUNDS["White"])
            cap.data.materials[0] = bpy.data.materials["Black Plastic"]
            strip.location.xy = (0, 0)


def set_background(mat, top, bottom):
    """Colour the backdrop: solid, or a top-to-bottom gradient in screen space."""
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    ramp = nodes.get("Background Ramp")
    if ramp is None:
        coords = nodes.new("ShaderNodeTexCoord")
        split = nodes.new("ShaderNodeSeparateXYZ")
        ramp = nodes.new("ShaderNodeValToRGB")
        ramp.name = "Background Ramp"
        links.new(coords.outputs["Window"], split.inputs["Vector"])
        links.new(split.outputs["Y"], ramp.inputs["Fac"])
        links.new(ramp.outputs["Color"], nodes["Principled BSDF"].inputs["Base Color"])
    ramp.color_ramp.elements[0].color = (*bottom, 1)
    ramp.color_ramp.elements[1].color = (*top, 1)


def render_layers(scene, stem, out_dir, root, strip, floor, film_layer=True):
    """Render the loupe and the film strip as separate transparent PNGs for compositing.

    Loupe layer: the loupe and the shadow it casts, on transparent. The film and
    floor are shadow catchers, so they vanish to the camera but still show,
    magnified and refracted, through the lens and acrylic, and still catch the
    loupe's shadow. Film strip layer: the strip and its own faint shadow, with
    the loupe removed. Lay the strip layer over a background, then the loupe
    layer on top, and you get the full render back. The loupe layer is made
    per background, since the glass shows the backdrop through it; the strip
    layer only once per shot.
    """
    loupe = [root, *root.children]
    film = [strip, *strip.children]
    layers_dir = os.path.join(out_dir, "layers")
    os.makedirs(layers_dir, exist_ok=True)
    settings = scene.render.image_settings
    settings.color_mode = "RGBA"
    scene.render.film_transparent = True

    def render(name):
        scene.render.filepath = os.path.join(layers_dir, f"{stem}_{name}.png")
        bpy.ops.render.render(write_still=True)

    for o in film + [floor]:
        o.is_shadow_catcher = True
    render("Loupe")

    for o in film:
        o.is_shadow_catcher = False
    if film_layer:
        for o in loupe:
            o.hide_render = True
        render("FilmStrip")
        for o in loupe:
            o.hide_render = False
    floor.is_shadow_catcher = False
    scene.render.film_transparent = False
    settings.color_mode = "RGB"


main()
