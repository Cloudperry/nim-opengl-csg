import std/[strformat, math, os, strutils]
import sdl3
import vk14
import GpuStream
import SlangIntegration

# 1. Compile-time Slang shader compilation & type generation via Slangc
importAndCompileShader("shaders/Test2D.slang", ["TestParams", "PushConstants"])

proc main() =
  let args = commandLineParams()
  var headlessPath = ""
  var testResize = false
  for a in args:
    if a.startsWith("--screenshotPath="):
      headlessPath = a.substr("--screenshotPath=".len)
    elif a == "--testResize":
      testResize = true

  if not init(INIT_VIDEO):
    quit fmt"Error initializing SDL3: {getError()}"

  var winWidth = 1280'i32
  var winHeight = 720'i32
  let flags = WINDOW_VULKAN or WINDOW_RESIZABLE or (if headlessPath.len > 0 and not testResize: WINDOW_HIDDEN else: 0.uint32)
  var win = createWindow("Checkpoint 1: 2D SDF Animated Circle", winWidth, winHeight, flags)
  if win == nil:
    quit fmt"Error creating window: {getError()}"

  # 2. Initialize GpuDevice
  var device = initGpuDevice(win)

  # 3. Create Target & Swapchain
  var target = createTarget(device, win, winWidth, winHeight)

  # 4. Load SPIR-V Compute Shader Object (bytecode embedded at compile-time by importAndCompileShader)
  let spvCode = getShaderCode_computeMain()
  var shader = loadComputeShader(device, spvCode, "main")

  # 5. Initialize Command Stream
  var stream = initGpuStream(device)

  # 6. Allocate host-mapped GPU buffer slice for TestParams
  var paramsSlice = allocSlice[TestParams](device, 1)

  let meta = getShaderMeta_computeMain()
  echo fmt"Shader reflection metadata: workgroup size = ({meta.workgroupX}, {meta.workgroupY}, {meta.workgroupZ})"

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
      of EVENT_WINDOW_PIXEL_SIZE_CHANGED, EVENT_WINDOW_RESIZED:
        let newW = event.window.data1
        let newH = event.window.data2
        if newW > 0 and newH > 0:
          echo fmt"Window resized event: {newW}x{newH}, resizing target..."
          target.resize(newW, newH)
      else:
        discard

    if testResize:
      if frameCount == 4:
        echo "Testing programmatic resize: 1280x720 -> 800x600"
        target.resize(800, 600)
      elif frameCount == 8:
        echo "Testing programmatic resize: 800x600 -> 1024x768"
        target.resize(1024, 768)
      elif frameCount == 12:
        echo "Testing programmatic resize: 1024x768 -> 1280x720"
        target.resize(1280, 720)
      elif frameCount == 16:
        echo "All programmatic resize cycles passed!"
        running = false
        break

    inc frameCount
    let timeVal = frameCount.float32 * 0.025f32

    # Skip rendering if window is minimized (width or height is 0)
    if target.width <= 0 or target.height <= 0:
      sleep(16)
      continue

    # Update TestParams in host-mapped VRAM directly (clean C struct layout, dynamic aspect ratio)
    paramsSlice[0] = TestParams(
      colorA: [0.95f32, 0.25f32, 0.15f32, 1.0f32],   # Warm coral red
      colorB: [0.15f32, 0.65f32, 0.95f32, 1.0f32],   # Cyan blue
      center: [0.0f32, 0.0f32],
      radius: 0.5f32,
      time: timeVal,
      aspectRatio: target.width.float32 / target.height.float32,
    )

    if not stream.beginFrame(target):
      target.resize(win, force = true)
      continue

    let wgX = (target.width.uint32 + meta.workgroupX - 1) div meta.workgroupX
    let wgY = (target.height.uint32 + meta.workgroupY - 1) div meta.workgroupY

    var push = PushConstants(params: paramsSlice.deviceAddress)
    stream.dispatch(shader, target, push, wgX, wgY, 1)

    if headlessPath.len > 0 and frameCount >= 5 and not testResize:
      # Readback and save PPM
      stream.readbackTargetPPM(target, headlessPath)
      echo fmt"Saved headless screenshot to {headlessPath}"
      running = false
      break

    if not stream.present(target):
      target.resize(win, force = true)

  discard vkDeviceWaitIdle(device.device)

  # Clean up resources in reverse order of creation
  dealloc(device, paramsSlice)
  destroy(shader)
  destroy(target)
  destroy(stream)
  destroy(device)
  destroyWindow(win)
  sdl3.quit()

  echo "Checkpoint 1 test completed cleanly!"

when isMainModule:
  main()
