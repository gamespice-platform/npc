class_name GSNpcGibs
extends RefCounted

## What a severed limb looks like: the limb's own triangles as a tumbling body, a raw stump on what is left, and blood.
## Drawn only; the server decides what came off ([GSNpcLimbs]). The limb is cut out of the model by vertex weight,
## not by scaling bones on a copy, which leaves stretched slivers; the skinned body hides it by collapsing its root bone.

## The default cap; the live one is [member GSNpcGore.max_gibs].
const MAX_GIBS := GSNpcGore.DEFAULT_MAX_GIBS
const GROUP := &"gs_npc_gibs"

static var _mesh_cache: Dictionary = {}
## A whole mesh's id and the bone collapsed -> the mesh that cut leaves, or null when it drops nothing.
static var _collapse_cache: Dictionary = {}
const COLLAPSE_CACHE_MAX := 256
const PRISTINE := &"gs_npc_pristine_mesh"
const COLLAPSED := &"gs_npc_collapsed_bones"
const STUMP_PREFIX := "Stump_"
const WOUND_PREFIX := "Wound_"
const WOUND_GROUP := &"gs_npc_wounds"
const POOL_SECONDS := 25.0

static var _blob_mat: StandardMaterial3D = null
static var _blob_mesh: SphereMesh = null
static var _pool_mat: StandardMaterial3D = null
static var _pool_mesh: CylinderMesh = null


static func drawn() -> bool:
	return DisplayServer.get_name() != "headless"


## Bone indices of [param root] and everything below it.
static func subtree(sk: Skeleton3D, root: int) -> Dictionary:
	var out := {root: true}
	var grew := true
	while grew:
		grew = false
		for i in sk.get_bone_count():
			if not out.has(i) and out.has(sk.get_bone_parent(i)):
				out[i] = true
				grew = true
	return out


## Vertices of one surface as the skeleton currently poses them.
static func skinned(sk: Skeleton3D, mi: MeshInstance3D, arrays: Array) -> PackedVector3Array:
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var out := verts.duplicate()
	var bi: Variant = arrays[Mesh.ARRAY_BONES]
	var wi: Variant = arrays[Mesh.ARRAY_WEIGHTS]
	var skin: Skin = mi.skin
	if verts.is_empty() or skin == null or not (bi is PackedInt32Array) or not (wi is PackedFloat32Array):
		return out
	var per := (bi as PackedInt32Array).size() / verts.size()
	var mats := []
	for i in skin.get_bind_count():
		var b := skin.get_bind_bone(i)
		if b < 0:
			b = sk.find_bone(skin.get_bind_name(i))
		mats.append(sk.get_bone_global_pose(b) * skin.get_bind_pose(i) if b >= 0 else Transform3D.IDENTITY)
	for v in verts.size():
		var p := Vector3.ZERO
		var total := 0.0
		for k in per:
			var w: float = (wi as PackedFloat32Array)[v * per + k]
			var bind: int = (bi as PackedInt32Array)[v * per + k]
			if w > 0.0 and bind < mats.size():
				p += (mats[bind] as Transform3D) * verts[v] * w
				total += w
		if total > 0.0:
			out[v] = p / total
	return out


static func _longest_edge(p: PackedVector3Array, a: int, b: int, c: int) -> float:
	return maxf(p[a].distance_to(p[b]), maxf(p[b].distance_to(p[c]), p[c].distance_to(p[a])))


## Collapses [param root]'s bone and drops every triangle of the drawn body the collapse would drag into a sheet
## (its longest edge grows past [param grow] times and by a visible amount). Each body gets its own mesh copy,
## so the shared resource stays whole.
static func collapse_bone(sk: Skeleton3D, model: Node, root: int, grow := 2.0) -> void:
	var meshes: Array = []
	var reused: Array = []
	for m in model.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		if mi.mesh is ArrayMesh and mi.skin != null:
			# A whole body of a kind cuts the same way: the first cut's mesh serves the rest, so a
			# sever stops being two script skinning passes over every vertex (about 8 ms each).
			var key := "" if mi.has_meta(PRISTINE) else "%d|%d" % [mi.mesh.get_instance_id(), root]
			if key != "" and _collapse_cache.has(key):
				reused.append([mi, _collapse_cache[key]])
				continue
			var before := []
			for s in mi.mesh.get_surface_count():
				before.append(skinned(sk, mi, mi.mesh.surface_get_arrays(s)))
			meshes.append([mi, before, key])
	sk.set_bone_pose_scale(root, Vector3.ONE * 0.001)
	var gone: Array = sk.get_meta(COLLAPSED, [])
	gone.append(root)
	sk.set_meta(COLLAPSED, gone)
	for entry in reused:
		var mi: MeshInstance3D = entry[0]
		mi.set_meta(PRISTINE, mi.mesh)
		if entry[1] != null:
			mi.mesh = entry[1]
	for entry in meshes:
		var mi: MeshInstance3D = entry[0]
		if not mi.has_meta(PRISTINE):
			mi.set_meta(PRISTINE, mi.mesh)
		var src := mi.mesh as ArrayMesh
		var dst := ArrayMesh.new()
		var changed := false
		var floor_len := src.get_aabb().get_longest_axis_size() * 0.03
		for s in src.get_surface_count():
			var arrays := src.surface_get_arrays(s)
			var mat := src.surface_get_material(s)
			var after := skinned(sk, mi, arrays)
			var was: PackedVector3Array = entry[1][s]
			var idx: Variant = arrays[Mesh.ARRAY_INDEX]
			var tris: PackedInt32Array = idx if idx is PackedInt32Array else PackedInt32Array(range(after.size()))
			var kept := PackedInt32Array()
			for t in range(0, tris.size() - 2, 3):
				var e0 := _longest_edge(was, tris[t], tris[t + 1], tris[t + 2])
				var e1 := _longest_edge(after, tris[t], tris[t + 1], tris[t + 2])
				if e1 > e0 * grow and e1 - e0 > floor_len:
					continue
				kept.append_array(tris.slice(t, t + 3))
			if kept.size() != tris.size():
				changed = true
			arrays[Mesh.ARRAY_INDEX] = kept if not kept.is_empty() else PackedInt32Array([0, 0, 0])
			dst.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, src.surface_get_format(s) & Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS)
			dst.surface_set_material(s, mat)
		if changed:
			mi.mesh = dst
		if entry[2] != "":
			if _collapse_cache.size() >= COLLAPSE_CACHE_MAX:
				_collapse_cache.clear()
			_collapse_cache[entry[2]] = dst if changed else null


## The limb's triangles in skeleton space, centred on its joint, or null when it has none.
static func limb_mesh(sk: Skeleton3D, model: Node, root: int, key: String) -> ArrayMesh:
	# Species/limb alone would serve a variant model another model's gib.
	for m in model.find_children("*", "MeshInstance3D", true, false):
		var src: Mesh = (m as MeshInstance3D).get_meta(PRISTINE, (m as MeshInstance3D).mesh)
		if src != null:
			key += "#%d" % src.get_instance_id()
			break
	if _mesh_cache.has(key):
		return _mesh_cache[key]
	var in_limb := subtree(sk, root)
	var centre := sk.get_bone_global_rest(root).origin
	var mesh := ArrayMesh.new()
	for m in model.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		# The pristine mesh, never one an earlier sever trimmed: the gib is the whole limb.
		var src: Mesh = mi.get_meta(PRISTINE, mi.mesh)
		if src == null:
			continue
		for s in src.get_surface_count():
			var arrays := src.surface_get_arrays(s)
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var bones: Variant = arrays[Mesh.ARRAY_BONES]
			var weights: Variant = arrays[Mesh.ARRAY_WEIGHTS]
			var idx: Variant = arrays[Mesh.ARRAY_INDEX]
			if verts.is_empty() or not (bones is PackedInt32Array) or not (weights is PackedFloat32Array):
				continue
			var per := (bones as PackedInt32Array).size() / verts.size()
			var skin: Skin = mi.skin
			var inside := PackedByteArray()
			inside.resize(verts.size())
			for v in verts.size():
				var w := 0.0
				for k in per:
					var b: int = (bones as PackedInt32Array)[v * per + k]
					if skin != null and b < skin.get_bind_count():
						var named := skin.get_bind_bone(b)
						b = named if named >= 0 else sk.find_bone(skin.get_bind_name(b))
					if in_limb.has(b):
						w += (weights as PackedFloat32Array)[v * per + k]
				inside[v] = 1 if w >= 0.5 else 0
			var tris: PackedInt32Array = idx if idx is PackedInt32Array else PackedInt32Array(range(verts.size()))
			var remap := {}
			var out := {}
			for key_name in [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_TEX_UV]:
				out[key_name] = []
			var out_idx := PackedInt32Array()
			var normals: Variant = arrays[Mesh.ARRAY_NORMAL]
			var uvs: Variant = arrays[Mesh.ARRAY_TEX_UV]
			for t in range(0, tris.size() - 2, 3):
				if not (inside[tris[t]] and inside[tris[t + 1]] and inside[tris[t + 2]]):
					continue
				for c in 3:
					var v := tris[t + c]
					if not remap.has(v):
						remap[v] = (out[Mesh.ARRAY_VERTEX] as Array).size()
						(out[Mesh.ARRAY_VERTEX] as Array).append(verts[v] - centre)
						if normals is PackedVector3Array:
							(out[Mesh.ARRAY_NORMAL] as Array).append((normals as PackedVector3Array)[v])
						if uvs is PackedVector2Array:
							(out[Mesh.ARRAY_TEX_UV] as Array).append((uvs as PackedVector2Array)[v])
					out_idx.append(remap[v])
			if out_idx.is_empty():
				continue
			var a: Array = []
			a.resize(Mesh.ARRAY_MAX)
			a[Mesh.ARRAY_VERTEX] = PackedVector3Array(out[Mesh.ARRAY_VERTEX])
			if not (out[Mesh.ARRAY_NORMAL] as Array).is_empty():
				a[Mesh.ARRAY_NORMAL] = PackedVector3Array(out[Mesh.ARRAY_NORMAL])
			if not (out[Mesh.ARRAY_TEX_UV] as Array).is_empty():
				a[Mesh.ARRAY_TEX_UV] = PackedVector2Array(out[Mesh.ARRAY_TEX_UV])
			a[Mesh.ARRAY_INDEX] = out_idx
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a)
			var mat := mi.get_surface_override_material(s)
			if mat == null:
				mat = src.surface_get_material(s)
			if mat != null and drawn():
				mesh.surface_set_material(mesh.get_surface_count() - 1, mat)
	var result: ArrayMesh = mesh if mesh.get_surface_count() > 0 else null
	_mesh_cache[key] = result
	return result


static func world_of(view: Node) -> Node:
	var tree := view.get_tree()
	return tree.current_scene if tree.current_scene != null else tree.root


static func flesh_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.42, 0.03, 0.05)
	m.roughness = 0.22
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.emission_enabled = true
	m.emission = Color(0.25, 0.0, 0.02)
	return m


static func bone_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.86, 0.82, 0.7)
	m.roughness = 0.6
	return m


static func blood(burst: bool, dir: Vector3, style := GSNpcGore.STYLE_GENERIC) -> CPUParticles3D:
	var sp := GSNpcGore.style_params(style)
	var p := CPUParticles3D.new()
	p.amount = maxi(int((40 if burst else 10) * GSNpcGore.spray_scale() * (float(sp["amount"]) if burst else 1.0)), 4)
	p.lifetime = 0.9 if burst else 0.8
	p.one_shot = burst
	p.explosiveness = 0.95 if burst else 0.0
	p.local_coords = false
	# Along the blow with a little lift: a jet goes the way the shot went, not straight up.
	p.direction = (dir.normalized() + Vector3.UP * 0.3).normalized() if dir.length() > 0.01 else Vector3.UP
	p.spread = float(sp["spread"]) if burst else 25.0
	var v := float(sp["speed"])
	p.initial_velocity_min = (2.0 if burst else 0.2) * v
	p.initial_velocity_max = (6.0 if burst else 1.0) * v
	p.gravity = Vector3(0.0, -9.8, 0.0)
	# Streaks, not beads: thin, long, aligned to their travel and varied in size.
	p.particle_flag_align_y = true
	p.scale_amount_min = 0.4
	p.scale_amount_max = 1.5
	p.mesh = _streak()
	return p


static var _streak_mesh: CapsuleMesh


static func _streak() -> CapsuleMesh:
	if _streak_mesh == null:
		_streak_mesh = CapsuleMesh.new()
		_streak_mesh.radius = 0.011
		_streak_mesh.height = 0.085
		_streak_mesh.radial_segments = 5
		_streak_mesh.rings = 1
		_streak_mesh.material = flesh_material()
	return _streak_mesh


## Spawns the limb as a body in the world, at [param joint_world], and returns it (null headless or with
## nothing to draw).
static func spawn_gib(sk: Skeleton3D, model: Node, key: String, root: int, limb: StringName, d: Dictionary, joint_world: Vector3, impulse: Vector3) -> Node3D:
	if not drawn():
		return null
	var mesh := limb_mesh(sk, model, root, key)
	var world := world_of(sk)
	if not GSNpcGore.gibs_enabled():
		return null
	# At the cap the oldest gib is reused, not freed and rebuilt: a crowd of kills costs no allocation churn.
	# A gib already freed this frame is still in the group: never count or reuse it.
	var live := world.get_tree().get_nodes_in_group(GROUP).filter(func(n: Node) -> bool: return not n.is_queued_for_deletion())
	var gib: RigidBody3D = null
	while GSNpcGore.max_gibs > 0 and live.size() >= GSNpcGore.max_gibs:
		var oldest := live[0] as RigidBody3D
		live.remove_at(0)
		if gib == null and oldest != null:
			gib = oldest
			for c in gib.get_children():
				gib.remove_child(c)
				c.queue_free()
		else:
			live_free(oldest)
	if gib == null:
		gib = RigidBody3D.new()
		gib.add_to_group(GROUP)
		gib.collision_layer = 0
		gib.collision_mask = 1
		world.add_child(gib)
	else:
		world.move_child(gib, -1)
	gib.name = "Gib_%s" % limb
	gib.sleeping = false
	gib.mass = float(d.get("gib_mass", 20.0))
	gib.global_transform = Transform3D(sk.global_transform.basis.orthonormalized(), joint_world)
	if mesh != null:
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		gib.add_child(mi)
		var box := BoxShape3D.new()
		var aabb := mesh.get_aabb()
		box.size = aabb.size.max(Vector3.ONE * 0.1) * 0.7
		var cs := CollisionShape3D.new()
		cs.shape = box
		cs.position = aabb.get_center()
		gib.add_child(cs)
	var par := sk.get_bone_parent(root)
	var out := sk.get_bone_global_rest(root).origin - sk.get_bone_global_rest(par).origin if par >= 0 else Vector3.UP
	var cap := cut_face(stump_radius(d), -out.normalized() if out.length() > 0.001 else Vector3.DOWN)
	gib.add_child(cap)
	var style := GSNpcGore.hit_style
	var sp := GSNpcGore.style_params(style)
	# The throw follows the blow: its direction scaled by the weapon, a hop up, and scatter that grows with spread.
	var scatter := float(sp["spread"]) / 55.0
	gib.linear_velocity = impulse * float(sp["throw"]) + Vector3(randf_range(-1.0, 1.0) * scatter, float(sp["lift"]) * randf_range(0.8, 1.2), randf_range(-1.0, 1.0) * scatter)
	var spin := float(sp["spin"])
	gib.angular_velocity = Vector3(randf_range(-spin, spin), randf_range(-spin, spin), randf_range(-spin, spin))
	var spray := blood(true, impulse, style)
	if GSNpcGore.spray_enabled():
		gib.add_child(spray)
		spray.emitting = true
	else:
		spray.free()
	var life := float(d.get("gib_seconds", 14.0))
	var until := Time.get_ticks_msec() + int(life * 1000.0)
	gib.set_meta(&"gs_npc_gib_until", until)
	gib.get_tree().create_timer(life).timeout.connect(_free_weak.bind(weakref(gib), until))
	return gib


## A raw cut on the part left behind, riding the parent bone: a flat-capped collar of flesh facing along the
## limb, a ring of pale muscle, a bone disc with a dark marrow dot, and a drip for a few seconds.
static func add_stump(sk: Skeleton3D, root: int, d: Dictionary, drip_blood := true) -> Node3D:
	if not drawn():
		return null
	var parent := sk.get_bone_parent(root)
	if parent < 0:
		return null
	var att := BoneAttachment3D.new()
	att.name = "%s%s" % [STUMP_PREFIX, sk.get_bone_name(root)]
	sk.add_child(att)
	att.bone_idx = parent
	var at := sk.get_bone_global_rest(parent).affine_inverse() * sk.get_bone_global_rest(root).origin
	var r := stump_radius(d)
	var dir := at.normalized() if at.length() > 0.001 else Vector3.UP
	var cut := cut_face(r, dir)
	cut.position = at + dir * r * 0.45
	att.add_child(cut)
	if not drip_blood:
		return att
	var drip := blood(false, Vector3.ZERO)
	drip.position = at
	att.add_child(drip)
	drip.emitting = true
	(Engine.get_main_loop() as SceneTree).create_timer(4.0).timeout.connect(_stop_weak.bind(weakref(drip)))
	return att


## Radius of a cut face for a limb whose region is [param d]: wide enough to read as a wound from across a room.
static func stump_radius(d: Dictionary) -> float:
	return clampf(float(d.get("radius", 0.3)) * 0.55, 0.07, 0.2)


## The cut itself at the origin, facing [param dir]: a ragged, closed collar of torn flesh behind a torn face, a
## ring of pale muscle, an uneven bone disc with a dark marrow pit. Meshes are shared by variant and scaled.
static func cut_face(r: float, dir: Vector3) -> Node3D:
	var cut := Node3D.new()
	var variant := randi() % CAP_VARIANTS
	cut.transform = Transform3D(Basis(Quaternion(Vector3.UP, dir)) * Basis(Vector3.UP, randf() * TAU) * Basis.from_scale(Vector3.ONE * r), Vector3.ZERO)
	cut.add_child(_cap_part(variant, "collar", flesh_material(), Vector3.ZERO))
	cut.add_child(_cap_part(variant, "face", flesh_material(), Vector3.ZERO))
	cut.add_child(_cap_part(variant, "muscle", muscle_material(), Vector3(0.0, 0.02, 0.0)))
	cut.add_child(_cap_part(variant, "bone", bone_material(), Vector3(0.0, 0.06, 0.0)))
	cut.add_child(_cap_part(variant, "marrow", marrow_material(), Vector3(0.0, 0.085, 0.0)))
	return cut


const CAP_VARIANTS := 4
const CAP_SEGMENTS := 16
static var _cap_meshes: Dictionary = {}


static func _cap_part(variant: int, part: String, mat: Material, at: Vector3) -> MeshInstance3D:
	var key := "%d/%s" % [variant, part]
	if not _cap_meshes.has(key):
		_cap_meshes[key] = _build_cap(variant, part)
	var mi := MeshInstance3D.new()
	mi.mesh = _cap_meshes[key]
	mi.material_override = mat
	mi.position = at
	return mi


## One part of a unit-radius cut: a torn outline (radius jittered per segment) filled as a fan, so there is no
## hole and no perfect circle. The collar is the wall dropping from the face, closed at the bottom.
static func _build_cap(variant: int, part: String) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7919 * (variant + 1)
	var scale_of := {"collar": 1.0, "face": 1.0, "muscle": 0.8, "bone": 0.32, "marrow": 0.13}
	var jitter := {"collar": 0.16, "face": 0.16, "muscle": 0.12, "bone": 0.1, "marrow": 0.0}
	var base: float = scale_of[part]
	var j: float = jitter[part]
	var ring := PackedVector3Array()
	var outer := PackedFloat32Array()
	# The outline of the face is shared by all parts of a variant so the layers sit inside each other.
	var rng_face := RandomNumberGenerator.new()
	rng_face.seed = 104729 * (variant + 1)
	for i in CAP_SEGMENTS:
		outer.append(1.0 + rng_face.randf_range(-0.16, 0.16))
	for i in CAP_SEGMENTS:
		var ang := TAU * float(i) / CAP_SEGMENTS
		var rad := base * (outer[i] if part != "bone" and part != "marrow" else 1.0 + rng.randf_range(-j, j))
		if part == "muscle":
			rad = base * outer[i] * (1.0 + rng.randf_range(-j, j) * 0.5)
		ring.append(Vector3(cos(ang) * rad, 0.0, sin(ang) * rad))
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var idx := PackedInt32Array()
	if part == "collar":
		var depth := 1.5
		for i in CAP_SEGMENTS:
			var p := ring[i]
			verts.append(p)
			norms.append(Vector3(p.x, 0.0, p.z).normalized())
			verts.append(Vector3(p.x * 0.85, -depth, p.z * 0.85))
			norms.append(Vector3(p.x, 0.0, p.z).normalized())
		for i in CAP_SEGMENTS:
			var n := (i + 1) % CAP_SEGMENTS
			idx.append_array([i * 2, n * 2, i * 2 + 1, n * 2, n * 2 + 1, i * 2 + 1])
		# Closed at the far end so a thrown gib is solid from any side.
		var c := verts.size()
		verts.append(Vector3(0.0, -depth, 0.0))
		norms.append(Vector3.DOWN)
		for i in CAP_SEGMENTS:
			idx.append_array([c, i * 2 + 1, ((i + 1) % CAP_SEGMENTS) * 2 + 1])
	else:
		var wob := 0.04 if part == "face" else 0.0
		verts.append(Vector3(0.0, wob, 0.0))
		norms.append(Vector3.UP)
		for i in CAP_SEGMENTS:
			var p := ring[i]
			p.y = rng.randf_range(-wob, wob) if part == "face" else 0.0
			verts.append(p)
			norms.append(Vector3.UP)
		for i in CAP_SEGMENTS:
			idx.append_array([0, 1 + (i + 1) % CAP_SEGMENTS, 1 + i])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


static func muscle_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.72, 0.2, 0.2)
	m.roughness = 0.35
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


static func marrow_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.3, 0.02, 0.03)
	m.roughness = 0.3
	return m


## Takes a limb off a drawn body: throws it as a gib, collapses its root bone and covers the cut. Returns the
## joint in world space, or `Vector3.INF` when the limb names no bone. [param key] names the cached limb mesh
## (definition id plus limb).
static func sever(sk: Skeleton3D, model: Node, key: String, limb: StringName, d: Dictionary, impulse: Vector3, silent := false) -> Vector3:
	var bones: Array = d.get("bones", [])
	var root := sk.find_bone(String(bones[0])) if not bones.is_empty() else -1
	if root < 0:
		return Vector3.INF
	var joint := sk.global_transform * sk.get_bone_global_pose(root).origin
	if not silent:
		spawn_gib(sk, model, key, root, limb, d, joint, impulse)
	collapse_bone(sk, model, root)
	add_stump(sk, root, d, not silent and GSNpcGore.spray_enabled())
	return joint


static func live_free(n: Node) -> void:
	if n != null:
		n.queue_free()


## Undoes every [method sever] on [param sk]: bones back to full scale, the drawn meshes whole, stumps gone.
## [param model] limits the mesh restore to that scene (default: the skeleton's siblings under its parent).
static func restore(sk: Skeleton3D, model: Node = null) -> void:
	for b in sk.get_meta(COLLAPSED, []):
		sk.set_bone_pose_scale(int(b), Vector3.ONE)
	sk.remove_meta(COLLAPSED)
	for c in sk.get_children():
		if c is BoneAttachment3D and (String(c.name).begins_with(STUMP_PREFIX) or String(c.name).begins_with(WOUND_PREFIX)):
			sk.remove_child(c)
			c.queue_free()
	var scope: Node = model if model != null else (sk.owner if sk.owner != null else sk.get_parent())
	if scope == null:
		return
	for m in scope.find_children("*", "MeshInstance3D", true, false):
		if m.has_meta(PRISTINE):
			m.mesh = m.get_meta(PRISTINE)
			m.remove_meta(PRISTINE)


## Timer callbacks hold a WeakRef: a lambda capturing the node itself logs "Lambda capture was freed" when the node is gone first.
static func _free_weak(ref: WeakRef, until := -1) -> void:
	var n := ref.get_ref() as Node
	# A recycled gib carries a later expiry; the timer of its first life must not cut the second short.
	if n != null and (until < 0 or int(n.get_meta(&"gs_npc_gib_until", until)) == until):
		n.queue_free()


static func _stop_weak(ref: WeakRef) -> void:
	var p := ref.get_ref() as CPUParticles3D
	if p != null:
		p.emitting = false


## Frees the oldest wound marks and pools until there is room for one more under [member GSNpcGore.max_wounds].
static func _make_room(tree: SceneTree) -> void:
	if GSNpcGore.max_wounds <= 0:
		return
	var live := tree.get_nodes_in_group(WOUND_GROUP)
	while live.size() >= GSNpcGore.max_wounds and not live.is_empty():
		var oldest := live[0] as Node
		live.remove_at(0)
		oldest.get_parent().remove_child(oldest)
		oldest.queue_free()


## A wet mark on the body where it was hit, riding the nearest bone. Pooled and capped; null headless, with gore
## off, or when no bone is near. [param world_point] is on or near the surface.
static func add_wound(sk: Skeleton3D, world_point: Vector3, size := 0.09) -> Node3D:
	if not drawn() or not GSNpcGore.wounds_enabled() or sk == null or not sk.is_inside_tree():
		return null
	var local := sk.global_transform.affine_inverse() * world_point
	var best := -1
	var best_d := INF
	var gone: Array = sk.get_meta(COLLAPSED, [])
	for i in sk.get_bone_count():
		if gone.has(i):
			continue
		var gap := sk.get_bone_global_pose(i).origin.distance_squared_to(local)
		if gap < best_d:
			best_d = gap
			best = i
	if best < 0:
		return null
	_make_room(sk.get_tree())
	if _blob_mat == null:
		_blob_mat = StandardMaterial3D.new()
		_blob_mat.albedo_color = Color(0.32, 0.01, 0.03)
		_blob_mat.roughness = 0.15
		_blob_mesh = SphereMesh.new()
		_blob_mesh.radius = 1.0
		_blob_mesh.height = 2.0
		_blob_mesh.radial_segments = 8
		_blob_mesh.rings = 4
		_blob_mesh.material = _blob_mat
	var att := BoneAttachment3D.new()
	att.name = "%s%d" % [WOUND_PREFIX, best]
	att.add_to_group(WOUND_GROUP)
	sk.add_child(att)
	att.bone_idx = best
	var mark := MeshInstance3D.new()
	mark.mesh = _blob_mesh
	var bone_local := sk.get_bone_global_pose(best).affine_inverse() * local
	var out := bone_local.normalized() if bone_local.length() > 0.001 else Vector3.UP
	var up := Vector3.UP if absf(out.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
	var basis := Basis.looking_at(out, up) * Basis.from_scale(Vector3(size, size * 0.8, size * 0.22))
	mark.transform = Transform3D(basis, bone_local)
	att.add_child(mark)
	return att


## A pool of blood on the floor at [param at] (a crawling body's trail): flat, shared mesh and material, capped
## with the wound marks and gone after [constant POOL_SECONDS]. Null headless or with gore off.
static func add_pool(tree: SceneTree, at: Vector3, radius := 0.22) -> Node3D:
	if not drawn() or not GSNpcGore.wounds_enabled() or tree == null:
		return null
	_make_room(tree)
	if _pool_mat == null:
		_pool_mat = StandardMaterial3D.new()
		_pool_mat.albedo_color = Color(0.28, 0.0, 0.02)
		_pool_mat.roughness = 0.1
		_pool_mesh = CylinderMesh.new()
		_pool_mesh.top_radius = 1.0
		_pool_mesh.bottom_radius = 1.0
		_pool_mesh.height = 0.004
		_pool_mesh.radial_segments = 10
		_pool_mesh.rings = 1
		_pool_mesh.material = _pool_mat
	var pool := MeshInstance3D.new()
	pool.mesh = _pool_mesh
	pool.add_to_group(WOUND_GROUP)
	pool.scale = Vector3(radius, 1.0, radius * 0.8)
	pool.rotation.y = randf() * TAU
	pool.position = at + Vector3(0.0, 0.012, 0.0)
	pool.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	(tree.current_scene if tree.current_scene != null else tree.root).add_child(pool)
	tree.create_timer(POOL_SECONDS).timeout.connect(_free_weak.bind(weakref(pool)))
	return pool
