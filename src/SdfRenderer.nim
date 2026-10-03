import
  std/[strformat, math, monotimes]
import std/times except `getTime`
import pkg/vmath
import pkg/confutils
import sdl3 except GPUDevice, GPUTexture, GPUBuffer, GPUSampler
import GpuStream, SlangIntegration, Logger, Scene, SdfScene

type
  RenderMode* {.size: sizeof(uint32).} = enum
    BasicLitScene = 0
    ShadowedLitScene = 1
    UnlitScene = 2
    DebugNormals = 3
    DebugStepCounts = 4

  SdfRendererScene* = enum
    DynamicObjectsTestRoom
    SoftShadowsTest

# Compile Slang compute shader and generate Nim BDA struct types
const sdfData = compileSlangShader("shaders/SdfRendererVk.slang")
generateNimObjects(parseShaderReflection(sdfData), [
  "SceneUniforms",
  "DebugSettings",
  "PointLight",
  "SdfPushParams",
])

type
  EngineState = object
    fullscreen: bool
    cameraOpts: FpCameraOptions
    camera: RasterizedCamera
    cameraLocked: bool
    lockTime: float32
    shouldClose: bool

  FrameState = object
    cursorDeltaX, cursorDeltaY, deltaTime: float

  SdfRendererState = object
    device: GpuDevice
    target: GpuTarget
    stream: GpuStream
    shader: ComputeShader
    sceneSlice: GpuSlice[SceneUniforms]
    debugSlice: GpuSlice[DebugSettings]
    progDataSlice: GpuSlice[SdfProgramData]
    progSlice: GpuSlice[SdfInstruction]
    progArgsSlice: GpuSlice[uint32]
    pointLightsSlice: GpuSlice[PointLight]
    sceneBuilder: SceneBuilder
    sceneProgramData: ref SdfProgramData
    sceneProgramInputs: ref SdfProgramInputs
    sceneProgram: ref seq[SdfInstruction]
    pointLights: seq[PointLight]
    dynamicCutter: tuple[outputI: uint8, instI: int]
    movingSphere: tuple[outputI: uint8, instI: int]
    scene: SdfRendererScene
    renderMode: RenderMode

  Config* = object
    scene* {.
      name: "scene", defaultValue: DynamicObjectsTestRoom, desc: "Select a scene"
    .}: SdfRendererScene
    renderMode* {.
      name: "renderMode", defaultValue: BasicLitScene, desc: "Initial shading/debug mode"
    .}: RenderMode
    slangBinPath* {.
      name: "slangBinPath", defaultValue: "", desc: "Slang shader compiler binary path"
    .}: string
    swapInterval* {.
      name: "swapInterval",
      defaultValue: 1,
      desc: "Controls VSync (0 = VSync off, 1 = VSync on, 2 = half-rate VSync on)"
    .}: int
    useSpirV* {.
      name: "useSpirV", defaultValue: false, desc: "Use SPIR-V for shader compilation"
    .}: bool
    camLockX* {.name: "camLockX", defaultValue: 0.0.}: float32
    camLockY* {.name: "camLockY", defaultValue: 0.0.}: float32
    camLockZ* {.name: "camLockZ", defaultValue: 0.0.}: float32
    camLockYaw* {.name: "camLockYaw", defaultValue: 0.0.}: float32
    camLockPitch* {.name: "camLockPitch", defaultValue: 0.0.}: float32
    lockTime* {.name: "lockTime", defaultValue: -1.0.}: float32
    screenshotPath* {.name: "screenshotPath", defaultValue: ""}: string

var
  state = EngineState()
  logger = Logger()
  sdfRenderer = SdfRendererState()
  win: sdl3.Window

proc updateCameraAspect(w, h: int32) =
  if h > 0:
    state.camera.aspectRatio = w.float32 / h.float32
    state.camera.updateProjectionMat()

proc dynamicObjectsScene() =
  sdfRenderer.sceneSlice[0].mainLightDirection = vec3(-5.0f32, -5.0f32, -3.0f32).normalize()
  sdfRenderer.sceneSlice[0].mainLightColor = vec3(0.9f32, 0.82f32, 0.7f32) / 6.0f32
  sdfRenderer.sceneSlice[0].ambientLightColor = vec3(0.08f32, 0.08f32, 0.08f32)
  sdfRenderer.sceneSlice[0].specularExponent = 16.0f32

  sdfRenderer.pointLights.setLen(0)
  sdfRenderer.pointLights.add PointLight(
    position: vec3(3.0f32, 1.5f32, 3.0f32),
    color: vec3(1.0f32, 0.55f32, 0.15f32),
    constTerm: 1.0f32,
    linearFalloff: 0.5f32,
    expFalloff: 1.0f32 / 20.0f32,
  )
  sdfRenderer.pointLights.add PointLight(
    position: vec3(-3.0f32, 1.5f32, 3.0f32),
    color: vec3(0.95f32, 0.90f32, 0.42f32),
    constTerm: 1.0f32,
    linearFalloff: 0.5f32,
    expFalloff: 1.0f32 / 20.0f32,
  )
  sdfRenderer.pointLights.add PointLight(
    position: vec3(0.0f32, 1.5f32, -5.0f32),
    color: vec3(0.30f32, 0.60f32, 1.0f32),
    constTerm: 1.0f32,
    linearFalloff: 0.5f32,
    expFalloff: 1.0f32 / 20.0f32,
  )
  writeSlice(sdfRenderer.pointLightsSlice, sdfRenderer.pointLights)

  sdfRenderer.sceneProgramData = new SdfProgramData
  sdfRenderer.sceneProgramInputs = new SdfProgramInputs
  sdfRenderer.sceneProgram = new seq[SdfInstruction]

  sdfRenderer.sceneBuilder = initSceneBuilder(
    sdfRenderer.sceneProgramData,
    sdfRenderer.sceneProgramInputs,
    sdfRenderer.sceneProgram,
  )

  let palette = sdfRenderer.sceneBuilder.addDefaultPalette()
  sdfRenderer.sceneBuilder.useMaterial(palette.wall)
  let innerBox =
    sdfRenderer.sceneBuilder.addRoundBox(vec3(0, 0, 0), vec3(9, 3, 9), 0.5).outputI
  let outerBox =
    sdfRenderer.sceneBuilder.addBox(vec3(0, 0, 0), vec3(10, 5, 10)).outputI
  let windowNorth =
    sdfRenderer.sceneBuilder.addBox(vec3(0, 0, -9), vec3(1.5, 1.5, 2)).outputI
  var room = sdfRenderer.sceneBuilder.cut(innerBox, outerBox).outputI
  sdfRenderer.dynamicCutter = sdfRenderer.sceneBuilder.addBox(vec3(0), vec3(1.5))
  room = sdfRenderer.sceneBuilder.cut(windowNorth, room).outputI
  room = sdfRenderer.sceneBuilder.cut(sdfRenderer.dynamicCutter.outputI, room).outputI
  sdfRenderer.sceneBuilder.useMaterial(palette.ball)
  sdfRenderer.movingSphere = sdfRenderer.sceneBuilder.addSphere(vec3(0, 0, 0), 2)
  room = sdfRenderer.sceneBuilder.smoothlyCombine(
    room, sdfRenderer.movingSphere.outputI
  ).outputI
  sdfRenderer.sceneBuilder.useMaterial(palette.wood)
  let box1 =
    sdfRenderer.sceneBuilder.addBox(vec3(0, -2, 6), vec3(2.5, 1, 2.5)).outputI
  sdfRenderer.sceneBuilder.useMaterial(palette.wall)
  let roofWindow =
    sdfRenderer.sceneBuilder.addBox(vec3(0, 5, 6), vec3(3, 2.5, 3)).outputI
  room = sdfRenderer.sceneBuilder.combine(room, box1).outputI
  room = sdfRenderer.sceneBuilder.cut(roofWindow, room).outputI
  sdfRenderer.sceneBuilder.useMaterial(palette.stone)
  let ground =
    sdfRenderer.sceneBuilder.addPlane(vec3(0, -5, 0), vec3(0, 1, 0), 0).outputI
  discard sdfRenderer.sceneBuilder.combine(room, ground)

  copyMem(sdfRenderer.progDataSlice.hostPtr, sdfRenderer.sceneProgramData[].addr, sizeof(SdfProgramData))
  writeSlice(sdfRenderer.progSlice, sdfRenderer.sceneProgram[])
  writeSlice(sdfRenderer.progArgsSlice, sdfRenderer.sceneProgramInputs.args)

proc softShadowsScene() =
  sdfRenderer.sceneSlice[0].mainLightDirection = vec3(1.0f32, -3.0f32, -3.0f32).normalize()
  sdfRenderer.sceneSlice[0].mainLightColor = vec3(0.9f32, 0.6f32, 0.3f32)
  sdfRenderer.sceneSlice[0].ambientLightColor = vec3(0.05f32, 0.05f32, 0.05f32)
  sdfRenderer.sceneSlice[0].specularExponent = 16.0f32
  sdfRenderer.pointLights.setLen(0)
  writeSlice(sdfRenderer.pointLightsSlice, sdfRenderer.pointLights)

  sdfRenderer.sceneProgramData = new SdfProgramData
  sdfRenderer.sceneProgramInputs = new SdfProgramInputs
  sdfRenderer.sceneProgram = new seq[SdfInstruction]

  sdfRenderer.sceneBuilder = initSceneBuilder(
    sdfRenderer.sceneProgramData,
    sdfRenderer.sceneProgramInputs,
    sdfRenderer.sceneProgram,
  )

  let ground =
    sdfRenderer.sceneBuilder.addPlane(vec3(0, -5, 0), vec3(0, 1, 0), 0).outputI
  let box1 = sdfRenderer.sceneBuilder.addBox(vec3(-5, -1, 0), vec3(2, 4, 2)).outputI
  let gb1 = sdfRenderer.sceneBuilder.combine(ground, box1).outputI
  let box2 = sdfRenderer.sceneBuilder.addBox(vec3(0, -2, -5), vec3(1, 3, 1)).outputI
  let gb2 = sdfRenderer.sceneBuilder.combine(gb1, box2).outputI
  let box3 = sdfRenderer.sceneBuilder.addBox(vec3(4, -3, -10), vec3(1, 2, 1)).outputI
  discard sdfRenderer.sceneBuilder.combine(gb2, box3)

  copyMem(sdfRenderer.progDataSlice.hostPtr, sdfRenderer.sceneProgramData[].addr, sizeof(SdfProgramData))
  writeSlice(sdfRenderer.progSlice, sdfRenderer.sceneProgram[])
  writeSlice(sdfRenderer.progArgsSlice, sdfRenderer.sceneProgramInputs.args)

proc initRenderer(conf: Config) =
  sdfRenderer.device = initGpuDevice(win)
  sdfRenderer.target = createTarget(sdfRenderer.device, win, 1280, 720)
  sdfRenderer.stream = initGpuStream(sdfRenderer.device)
  sdfRenderer.shader = loadComputeShader(sdfRenderer.device, sdfData.bytecode, "main")

  sdfRenderer.sceneSlice = allocSlice[SceneUniforms](sdfRenderer.device, 1)
  sdfRenderer.debugSlice = allocSlice[DebugSettings](sdfRenderer.device, 1)
  sdfRenderer.progDataSlice = allocSlice[SdfProgramData](sdfRenderer.device, 1)
  sdfRenderer.progSlice = allocSlice[SdfInstruction](sdfRenderer.device, 128)
  sdfRenderer.progArgsSlice = allocSlice[uint32](sdfRenderer.device, 1024)
  sdfRenderer.pointLightsSlice = allocSlice[PointLight](sdfRenderer.device, 32)

  sdfRenderer.scene = conf.scene
  sdfRenderer.renderMode = conf.renderMode

  case sdfRenderer.scene
  of DynamicObjectsTestRoom:
    dynamicObjectsScene()
  of SoftShadowsTest:
    softShadowsScene()

proc uninitRenderer() =
  if sdfRenderer.device != nil and sdfRenderer.device.device.int64 != 0:
    waitIdle(sdfRenderer.device)
    sdfRenderer.device.dealloc(sdfRenderer.sceneSlice)
    sdfRenderer.device.dealloc(sdfRenderer.debugSlice)
    sdfRenderer.device.dealloc(sdfRenderer.progDataSlice)
    sdfRenderer.device.dealloc(sdfRenderer.progSlice)
    sdfRenderer.device.dealloc(sdfRenderer.progArgsSlice)
    sdfRenderer.device.dealloc(sdfRenderer.pointLightsSlice)
    sdfRenderer.shader.destroy()
    sdfRenderer.stream.destroy()
    sdfRenderer.target.destroy()
    sdfRenderer.device.destroy()

proc updateCamera(frame: FrameState) =
  if not state.cameraLocked:
    var numKeys: cint
    let keyState = getKeyboardState(numKeys)
    var moveDirection = vec3(0.0f32, 0.0f32, 0.0f32)
    if keyState[SCANCODE_COMMA.int] or keyState[SCANCODE_W.int]:
      moveDirection.z -= 1
    elif keyState[SCANCODE_O.int] or keyState[SCANCODE_S.int]:
      moveDirection.z += 1
    if keyState[SCANCODE_E.int] or keyState[SCANCODE_D.int]:
      moveDirection.x += 1
    elif keyState[SCANCODE_A.int]:
      moveDirection.x -= 1
    if keyState[SCANCODE_SPACE.int]:
      moveDirection.y += 1
    elif keyState[SCANCODE_BACKSLASH.int] or keyState[SCANCODE_LSHIFT.int]:
      moveDirection.y -= 1

    state.camera.doFirstPersonCameraMovement(
      state.cameraOpts,
      moveDirection,
      frame.cursorDeltaX,
      frame.cursorDeltaY,
      frame.deltaTime,
    )

proc update(frame: FrameState) =
  updateCamera(frame)

proc updateSceneDynamicArgs() =
  case sdfRenderer.scene
  of DynamicObjectsTestRoom:
    let time =
      if state.lockTime != -1.0f32:
        state.lockTime
      else:
        getTicks().float32 / 1000.0f32
    let cutterInst = sdfRenderer.sceneProgram[][sdfRenderer.dynamicCutter.instI]
    let newX: float32 = sin(time * 0.7f32) * 10.0f32
    sdfRenderer.progArgsSlice[cutterInst.argsI.int] = cast[uint32](newX)

    let sphereInst = sdfRenderer.sceneProgram[][sdfRenderer.movingSphere.instI]
    let newY: float32 = sin(time * 0.4f32) * 5.0f32
    sdfRenderer.progArgsSlice[sphereInst.argsI.int + 1] = cast[uint32](newY)
  else:
    discard

proc draw(conf: Config) =
  if sdfRenderer.target.width <= 0 or sdfRenderer.target.height <= 0:
    return

  if not sdfRenderer.stream.beginFrame(sdfRenderer.target):
    sdfRenderer.target.resize(win, force = true)
    return

  # Writes to BDA buffers happen after beginFrame() (post-fence wait) and before present() to avoid race conditions
  updateSceneDynamicArgs()

  let w = sdfRenderer.target.width
  let h = sdfRenderer.target.height

  sdfRenderer.sceneSlice[0].aspect = w.float32 / h.float32
  sdfRenderer.sceneSlice[0].bgColor = vec3(0.2f32, 0.3f32, 0.3f32)
  sdfRenderer.sceneSlice[0].fov = 80.0f32
  sdfRenderer.sceneSlice[0].camPos = state.camera.pos
  sdfRenderer.sceneSlice[0].camForward = state.camera.forward
  sdfRenderer.sceneSlice[0].camRight = state.camera.right
  sdfRenderer.sceneSlice[0].camUp = state.camera.up

  sdfRenderer.debugSlice[0].mode = sdfRenderer.renderMode.int32

  var push = SdfPushParams(
    scene: sdfRenderer.sceneSlice.deviceAddress,
    debugOpt: sdfRenderer.debugSlice.deviceAddress,
    progData: sdfRenderer.progDataSlice.deviceAddress,
    prog: sdfRenderer.progSlice.deviceAddress,
    pointLights: sdfRenderer.pointLightsSlice.deviceAddress,
    progArgs: sdfRenderer.progArgsSlice.deviceAddress,
    lightCount: sdfRenderer.pointLights.len.uint32,
    instructionCount: sdfRenderer.sceneProgram[].len.uint32,
  )

  let groupsX = (w.uint32 + 7) div 8
  let groupsY = (h.uint32 + 7) div 8

  sdfRenderer.stream.dispatch(sdfRenderer.shader, sdfRenderer.target, push, groupsX, groupsY, 1)

  if conf.screenshotPath.len > 0:
    sdfRenderer.stream.readbackTargetPPM(sdfRenderer.target, conf.screenshotPath)
    state.shouldClose = true
  else:
    if not sdfRenderer.stream.present(sdfRenderer.target):
      sdfRenderer.target.resize(win, force = true)

proc handleKeyDown(scancode: Scancode, keymod: Keymod) =
  if scancode == SCANCODE_ESCAPE:
    state.shouldClose = true
  elif scancode == SCANCODE_F11:
    state.fullscreen = not state.fullscreen
    discard setWindowFullscreen(win, state.fullscreen)
  elif scancode == SCANCODE_F1:
    sdfRenderer.renderMode = BasicLitScene
  elif scancode == SCANCODE_F2:
    sdfRenderer.renderMode = ShadowedLitScene
  elif scancode == SCANCODE_F3:
    sdfRenderer.renderMode = UnlitScene
  elif scancode == SCANCODE_F5:
    sdfRenderer.renderMode = DebugNormals
  elif scancode == SCANCODE_F6:
    sdfRenderer.renderMode = DebugStepCounts
  elif scancode == SCANCODE_P:
    let pos = state.camera.pos
    let curTime = getTicks().float32 / 1000.0f32
    logger.log fmt"Position (X, Y, Z): ({pos.x}, {pos.y}, {pos.z})"
    logger.log fmt"Orientation (Yaw, Pitch): ({state.camera.yaw}, {state.camera.pitch})"
    logger.log fmt"Time: {curTime}"
    logger.log fmt"CLI args for this perspective and time: --camLockX={pos.x} --camLockY={pos.y} --camLockZ={pos.z} " &
      fmt"--camLockYaw={state.camera.yaw} --camLockPitch={state.camera.pitch} --lockTime={curTime}"

proc main() =
  let conf = Config.load(copyrightBanner = "Vulkan 1.4 SDF raymarching renderer")
  logger = stdout.initLogger()

  if not init(INIT_VIDEO):
    quit fmt"Error initialising SDL3: {getError()}"

  let winTitle = "Vulkan 1.4 SDF Raymarching"
  let flags = WINDOW_VULKAN or WINDOW_RESIZABLE or (if conf.screenshotPath.len > 0: WINDOW_HIDDEN else: 0.uint32)
  win = createWindow(winTitle.cstring, 1280, 720, flags)
  if win == nil:
    quit fmt"Error creating SDL3 window: {getError()}"

  if conf.screenshotPath.len == 0:
    discard setWindowRelativeMouseMode(win, true)

  initRenderer(conf)

  state.cameraOpts = FpCameraOptions()
  state.camera = initPerspectiveCamera(80, 1280 / 720, 0.1, 100, false)
  let cameraLockPos = vec3(conf.camLockX, conf.camLockY, conf.camLockZ)
  state.camera.pos = cameraLockPos
  state.camera.yaw = conf.camLockYaw
  state.camera.pitch = conf.camLockPitch
  (state.camera.forward, state.camera.right, state.camera.up) =
    state.camera.getLocalDirections()

  if cameraLockPos != vec3(0.0f32, 0.0f32, 0.0f32) or (conf.camLockYaw, conf.camLockPitch) != (0.0f32, 0.0f32):
    state.cameraLocked = true
  state.lockTime = conf.lockTime

  var frame = FrameState()
  var prevFrameStart = getMonoTime()

  while not state.shouldClose:
    frame = FrameState()
    let currFrameStart = getMonoTime()
    let frameDuration = currFrameStart - prevFrameStart
    frame.deltaTime =
      frameDuration.inNanoseconds().float / 1_000_000_000.0
    prevFrameStart = currFrameStart

    var event: Event
    while pollEvent(event):
      case event.type:
      of EVENT_QUIT:
        state.shouldClose = true
      of EVENT_WINDOW_PIXEL_SIZE_CHANGED, EVENT_WINDOW_RESIZED:
        let newW = event.window.data1
        let newH = event.window.data2
        if newW > 0 and newH > 0:
          sdfRenderer.target.resize(newW, newH)
          updateCameraAspect(newW, newH)
      of EVENT_MOUSE_MOTION:
        frame.cursorDeltaX += event.motion.xrel.float
        frame.cursorDeltaY += event.motion.yrel.float
      of EVENT_KEY_DOWN:
        handleKeyDown(event.key.scancode, event.key.`mod`)
      else:
        discard

    update(frame)
    let updateEnd = getMonoTime()
    draw(conf)
    let currFrameEnd = getMonoTime()

    logger.logPerf(
      updateEnd - currFrameStart,
      currFrameEnd - updateEnd,
      currFrameEnd - currFrameStart,
    )

  uninitRenderer()
  destroyWindow(win)

when isMainModule:
  main()
