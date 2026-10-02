## Vulkan 1.4 Multi-Pass Compute Particle Simulation
## Features:
## - 200,000 GPU-simulated particles with Buffer Device Address (BDA)
## - Pass 1: ClearTarget via vkCmdClearColorImage to dusk midnight blue
## - Pass 2: Decoupled pure compute simulation (harmonic flow field + sunset orange-to-blue gradient)
## - Pipeline memory barrier between simulation write and render read
## - Pass 3: Compute rasterization into GpuTarget storage image
## - Swapchain presentation & dynamic window resizing

import std/[strformat, math, os, strutils, random]
import sdl3
import vk14
import GpuStream
import SlangIntegration

# Explicit compile-time Slang shader compilation & reflection type generation
const simData = compileSlangShader("shaders/ParticleSim.slang")
generateNimObjects(parseShaderReflection(simData), ["Particle", "SimPushConstants"])

const renderData = compileSlangShader("shaders/ParticleRender.slang")
generateNimObjects(parseShaderReflection(renderData), ["RenderPushConstants"])

const NumParticles = 200_000

proc initParticles(slice: var GpuSlice[Particle], count: int, aspect: float32) =
  randomize(42)
  for i in 0 ..< count:
    let angle = rand(2.0 * PI)
    let dist = sqrt(rand(1.0)) * 0.95
    let px = (cos(angle) * dist * aspect).float32
    let py = (sin(angle) * dist).float32
    let seedVal = rand(1.0f32)
    let speedVal = 0.15f32 + rand(0.35f32)
    let sizeVal = 1.0f32 + rand(1.2f32)

    slice[i] = Particle(
      position: [px, py],
      velocity: [0.0f32, 0.0f32],
      color: [1.0f32, 0.55f32, 0.18f32, 0.95f32],
      life: rand(10.0f32),
      size: sizeVal,
      speed: speedVal,
      seed: seedVal,
    )

proc main() =
  let args = commandLineParams()
  var headlessPath = ""
  for a in args:
    if a.startsWith("--screenshotPath="):
      headlessPath = a.substr("--screenshotPath=".len)

  if not init(INIT_VIDEO):
    quit fmt"Error initializing SDL3: {getError()}"

  var winWidth = 1280'i32
  var winHeight = 720'i32
  let flags = WINDOW_VULKAN or WINDOW_RESIZABLE or (if headlessPath.len > 0: WINDOW_HIDDEN else: 0.uint32)
  var win = createWindow("Vulkan 1.4 Compute Particle Simulation (200k Particles)", winWidth, winHeight, flags)
  if win == nil:
    quit fmt"Error creating window: {getError()}"

  # 1. Initialize Vulkan 1.4 GpuDevice
  var device = initGpuDevice(win)

  # 2. Create Target & Swapchain
  var target = createTarget(device, win, winWidth, winHeight)

  # 3. Load SPIR-V Compute Shader Objects (bytecode embedded at compile-time)
  var simShader = loadComputeShader(device, simData.bytecode, "main")
  var renderShader = loadComputeShader(device, renderData.bytecode, "main")

  # 4. Initialize Command Stream
  var stream = initGpuStream(device)

  # 5. Allocate host-mapped GPU buffer slice for particles
  var particlesSlice = allocSlice[Particle](device, NumParticles)
  initParticles(particlesSlice, NumParticles, winWidth.float32 / winHeight.float32)

  echo fmt"Initialized {NumParticles} particles in host-mapped VRAM ({sizeof(Particle) * NumParticles div 1024} KB)"
  echo fmt"Simulation workgroup size: {simData.workgroupX}x{simData.workgroupY}x{simData.workgroupZ}"
  echo fmt"Rendering workgroup size: {renderData.workgroupX}x{renderData.workgroupY}x{renderData.workgroupZ}"

  var running = true
  var frameCount = 0
  var lastTicks = getTicks()
  var fpsTimer = lastTicks
  var fpsFrames = 0
  var totalTime = 0.0f32

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
          target.resize(newW, newH)
      else:
        discard

    let currentTicks = getTicks()
    let dt = min((currentTicks - lastTicks).float32 / 1000.0f32, 0.05f32)
    lastTicks = currentTicks
    totalTime += dt
    inc frameCount
    inc fpsFrames

    if currentTicks - fpsTimer >= 1000:
      let fps = (fpsFrames.float32 * 1000.0f32) / (currentTicks - fpsTimer).float32
      echo fmt"Frame {frameCount}: {fps:.1f} FPS (200k particles multi-pass compute)"
      fpsTimer = currentTicks
      fpsFrames = 0

    # Skip rendering if window is minimized (width or height is 0)
    if target.width <= 0 or target.height <= 0:
      sleep(16)
      continue

    if not stream.beginFrame(target):
      target.resize(win, force = true)
      continue

    let aspect = target.width.float32 / target.height.float32

    # --- Pass 1: Clear Target Image to Dusk Midnight Blue Backdrop ---
    stream.clearTarget(target, 0.015f32, 0.018f32, 0.040f32, 1.0f32)

    # --- Pass 2: Particle Simulation (Decoupled Pure Compute Pass) ---
    var simPush = SimPushConstants(
      particles: particlesSlice.deviceAddress,
      particleCount: NumParticles.uint32,
      deltaTime: dt,
      time: totalTime,
      aspectRatio: aspect,
    )
    let simWgX = (NumParticles.uint32 + simData.workgroupX - 1) div simData.workgroupX
    stream.dispatch(simShader, simPush, simWgX, 1, 1)

    # --- Compute-to-Compute Memory Barrier ---
    # Ensures particle buffer writes in Pass 2 are visible to render reads in Pass 3
    stream.barrier()

    # --- Pass 3: Particle Rasterization Compute Pass ---
    var renderPush = RenderPushConstants(
      particles: particlesSlice.deviceAddress,
      particleCount: NumParticles.uint32,
      screenWidth: target.width.uint32,
      screenHeight: target.height.uint32,
      aspectRatio: aspect,
    )
    let renderWgX = (NumParticles.uint32 + renderData.workgroupX - 1) div renderData.workgroupX
    stream.dispatch(renderShader, target, renderPush, renderWgX, 1, 1)

    # Screenshot capture for headless testing/verification
    if headlessPath.len > 0 and frameCount >= 20:
      stream.readbackTargetPPM(target, headlessPath)
      echo fmt"Saved particle simulation screenshot to {headlessPath}"
      running = false
      break

    # Present frame to swapchain
    if not stream.present(target):
      target.resize(win, force = true)

  discard vkDeviceWaitIdle(device.device)

  # Clean up resources in reverse order of creation
  dealloc(device, particlesSlice)
  destroy(simShader)
  destroy(renderShader)
  destroy(target)
  destroy(stream)
  destroy(device)
  destroyWindow(win)
  sdl3.quit()

  echo "Particle simulation exited cleanly!"

when isMainModule:
  main()
