import std/unittest
import pkg/glm
import SdfScene

suite "SDF material bytecode":
  var data: ref SdfProgramData
  var inputs: ref SdfProgramInputs
  var instructions: ref seq[SdfInstruction]
  var builder: SceneBuilder

  setup:
    new data
    new inputs
    new instructions
    builder = initSceneBuilder(data, inputs, instructions)

  test "default white preserves uncolored scenes":
    let sphere = builder.addSphere(vec3f(0), 1)
    check data.materialData[0].color == vec3f(1)
    check instructions[sphere.instI].materialI == 0

  test "materials follow primitives and survive animation":
    let teal = builder.addMaterial(vec3f(0.16, 0.38, 0.34))
    let coral = builder.addMaterial(vec3f(1.0, 0.08, 0.035))
    builder.useMaterial(teal)
    let box = builder.addBox(vec3f(0), vec3f(2))
    builder.useMaterial(coral)
    let sphere = builder.addSphere(vec3f(0), 1)
    discard builder.smoothlyCombine(box.outputI, sphere.outputI)
    check instructions[box.instI].materialI == teal
    check instructions[sphere.instI].materialI == coral
    check data.materialData[coral].color == vec3f(1.0, 0.08, 0.035)
    let argsI = instructions[sphere.instI].argsI
    inputs.args[argsI.int + 1] = cast[uint32](2.0'f32)
    check instructions[sphere.instI].materialI == coral

  test "plane and rounded box use the selected material":
    let material = builder.addMaterial(vec3f(0.5, 0.3, 0.1))
    builder.useMaterial(material)
    let plane = builder.addPlane(vec3f(0), vec3f(0, 1, 0), 0)
    let box = builder.addRoundBox(vec3f(0), vec3f(2))
    discard builder.cut(plane.outputI, box.outputI)
    check instructions[plane.instI].materialI == material
    check instructions[box.instI].materialI == material

  test "instruction packing and material stride match Slang":
    check sizeof(SdfInstruction) == 8
    check sizeof(Material) == 16
    check offsetOf(SdfInstruction, materialI) == 5
    check sizeof(SdfProgramData) == 256 * 16

  test "material capacity includes slot 255 without wrapping":
    for i in 1 .. 255:
      check builder.addMaterial(vec3f(0.5)) == i.uint8
    builder.useMaterial(255)
    let sphere = builder.addSphere(vec3f(0), 1)
    check instructions[sphere.instI].materialI == 255
    expect ValueError:
      discard builder.addMaterial(vec3f(0.5))

  test "invalid colors and unregistered indices are rejected":
    expect ValueError:
      builder.useMaterial(1)
    expect ValueError:
      discard builder.addMaterial(vec3f(-0.1, 0, 0))
    expect ValueError:
      discard builder.addMaterial(vec3f(0, 1.1, 0))
