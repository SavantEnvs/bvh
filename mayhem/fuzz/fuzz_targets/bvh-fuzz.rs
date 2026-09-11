#![no_main]
use libfuzzer_sys::fuzz_target;
use bvh::aabb::{Bounded, AABB};
use bvh::bounding_hierarchy::BHShape;
use bvh::bvh::BVH;
use bvh::ray::Ray;
use bvh::{Point3, Vector3};

//From examples/simple.rs
#[derive(Debug)]
struct Sphere {
    position: Point3,
    radius: f32,
    node_index: usize,
}

impl Bounded for Sphere {
    fn aabb(&self) -> AABB {
        let half_size = Vector3::new(self.radius, self.radius, self.radius);
        let min = self.position - half_size;
        let max = self.position + half_size;
        AABB::with_bounds(min, max)
    }
}

impl BHShape for Sphere {
    fn set_bh_node_index(&mut self, index: usize) {
        self.node_index = index;
    }

    fn bh_node_index(&self) -> usize {
        self.node_index
    }
}

fuzz_target!(|data: &[u8]| {
    if data.len() > (10 * 4) {
        let origin = Point3::new(unsafe{std::ptr::read(&data[0])} as f32, unsafe{std::ptr::read(&data[4])} as f32, unsafe{std::ptr::read(&data[8])} as f32);
        let direction = Vector3::new(unsafe{std::ptr::read(&data[12])} as f32, unsafe{std::ptr::read(&data[16])} as f32, unsafe{std::ptr::read(&data[20])} as f32);
        let ray = Ray::new(origin, direction);
        let mut idx = 24;
        let mut spheres = Vec::new();
        while idx + (4 * 4) < data.len() {
            let position = Point3::new(unsafe{std::ptr::read(&data[idx])} as f32, unsafe{std::ptr::read(&data[idx + 4])} as f32, unsafe{std::ptr::read(&data[idx + 8])} as f32);
            let mut radius = unsafe{std::ptr::read(&data[idx])} as f32;
            radius = radius.abs();

            spheres.push(Sphere {
                position,
                radius,
                node_index: 1,
            });
            idx += (4 * 4);
        }
        let bvh = BVH::build(&mut spheres);
        let hit_sphere_aabbs = bvh.traverse(&ray, &spheres);
    }
});
