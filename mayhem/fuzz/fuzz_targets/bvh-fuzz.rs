#![no_main]

//! Port of the original `bvh-fuzz` harness (fuzz/fuzz_targets/bvh-fuzz.rs on the
//! archived integration branch) to the bvh 0.12 API: decode a ray plus a set of
//! spheres from raw bytes, build a BVH over the spheres, and traverse it.

use bvh::aabb::{Aabb, Bounded};
use bvh::bounding_hierarchy::BHShape;
use bvh::bvh::Bvh;
use bvh::ray::Ray;
use libfuzzer_sys::fuzz_target;
use nalgebra::{Point3, Vector3};

#[derive(Debug)]
struct Sphere {
    position: Point3<f32>,
    radius: f32,
    node_index: usize,
}

impl Bounded<f32, 3> for Sphere {
    fn aabb(&self) -> Aabb<f32, 3> {
        let half_size = Vector3::new(self.radius, self.radius, self.radius);
        let min = self.position - half_size;
        let max = self.position + half_size;
        Aabb::with_bounds(min, max)
    }
}

impl BHShape<f32, 3> for Sphere {
    fn set_bh_node_index(&mut self, index: usize) {
        self.node_index = index;
    }

    fn bh_node_index(&self) -> usize {
        self.node_index
    }
}

fuzz_target!(|data: &[u8]| {
    if data.len() > (10 * 4) {
        let origin = Point3::new(data[0] as f32, data[4] as f32, data[8] as f32);
        let direction = Vector3::new(data[12] as f32, data[16] as f32, data[20] as f32);
        if direction == Vector3::zeros() {
            return;
        }
        let ray = Ray::new(origin, direction);
        let mut idx = 24;
        let mut spheres = Vec::new();
        while idx + (4 * 4) < data.len() {
            let position = Point3::new(
                data[idx] as f32,
                data[idx + 4] as f32,
                data[idx + 8] as f32,
            );
            let radius = (data[idx] as f32).abs();

            spheres.push(Sphere {
                position,
                radius,
                node_index: 1,
            });
            idx += 4 * 4;
        }
        let bvh = Bvh::build(&mut spheres);
        let _hit_sphere_aabbs = bvh.traverse(&ray, &spheres);
    }
});
