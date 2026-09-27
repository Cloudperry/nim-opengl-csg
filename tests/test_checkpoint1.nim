import std/[strformat, math, os, strutils]
import sdl3
import vk14
import GpuStream
import SlangIntegration

# 1. Compile-time Slang shader compilation & type generation via Slangc
importSlangShader("shaders/Test2D.slang", ["TestParams", "PushConstants"])

proc main() =
  let args = commandLineParams()
  var headlessPath = ""
  for a in args:
    if a.startsWith("--screenshotPath="):
      headlessPath = a.substr("--screenshotPath=".len)

  if not init(INIT_VIDEO):
    quit fmt"Error initializing SDL3: {getError()}"

  let winWidth = 1280'i32
  let winHeight = 720'i32
  let flags = WINDOW_VULKAN or (if headlessPath.len > 0: WINDOW_HIDDEN else: 0.uint32)
  let win = createWindow("Checkpoint 1: 2D SDF Animated Circle", winWidth, winHeight, flags)
  if win == nil:
    quit fmt"Error creating window: {getError()}"

  # 2. Initialize GpuDevice
  let device = initGpuDevice(win)

  # 3. Create Target & Swapchain
  let target = createTarget(device, win, winWidth, winHeight)

  # 4. Load SPIR-V Compute Shader Object (compiled automatically by importSlangShader)
  let spvCode = readFile(getShaderBinaryPath_computeMain())
  let shader = loadComputeShader(device, spvCode, "main")

  # 5. Initialize Command Stream
  let stream = initGpuStream(device)

  # 6. Allocate host-mapped GPU buffer slice for TestParams
  var paramsSlice = allocSlice[TestParams](device, 1)

  let meta = getShaderMeta_computeMain()
  echo fmt"Shader reflection metadata: workgroup size = ({meta.workgroupX}, {meta.workgroupY}, {meta.workgroupZ})"

  let wgX = (winWidth.uint32 + meta.workgroupX - 1) div meta.workgroupX
  let wgY = (winHeight.uint32 + meta.workgroupY - 1) div meta.workgroupY

  var running = true
  var frameCount = 0
  while running:
    var event: Event
    while pollEvent(event):
      case event.type:
      of EVENT_QUIT:
        running = false
      of EVENT_KEY_DOWN:
        if event.key.scancode == SCANCODE_ESCAPE:
          running = false
      else:
        discard

    inc frameCount
    let timeVal = frameCount.float32 * 0.025f32

    # Update TestParams in host-mapped VRAM directly (clean C struct layout, no manual padding)
    paramsSlice[0] = TestParams(
      colorA: [0.95f32, 0.25f32, 0.15f32, 1.0f32],   # Warm coral red
      colorB: [0.15f32, 0.65f32, 0.95f32, 1.0f32],   # Cyan blue
      center: [0.0f32, 0.0f32],
      radius: 0.5f32,
      time: timeVal,
      aspectRatio: winWidth.float32 / winHeight.float32,
    )

    if not stream.beginFrame(target):
      continue

    var push = PushConstants(params: paramsSlice.deviceAddress)
    stream.dispatch(shader, target, push, wgX, wgY, 1)

    if headlessPath.len > 0 and frameCount >= 5:
      # Readback and save PPM
      stream.readbackTargetPPM(target, headlessPath)
      echo fmt"Saved headless screenshot to {headlessPath}"
      running = false
      break

    stream.present(target)

  discard vkDeviceWaitIdle(device.device)
  echo "Checkpoint 1 test completed successfully!"

when isMainModule:
  main()
