//! Immediate-mode geometry, mirroring the engine's
//! `DrawIndexedExecutorDX11<BasicVertexDX11::Vertex>` (the dynamic
//! vertex/index buffer pair every `GeometryActor` renders through) and the
//! shape-building methods of `GeometryActor` (Source/GeometryActor.cpp).
//!
//! The chapter-3 lesson lives here: vertices and indices are plain CPU
//! vectors that get rewritten into DYNAMIC buffers (Map/WRITE_DISCARD) each
//! time they change — redefining geometry every frame instead of baking it.

use glam::{Mat3, Vec2, Vec3, Vec4};
use windows::Win32::Graphics::Direct3D::D3D_PRIMITIVE_TOPOLOGY;
use windows::Win32::Graphics::Direct3D11::{
    D3D11_BIND_INDEX_BUFFER, D3D11_BIND_VERTEX_BUFFER, D3D11_BUFFER_DESC, D3D11_CPU_ACCESS_WRITE,
    D3D11_MAP_WRITE_DISCARD, D3D11_MAPPED_SUBRESOURCE, D3D11_USAGE_DYNAMIC, ID3D11Buffer,
    ID3D11Device, ID3D11DeviceContext,
};

/// Mirrors `BasicVertexDX11::Vertex`: POSITION, NORMAL, COLOR, TEXCOORD with
/// appended offsets (0/12/24/40, stride 48). Plain arrays keep the layout
/// exact (glam's `Vec4` is 16-byte aligned and would insert padding).
#[repr(C)]
#[derive(Clone, Copy)]
pub struct BasicVertex {
    pub position: [f32; 3],
    pub normal: [f32; 3],
    pub color: [f32; 4],
    pub texcoords: [f32; 2],
}

pub struct ImmediateMesh {
    pub vertices: Vec<BasicVertex>,
    pub indices: Vec<u32>,
    pub topology: D3D_PRIMITIVE_TOPOLOGY,
    /// Current color applied by the add/draw helpers, mirroring
    /// `GeometryActor::SetColor`.
    pub color: Vec4,
    dirty: bool,
    vertex_buffer: Option<ID3D11Buffer>,
    vertex_capacity: usize,
    index_buffer: Option<ID3D11Buffer>,
    index_capacity: usize,
}

impl ImmediateMesh {
    pub fn new(topology: D3D_PRIMITIVE_TOPOLOGY) -> Self {
        Self {
            vertices: Vec::new(),
            indices: Vec::new(),
            topology,
            color: Vec4::ONE,
            dirty: false,
            vertex_buffer: None,
            vertex_capacity: 0,
            index_buffer: None,
            index_capacity: 0,
        }
    }

    pub fn reset(&mut self) {
        self.vertices.clear();
        self.indices.clear();
        self.dirty = true;
    }

    pub fn add_vertex_full(&mut self, position: Vec3, normal: Vec3, color: Vec4, texcoords: Vec2) {
        self.vertices.push(BasicVertex {
            position: position.to_array(),
            normal: normal.to_array(),
            color: color.to_array(),
            texcoords: texcoords.to_array(),
        });
        self.dirty = true;
    }

    /// `GeometryActor::AddVertex( position )` — default normal (0,1,0),
    /// current color, zero texcoords.
    pub fn add_vertex(&mut self, position: Vec3) {
        self.add_vertex_full(position, Vec3::Y, self.color, Vec2::ZERO);
    }

    pub fn add_vertex_tex(&mut self, position: Vec3, texcoords: Vec2) {
        self.add_vertex_full(position, Vec3::Y, self.color, texcoords);
    }

    pub fn add_vertex_normal(&mut self, position: Vec3, normal: Vec3) {
        self.add_vertex_full(position, normal, self.color, Vec2::ZERO);
    }

    pub fn add_vertex_normal_tex(&mut self, position: Vec3, normal: Vec3, texcoords: Vec2) {
        self.add_vertex_full(position, normal, self.color, texcoords);
    }

    pub fn add_index(&mut self, index: u32) {
        self.indices.push(index);
        self.dirty = true;
    }

    /// Upload to the GPU if anything changed, growing the DYNAMIC buffers
    /// when the data outgrows them (the engine's executors size to
    /// `SetMaxVertexCount`; here capacity just follows the data).
    pub fn commit(&mut self, device: &ID3D11Device, context: &ID3D11DeviceContext) {
        if !self.dirty || self.vertices.is_empty() {
            self.dirty = false;
            return;
        }

        if self.vertices.len() > self.vertex_capacity {
            self.vertex_buffer = Some(create_dynamic_buffer(
                device,
                (self.vertices.len() * size_of::<BasicVertex>()) as u32,
                D3D11_BIND_VERTEX_BUFFER.0 as u32,
            ));
            self.vertex_capacity = self.vertices.len();
        }
        if self.indices.len() > self.index_capacity {
            self.index_buffer = Some(create_dynamic_buffer(
                device,
                (self.indices.len() * size_of::<u32>()) as u32,
                D3D11_BIND_INDEX_BUFFER.0 as u32,
            ));
            self.index_capacity = self.indices.len();
        }

        // SAFETY: Each mapped write stays within the buffer's byte size,
        // which was allocated from the same lengths just above (capacities
        // only grow). WRITE_DISCARD hands back fresh memory each time.
        unsafe {
            if let Some(vb) = &self.vertex_buffer {
                let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
                if context.Map(vb, 0, D3D11_MAP_WRITE_DISCARD, 0, Some(&mut mapped)).is_ok() {
                    std::ptr::copy_nonoverlapping(
                        self.vertices.as_ptr(),
                        mapped.pData as *mut BasicVertex,
                        self.vertices.len(),
                    );
                    context.Unmap(vb, 0);
                }
            }
            if let Some(ib) = &self.index_buffer {
                let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
                if context.Map(ib, 0, D3D11_MAP_WRITE_DISCARD, 0, Some(&mut mapped)).is_ok() {
                    std::ptr::copy_nonoverlapping(
                        self.indices.as_ptr(),
                        mapped.pData as *mut u32,
                        self.indices.len(),
                    );
                    context.Unmap(ib, 0);
                }
            }
        }

        self.dirty = false;
    }

    pub fn buffers(&self) -> Option<(&ID3D11Buffer, &ID3D11Buffer)> {
        match (&self.vertex_buffer, &self.index_buffer) {
            (Some(vb), Some(ib)) if !self.indices.is_empty() => Some((vb, ib)),
            _ => None,
        }
    }

    // --- Shape builders, ported from GeometryActor ---------------------------

    /// `GeometryActor::DrawSphere`: grid-tessellated over theta 0..2pi (cols =
    /// slices) and phi 0..pi (rows = stacks), sampled per `Sphere3f`.
    pub fn draw_sphere(&mut self, center: Vec3, radius: f32, stacks: u32, slices: u32) {
        let stacks = stacks.max(2);
        let slices = slices.max(4);

        self.tessellate_tri_grid(stacks, slices, |theta, phi| {
            let normal = Vec3::new(
                phi.sin() * theta.cos(),
                phi.cos(),
                phi.sin() * theta.sin(),
            );
            let position = center + normal * radius;
            let tex = Vec2::new(
                theta / (2.0 * std::f32::consts::PI),
                phi / std::f32::consts::PI,
            );
            (position, normal, tex)
        }, 2.0 * std::f32::consts::PI, std::f32::consts::PI);
    }

    /// `GeometryActor::DrawCylinder`: a `Cone3f` (two endpoints, two radii)
    /// grid-tessellated over theta 0..2pi and height factor 0..1.
    pub fn draw_cylinder(
        &mut self,
        p1: Vec3,
        p2: Vec3,
        r1: f32,
        r2: f32,
        stacks: u32,
        slices: u32,
    ) {
        let stacks = stacks.max(2);
        let slices = slices.max(4);

        let axis = p1 - p2;
        let vnorm = axis.normalize();
        let height = axis.length();
        let unit = perpendicular(axis).normalize();
        let delta_radius = r1 - r2;
        let slope = delta_radius / height;

        self.tessellate_tri_grid(stacks, slices, |theta, h| {
            let rot = Mat3::from_axis_angle(vnorm, theta);
            let radius = r2 + delta_radius * h;
            let position = p2 + vnorm * height * h + rot * unit * radius;
            let normal = (rot * unit - vnorm * slope).normalize();
            let tex = Vec2::new(h, theta); // TexcoordsFromCone: (height, theta)
            (position, normal, tex)
        }, 2.0 * std::f32::consts::PI, 1.0);
    }

    /// The `GridTessellator2f::TessellateTriGrid` pattern: (rows+1)*(cols+1)
    /// vertices sampled over [0,xmax] x [0,ymax], two triangles per cell.
    fn tessellate_tri_grid(
        &mut self,
        rows: u32,
        cols: u32,
        sample: impl Fn(f32, f32) -> (Vec3, Vec3, Vec2),
        xmax: f32,
        ymax: f32,
    ) {
        let base = self.vertices.len() as u32;
        let col_step = xmax / cols as f32;
        let row_step = ymax / rows as f32;

        for row in 0..=rows {
            for col in 0..=cols {
                let x = col_step * col as f32;
                let y = row_step * row as f32;
                let (position, normal, tex) = sample(x, y);
                self.add_vertex_full(position, normal, self.color, tex);
            }
        }

        for z in 0..rows {
            for x in 0..cols {
                self.add_index(base + z * (cols + 1) + x);
                self.add_index(base + z * (cols + 1) + x + 1);
                self.add_index(base + (z + 1) * (cols + 1) + x);

                self.add_index(base + z * (cols + 1) + x + 1);
                self.add_index(base + (z + 1) * (cols + 1) + x + 1);
                self.add_index(base + (z + 1) * (cols + 1) + x);
            }
        }
    }

    /// `GeometryActor::DrawDisc`: a triangle fan around a center vertex.
    pub fn draw_disc(&mut self, center: Vec3, normal: Vec3, radius: f32, slices: u32) {
        let slices = slices.max(4);
        let vnorm = normal.normalize();
        let up = Vec3::Y;

        let unit = if vnorm == up || vnorm == -up {
            Vec3::X
        } else {
            vnorm.cross(up).cross(vnorm).normalize()
        };

        let slice_step = 2.0 * std::f32::consts::PI / slices as f32;
        let base = self.vertices.len() as u32;

        self.add_vertex_normal(center, vnorm);

        for slice in 0..=slices {
            let theta = slice_step * slice as f32;
            let rot = Mat3::from_axis_angle(vnorm, theta);
            let position = center + rot * unit * radius;
            self.add_vertex_normal(position, vnorm);
        }

        for x in 1..=slices {
            self.add_index(base);
            self.add_index(base + x);
            self.add_index(base + x + 1);
        }
    }

    /// `GeometryActor::DrawRect`: one quad with a shared face normal.
    pub fn draw_rect(&mut self, center: Vec3, xdir: Vec3, ydir: Vec3, extents: Vec2) {
        let base = self.vertices.len() as u32;
        let x = xdir * extents.x;
        let y = ydir * extents.y;
        let normal = xdir.cross(ydir);

        self.add_vertex_normal_tex(center + x + y, normal, Vec2::new(0.0, 0.0));
        self.add_vertex_normal_tex(center - x + y, normal, Vec2::new(1.0, 0.0));
        self.add_vertex_normal_tex(center - x - y, normal, Vec2::new(1.0, 1.0));
        self.add_vertex_normal_tex(center + x - y, normal, Vec2::new(0.0, 1.0));

        self.add_index(base);
        self.add_index(base + 1);
        self.add_index(base + 2);
        self.add_index(base);
        self.add_index(base + 2);
        self.add_index(base + 3);
    }

    /// `GeometryActor::DrawBox`: six rects.
    pub fn draw_box(&mut self, center: Vec3, extents: Vec3) {
        let (xdir, ydir, zdir) = (Vec3::X, Vec3::Y, Vec3::Z);
        let x = xdir * extents.x;
        let y = ydir * extents.y;
        let z = zdir * extents.z;

        self.draw_rect(center + z, xdir, ydir, Vec2::new(extents.x, extents.y));
        self.draw_rect(center - z, -xdir, ydir, Vec2::new(extents.x, extents.y));
        self.draw_rect(center + x, -zdir, ydir, Vec2::new(extents.z, extents.y));
        self.draw_rect(center - x, zdir, ydir, Vec2::new(extents.z, extents.y));
        self.draw_rect(center + y, xdir, -zdir, Vec2::new(extents.x, extents.z));
        self.draw_rect(center - y, xdir, zdir, Vec2::new(extents.x, extents.z));
    }

    /// `GeometryActor::DrawArrow`: shaft cylinder + head cone + backing disc.
    /// The C++ calls DrawCylinder/DrawDisc with their default stack/slice
    /// counts (2/10 and 12).
    pub fn draw_arrow(
        &mut self,
        base: Vec3,
        point: Vec3,
        shaft_radius: f32,
        head_radius: f32,
        head_length: f32,
    ) {
        let arrow = point - base;
        let arrow_length = arrow.length();
        let unit_arrow = arrow / arrow_length;
        let shaft_end = base + unit_arrow * (arrow_length - head_length);

        self.draw_cylinder(base, shaft_end, shaft_radius, shaft_radius, 2, 10);
        self.draw_cylinder(shaft_end, point, head_radius, 0.0, 2, 10);
        self.draw_disc(shaft_end, -unit_arrow, head_radius, 12);
    }

    /// `GeometryActor::DrawBezierCurve` (LINELIST topology expected).
    pub fn draw_bezier_curve(&mut self, points: [Vec3; 4], t0: f32, t1: f32, segments: u32) {
        let base = self.vertices.len() as u32;
        let step = (t1 - t0) / segments as f32;

        for i in 0..=segments {
            let t = t0 + step * i as f32;
            let mt = 1.0 - t;
            let point = points[0] * mt.powi(3)
                + points[1] * 3.0 * t * mt.powi(2)
                + points[2] * 3.0 * t * t * mt
                + points[3] * t.powi(3);
            self.add_vertex(point);
        }

        for i in 0..segments {
            self.add_index(base + i);
            self.add_index(base + i + 1);
        }
    }
}

/// `Vector3f::Perpendicular`: any unit vector perpendicular to `v`. The exact
/// choice only moves the tessellation seam, which is not visible.
fn perpendicular(v: Vec3) -> Vec3 {
    let axis = if v.x.abs() < v.y.abs().min(v.z.abs()) {
        Vec3::X
    } else if v.y.abs() < v.z.abs() {
        Vec3::Y
    } else {
        Vec3::Z
    };
    v.cross(axis)
}

fn create_dynamic_buffer(device: &ID3D11Device, byte_width: u32, bind_flags: u32) -> ID3D11Buffer {
    let desc = D3D11_BUFFER_DESC {
        ByteWidth: byte_width,
        Usage: D3D11_USAGE_DYNAMIC,
        BindFlags: bind_flags,
        CPUAccessFlags: D3D11_CPU_ACCESS_WRITE.0 as u32,
        MiscFlags: 0,
        StructureByteStride: 0,
    };
    let mut buffer: Option<ID3D11Buffer> = None;
    // SAFETY: Valid descriptor and out-param; no initial data for dynamic
    // buffers.
    unsafe {
        device
            .CreateBuffer(&desc, None, Some(&mut buffer))
            .expect("dynamic buffer creation failed");
    }
    buffer.unwrap()
}
