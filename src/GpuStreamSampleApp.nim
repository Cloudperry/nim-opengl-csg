## Vulkan 1.4 Multi-Pass Compute Particle Simulation & Benchmark
## Features:
## - Scalable GPU-simulated particles with Buffer Device Address (BDA)
## - Pass 1: ClearTarget via vkCmdClearColorImage to dusk midnight blue
## - Pass 2: Decoupled pure compute simulation (harmonic flow field + sunset orange-to-blue gradient)
## - Pipeline memory barrier between simulation write and render read
## - Pass 3: Compute rasterization into GpuTarget storage image
## - Swapchain presentation, dynamic window resizing, and 20-second benchmark profiling

import std/[strformat, math, os, strutils, random, algorithm]
import confutils
import sdl3
import vk14
import GpuStream
import SlangIntegration

type
  ParticleConfig* = object
    particles* {.
      desc: "Number of particles to simulate (supports e.g. 500k, 1M, 5M, 500000)",
      defaultValue: "500000",
      abbr: "n" }: string
    benchmark* {.
      desc: "Run 20-second stress benchmark and print performance report",
      defaultValue: false }: bool
    screenshotPath* {.
      desc: "Optional path to save PPM screenshot after simulation/benchmark",
      defaultValue: "" }: string
    width* {.
      desc: "Initial window width",
      defaultValue: 1280 }: int
    height* {.
      desc: "Initial window height",
      defaultValue: 720 }: int

# Explicit compile-time Slang shader compilation & reflection type generation
const simData = compileSlangShader("shaders/ParticleSim.slang")
generateNimObjects(parseShaderReflection(simData), ["Particle", "SimPushConstants"])

const renderData = compileSlangShader("shaders/ParticleRender.slang")
generateNimObjects(parseShaderReflection(renderData), ["RenderPushConstants"])

proc formatCount(n: int): string =
  insertSep($n, ',')

proc parseParticleCount(s: string): int =
  var cleaned = s.toLowerAscii().replace("_", "").replace(",", "").strip()
  var multiplier = 1
  if cleaned.endsWith("m"):
    multiplier = 1_000_000
    cleaned = cleaned[0 .. ^2]
  elif cleaned.endsWith("k"):
    multiplier = 1_000
    cleaned = cleaned[0 .. ^2]
  try:
    result = parseInt(cleaned) * multiplier
    if result <= 0:
      result = 500_000
  except ValueError:
    echo "Warning: Invalid particle count '", s, "', defaulting to 500,000"
    result = 500_000

proc normalizeArgs(args: seq[string]): seq[string] =
  var i = 0
  while i < args.len:
    let a = args[i]
    if (a in ["-n", "--particles", "--screenshotPath", "--width", "--height"]) and i + 1 < args.len and not args[i+1].startsWith("-"):
      result.add a & "=" & args[i+1]
      inc i, 2
    else:
      result.add a
      inc i

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
      position: vec2(px, py),
      velocity: vec2(0.0f32, 0.0f32),
      color: vec4(1.0f32, 0.55f32, 0.18f32, 0.95f32),
      life: rand(10.0f32),
      size: sizeVal,
      speed: speedVal,
      seed: seedVal,
    )

proc switchParticles(
    device: GpuStream.GpuDevice,
    slice: var GpuSlice[Particle],
    newCount: int,
    aspect: float32,
) =
  if newCount == slice.len or newCount <= 0: return
  discard vkDeviceWaitIdle(device.device)
  dealloc(device, slice)
  slice = allocSlice[Particle](device, newCount)
  initParticles(slice, newCount, aspect)
  let mb = (sizeof(Particle) * newCount).float32 / (1024.0 * 1024.0)
  echo fmt"Switched to {formatCount(newCount)} particles ({mb:.2f} MB host-mapped VRAM)"

proc printBenchmarkSummary(frameTimes: seq[float32], count: int, totalSec: float32) =
  if frameTimes.len == 0: return
  var sorted = frameTimes
  sort(sorted)
  var totalMs = 0.0f32
  for t in sorted: totalMs += t
  let avgMs = totalMs / sorted.len.float32
  let avgFps = 1000.0f32 / avgMs
  let minMs = sorted[0]
  let maxMs = sorted[^1]
  let p99Idx = min(int(sorted.len.float32 * 0.99), sorted.len - 1)
  let p99Ms = sorted[p99Idx]
  let low1Fps = 1000.0f32 / p99Ms
  let throughputM = (count.float32 * avgFps) / 1_000_000.0f32
  let estBandwidthGB = (throughputM * 288.0f32) / 1000.0f32
  let vramMB = (sizeof(Particle) * count).float32 / (1024.0 * 1024.0)

  echo ""
  echo "================================================================================"
  echo "       Vulkan 1.4 Compute Particle Simulation (20-Second Benchmark)            "
  echo "================================================================================"
  echo fmt"Particle Count:           {formatCount(count)} particles"
  echo fmt"Buffer Memory:            {vramMB:.2f} MB (Direct BDA host-mapped VRAM)"
  echo fmt"Benchmark Duration:       {totalSec:.2f} seconds ({sorted.len} frames)"
  echo "--------------------------------------------------------------------------------"
  echo fmt"Average Framerate:        {avgFps:.1f} FPS"
  echo fmt"Average Frametime:        {avgMs:.2f} ms"
  echo fmt"1% Low Framerate:         {low1Fps:.1f} FPS ({p99Ms:.2f} ms)"
  echo fmt"Fastest Frame:            {minMs:.2f} ms ({1000.0f32 / minMs:.1f} FPS)"
  echo fmt"Slowest Frame:            {maxMs:.2f} ms ({1000.0f32 / maxMs:.1f} FPS)"
  echo "--------------------------------------------------------------------------------"
  echo fmt"Compute Throughput:       {throughputM:.1f} Million particles/sec"
  echo fmt"Est. Memory Bandwidth:    ~{estBandwidthGB:.1f} GB/sec"
  echo "================================================================================"
  echo ""

proc main() =
  let conf = ParticleConfig.load(cmdLine = normalizeArgs(commandLineParams()))
  let particleCount = parseParticleCount(conf.particles)
  let winWidth = conf.width.int32
  let winHeight = conf.height.int32
  let headlessPath = conf.screenshotPath

  if not init(INIT_VIDEO):
    quit fmt"Error initializing SDL3: {getError()}"

  let winTitle = fmt"Vulkan 1.4 Compute Particles ({formatCount(particleCount)} Particles)"
  let flags = WINDOW_VULKAN or WINDOW_RESIZABLE or (if headlessPath.len > 0: WINDOW_HIDDEN else: 0.uint32)
  var win = createWindow(winTitle.cstring, winWidth, winHeight, flags)
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
  var particlesSlice = allocSlice[Particle](device, particleCount)
  initParticles(particlesSlice, particleCount, winWidth.float32 / winHeight.float32)

  let vramMB = (sizeof(Particle) * particleCount).float32 / (1024.0 * 1024.0)
  echo fmt"Initialized {formatCount(particleCount)} particles in host-mapped VRAM ({vramMB:.2f} MB)"
  echo fmt"Simulation workgroup size: {simData.workgroupX}x{simData.workgroupY}x{simData.workgroupZ}"
  echo fmt"Rendering workgroup size: {renderData.workgroupX}x{renderData.workgroupY}x{renderData.workgroupZ}"
  if conf.benchmark:
    echo "Running 20-second stress benchmark..."
  else:
    echo "Controls: [Up] +50k | [Down] -50k | [R] Reset | [ESC] Quit"

  var running = true
  var frameCount = 0
  var lastTicks = getTicks()
  var fpsTimer = lastTicks
  var fpsFrames = 0
  var totalTime = 0.0f32
  var benchmarkTime = 0.0f32
  var frameTimes: seq[float32] = @[]

  while running:
    var event: Event
    while pollEvent(event):
      case event.type:
      of EVENT_QUIT:
        running = false
      of EVENT_KEY_DOWN:
        let curAspect = if target.height > 0: target.width.float32 / target.height.float32 else: 1.777f32
        case event.key.scancode:
        of SCANCODE_ESCAPE:
          running = false
        of SCANCODE_UP:
          let nextCount = particlesSlice.len + 50_000
          switchParticles(device, particlesSlice, nextCount, curAspect)
        of SCANCODE_DOWN:
          let nextCount = max(50_000, particlesSlice.len - 50_000)
          switchParticles(device, particlesSlice, nextCount, curAspect)
        of SCANCODE_R:
          initParticles(particlesSlice, particlesSlice.len, curAspect)
          echo "Reset and re-randomized particles!"
        else:
          discard
      of EVENT_WINDOW_PIXEL_SIZE_CHANGED, EVENT_WINDOW_RESIZED:
        let newW = event.window.data1
        let newH = event.window.data2
        if newW > 0 and newH > 0:
          target.resize(newW, newH)
      else:
        discard

    let currentTicks = getTicks()
    let frameMs = (currentTicks - lastTicks).float32
    let dt = min(frameMs / 1000.0f32, 0.05f32)
    lastTicks = currentTicks
    totalTime += dt
    inc frameCount
    inc fpsFrames

    if conf.benchmark and frameCount > 10:
      frameTimes.add(frameMs)
      benchmarkTime += frameMs / 1000.0f32

    if currentTicks - fpsTimer >= 1000:
      let elapsedSec = (currentTicks - fpsTimer).float32 / 1000.0f32
      let fps = fpsFrames.float32 / elapsedSec
      let avgMs = (elapsedSec * 1000.0f32) / fpsFrames.float32
      let mPartsPerSec = (particlesSlice.len.float32 * fps) / 1_000_000.0f32
      let titleStr = fmt"Vulkan 1.4 Particles | {formatCount(particlesSlice.len)} particles | {fps:.1f} FPS ({avgMs:.2f} ms) | {mPartsPerSec:.1f}M part/s"
      discard setWindowTitle(win, titleStr.cstring)
      echo fmt"Frame {frameCount}: {fps:.1f} FPS ({avgMs:.2f} ms) | {formatCount(particlesSlice.len)} particles | {mPartsPerSec:.1f}M particles/sec"
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
    let activeCount = particlesSlice.len.uint32

    # --- Pass 1: Clear Target Image to Dusk Midnight Blue Backdrop ---
    stream.clearTarget(target, 0.015f32, 0.018f32, 0.040f32, 1.0f32)

    # --- Pass 2: Particle Simulation (Decoupled Pure Compute Pass) ---
    var simPush = SimPushConstants(
      particles: particlesSlice.deviceAddress,
      particleCount: activeCount,
      deltaTime: dt,
      time: totalTime,
      aspectRatio: aspect,
    )
    let simWgX = (activeCount + simData.workgroupX - 1) div simData.workgroupX
    stream.dispatch(simShader, simPush, simWgX, 1, 1)

    # --- Compute-to-Compute Memory Barrier ---
    # Ensures particle buffer writes in Pass 2 are visible to render reads in Pass 3
    stream.barrier()

    # --- Pass 3: Particle Rasterization Compute Pass ---
    var renderPush = RenderPushConstants(
      particles: particlesSlice.deviceAddress,
      particleCount: activeCount,
      screenWidth: target.width.uint32,
      screenHeight: target.height.uint32,
      aspectRatio: aspect,
    )
    let renderWgX = (activeCount + renderData.workgroupX - 1) div renderData.workgroupX
    stream.dispatch(renderShader, target, renderPush, renderWgX, 1, 1)

    # Screenshot capture for headless testing/verification
    let benchmarkDone = conf.benchmark and benchmarkTime >= 20.0f32
    let captureReady = if conf.benchmark: benchmarkDone else: (frameCount >= 20)
    if headlessPath.len > 0 and captureReady:
      stream.readbackTargetPPM(target, headlessPath)
      echo fmt"Saved particle simulation screenshot to {headlessPath}"
      if not conf.benchmark:
        running = false
        break

    if benchmarkDone:
      running = false
      printBenchmarkSummary(frameTimes, particlesSlice.len, benchmarkTime)
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
