import std/[strformat, options, lenientops]
import pkg/[glm]
import ./glad/gl
import GlUtils

type
  SdfInstructionKind* {.size: sizeof(uint8).} = enum
    # Operations
    AddOp
    SubOp
    InterOp
    XorOp
    SmoothAddOp
    SmoothSubOp
    SmoothInterOp # Shapes
    Sphere
    Box
    RoundBox
    BoxFrame
    Cone
    CappedCone
    HexPrism
    TriPrism
    Capsule
    CappedCylinder
    RoundedCylinder
    CutSphere
    Octahedron
    Pyramid
    Triangle
    Quad
    Plane

  Material* = object
    color*: Vec3f
    metalness: GLfloat

  # A distinct type could be used to give extra type safety for material, argument and runtime data indices. Its a bit annoying though,
  # because there is no easy way to borrow all operators for a distinct type.
  # ArgIndex* = distinct uint32

makeSsbo:
  type
    SdfProgramData* = object
      materialData*: array[256, Material]

    SdfProgramInputs* = object
      args*: seq[uint32]

    SdfInstruction* = object
      kind*: SdfInstructionKind
      runtimeArgsI*: uint8
      argsI*: uint16
      outputI*: uint8
      materialI*: uint8
      argCount*: uint8
      runtimeArgCount*: uint8

proc emptySdfProgram*(): seq[SdfInstruction] =
  @[]

const maxOutputSlots = 10

# TODO: Add a better API for dynamically changing existing shapes and instructions (low priority)
type SceneBuilder* = object
  nextArgI: uint16 = 0
  materialCount: int = 1
  currentMaterial: uint8 = 0
  # This holds the index of the instruction that wrote in the slot, if the result hasn't been used yet
  outputSlotUsage: array[maxOutputSlots, Option[int]]
  nextOutputI: uint8 = 0
  data: ref SdfProgramData
  inputs: ref SdfProgramInputs
  instructions: ref seq[SdfInstruction]

proc initSceneBuilder*(
    data: ref SdfProgramData,
    inputs: ref SdfProgramInputs,
    instructions: ref seq[SdfInstruction],
): SceneBuilder =
  data.materialData[0] = Material(color: vec3f(1))
  SceneBuilder(data: data, inputs: inputs, instructions: instructions)

proc addMaterial*(prog: var SceneBuilder, color: Vec3f): uint8 =
  ## Registers a linear RGB color. Slot zero is the default white material.
  for channel in 0 .. 2:
    if not (color[channel] >= 0 and color[channel] <= 1):
      raise newException(ValueError, "Material color components must be in [0, 1]")
  if prog.materialCount >= prog.data.materialData.len:
    raise newException(ValueError, "SDF material table is full (256 materials)")
  result = prog.materialCount.uint8
  prog.data.materialData[result] = Material(color: color)
  inc prog.materialCount

proc useMaterial*(prog: var SceneBuilder, materialI: uint8) =
  ## Applies to subsequent primitives; CSG operations inherit their inputs' colors.
  if materialI.int >= prog.materialCount:
    raise newException(ValueError, "SDF material index has not been registered")
  prog.currentMaterial = materialI

proc addDefaultPalette*(prog: var SceneBuilder): tuple[wall, stone, ball, wood: uint8] =
  (
    wall: prog.addMaterial(vec3f(0.72, 0.66, 0.55)),
    stone: prog.addMaterial(vec3f(0.45, 0.32, 0.20)),
    ball: prog.addMaterial(vec3f(0.06, 0.82, 0.70)),
    wood: prog.addMaterial(vec3f(0.50, 0.26, 0.12)),
  )

# TODO: Split to different functions for shapes and operators to make the fn call signature less messy
proc makeInsn(
    kind: SdfInstructionKind,
    argsI: uint16,
    outputI, argCount: uint8,
    runtimeArgsI, runtimeArgCount = uint8.none,
): SdfInstruction =
  result =
    SdfInstruction(kind: kind, argsI: argsI, outputI: outputI, argCount: argCount)

  result.runtimeArgsI =
    if runtimeArgsI.isSome:
      runtimeArgsI.get
    else:
      uint8.high # This instruction doesn't use any runtime arguments

  if runtimeArgCount.isSome:
    result.runtimeArgCount = runtimeArgCount.get

template makeUintArgs(arr: untyped) =
  const arrSize = sizeof(arr[0]) div sizeof(uint32) * arr.len
  let args {.inject.} = cast[array[arr.len, uint32]](arr)

proc addArgs(prog: var SceneBuilder, args: openArray[uint32]) =
  prog.inputs.args &= args
  prog.nextArgI += args.len.uint16

# This is broken but why?
proc size(params: openArray[uint32]): uint32 =
  sizeof(params) div 4 # How many uint32s is this params array?

proc addInsnWithOutput(
    prog: var SceneBuilder, i: SdfInstruction
): tuple[outputI: uint8, instI: int] =
  # Mark the output slot that this instruction used as input to be unused
  if i.runtimeArgsI != uint8.high:
    for slotI in i.runtimeArgsI ..< i.runtimeArgsI + i.runtimeArgCount:
      prog.outputSlotUsage[slotI] = int.none

  # Check that the output slot this instruction writes to is unused and mark it as being used by this instruction
  let outputSlotState = prog.outputSlotUsage[i.outputI]
  assert(
    outputSlotState.isNone,
    &"\nAttempt to overwrite output slot:\n\nInstruction {prog.instructions[].len}: {i}...\ntried to use output slot {i.outputI} " &
      &"that was written to by:\n\ninstruction {outputSlotState.get}: {prog.instructions[outputSlotState.get]}...\n" &
      &"and not used by any combining operator",
  )
  let instI = prog.instructions[].len
  prog.outputSlotUsage[i.outputI] = instI.some

  result = (i.outputI, instI)
  var instruction = i
  if instruction.kind >= Sphere:
    instruction.materialI = prog.currentMaterial
  prog.instructions[].add instruction
  prog.nextOutputI += 1
  prog.nextOutputI = prog.nextOutputI mod maxOutputSlots

  # TODO: Replace with logger?
  when defined(showSdfInstructions):
    echo fmt"Instruction {prog.instructions[].high}: {instruction}"

#[
Code that was used to test slot overwrite protection:

let innerBox = sdfRenderer.sceneBuilder.addRoundBox(vec3f(0, 0, 0), vec3f(9, 3, 9), 0.5).outputI
let outerBox = sdfRenderer.sceneBuilder.addBox(vec3f(0, 0, 0), vec3f(10, 5, 10)).outputI
var windowNorth = sdfRenderer.sceneBuilder.addBox(vec3f(0, 0, -9), vec3f(1.5, 1.5, 2)).outputI
windowNorth = sdfRenderer.sceneBuilder.addBox(vec3f(0, 0, -9), vec3f(1.5, 1.5, 2)).outputI
windowNorth = sdfRenderer.sceneBuilder.addBox(vec3f(0, 0, -9), vec3f(1.5, 1.5, 2)).outputI
windowNorth = sdfRenderer.sceneBuilder.addBox(vec3f(0, 0, -9), vec3f(1.5, 1.5, 2)).outputI
windowNorth = sdfRenderer.sceneBuilder.addBox(vec3f(0, 0, -9), vec3f(1.5, 1.5, 2)).outputI
windowNorth = sdfRenderer.sceneBuilder.addBox(vec3f(0, 0, -9), vec3f(1.5, 1.5, 2)).outputI
windowNorth = sdfRenderer.sceneBuilder.addBox(vec3f(0, 0, -9), vec3f(1.5, 1.5, 2)).outputI
windowNorth = sdfRenderer.sceneBuilder.addBox(vec3f(0, 0, -9), vec3f(1.5, 1.5, 2)).outputI
let room = sdfRenderer.sceneBuilder.cut(innerBox, outerBox)
windowNorth = sdfRenderer.sceneBuilder.addBox(vec3f(0, 0, -9), vec3f(1.5, 1.5, 2)).outputI
# This will cause an overwrite:
# windowNorth = sdfRenderer.sceneBuilder.addBox(vec3f(0, 0, -9), vec3f(1.5, 1.5, 2)).outputI

This would make for a good test...
]#

const defaultRoundingFactor: GLfloat = 0.25

# These functions return the output parameter slot where their results will be written
# TODO: Generate from function signature using macros?
proc addSphere*(
    prog: var SceneBuilder, p: Vec3f, r: GLfloat
): tuple[outputI: uint8, instI: int] =
  makeUintArgs [p.x, p.y, p.z, r]
  result = prog.addInsnWithOutput makeInsn(
    Sphere, prog.nextArgI, prog.nextOutputI, sizeof(args) div 4
  )
  prog.addArgs args

proc addBox*(
    prog: var SceneBuilder, p: Vec3f, halfExtents: Vec3f
): tuple[outputI: uint8, instI: int] =
  makeUintArgs [p.x, p.y, p.z, halfExtents.x, halfExtents.y, halfExtents.z]
  result = prog.addInsnWithOutput makeInsn(
    Box, prog.nextArgI, prog.nextOutputI, sizeof(args) div 4
  )
  prog.addArgs args

proc addRoundBox*(
    prog: var SceneBuilder, p: Vec3f, halfExtents: Vec3f, r = defaultRoundingFactor
): tuple[outputI: uint8, instI: int] =
  makeUintArgs [p.x, p.y, p.z, halfExtents.x, halfExtents.y, halfExtents.z, r]
  result = prog.addInsnWithOutput makeInsn(
    RoundBox, prog.nextArgI, prog.nextOutputI, sizeof(args) div 4
  )
  prog.addArgs args

proc addBoxFrame*(
    prog: var SceneBuilder, p: Vec3f, halfExtents: Vec3f, e: GLfloat
): tuple[outputI: uint8, instI: int] =
  makeUintArgs [p.x, p.y, p.z, halfExtents.x, halfExtents.y, halfExtents.z, e]
  result = prog.addInsnWithOutput makeInsn(
    BoxFrame, prog.nextArgI, prog.nextOutputI, sizeof(args) div 4
  )
  prog.addArgs args

proc addCone*(
    prog: var SceneBuilder, p: Vec3f, c: Vec2f, h: GLfloat
): tuple[outputI: uint8, instI: int] =
  makeUintArgs [p.x, p.y, p.z, c.x, c.y, h]
  result = prog.addInsnWithOutput makeInsn(
    Cone, prog.nextArgI, prog.nextOutputI, sizeof(args) div 4
  )
  prog.addArgs args

proc addCappedCone*(
    prog: var SceneBuilder, p, a, b: Vec3f, ra, rb: GLfloat
): tuple[outputI: uint8, instI: int] =
  makeUintArgs [p.x, p.y, p.z, a.x, a.y, a.z, b.x, b.y, b.z, ra, rb]
  result = prog.addInsnWithOutput makeInsn(
    CappedCone, prog.nextArgI, prog.nextOutputI, sizeof(args) div 4
  )
  prog.addArgs args

proc addHexPrism*(
    prog: var SceneBuilder, p: Vec3f, h: Vec2f
): tuple[outputI: uint8, instI: int] =
  makeUintArgs [p.x, p.y, p.z, h.x, h.y]
  result = prog.addInsnWithOutput makeInsn(
    HexPrism, prog.nextArgI, prog.nextOutputI, sizeof(args) div 4
  )
  prog.addArgs args

proc addTriPrism*(
    prog: var SceneBuilder, p: Vec3f, h: Vec2f
): tuple[outputI: uint8, instI: int] =
  makeUintArgs [p.x, p.y, p.z, h.x, h.y]
  result = prog.addInsnWithOutput makeInsn(
    TriPrism, prog.nextArgI, prog.nextOutputI, sizeof(args) div 4
  )
  prog.addArgs args

proc addCapsule*(
    prog: var SceneBuilder, p: Vec3f, h, r: GLfloat
): tuple[outputI: uint8, instI: int] =
  makeUintArgs [p.x, p.y, p.z, h, r]
  result = prog.addInsnWithOutput makeInsn(
    Capsule, prog.nextArgI, prog.nextOutputI, sizeof(args) div 4
  )
  prog.addArgs args

proc addCappedCylinder*(
    prog: var SceneBuilder, p, a, b: Vec3f, r: GLfloat
): tuple[outputI: uint8, instI: int] =
  makeUintArgs [p.x, p.y, p.z, a.x, a.y, a.z, b.x, b.y, b.z, r]
  result = prog.addInsnWithOutput makeInsn(
    CappedCylinder, prog.nextArgI, prog.nextOutputI, sizeof(args) div 4
  )
  prog.addArgs args

proc addRoundedCylinder*(
    prog: var SceneBuilder, p: Vec3f, ra, rb: GLfloat, h = defaultRoundingFactor
): tuple[outputI: uint8, instI: int] =
  makeUintArgs [p.x, p.y, p.z, ra, rb, h]
  result = prog.addInsnWithOutput makeInsn(
    RoundedCylinder, prog.nextArgI, prog.nextOutputI, sizeof(args) div 4
  )
  prog.addArgs args

proc addCutSphere*(
    prog: var SceneBuilder, p: Vec3f, r, h: GLfloat
): tuple[outputI: uint8, instI: int] =
  makeUintArgs [p.x, p.y, p.z, r, h]
  result = prog.addInsnWithOutput makeInsn(
    CutSphere, prog.nextArgI, prog.nextOutputI, sizeof(args) div 4
  )
  prog.addArgs args

proc addOctahedron*(
    prog: var SceneBuilder, p: Vec3f, s: GLfloat
): tuple[outputI: uint8, instI: int] =
  makeUintArgs [p.x, p.y, p.z, s]
  result = prog.addInsnWithOutput makeInsn(
    Octahedron, prog.nextArgI, prog.nextOutputI, sizeof(args) div 4
  )
  prog.addArgs args

proc addPyramid*(
    prog: var SceneBuilder, p: Vec3f, h: GLfloat
): tuple[outputI: uint8, instI: int] =
  makeUintArgs [p.x, p.y, p.z, h]
  result = prog.addInsnWithOutput makeInsn(
    Pyramid, prog.nextArgI, prog.nextOutputI, sizeof(args) div 4
  )
  prog.addArgs args

proc addTriangle*(
    prog: var SceneBuilder, p, a, b, c: Vec3f
): tuple[outputI: uint8, instI: int] =
  makeUintArgs [p.x, p.y, p.z, a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z]
  result = prog.addInsnWithOutput makeInsn(
    Triangle, prog.nextArgI, prog.nextOutputI, sizeof(args) div 4
  )
  prog.addArgs args

proc addQuad*(
    prog: var SceneBuilder, p, a, b, c, d: Vec3f
): tuple[outputI: uint8, instI: int] =
  makeUintArgs [
    p.x, p.y, p.z, a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z, d.x, d.y, d.z
  ]
  result = prog.addInsnWithOutput makeInsn(
    Quad, prog.nextArgI, prog.nextOutputI, sizeof(args) div 4
  )
  prog.addArgs args

proc addPlane*(
    prog: var SceneBuilder, p, n: Vec3f, h: GLfloat
): tuple[outputI: uint8, instI: int] =
  makeUintArgs [p.x, p.y, p.z, n.x, n.y, n.z, h]
  result = prog.addInsnWithOutput makeInsn(
    Plane, prog.nextArgI, prog.nextOutputI, sizeof(args) div 4
  )
  prog.addArgs args

proc assertContiguousInputs(inputs: openArray[uint8]) =
  when not defined(release) and not defined(danger):
    for i in 0 ..< inputs.high:
      assert(
        inputs[i + 1] - inputs[i] == 1.uint8,
        "Inputs for SDF must be next to each other in memory. " &
          "The GPU SDF instruction interpreter can only read parameters in order.",
      )

proc combine*(
    prog: var SceneBuilder, d1Index, d2Index: uint8
): tuple[outputI: uint8, instI: int] =
  assertContiguousInputs [d1Index, d2Index]
  result = prog.addInsnWithOutput makeInsn(
    AddOp, uint16.high, prog.nextOutputI, 0, d1Index.some, 2.uint8.some
  )

proc cut*(
    prog: var SceneBuilder, d1Index, d2Index: uint8
): tuple[outputI: uint8, instI: int] =
  assertContiguousInputs [d1Index, d2Index]
  result = prog.addInsnWithOutput makeInsn(
    SubOp, uint16.high, prog.nextOutputI, 0, d1Index.some, 2.uint8.some
  )

proc intersect*(
    prog: var SceneBuilder, d1Index, d2Index: uint8
): tuple[outputI: uint8, instI: int] =
  assertContiguousInputs [d1Index, d2Index]
  result = prog.addInsnWithOutput makeInsn(
    InterOp, uint16.high, prog.nextOutputI, 0, d1Index.some, 2.uint8.some
  )

proc combineWithoutOverlap*(
    prog: var SceneBuilder, d1Index, d2Index: uint8
): tuple[outputI: uint8, instI: int] =
  assertContiguousInputs [d1Index, d2Index]
  result = prog.addInsnWithOutput makeInsn(
    XorOp, uint16.high, prog.nextOutputI, 0, d1Index.some, 2.uint8.some
  )

proc smoothlyCombine*(
    prog: var SceneBuilder, d1Index, d2Index: uint8, k = defaultRoundingFactor
): tuple[outputI: uint8, instI: int] =
  makeUintArgs [k]
  assertContiguousInputs [d1Index, d2Index]
  result = prog.addInsnWithOutput makeInsn(
    SmoothAddOp, prog.nextArgI, prog.nextOutputI, 1, d1Index.some, 2.uint8.some
  )
  prog.addArgs args

proc smoothlyCut*(
    prog: var SceneBuilder, d1Index, d2Index: uint8, k = defaultRoundingFactor
): tuple[outputI: uint8, instI: int] =
  makeUintArgs [k]
  assertContiguousInputs [d1Index, d2Index]
  result = prog.addInsnWithOutput makeInsn(
    SmoothSubOp, prog.nextArgI, prog.nextOutputI, 1, d1Index.some, 2.uint8.some
  )
  prog.addArgs args

proc smoothlyIntersect*(
    prog: var SceneBuilder, d1Index, d2Index: uint8, k = defaultRoundingFactor
): tuple[outputI: uint8, instI: int] =
  makeUintArgs [k]
  assertContiguousInputs [d1Index, d2Index]
  result = prog.addInsnWithOutput makeInsn(
    SmoothInterOp, prog.nextArgI, prog.nextOutputI, 1, d1Index.some, 2.uint8.some
  )
  prog.addArgs args
