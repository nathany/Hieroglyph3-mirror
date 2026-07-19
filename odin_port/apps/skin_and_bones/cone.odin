// The procedurally generated, weighted, skinned cone plus the bone/animation
// machinery it drives — mirroring GeometryGeneratorDX11::
// GenerateWeightedSkinnedCone, AnimationStream (QuadraticInOut easing,
// play-once semantics), SkinnedBoneController, and SkinnedActor's skin-matrix
// bookkeeping.
package main

import "core:math"
import "core:math/linalg"

// Mirrors the generator's vertex element order: POSITION, BONEIDS,
// BONEWEIGHTS, TEXCOORDS, NORMAL — interleaved offsets 0/12/28/44/52,
// stride 64. Each vertex is influenced by (at most) two adjacent bones.
Skinned_Vertex :: struct {
	position: [3]f32,
	bone_ids: [4]i32,
	weights:  [4]f32,
	tex:      [2]f32,
	normal:   [3]f32,
}

// --- AnimationStream<Vector3f> ----------------------------------------------

// Keyframes are stored as parallel time/value arrays; `frame` is the index of
// the keyframe the stream is currently *leaving*, so the pair (frame,
// frame+1) brackets `time`. A stream with a single keyframe has no bracket at
// all and therefore stops on its very first update — that is how the position
// streams here stay pinned at the bind offset.
Anim_Stream :: struct {
	times:   [dynamic]f32,
	values:  [dynamic][3]f32,
	current: [3]f32,
	frame:   int,
	time:    f32,
	running: bool,
}

anim_destroy :: proc(s: ^Anim_Stream) {
	delete(s.times)
	delete(s.values)
}

anim_add :: proc(s: ^Anim_Stream, t: f32, v: [3]f32) {
	append(&s.times, t)
	append(&s.values, v)
	// AddState seeds the current value from the first keyframe so the bind
	// pose can be evaluated before any animation is played.
	if len(s.times) == 1 {
		s.current = v
	}
}

// AnimationStream::Play over the full range (PlayAllAnimations).
anim_play :: proc(s: ^Anim_Stream) {
	if len(s.times) == 0 {
		return
	}
	s.running = true
	s.frame = 0
	s.time = 0
	s.current = s.values[0]
}

// The engine's QuadraticInOut tween (Include/Tween.inl).
@(private = "file")
quadratic_in_out :: proc(start, end: [3]f32, t: f32) -> [3]f32 {
	t := t
	s: f32
	if t < 0.5 {
		t *= 2.0
		s = t * t * 0.5
	} else {
		t = (t - 1.0) * 2.0
		s = (1.0 - t * t) * 0.5 + 0.5
	}
	return start * (1.0 - s) + end * s
}

// AnimationStream::Update: advance, then either finish (play-once — the
// animation stops on its last frame until replayed with 'A') or ease between
// the bracketing keyframes.
anim_update :: proc(s: ^Anim_Stream, dt: f32) {
	if !s.running {
		return
	}
	end_frame := len(s.times) - 1
	s.time += dt
	if s.frame + 1 < len(s.times) {
		for s.frame < end_frame && s.times[s.frame + 1] < s.time {
			s.frame += 1
		}
	}
	if s.frame >= end_frame {
		s.frame = min(s.frame, end_frame)
		s.running = false
		s.current = s.values[s.frame]
	} else {
		numerator := s.time - s.times[s.frame]
		denominator := s.times[s.frame + 1] - s.times[s.frame]
		if denominator <= 0 {
			denominator = 0.1
		}
		s.current = quadratic_in_out(s.values[s.frame], s.values[s.frame + 1], numerator / denominator)
	}
}

// --- SkinnedBoneController / SkinnedActor ------------------------------------

// One bone = one C++ Node3D plus the SkinnedBoneController attached to it.
// The chain is flat: bone i's parent is bone i-1. `world` is rebuilt every
// frame; `inv_bind` is captured once and never touched again.
//
// The C++ controller also carries a bind *rotation* (added to the rotation
// stream's value the same way bind_position is added to the position
// stream's). It is zero for every bone in this sample, so it is omitted.
Bone :: struct {
	bind_position: [3]f32,
	pos_stream:    Anim_Stream,
	rot_stream:    Anim_Stream,
	world:         matrix[4, 4]f32,
	inv_bind:      matrix[4, 4]f32,
}

bones_destroy :: proc(bones: ^[dynamic]Bone) {
	for &b in bones {
		anim_destroy(&b.pos_stream)
		anim_destroy(&b.rot_stream)
	}
	delete(bones^)
}

// The engine's Euler composition is row-vector Rz*Rx*Ry; column-vector
// equivalent Ry*Rx*Rz.
@(private = "file")
euler_rotation :: proc(v: [3]f32) -> matrix[4, 4]f32 {
	return(
		linalg.matrix4_rotate_f32(v.y, {0, 1, 0}) *
		linalg.matrix4_rotate_f32(v.x, {1, 0, 0}) *
		linalg.matrix4_rotate_f32(v.z, {0, 0, 1}) \
	)
}

// SkinnedBoneController::Update + the node hierarchy walk: each bone's local
// transform is translate(bind + animated position) * rotate(animated
// rotation), chained down from the actor's node world.
bones_update :: proc(bones: []Bone, parent_world: matrix[4, 4]f32, dt: f32) {
	for &b, i in bones {
		anim_update(&b.pos_stream, dt)
		anim_update(&b.rot_stream, dt)
		local :=
			linalg.matrix4_translate_f32(b.bind_position + b.pos_stream.current) *
			euler_rotation(b.rot_stream.current)
		parent := parent_world if i == 0 else bones[i - 1].world
		b.world = parent * local
	}
}

// SkinnedActor::SetBindPose: capture inverse bind matrices with the chain in
// its bind configuration (the C++ does this before the app moves the actor
// nodes, so the parent here is identity).
//
// That identity parent is load-bearing, not incidental. Because inv_bind is
// captured with no node transform baked in, while the per-frame `world`
// below IS built under the actor's node transform, the product world *
// inv_bind carries the actor's translation and spin along with the bone's
// own motion. The node transform therefore rides *inside* the skin matrices,
// which is exactly why the shaders can ignore WorldMatrix. Capturing the
// bind pose after positioning the actor would cancel that out and leave all
// three actors stacked at the origin.
//
// dt is 0 so every stream reports its first keyframe; this stands in for the
// C++ controller's "skip the first update to allow the bind pose to be read".
bones_set_bind_pose :: proc(bones: []Bone) {
	bones_update(bones, 1, 0)
	for &b in bones {
		b.inv_bind = linalg.inverse(b.world)
	}
}

// SkinnedBoneController::GetTransform / GetNormalTransform, column-vector:
// skin = world * inv_bind; normal matrix = transpose(inverse(skin)).
//
// Read right to left: inv_bind lifts a vertex out of the bone's bind-pose
// frame into bone-local space, then world puts it back down wherever the
// bone has animated to. A bone that has not moved yields world == bind, so
// skin collapses to identity and its vertices sit still — the property the
// whole scheme rests on. The C++ writes the same product the other way round
// (m_InvBindPose * WorldMatrix) because the engine is row-vector.
//
// The separate normal matrix is the inverse-transpose, needed because the
// skin matrices are not pure rotations: they translate, and a chain of them
// can shear, which would tilt normals the wrong way under a plain rotate.
bone_skin_matrix :: proc(b: ^Bone) -> matrix[4, 4]f32 {
	return b.world * b.inv_bind
}

bone_skin_normal_matrix :: proc(b: ^Bone) -> matrix[4, 4]f32 {
	return linalg.transpose(linalg.inverse(bone_skin_matrix(b)))
}

bones_play_all :: proc(bones: []Bone) {
	for &b in bones {
		anim_play(&b.pos_stream)
		anim_play(&b.rot_stream)
	}
}

// GenerateWeightedSkinnedCone's bone setup: a vertical chain (bone 0 at the
// actor, the rest boneHeightStep apart), each with a static position stream
// and — for all but the root — a 6-second swinging rotation (eased between
// keyframes at 1s intervals).
make_bones :: proc(num_bones: int, height: f32) -> (bones: [dynamic]Bone) {
	bone_height_step := height / f32(num_bones)
	for i in 0 ..< num_bones {
		b: Bone
		if i != 0 {
			b.bind_position = {0, bone_height_step, 0}
		}
		anim_add(&b.pos_stream, 0, {0, 0, 0})
		anim_add(&b.rot_stream, 0, {0, 0, 0})
		// Every non-root bone runs the identical stream, so the small
		// per-bone rotations compound down the chain and the tip swings much
		// further than the base. The last keyframe returns to zero at t=6;
		// after that the stream stops (play-once) and the cone holds its
		// pose until 'A' replays it — preserved from the C++.
		if i > 0 {
			anim_add(&b.rot_stream, 1, {0.75, -0.25, 0})
			anim_add(&b.rot_stream, 2, {-0.75, 0.25, 0})
			anim_add(&b.rot_stream, 3, {0.75, -0.25, 0})
			anim_add(&b.rot_stream, 4, {-0.75, 0.25, 0})
			anim_add(&b.rot_stream, 5, {0.75, -0.25, 0})
			anim_add(&b.rot_stream, 6, {0, 0, 0})
		}
		append(&bones, b)
	}
	return
}

// --- The cone geometry --------------------------------------------------------

// GenerateWeightedSkinnedCone's mesh: an apex vertex, VRes rings of URes
// vertices widening toward the base, and a bottom-center vertex. Bone
// weights blend the two bones bracketing each vertex's height.
generate_skinned_cone :: proc(
	u_res, v_res: int,
	radius, height: f32,
	num_bones: int,
) -> (
	vertices: [dynamic]Skinned_Vertex,
	indices: [dynamic]u32,
) {
	num_vertex_rings := v_res
	bone_height_step := height / f32(num_bones)
	tex_scale := [2]f32{4.0 / (math.PI * 2.0), 12.0 / height}

	// Apex: fully weighted to the last bone.
	append(&vertices, Skinned_Vertex{
		position = {0, height, 0},
		bone_ids = {i32(num_bones - 1), 0, 0, 0},
		weights = {1, 0, 0, 0},
		tex = {0, 0},
		normal = {0, 1, 0},
	})

	for v in 0 ..< num_vertex_rings {
		for u in 0 ..< u_res {
			u_angle := f32(u) / f32(u_res) * math.PI * 2.0
			height_scale := f32(v) / f32(num_vertex_rings)
			x := math.cos(u_angle) * radius * height_scale
			y := height - height_scale * height
			z := math.sin(u_angle) * radius * height_scale

			// Bone assignment by height: b0 is the band the vertex falls in,
			// b1 the one above (clamped at the tip). The weights are already
			// normalized by construction — w1 is the fraction into the band
			// HALVED, so it only ever reaches 0.5, and w0 takes the rest.
			// The truncation to a whole band means each vertex blends the two
			// bones bracketing it and never more, matching the two populated
			// lanes of bone_ids/weights (lanes z and w stay zero, and the
			// shaders still evaluate them — weight 0 against bone 0).
			b0 := min(int(y / bone_height_step), num_bones - 1)
			b1 := min(b0 + 1, num_bones - 1)
			w1 := (y / bone_height_step - f32(b0)) / 2.0
			w0 := 1.0 - w1

			// The cone's surface normal, tilted by the slope (the v=0 ring
			// collapses onto the apex; its degenerate normal matches the C++).
			n := [3]f32{x, 0, z}
			n.y = math.atan(radius / height) * linalg.length(n)
			n = linalg.normalize(n)

			append(&vertices, Skinned_Vertex{
				position = {x, y, z},
				bone_ids = {i32(b0), i32(b1), 0, 0},
				weights = {w0, w1, 0, 0},
				tex = {tex_scale.x * u_angle, tex_scale.y * height_scale * height},
				normal = n,
			})
		}
	}

	// Bottom center: weighted to the root bone.
	append(&vertices, Skinned_Vertex{
		position = {0, 0, 0},
		bone_ids = {0, 0, 0, 0},
		weights = {1, 0, 0, 0},
		tex = {0, 0},
		normal = {0, 0, 1},
	})

	num_verts := num_vertex_rings * u_res + 2

	// Top fan around the apex.
	for u in 0 ..< u_res {
		next_u := (u + 1) % u_res
		append(&indices, 0, u32(next_u + 1), u32(u + 1))
	}
	// Ring quads.
	for v in 1 ..< v_res {
		top := 1 + (v - 1) * u_res
		bottom := top + u_res
		for u in 0 ..< u_res {
			next_u := (u + 1) % u_res
			curr_top := u32(top + u)
			next_top := u32(top + next_u)
			curr_bottom := u32(bottom + u)
			next_bottom := u32(bottom + next_u)
			append(&indices, curr_top, next_top, next_bottom)
			append(&indices, next_bottom, curr_bottom, curr_top)
		}
	}
	// Bottom fan around the center.
	{
		top := 1 + (v_res - 1) * u_res
		center := u32(num_verts - 1)
		for u in 0 ..< u_res {
			next_u := (u + 1) % u_res
			append(&indices, u32(top + next_u), center, u32(top + u))
		}
	}

	return
}

// --- The bone axis gizmos -----------------------------------------------------

// GenerateAxisGeometry: three colored spikes (X red, Y green, Z blue), each a
// 4-sided pyramid from a small base quad to a tip 3 units out. Vertex is
// POSITION + COLOR (28 bytes), drawn with VertexColor.hlsl.
Axis_Vertex :: struct {
	position: [3]f32,
	color:    [4]f32,
}

AXIS_THICKNESS :: 0.05
AXIS_LENGTH :: 3.0

axis_vertices := [15]Axis_Vertex{
	// X spike (red)
	{{0, AXIS_THICKNESS, AXIS_THICKNESS}, {1, 0, 0, 1}},
	{{0, -AXIS_THICKNESS, AXIS_THICKNESS}, {1, 0, 0, 1}},
	{{0, -AXIS_THICKNESS, -AXIS_THICKNESS}, {1, 0, 0, 1}},
	{{0, AXIS_THICKNESS, -AXIS_THICKNESS}, {1, 0, 0, 1}},
	{{AXIS_LENGTH, 0, 0}, {1, 0, 0, 1}},
	// Y spike (green)
	{{AXIS_THICKNESS, 0, AXIS_THICKNESS}, {0, 1, 0, 1}},
	{{-AXIS_THICKNESS, 0, AXIS_THICKNESS}, {0, 1, 0, 1}},
	{{-AXIS_THICKNESS, 0, -AXIS_THICKNESS}, {0, 1, 0, 1}},
	{{AXIS_THICKNESS, 0, -AXIS_THICKNESS}, {0, 1, 0, 1}},
	{{0, AXIS_LENGTH, 0}, {0, 1, 0, 1}},
	// Z spike (blue)
	{{AXIS_THICKNESS, AXIS_THICKNESS, 0}, {0, 0, 1, 1}},
	{{-AXIS_THICKNESS, AXIS_THICKNESS, 0}, {0, 0, 1, 1}},
	{{-AXIS_THICKNESS, -AXIS_THICKNESS, 0}, {0, 0, 1, 1}},
	{{AXIS_THICKNESS, -AXIS_THICKNESS, 0}, {0, 0, 1, 1}},
	{{0, 0, AXIS_LENGTH}, {0, 0, 1, 1}},
}

axis_indices := [36]u32{
	0, 1, 4, 1, 2, 4, 2, 3, 4, 3, 0, 4, // X
	5, 6, 9, 6, 7, 9, 7, 8, 9, 8, 5, 9, // Y
	10, 11, 14, 11, 12, 14, 12, 13, 14, 13, 10, 14, // Z
}
