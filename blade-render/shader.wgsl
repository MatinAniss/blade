const MAX_BOUNCES: i32 = 3;

struct Parameters {
    cam_position: vec3<f32>,
    depth: f32,
    cam_orientation: vec4<f32>,
    fov: vec2<f32>,
};

// Has to match the host!
struct Vertex {
    pos: vec3<f32>,
    normal: u32,
    tex_coords: vec2<f32>,
    pad: vec2<f32>,
}
struct VertexBuffer {
    data: array<Vertex>,
}
struct IndexBuffer {
    data: array<u32>,
}
var<storage, read> vertex_buffers: binding_array<VertexBuffer, 1>;
var<storage, read> index_buffers: binding_array<IndexBuffer, 1>;

struct HitEntry {
    index_buf: u32,
    vertex_buf: u32,
    // packed object->world rotation quaternion
    rotation: u32,
    //geometry_to_object_rm: mat3x4<f32>,
}
var<storage, read> hit_entries: array<HitEntry>;

var<uniform> parameters: Parameters;
var acc_struct: acceleration_structure;


var output: texture_storage_2d<rgba8unorm, write>;

fn qrot(q: vec4<f32>, v: vec3<f32>) -> vec3<f32> {
    return v + 2.0*cross(q.xyz, cross(q.xyz,v) + q.w*v);
}

fn compute_hit_color(ri: RayIntersection, hit_world: vec3<f32>) -> vec4<f32> {
    let entry = hit_entries[ri.instance_custom_index + ri.geometry_index];

    var indices = ri.primitive_index * 3u + vec3<u32>(0u, 1u, 2u);
    if (entry.index_buf != ~0u) {
        let iptr = &index_buffers[entry.index_buf].data;
        indices = vec3<u32>((*iptr)[indices.x], (*iptr)[indices.y], (*iptr)[indices.z]);
    }

    let vptr = &vertex_buffers[entry.vertex_buf].data;
    let vertices = array<Vertex, 3>(
        (*vptr)[indices.x],
        (*vptr)[indices.y],
        (*vptr)[indices.z],
    );

    let barycentrics = vec3<f32>(1.0 - ri.barycentrics.x - ri.barycentrics.y, ri.barycentrics);
    let pos_object = mat3x3(vertices[0].pos, vertices[1].pos, vertices[2].pos) * barycentrics;
    let pos_world = ri.object_to_world * vec4<f32>(pos_object, 1.0);
    let tex_coords = mat3x2(vertices[0].tex_coords, vertices[1].tex_coords, vertices[2].tex_coords) * barycentrics;
    let normal_rough = mat3x2(unpack2x16snorm(vertices[0].normal), unpack2x16snorm(vertices[1].normal), unpack2x16snorm(vertices[2].normal)) * barycentrics;
    let normal_object = vec3<f32>(normal_rough, sqrt(1.0 - dot(normal_rough, normal_rough)));
    let object_to_world_rot = normalize(unpack4x8snorm(entry.rotation));
    let normal_world = qrot(object_to_world_rot, normal_object);

    // Note: this line allows to check the correctness of data passed in
    //return vec4<f32>(abs(pos_world - hit_world) * 1000000.0, 1.0);
    return vec4<f32>(normal_world, 1.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    let target_size = textureDimensions(output);
    let half_size = vec2<f32>(target_size >> vec2<u32>(1u));
    let ndc = (vec2<f32>(global_id.xy) - half_size) / half_size;
    if (any(global_id.xy > target_size)) {
        return;
    }

    let local_dir = vec3<f32>(ndc * tan(parameters.fov), 1.0);
    let world_dir = normalize(qrot(parameters.cam_orientation, local_dir));

    var rq: ray_query;
    var ray_pos = parameters.cam_position;
    var ray_dir = world_dir;
    rayQueryInitialize(&rq, acc_struct, RayDesc(0u, 0xFFu, 0.1, parameters.depth, ray_pos, ray_dir));
    var iterations = 0u;
    while (rayQueryProceed(&rq)) {iterations += 1u;}
    let intersection = rayQueryGetCommittedIntersection(&rq);

    var color = vec4<f32>(0.0);
    if (intersection.kind != RAY_QUERY_INTERSECTION_NONE) {
        let expected = ray_pos + intersection.t * ray_dir;
        color = compute_hit_color(intersection, expected);
    }
    textureStore(output, global_id.xy, color);
}

var input: texture_2d<f32>;
struct VertexOutput {
    @builtin(position) clip_pos: vec4<f32>,
    @location(0) @interpolate(flat) input_size: vec2<u32>,
}

@vertex
fn draw_vs(@builtin(vertex_index) vi: u32) -> VertexOutput {
    var vo: VertexOutput;
    vo.clip_pos = vec4<f32>(f32(vi & 1u) * 4.0 - 1.0, f32(vi & 2u) * 2.0 - 1.0, 0.0, 1.0);
    vo.input_size = textureDimensions(input, 0);
    return vo;
}

@fragment
fn draw_fs(vo: VertexOutput) -> @location(0) vec4<f32> {
    let tc = vec2<i32>(i32(vo.clip_pos.x), i32(vo.input_size.y) - i32(vo.clip_pos.y));
    return textureLoad(input, tc, 0);
}