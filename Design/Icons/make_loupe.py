import bpy, bmesh, math, sys, os
from mathutils import Vector

OUT = os.path.dirname(os.path.abspath(__file__))
SAMPLES = int(os.environ.get("LOUPE_SAMPLES", "256"))
ALPHA = os.environ.get("LOUPE_ALPHA") == "1"  # transparent background, shadow kept

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.unit_settings.system = 'METRIC'
scene.unit_settings.scale_length = 0.01  # 1 unit = 1 cm


def lathe(name, profile, steps=192, smooth=True):
    """Spin a closed (x, z) profile around Z into a solid of revolution."""
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    verts = [bm.verts.new((x, 0, z)) for x, z in profile]
    edges = [bm.edges.new((verts[i], verts[(i + 1) % len(verts)])) for i in range(len(verts))]
    bmesh.ops.spin(bm, geom=verts + edges, cent=(0, 0, 0), axis=(0, 0, 1),
                   angle=math.tau, steps=steps, use_merge=True)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(me)
    bm.free()
    for p in me.polygons:
        p.use_smooth = smooth
    ob = bpy.data.objects.new(name, me)
    bpy.context.collection.objects.link(ob)
    return ob


def arc(cx, cz, r, a0, a1, n):
    return [(cx + r * math.cos(a0 + (a1 - a0) * i / n), cz + r * math.sin(a0 + (a1 - a0) * i / n))
            for i in range(n + 1)]


def smooth_by_angle(ob, deg=35):
    mod = ob.modifiers.new("Sharp", 'EDGE_SPLIT')
    mod.split_angle = math.radians(deg)
    mod.use_edge_sharp = False


# ---------- Clear acrylic base (open-bottom bell) ----------
T = 0.18  # wall thickness
shoulder = [(2.30 - 0.25 * (1 - math.cos(t * math.pi / 2)), 1.15 + 0.45 * math.sin(t * math.pi / 2))
            for t in [i / 10 for i in range(1, 11)]]
outer = arc(2.40, 0.05, 0.05, -math.pi / 2, 0, 4)              # rounded foot, outside
outer += [(2.45, 0.4), (2.38, 0.8), (2.30, 1.15)] + shoulder
outer += [(2.04, 1.75), (2.03, 2.65)]
outer += arc(2.03 - T / 2, 2.65, T / 2, 0, math.pi, 6)[1:]     # rounded neck lip
inner = [(2.03 - T, 1.75)] + [(x - T, z) for x, z in reversed(shoulder)]
inner += [(2.30 - T, 1.15), (2.38 - T, 0.8), (2.45 - T, 0.4), (2.45 - T, 0.05)]
inner += arc(2.45 - T + 0.05, 0.05, 0.05, math.pi, 1.5 * math.pi, 4)[1:-1]
base_profile = outer + inner
base = lathe("LoupeBase", base_profile)
smooth_by_angle(base, 40)

# ---------- Black cap ----------
# A sleeve over the glass neck that tapers in toward the top.
cap = [(2.10, 2.25)]
cap += arc(2.12, 2.29, 0.04, -math.pi / 2, 0, 3)               # rounded bottom edge
cap += [(2.10, 2.9), (1.95, 3.55), (1.87, 3.81)]
cap += arc(1.80, 3.81, 0.07, 0, math.pi / 2, 5)[1:]            # rounded top edge
# Fine concentric ribs on the inner conical rim, stepped like stair treads
# so each rib has a lit top and a shaded riser.
r0, z0, r1, z1, n_ribs = 1.73, 3.88, 1.58, 3.58, 16
dr, dz = (r1 - r0) / n_ribs, (z1 - z0) / n_ribs
for i in range(n_ribs):
    r, z = r0 + dr * i, z0 + dz * i
    cap += [(r, z), (r, z + dz * 0.85), (r + dr * 0.8, z + dz)]
cap += [(r1, z1), (1.53, 3.55), (1.53, 3.35), (1.72, 3.30), (1.80, 3.23),
        (1.80, 2.86), (2.07, 2.80), (2.07, 2.25)]
cap_ob = lathe("LoupeCap", cap)
smooth_by_angle(cap_ob, 30)

# ---------- Lens (plano-convex, dome up) ----------
LR, LZ, dome = 1.56, 3.36, 0.30
R = (LR ** 2 + dome ** 2) / (2 * dome)
a = math.asin(LR / R)
lens = [(R * math.sin(a * (1 - i / 24)), LZ + dome - R + R * math.cos(a * (1 - i / 24))) for i in range(25)]
lens = lens[::-1]  # centre -> edge
lens = [(0.0, LZ + dome)] + [p for p in lens[1:]] + [(LR, LZ - 0.06), (0.0, LZ - 0.06)]
lens_ob = lathe("LoupeLens", lens)

# ---------- Materials ----------
def principled(name):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    return m, m.node_tree.nodes["Principled BSDF"]

acrylic, p = principled("Acrylic")
p.inputs["Base Color"].default_value = (0.90, 0.93, 0.94, 1)
p.inputs["Transmission Weight"].default_value = 1.0
p.inputs["Roughness"].default_value = 0.03
p.inputs["IOR"].default_value = 1.49

lens_glass, p = principled("LensGlass")
p.inputs["Base Color"].default_value = (0.93, 0.97, 0.96, 1)
p.inputs["Transmission Weight"].default_value = 1.0
p.inputs["Roughness"].default_value = 0.0
p.inputs["IOR"].default_value = 1.52

plastic, p = principled("BlackPlastic")
p.inputs["Base Color"].default_value = (0.004, 0.004, 0.0045, 1)
p.inputs["Roughness"].default_value = 0.22
p.inputs["Specular IOR Level"].default_value = 0.5
p.inputs["Coat Weight"].default_value = 0.0
p.inputs["Coat Roughness"].default_value = 0.2

base.data.materials.append(acrylic)
cap_ob.data.materials.append(plastic)
lens_ob.data.materials.append(lens_glass)

# ---------- Studio: white sweep, lights, camera ----------
bpy.ops.mesh.primitive_plane_add(size=60, location=(0, 0, 0))
floor = bpy.context.object
floor.name = "Sweep"
# bend the back half of the plane up into a seamless curve
me = floor.data
bm = bmesh.new(); bm.from_mesh(me)
bmesh.ops.subdivide_edges(bm, edges=bm.edges[:], cuts=60, use_grid_fill=True)
for v in bm.verts:
    if v.co.y > 6:
        d = v.co.y - 6
        ang = min(d / 8, 1) * math.pi / 2
        v.co.z = 8 * (1 - math.cos(ang)) + max(0, d - 8 * math.pi / 2)
        v.co.y = 6 + 8 * math.sin(ang) if d < 8 * math.pi / 2 else 14
bm.to_mesh(me); bm.free()
for poly in me.polygons:
    poly.use_smooth = True
white, p = principled("Backdrop")
p.inputs["Base Color"].default_value = (0.25, 0.25, 0.25, 1)
p.inputs["Roughness"].default_value = 0.8
# Camera and refracted rays see a bright white sweep; reflections see it dim,
# so the black plastic keeps its depth (a common product-shot cheat).
nt = white.node_tree
lp = nt.nodes.new("ShaderNodeLightPath")
emit = nt.nodes.new("ShaderNodeEmission")
emit.inputs["Strength"].default_value = 1.0
either = nt.nodes.new("ShaderNodeMath"); either.operation = 'MAXIMUM'
nt.links.new(lp.outputs["Is Camera Ray"], either.inputs[0])
nt.links.new(lp.outputs["Is Transmission Ray"], either.inputs[1])
mix = nt.nodes.new("ShaderNodeMixShader")
nt.links.new(either.outputs[0], mix.inputs["Fac"])
nt.links.new(nt.nodes["Principled BSDF"].outputs[0], mix.inputs[1])
nt.links.new(emit.outputs[0], mix.inputs[2])
nt.links.new(mix.outputs[0], nt.nodes["Material Output"].inputs["Surface"])
# Soft contact shadow: dim the white sweep where ambient occlusion finds the loupe nearby.
ao = nt.nodes.new("ShaderNodeAmbientOcclusion")
ao.inputs["Distance"].default_value = 1.8
ao.samples = 16
shade = nt.nodes.new("ShaderNodeMapRange")
shade.inputs["To Min"].default_value = 0.35
nt.links.new(ao.outputs["AO"], shade.inputs["Value"])
nt.links.new(shade.outputs["Result"], emit.inputs["Strength"])
floor.data.materials.append(white)

# Black flags just out of frame: the glass reflects and refracts them, which
# gives the clear base dark edges to read against the white sweep.
flag_mat, p = principled("Flag")
p.inputs["Base Color"].default_value = (0.0, 0.0, 0.0, 1)
p.inputs["Roughness"].default_value = 1.0
for name, x in (("FlagL", -4.2), ("FlagR", 4.2)):
    bpy.ops.mesh.primitive_plane_add(size=1, location=(x, 1.0, 2.5))
    flag = bpy.context.object
    flag.name = name
    flag.scale = (5, 4, 1)
    flag.rotation_euler = (0, math.radians(90), math.radians(-20 if x < 0 else 20))
    flag.data.materials.append(flag_mat)
    flag.visible_camera = False
    flag.visible_shadow = False

def area(name, loc, size, power, rot_target=(0, 0, 2.2)):
    bpy.ops.object.light_add(type='AREA', location=loc)
    l = bpy.context.object
    l.name = name
    l.data.size = size
    l.data.energy = power
    d = Vector(rot_target) - Vector(loc)
    l.rotation_euler = d.to_track_quat('-Z', 'Y').to_euler()
    return l

area("Key", (-10, -9, 12), 6, 2500)
area("Fill", (12, -6, 6), 5, 900)
area("Top", (0, 1, 16), 8, 1800)
area("Rim", (0, 14, 6), 6, 1200)

world = bpy.data.worlds.new("World")
scene.world = world
world.use_nodes = True
world.node_tree.nodes["Background"].inputs["Color"].default_value = (1, 1, 1, 1)
world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.02

bpy.ops.object.camera_add(location=(0, -21, 11.5))
cam = bpy.context.object
cam.data.lens = 100
cam.data.sensor_width = 36
d = Vector((0, 0, 1.9)) - cam.location
cam.rotation_euler = d.to_track_quat('-Z', 'Y').to_euler()
cam.data.dof.use_dof = True
cam.data.dof.focus_distance = d.length
cam.data.dof.aperture_fstop = 11
scene.camera = cam

# ---------- Render ----------
scene.render.engine = 'CYCLES'
try:
    prefs = bpy.context.preferences.addons['cycles'].preferences
    prefs.compute_device_type = 'METAL'
    prefs.get_devices()
    for dev in prefs.devices:
        dev.use = True
    scene.cycles.device = 'GPU'
except Exception as e:
    print("GPU unavailable:", e)
scene.cycles.samples = SAMPLES
scene.cycles.use_denoising = True
scene.cycles.max_bounces = 24
scene.cycles.transmission_bounces = 24
scene.cycles.glossy_bounces = 12
scene.cycles.caustics_reflective = False
scene.cycles.caustics_refractive = False
scene.view_settings.view_transform = 'Standard'
scene.view_settings.look = 'None'
scene.view_settings.exposure = 0.0
scene.render.resolution_x = 900
scene.render.resolution_y = 1000
scene.render.filepath = os.path.join(OUT, "loupe_render.png")
if ALPHA:
    # The sweep turns into a shadow catcher: only the loupe and its shadow
    # remain, and the glass lets the transparent background show through.
    floor.is_shadow_catcher = True
    scene.render.film_transparent = True
    scene.cycles.film_transparent_glass = True
    scene.render.image_settings.file_format = 'PNG'
    scene.render.image_settings.color_mode = 'RGBA'
    scene.render.filepath = os.path.join(OUT, "loupe_alpha.png")

if not ALPHA:
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT, "loupe.blend"))
bpy.ops.render.render(write_still=True)
