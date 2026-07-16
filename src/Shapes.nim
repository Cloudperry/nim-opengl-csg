import std/lenientops
import glad/gl
import pkg/glm
import Scene, GlUtils

type SimpleModel* = tuple[vertices: seq[ColoredVertex], indices: seq[GLuint]]

# TODO: Make better shape functions. These are ChatGPT generated shapes for quick testing.
proc makeCube*(color: Vec3f): SimpleModel =
  return (
    vertices: @[
      # Front face (z = 0.5, normal = +Z)
      ColoredVertex(pos: vec3f(-0.5, -0.5, 0.5), color: color, normal: vec3f(0, 0, 1)),
      ColoredVertex(pos: vec3f(0.5, -0.5, 0.5), color: color, normal: vec3f(0, 0, 1)),
      ColoredVertex(pos: vec3f(0.5, 0.5, 0.5), color: color, normal: vec3f(0, 0, 1)),
      ColoredVertex(pos: vec3f(-0.5, 0.5, 0.5), color: color, normal: vec3f(0, 0, 1)),

      # Back face (z = -0.5, normal = -Z)
      ColoredVertex(pos: vec3f(-0.5, -0.5, -0.5), color: color, normal: vec3f(0, 0, -1)),
      ColoredVertex(pos: vec3f(0.5, -0.5, -0.5), color: color, normal: vec3f(0, 0, -1)),
      ColoredVertex(pos: vec3f(0.5, 0.5, -0.5), color: color, normal: vec3f(0, 0, -1)),
      ColoredVertex(pos: vec3f(-0.5, 0.5, -0.5), color: color, normal: vec3f(0, 0, -1)),

      # Left face (x = -0.5, normal = -X)
      ColoredVertex(pos: vec3f(-0.5, -0.5, -0.5), color: color, normal: vec3f(-1, 0, 0)),
      ColoredVertex(pos: vec3f(-0.5, -0.5, 0.5), color: color, normal: vec3f(-1, 0, 0)),
      ColoredVertex(pos: vec3f(-0.5, 0.5, 0.5), color: color, normal: vec3f(-1, 0, 0)),
      ColoredVertex(pos: vec3f(-0.5, 0.5, -0.5), color: color, normal: vec3f(-1, 0, 0)),

      # Right face (x = 0.5, normal = +X)
      ColoredVertex(pos: vec3f(0.5, -0.5, -0.5), color: color, normal: vec3f(1, 0, 0)),
      ColoredVertex(pos: vec3f(0.5, -0.5, 0.5), color: color, normal: vec3f(1, 0, 0)),
      ColoredVertex(pos: vec3f(0.5, 0.5, 0.5), color: color, normal: vec3f(1, 0, 0)),
      ColoredVertex(pos: vec3f(0.5, 0.5, -0.5), color: color, normal: vec3f(1, 0, 0)),

      # Top face (y = 0.5, normal = +Y)
      ColoredVertex(pos: vec3f(-0.5, 0.5, -0.5), color: color, normal: vec3f(0, 1, 0)),
      ColoredVertex(pos: vec3f(0.5, 0.5, -0.5), color: color, normal: vec3f(0, 1, 0)),
      ColoredVertex(pos: vec3f(0.5, 0.5, 0.5), color: color, normal: vec3f(0, 1, 0)),
      ColoredVertex(pos: vec3f(-0.5, 0.5, 0.5), color: color, normal: vec3f(0, 1, 0)),

      # Bottom face (y = -0.5, normal = -Y)
      ColoredVertex(pos: vec3f(-0.5, -0.5, -0.5), color: color, normal: vec3f(0, -1, 0)),
      ColoredVertex(pos: vec3f(0.5, -0.5, -0.5), color: color, normal: vec3f(0, -1, 0)),
      ColoredVertex(pos: vec3f(0.5, -0.5, 0.5), color: color, normal: vec3f(0, -1, 0)),
      ColoredVertex(pos: vec3f(-0.5, -0.5, 0.5), color: color, normal: vec3f(0, -1, 0)),
    ],
    indices: @[
      0,
      1,
      2,
      0,
      2,
      3, # Front
      4,
      6,
      5,
      4,
      7,
      6, # Back
      8,
      9,
      10,
      8,
      10,
      11, # Left
      12,
      14,
      13,
      12,
      15,
      14, # Right
      16,
      18,
      17,
      16,
      19,
      18, # Top
      20,
      21,
      22,
      20,
      22,
      23, # Bottom
    ],
  )

proc makePyramid*(color: Vec3f): SimpleModel =
  return (
    vertices: @[
      # Base (y = -0.5, normal = -Y)
      ColoredVertex(pos: vec3f(-0.5, -0.5, -0.5), color: color, normal: vec3f(0, -1, 0)),
      ColoredVertex(pos: vec3f(0.5, -0.5, -0.5), color: color, normal: vec3f(0, -1, 0)),
      ColoredVertex(pos: vec3f(0.5, -0.5, 0.5), color: color, normal: vec3f(0, -1, 0)),
      ColoredVertex(pos: vec3f(-0.5, -0.5, 0.5), color: color, normal: vec3f(0, -1, 0)),

      # Apex (0, 0.5, 0)
      # Side 1 (front, z=+0.5)
      ColoredVertex(
        pos: vec3f(0, 0.5, 0), color: color, normal: normalize(vec3f(0, 0.5, 0.5))
      ),
      ColoredVertex(
        pos: vec3f(-0.5, -0.5, 0.5), color: color, normal: normalize(vec3f(0, 0.5, 0.5))
      ),
      ColoredVertex(
        pos: vec3f(0.5, -0.5, 0.5), color: color, normal: normalize(vec3f(0, 0.5, 0.5))
      ),

      # Side 2 (back, z=-0.5)
      ColoredVertex(
        pos: vec3f(0, 0.5, 0), color: color, normal: normalize(vec3f(0, 0.5, -0.5))
      ),
      ColoredVertex(
        pos: vec3f(0.5, -0.5, -0.5),
        color: color,
        normal: normalize(vec3f(0, 0.5, -0.5)),
      ),
      ColoredVertex(
        pos: vec3f(-0.5, -0.5, -0.5),
        color: color,
        normal: normalize(vec3f(0, 0.5, -0.5)),
      ),

      # Side 3 (right, x=+0.5)
      ColoredVertex(
        pos: vec3f(0, 0.5, 0), color: color, normal: normalize(vec3f(0.5, 0.5, 0))
      ),
      ColoredVertex(
        pos: vec3f(0.5, -0.5, 0.5), color: color, normal: normalize(vec3f(0.5, 0.5, 0))
      ),
      ColoredVertex(
        pos: vec3f(0.5, -0.5, -0.5), color: color, normal: normalize(vec3f(0.5, 0.5, 0))
      ),

      # Side 4 (left, x=-0.5)
      ColoredVertex(
        pos: vec3f(0, 0.5, 0), color: color, normal: normalize(vec3f(-0.5, 0.5, 0))
      ),
      ColoredVertex(
        pos: vec3f(-0.5, -0.5, -0.5),
        color: color,
        normal: normalize(vec3f(-0.5, 0.5, 0)),
      ),
      ColoredVertex(
        pos: vec3f(-0.5, -0.5, 0.5),
        color: color,
        normal: normalize(vec3f(-0.5, 0.5, 0)),
      ),
    ],
    indices: @[
      0,
      1,
      2,
      0,
      2,
      3, # Base
      4,
      5,
      6, # Front
      7,
      8,
      9, # Back
      10,
      11,
      12, # Right
      13,
      14,
      15, # Left
    ],
  )

proc makeSphere*(radius: float, slices, stacks: int, color: Vec3f): SimpleModel =
  var vertices: seq[ColoredVertex]
  var indices: seq[int]

  for stack in 0 .. stacks:
    let phi = PI * float32(stack) / float32(stacks) # 0..π
    let y = cos(phi)
    let r = sin(phi)
    for slice in 0 .. slices:
      let theta = 2.0f32 * PI * float32(slice) / float32(slices) # 0..2π
      let x = r * cos(theta)
      let z = r * sin(theta)

      let pos = vec3f(x * radius, y * radius, z * radius)
      let normal = normalize(vec3f(x, y, z)) # outward normal
      vertices.add(ColoredVertex(pos: pos, color: color, normal: normal))

  for stack in 0 ..< stacks:
    for slice in 0 ..< slices:
      let first = stack * (slices + 1) + slice
      let second = first + slices + 1

      indices.add(first)
      indices.add(first + 1)
      indices.add(second)

      indices.add(second)
      indices.add(first + 1)
      indices.add(second + 1)

  return (vertices, indices)
