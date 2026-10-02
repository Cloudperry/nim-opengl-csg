## Test Checkpoint 2: Full SDF Slang Shader BDA Migration & Reflection Test
##
## Verifies:
## 1. Slang shader compilation of shaders/SdfRendererVk.slang targeting SPIR-V compute.
## 2. Compile-time generation of Nim object definitions via generateNimObjects:
##    - SceneUniforms (108 bytes, Vec3 fields directly integrated with treeform/vmath)
##    - DebugSettings (4 bytes, RenderMode enum)
##    - Material (16 bytes, color: Vec3, metalness: float32)
##    - SdfProgramData (4096 bytes, array[256, Material])
##    - SdfInstruction (8 bytes, packed uints)
##    - PointLight (36 bytes, position/color: Vec3, attenuation floats)
##    - SdfPushParams (56 bytes, 64-bit BDA pointers + uint metadata)
## 3. Static compile-time and runtime size/alignment assertions.
## 4. Slang reflection metadata: 8x8x1 compute workgroup, push constant block, image bindings.
## 5. Direct treeform/vmath ergonomics: zero-copy field access, vector math operations.
## 6. Vulkan 1.4 device & VK_EXT_shader_object SPIR-V compute shader loading.

import std/[strformat, math]
import sdl3
import vk14
import GpuStream
import SlangIntegration

# 1. Compile Slang compute shader with BDA and C-layout at compile time
const sdfData = compileSlangShader("shaders/SdfRendererVk.slang")

# 2. Minimal macro generates type definitions & compile-time size assertions
generateNimObjects(parseShaderReflection(sdfData), [
  "SceneUniforms",
  "DebugSettings",
  "Material",
  "SdfProgramData",
  "SdfInstruction",
  "PointLight",
  "SdfPushParams",
])

proc runReflectionChecks() =
  echo "--- 1. Compile-Time Slang Reflection & Type Size Assertions ---"

  echo fmt"  SceneUniforms:    {sizeof(SceneUniforms):>4} bytes (expected 108)"
  echo fmt"  DebugSettings:    {sizeof(DebugSettings):>4} bytes (expected   4)"
  echo fmt"  Material:         {sizeof(Material):>4} bytes (expected  16)"
  echo fmt"  SdfProgramData:   {sizeof(SdfProgramData):>4} bytes (expected 4096)"
  echo fmt"  SdfInstruction:   {sizeof(SdfInstruction):>4} bytes (expected   8)"
  echo fmt"  PointLight:       {sizeof(PointLight):>4} bytes (expected  36)"
  echo fmt"  SdfPushParams:    {sizeof(SdfPushParams):>4} bytes (expected  56)"

  doAssert sizeof(SceneUniforms) == 108, "SceneUniforms size mismatch"
  doAssert sizeof(DebugSettings) == 4, "DebugSettings size mismatch"
  doAssert sizeof(Material) == 16, "Material size mismatch"
  doAssert sizeof(SdfProgramData) == 4096, "SdfProgramData size mismatch"
  doAssert sizeof(SdfInstruction) == 8, "SdfInstruction size mismatch"
  doAssert sizeof(PointLight) == 36, "PointLight size mismatch"
  doAssert sizeof(SdfPushParams) == 56, "SdfPushParams size mismatch"
  doAssert sizeof(SdfPushParams) <= 128, "SdfPushParams exceeds 128-byte hardware push constant limit"

  echo "[PASS] All 7 struct sizes match Slang C-layout reflection exactly!"

proc runWorkgroupAndBindingChecks() =
  echo "--- 2. Compute Workgroup & Shader Reflection Bindings ---"

  echo fmt"  Workgroup Size:   {sdfData.workgroupX} x {sdfData.workgroupY} x {sdfData.workgroupZ}"
  doAssert sdfData.workgroupX == 8, "Expected workgroupX == 8"
  doAssert sdfData.workgroupY == 8, "Expected workgroupY == 8"
  doAssert sdfData.workgroupZ == 1, "Expected workgroupZ == 1"

  let sdfReflection = parseShaderReflection(sdfData)
  var foundPush = false
  var foundImage = false
  for p in sdfReflection.parameters:
    if p.name == "push":
      foundPush = true
      echo fmt"  Parameter 'push':        kind={p.binding.kind}, index={p.binding.index}"
      doAssert p.binding.kind == "pushConstantBuffer"
    elif p.name == "outputImage":
      foundImage = true
      echo fmt"  Parameter 'outputImage': kind={p.binding.kind}, index={p.binding.index}"
      doAssert p.binding.kind == "descriptorTableSlot"

  doAssert foundPush, "Parameter 'push' not found in reflection"
  doAssert foundImage, "Parameter 'outputImage' not found in reflection"
  echo "[PASS] Workgroup dimensions and resource bindings match specification!"

proc runVmathIntegrationChecks() =
  echo "--- 3. Direct treeform/vmath Ergonomics & Interoperability ---"

  var uniforms: SceneUniforms
  uniforms.aspect = 16.0f32 / 9.0f32
  uniforms.fov = 60.0f32
  uniforms.camPos = vec3(0.0f32, 1.5f32, 5.0f32)
  uniforms.camForward = normalize(vec3(0.0f32, -0.2f32, -1.0f32))
  uniforms.camRight = normalize(cross(uniforms.camForward, vec3(0.0f32, 1.0f32, 0.0f32)))
  uniforms.camUp = cross(uniforms.camRight, uniforms.camForward)
  uniforms.bgColor = vec3(0.05f32, 0.05f32, 0.08f32)
  uniforms.mainLightDirection = normalize(vec3(-0.5f32, -1.0f32, -0.5f32))
  uniforms.mainLightColor = vec3(1.0f32, 0.95f32, 0.85f32)
  uniforms.ambientLightColor = vec3(0.1f32, 0.12f32, 0.15f32)
  uniforms.specularExponent = 48.0f32

  # Direct field access without copies
  doAssert abs(uniforms.camPos.x - 0.0f32) < 1e-5
  doAssert abs(uniforms.camPos.y - 1.5f32) < 1e-5
  doAssert abs(uniforms.camPos.z - 5.0f32) < 1e-5

  # Vector arithmetic with vmath
  let movedPos = uniforms.camPos + uniforms.camForward * 2.0f32
  doAssert movedPos.z < uniforms.camPos.z

  # Material and SdfProgramData
  var progData: SdfProgramData
  progData.materialData[0] = Material(
    color: vec3(0.9f32, 0.3f32, 0.2f32),
    metalness: 0.8f32
  )
  doAssert progData.materialData[0].color.x == 0.9f32
  doAssert progData.materialData[0].metalness == 0.8f32

  # PointLight
  var light: PointLight
  light.position = vec3(3.0f32, 4.0f32, 1.0f32)
  light.color = vec3(1.0f32, 0.8f32, 0.6f32)
  light.constTerm = 1.0f32
  light.linearFalloff = 0.09f32
  light.expFalloff = 0.032f32
  doAssert light.position.y == 4.0f32
  doAssert light.color.z == 0.6f32

  # SdfPushParams pointer block
  var pushParams: SdfPushParams
  pushParams.scene = 0x1000_2000'u64
  pushParams.debugOpt = 0x1000_3000'u64
  pushParams.progData = 0x1000_4000'u64
  pushParams.prog = 0x1000_5000'u64
  pushParams.pointLights = 0x1000_6000'u64
  pushParams.progArgs = 0x1000_7000'u64
  pushParams.lightCount = 4'u32
  pushParams.instructionCount = 64'u32

  doAssert pushParams.scene == 0x1000_2000'u64
  doAssert pushParams.lightCount == 4'u32
  doAssert pushParams.instructionCount == 64'u32

  echo "[PASS] Direct vmath assignments, math operations, and zero-copy field access verified!"

proc runVulkanHardwareShaderObjectChecks() =
  echo "--- 4. Vulkan 1.4 Device & VK_EXT_shader_object Compatibility ---"

  if not init(INIT_VIDEO):
    quit "Failed to init SDL3"
  defer: sdl3.quit()

  let win = createWindow("VulkanShaderTest", 64, 64, WINDOW_VULKAN or WINDOW_HIDDEN)
  if win == nil:
    quit "Failed to create SDL3 Vulkan window"
  defer: destroyWindow(win)

  var device = initGpuDevice(win)
  defer: device.destroy()
  echo "  Initialized Vulkan 1.4 physical device & logical device"

  let computeShader = device.loadComputeShader(sdfData.bytecode, "main")
  echo fmt"  Successfully loaded VK_EXT_shader_object from SPIR-V bytecode ({sdfData.bytecode.len} bytes)"
  doAssert computeShader.handle.uint64 != 0'u64, "Shader handle must be non-null"

  computeShader.destroy()
  echo "  Destroyed compute shader object"

  echo "[PASS] SPIR-V binary loaded and verified successfully on Vulkan 1.4 hardware!"

proc main() =
  echo ""
  echo "================================================================================"
  echo "  Checkpoint 2: Full SDF Slang Shader BDA Migration & Reflection Test           "
  echo "================================================================================"
  echo fmt"Shader Source:  {sdfData.sourcePath}"
  echo fmt"SPIR-V Output:  {sdfData.spvPath} ({sdfData.bytecode.len} bytes)"
  echo fmt"Reflection:    {sdfData.reflectionPath}"
  echo ""

  runReflectionChecks()
  echo ""
  runWorkgroupAndBindingChecks()
  echo ""
  runVmathIntegrationChecks()
  echo ""
  runVulkanHardwareShaderObjectChecks()
  echo ""

  echo "================================================================================"
  echo "  [SUCCESS] All Checkpoint 2 tests passed!                                     "
  echo "================================================================================"
  echo ""

when isMainModule:
  main()
