import std/[os, strformat, options, math, monotimes, sequtils, importutils, sugar]
import std/times except `getTime`
import pkg/[glm, glfw, confutils]
from pkg/glfw/wrapper import `rawMouseMotionSupported`
import ./glad/gl
import GlUtils, Slangc, Scene, Logger, Shapes, SdfScene

type RenderMode {.size: sizeof(uint32).} = enum
  BasicLitScene
  ShadowedLitScene
  UnlitScene
  DebugNormals
  DebugStepCounts

makeGlObjects(RaiseError, std140Alignment):
  type GpuSdfSceneUniforms = object
    aspect: GLfloat
    camPos, camForward, camRight, camUp, hitColor, bgColor: Vec3f
    fov: GLfloat
    mainLightDirection, mainLightColor, ambientLightColor: Vec3f
    specularExponent: GLfloat

  type DebugSettings = object
    mode: RenderMode

type
  EngineState = object # Window/input
    fullscreen: bool
    monitor: Monitor
    prevWinProps: tuple[x, y, w, h, refreshRate: int]
    cameraOpts: FpCameraOptions
    prevCursorX, prevCursorY: float
    # Graphics
    vertexShaderText, fragmentShaderText: string
    camera: RasterizedCamera
    cameraLocked: bool
    lockTime: float32

  FrameState = object
    cursorDeltaX, cursorDeltaY, deltaTime: float

  SdfRendererScene = enum
    DynamicObjectsTestRoom
    SoftShadowsTest

  ScreenSpaceVertex = object
    pos, uv: Vec2f

  # TODO: Move camera data in this object (possibly using the existing camera class, but without rasterization specific stuff).
  # Set uniforms by making a function that uses the camera class data.
  SdfRendererState = object
    shader: ShaderRef
    sceneUbo: ShaderDataBufferRef[GpuSdfSceneUniforms]
    debugOptUbo: ShaderDataBufferRef[DebugSettings]
    sceneProgramData: ShaderDataBufferRef[SdfProgramData]
    sceneProgramInputs: ShaderDataBufferRef[SdfProgramInputs]
    sceneProgram: ShaderDataBufferRef[seq[SdfInstruction]]
    pointLights: ShaderDataBufferRef[seq[PointLight]]
    sceneBuilder: SceneBuilder
    imagePlaneVbo: VertexBufferRef[ScreenSpaceVertex]
    imagePlaneVao: VertexArrayRef
    dynamicCutter: tuple[outputI: uint8, instI: int]
    movingSphere: tuple[outputI: uint8, instI: int]
    scene: SdfRendererScene

  Config* = object # Game settings
    scene* {.
      name: "scene", defaultValue: DynamicObjectsTestRoom, desc: "Select a scene"
    .}: SdfRendererScene
    # Renderer settings
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

const
  shapeColor = vec3f(1.0)
  shadersDir = currentSourcePath().parentDir().parentDir() / "shaders"

var
  state = EngineState()
  logger = Logger()
  sdfRenderer = SdfRendererState()

proc updateCameraAspect(width, height: int) =
  glViewport(0, 0, width, height)

proc dynamicObjectsScene() =
  sdfRenderer.sceneUbo.mainLightDirection = vec3f(-5, -5, -3).normalize()
  sdfRenderer.sceneUbo.mainLightColor = vec3f(0.9, 0.82, 0.7) / 6
  sdfRenderer.sceneUbo.ambientLightColor = vec3f(0.08)
  sdfRenderer.sceneUbo.specularExponent = 16
  sdfRenderer.pointLights.add PointLight(
    position: vec3f(3, 1.5, 3),
    color: vec3f(0.9, 0.78, 0.62),
    constTerm: 1,
    linearFalloff: 0.5,
    expFalloff: 1 / 20,
  )
  sdfRenderer.pointLights.add PointLight(
    position: vec3f(-3, 1.5, 3),
    color: vec3f(0.64, 0.8, 0.9) / 2,
    constTerm: 1,
    linearFalloff: 0.5,
    expFalloff: 1 / 20,
  )
  sdfRenderer.pointLights.add PointLight(
    position: vec3f(0, 1.5, -5),
    color: vec3f(0.8, 0.86, 1.0) / 2,
    constTerm: 1,
    linearFalloff: 0.5,
    expFalloff: 1 / 20,
  )
  sdfRenderer.pointLights.upload()

  sdfRenderer.sceneBuilder = initSceneBuilder(
    sdfRenderer.sceneProgramData.data, sdfRenderer.sceneProgramInputs.data,
    sdfRenderer.sceneProgram.data,
  )
  let palette = sdfRenderer.sceneBuilder.addDefaultPalette()
  sdfRenderer.sceneBuilder.useMaterial(palette.wall)
  let innerBox =
    sdfRenderer.sceneBuilder.addRoundBox(vec3f(0, 0, 0), vec3f(9, 3, 9), 0.5).outputI
  let outerBox =
    sdfRenderer.sceneBuilder.addBox(vec3f(0, 0, 0), vec3f(10, 5, 10)).outputI
  let windowNorth =
    sdfRenderer.sceneBuilder.addBox(vec3f(0, 0, -9), vec3f(1.5, 1.5, 2)).outputI
  var room = sdfRenderer.sceneBuilder.cut(innerBox, outerBox).outputI
  sdfRenderer.dynamicCutter = sdfRenderer.sceneBuilder.addBox(vec3f(0), vec3f(1.5))
  room = sdfRenderer.sceneBuilder.cut(windowNorth, room).outputI
  room = sdfRenderer.sceneBuilder.cut(sdfRenderer.dynamicCutter.outputI, room).outputI
  sdfRenderer.sceneBuilder.useMaterial(palette.ball)
  sdfRenderer.movingSphere = sdfRenderer.sceneBuilder.addSphere(vec3f(0, 0, 0), 2)
  room = sdfRenderer.sceneBuilder.smoothlyCombine(
    room, sdfRenderer.movingSphere.outputI
  ).outputI
  sdfRenderer.sceneBuilder.useMaterial(palette.stone)
  let box1 =
    sdfRenderer.sceneBuilder.addBox(vec3f(0, -2, 6), vec3f(2.5, 1, 2.5)).outputI
  sdfRenderer.sceneBuilder.useMaterial(palette.wall)
  let roofWindow =
    sdfRenderer.sceneBuilder.addBox(vec3f(0, 5, 6), vec3f(3, 2.5, 3)).outputI
  room = sdfRenderer.sceneBuilder.combine(room, box1).outputI
  room = sdfRenderer.sceneBuilder.cut(roofWindow, room).outputI
  sdfRenderer.sceneBuilder.useMaterial(palette.stone)
  let ground =
    sdfRenderer.sceneBuilder.addPlane(vec3f(0, -5, 0), vec3f(0, 1, 0), 0).outputI
  discard sdfRenderer.sceneBuilder.combine(room, ground)
  sdfRenderer.sceneProgramData.uploadField(materialData)

proc softShadowsScene() =
  sdfRenderer.sceneUbo.mainLightDirection = vec3f(1, -3, -3).normalize()
  sdfRenderer.sceneUbo.mainLightColor = vec3f(0.9, 0.6, 0.3)
  sdfRenderer.sceneUbo.ambientLightColor = vec3f(0.05)
  sdfRenderer.sceneUbo.specularExponent = 16
  #[sdfRenderer.pointLights.add PointLight(
    position: vec3f(3, 1.5, 3), color: vec3f(0.8, 0.4, 0) / 3,
    constTerm: 1, linearFalloff: 0.5, expFalloff: 1/20
  )
  sdfRenderer.pointLights.add PointLight(
    position: vec3f(-3, 1.5, 3), color: vec3f(0, 0.5, 0.7) / 3,
    constTerm: 1, linearFalloff: 0.5, expFalloff: 1/20
  )
  sdfRenderer.pointLights.add PointLight(
    position: vec3f(0, 1.5, -5), color: vec3f(0.4, 0.4, 0.4) / 8,
    constTerm: 1, linearFalloff: 0.5, expFalloff: 1/20
  )
  sdfRenderer.pointLights.upload()]#

  sdfRenderer.sceneBuilder = initSceneBuilder(
    sdfRenderer.sceneProgramData.data, sdfRenderer.sceneProgramInputs.data,
    sdfRenderer.sceneProgram.data,
  )
  let ground =
    sdfRenderer.sceneBuilder.addPlane(vec3f(0, -5, 0), vec3f(0, 1, 0), 0).outputI
  let box1 = sdfRenderer.sceneBuilder.addBox(vec3f(-5, -1, 0), vec3f(2, 4, 2)).outputI
  let gb1 = sdfRenderer.sceneBuilder.combine(ground, box1).outputI
  let box2 = sdfRenderer.sceneBuilder.addBox(vec3f(0, -2, -5), vec3f(1, 3, 1)).outputI
  let gb2 = sdfRenderer.sceneBuilder.combine(gb1, box2).outputI
  let box3 = sdfRenderer.sceneBuilder.addBox(vec3f(4, -3, -10), vec3f(1, 2, 1)).outputI
  discard sdfRenderer.sceneBuilder.combine(gb2, box3).outputI
  sdfRenderer.sceneProgramData.uploadField(materialData)

proc init(
    win: Window,
    useSpirV: bool,
    cameraLockPos: Vec3f,
    cameraLockYaw, cameraLockPitch, lockTime: float32,
    slangToGlslTime: Duration,
) =
  let monitorSize = (state.monitor.workArea.w, state.monitor.workArea.h)
  state.fullscreen = win.size == monitorSize
  (state.prevCursorX, state.prevCursorY) = win.cursorPos

  # Set camera options to defaults. Mouse sensitivity is fast on a gaming mouse, but might be too slow for a normal mouse.
  state.cameraOpts = FpCameraOptions()
  state.camera = initPerspectiveCamera(80, 150 / 100, 0.1, 100, false)
  state.camera.pos = cameraLockPos
  state.camera.yaw = cameraLockYaw
  state.camera.pitch = cameraLockPitch
  if cameraLockPos != vec3f(0) or (cameraLockYaw, cameraLockPitch) != (0.0'f32, 0.0'f32):
    state.cameraLocked = true
    (state.camera.forward, state.camera.right, state.camera.up) =
      state.camera.getLocalDirections()
  state.lockTime = lockTime

  logger = stdout.initLogger()
  let (width, height) = glfw.framebufferSize(win)
  updateCameraAspect(width, height)

  let shaderCompileStart = getMonoTime()
  if not useSpirV:
    sdfRenderer.shader =
      initShaderProg(state.vertexShaderText, state.fragmentShaderText)
  else:
    sdfRenderer.shader =
      initBinShaderProg(state.vertexShaderText, state.fragmentShaderText)
  let shaderCompileEnd = getMonoTime()
  let shaderCompileTime = shaderCompileEnd - shaderCompileStart
  let shaderCompileTotalTime = slangToGlslTime + shaderCompileTime
  logger.log fmt"Shader compilation took {shaderCompileTotalTime.inMicroseconds()} µs " &
    fmt"({slangToGlslTime.inMicroseconds()} µs Slang -> GLSL, {shaderCompileTime.inMicroseconds()} µs GLSL -> GPU native program)"
  sdfRenderer.sceneUbo = initShaderDataBuffer[GpuSdfSceneUniforms](
    sdfRenderer.shader, 0, GL_UNIFORM_BUFFER, GL_DYNAMIC_DRAW
  )
  sdfRenderer.debugOptUbo = initShaderDataBuffer[DebugSettings](
    sdfRenderer.shader, 1, GL_UNIFORM_BUFFER, GL_DYNAMIC_DRAW
  )
  sdfRenderer.sceneProgramData = initShaderDataBuffer[SdfProgramData](
    sdfRenderer.shader,
    0,
    GL_SHADER_STORAGE_BUFFER,
    GL_DYNAMIC_DRAW,
    data = SdfProgramData().some,
  )
  sdfRenderer.sceneProgramInputs = initShaderDataBuffer[SdfProgramInputs](
    sdfRenderer.shader,
    4,
    GL_SHADER_STORAGE_BUFFER,
    GL_DYNAMIC_DRAW,
    data = SdfProgramInputs().some,
  )
  sdfRenderer.sceneProgram = initShaderDataBuffer[seq[SdfInstruction]](
    sdfRenderer.shader,
    1,
    GL_SHADER_STORAGE_BUFFER,
    GL_DYNAMIC_DRAW,
    data = emptySdfProgram().some,
  )
  sdfRenderer.pointLights = initShaderDataBuffer[seq[PointLight]](
    sdfRenderer.shader, 2, GL_SHADER_STORAGE_BUFFER, GL_DYNAMIC_DRAW
  )

  case sdfRenderer.scene
  of DynamicObjectsTestRoom:
    dynamicObjectsScene()
  of SoftShadowsTest:
    softShadowsScene()

  let imagePlaneTriangle = @[
    ScreenSpaceVertex(pos: vec2f(-1.0, -1.0), uv: vec2f(0.0, 0.0)), # Bottom left
    ScreenSpaceVertex(pos: vec2f(3.0, -1.0), uv: vec2f(2.0, 0.0)), # Bottom right
    ScreenSpaceVertex(pos: vec2f(-1.0, 3.0), uv: vec2f(0.0, 2.0)), # Top left
  ]

  sdfRenderer.imagePlaneVbo = initVertexBuffer (imagePlaneTriangle, GL_STATIC_DRAW).some
  sdfRenderer.imagePlaneVao = initVertexArray()
  sdfRenderer.imagePlaneVao.use()
  sdfRenderer.imagePlaneVbo.use()

  glEnable(GL_FRAMEBUFFER_SRGB)

proc uninit() =
  sdfRenderer.imagePlaneVbo.cleanup()
  sdfRenderer.imagePlaneVao.cleanup()
  sdfRenderer.sceneUbo.cleanup()
  sdfRenderer.shader.cleanup()

proc update(win: Window, frame: var FrameState) =
  let cursorPos = win.cursorPos
  (frame.cursorDeltaX, frame.cursorDeltaY) =
    (cursorPos.x - state.prevCursorX, cursorPos.y - state.prevCursorY)
  (state.prevCursorX, state.prevCursorY) = cursorPos

  if not state.cameraLocked:
    var moveDirection = vec3f(0)
    if win.isKeyDown(keyComma) or win.isKeyDown(keyW):
      moveDirection.z -= 1
    elif win.isKeyDown(keyO) or win.isKeyDown(keyS):
      moveDirection.z += 1
    if win.isKeyDown(keyE) or win.isKeyDown(keyD):
      moveDirection.x += 1
    elif win.isKeyDown(keyA):
      moveDirection.x -= 1
    if win.isKeyDown(keySpace):
      moveDirection.y += 1
    elif win.isKeyDown(keyBackslash) or win.isKeyDown(keyLeftShift):
      moveDirection.y -= 1

    state.camera.doFirstPersonCameraMovement(
      state.cameraOpts, moveDirection, frame.cursorDeltaX, frame.cursorDeltaY,
      frame.deltaTime,
    )

  # Update SDF program if dynamic scene
  case sdfRenderer.scene
  of DynamicObjectsTestRoom:
    let time =
      if state.lockTime != -1.0:
        state.lockTime
      else:
        glfw.getTime().float32
    let cutterInst = sdfRenderer.sceneProgram.data[sdfRenderer.dynamicCutter.instI]
    let newX: float32 = sin(time * 0.7) * 10
    sdfRenderer.sceneProgramInputs.data.args[cutterInst.argsI.uint32] =
      cast[uint32](newX)
    let sphereInst = sdfRenderer.sceneProgram.data[sdfRenderer.movingSphere.instI]
    let newY: float32 = sin(time * 0.4) * 5
    sdfRenderer.sceneProgramInputs.data.args[sphereInst.argsI.uint32 + 1] =
      cast[uint32](newY)
  else:
    discard

proc setUniforms(c: RasterizedCamera) =
  sdfRenderer.sceneUbo.camPos = c.pos
  sdfRenderer.sceneUbo.camForward = c.forward
  sdfRenderer.sceneUbo.camRight = c.right
  sdfRenderer.sceneUbo.camUp = c.up

proc draw(win: Window) =
  glClearColor(0.2, 0.3, 0.3, 1.0)
  glClear(GL_COLOR_BUFFER_BIT)

  sdfRenderer.shader.use()
  sdfRenderer.sceneUbo.use(sdfRenderer.shader)
  # TODO: Move this into the appropriate callback
  let (width, height) = glfw.framebufferSize(win)
  sdfRenderer.sceneUbo.aspect = width / height
  sdfRenderer.sceneUbo.hitColor = vec3f(1, 1, 1)
  sdfRenderer.sceneUbo.bgColor = vec3f(0.2, 0.3, 0.3)
  sdfRenderer.sceneUbo.fov = 80
  state.camera.setUniforms()

  sdfRenderer.imagePlaneVao.use()
  sdfRenderer.sceneProgramInputs.uploadField(args)
  sdfRenderer.sceneProgram.upload()
  glDrawArrays(GL_TRIANGLES, 0, 6)

proc sizeCb(win: Window, size: tuple[w, h: int32]) =
  updateCameraAspect(size.w, size.h)

proc keyCb(
    win: Window, key: Key, scanCode: int32, action: KeyAction, modKeys: set[ModifierKey]
) =
  if key == keyEscape and action == kaDown:
    win.shouldClose = true
  elif (
    key == keyLeftAlt and win.isKeyDown(keyEnter) or
    key == keyEnter and win.isKeyDown(keyLeftAlt)
  ) and action == kaDown:
    if not state.fullscreen:
      let monitorArea = state.monitor.workArea()
      let monitorMode = state.monitor.videoMode()
      state.prevWinProps =
        (win.pos.x, win.pos.y, win.size.w, win.size.h, monitorMode.refreshRate)
      logger.log fmt"Going into fullscreen {(monitorArea.x, monitorArea.y, monitorArea.w, monitorArea.h, monitorMode.refreshRate)}"
      win.monitor = (
        state.monitor, monitorArea.x, monitorArea.y, monitorArea.w, monitorArea.h,
        monitorMode.refreshRate,
      )
    else:
      let winProps = (
        state.prevWinProps.x, state.prevWinProps.y, state.prevWinProps.w,
        state.prevWinProps.h, state.prevWinProps.refreshRate,
      )
      logger.log fmt"Going out of fullscreen {winProps}"
      win.monitor = (
        newMonitor(nil),
        state.prevWinProps.x,
        state.prevWinProps.y,
        state.prevWinProps.w,
        state.prevWinProps.h,
        state.prevWinProps.refreshRate,
      )
    state.fullscreen = not state.fullscreen

  # TODO: Camera is not getting updated using the window size callback on fullscreen. This is a hack to update it.
  # Find out why size callbacks don't fire on fullscreen.
  let (width, height) = glfw.framebufferSize(win)
  # SDF debug keybinds
  if key == keyF1 and action == kaDown:
    sdfRenderer.debugOptUbo.mode = BasicLitScene
  elif key == keyF2 and action == kaDown:
    sdfRenderer.debugOptUbo.mode = ShadowedLitScene
  elif key == keyF3 and action == kaDown:
    sdfRenderer.debugOptUbo.mode = UnlitScene
  elif key == keyF5 and action == kaDown:
    sdfRenderer.debugOptUbo.mode = DebugNormals
  elif key == keyF6 and action == kaDown:
    sdfRenderer.debugOptUbo.mode = DebugStepCounts
  elif key == keyP and action == kaDown:
    let pos = state.camera.pos
    logger.log fmt"Position (X, Y, Z): ({pos.x}, {pos.y}, {pos.z})"
    logger.log fmt"Orientation (Yaw, Pitch): ({state.camera.yaw}, {state.camera.pitch})"
    logger.log fmt"Time: {glfw.getTime().float32}"
    logger.log fmt"CLI args for this perspective and time: --camLockX={pos.x} --camLockY={pos.y} --camLockZ={pos.z} " &
      fmt"--camLockYaw={state.camera.yaw} --camLockPitch={state.camera.pitch} --lockTime={glfw.getTime().float32}"
  updateCameraAspect(width, height)

proc positionCb(win: Window, pos: tuple[x, y: int32]) =
  let newMonitor = win.monitor
  privateAccess(newMonitor.type)
  if newMonitor.handle != nil:
    # Linux Wayland sometimes gave nil monitors for win.monitor, check that its not nil
    state.monitor = newMonitor

proc compileShaders(useSpirV: bool, slangPath = "") =
  let target = if useSpirV: SpirV else: Glsl
  let inFile = shadersDir / "SdfRenderer.slang"

  let vertOpts = initSlangcOptions(inFile = inFile, stage = Vertex, target = target)
  state.vertexShaderText = compileShaderOrRaise(vertOpts, slangPath)

  let fragOpts = initSlangcOptions(inFile = inFile, stage = Fragment, target = target)
  state.fragmentShaderText = compileShaderOrRaise(fragOpts, slangPath)

proc initGlfwAndGlad(conf: Config): tuple[win: Window, cfg: OpenglWindowConfig] =
  # GLFW window and OpenGL context init
  glfw.initialize()
  var cfg = DefaultOpenglWindowConfig
  cfg.size = (w: 640, h: 480)
  cfg.title = "OpenGL SDF raymarching"
  cfg.resizable = true
  cfg.version = glv46
  cfg.forwardCompat = true
  cfg.profile = opCoreProfile
  cfg.debugContext = not (defined(release) or defined(danger))

  # GLFW init that has to be done after window creation
  var win = newWindow(cfg)
  if not gladLoadGL(getProcAddress):
    quit "Error initialising OpenGL"
  if cfg.debugContext: # Enable debug logging when using an OpenGL debug context
    #[
    This proc probably needs to be global for it to not cause a segfault as the logger proc
    let glDebugLoggerProc: LoggerProc = proc (msg: string) =
      logger.log msg
    setGlDebugLoggerProc glDebugLoggerProc
    ]#
    setupGlDebugLogging()

  win.keyCb = keyCb
  win.windowSizeCb = sizeCb
  win.windowPositionCb = positionCb
  win.aspectRatio = (3, 2)
  win.cursorMode = cmDisabled
  state.monitor = getPrimaryMonitor()

  if rawMouseMotionSupported() != 0:
    win.rawMouseMotion = true
  else:
    logger.log "Raw mouse motion not supported. Camera rotation speed will be dependent on desktop mouse settings."

  glfw.swapInterval(conf.swapInterval)
  return (win, cfg)

proc main() =
  let conf = Config.load(copyrightBanner = "Sphere tracing renderer")
  sdfRenderer.scene = conf.scene
  let slangToGlslStart = getMonoTime()
  compileShaders(conf.useSpirV, conf.slangBinPath)
  let slangToGlslEnd = getMonoTime()
  let slangToGlslTime = slangToGlslEnd - slangToGlslStart

  var (win, cfg) = initGlfwAndGlad(conf)
  let cameraPos = vec3f(conf.camLockX, conf.camLockY, conf.camLockZ)
  win.init(
    conf.useSpirV, cameraPos, conf.camLockYaw, conf.camLockPitch, conf.lockTime,
    slangToGlslTime,
  )
  sdfRenderer.debugOptUbo.mode = conf.renderMode

  var frame = FrameState()
  var prevFrameStart = getMonoTime()

  while not win.shouldClose:
    frame = FrameState()
    let currFrameStart = getMonoTime()
    let frameDuration = currFrameStart - prevFrameStart
    frame.deltaTime =
      frameDuration.inNanoseconds() / initDuration(seconds = 1).inNanoseconds()
    prevFrameStart = currFrameStart

    win.update(frame)
    let updateEnd = getMonoTime()
    win.draw()
    glfw.swapBuffers(win)

    let currFrameEnd = getMonoTime()
    logger.logPerf(
      updateEnd - currFrameStart,
      currFrameEnd - updateEnd,
      currFrameEnd - currFrameStart,
    )

    glfw.pollEvents()

  uninit()
  glfw.terminate()

  let stats = logger.getStatsForRange(0, 999)
  let fpsAvg = inNanoseconds(initDuration(seconds = 1)) / inNanoseconds(stats.avgFrame)
  let avgFrameUs = inMicroseconds(stats.avgFrame)
  let (minTime, maxTime) =
    (inMicroseconds(stats.minFrame), inMicroseconds(stats.maxFrame))
  let bufferDurationSec = inSeconds(stats.bufferDuration)
  logger.writeTerminalStatusLine some(
    &"Performance stats for last {bufferDurationSec} seconds:\n  FPS: {fpsAvg:.1f} ({avgFrameUs} µs), 5% Min/max frametimes: {minTime}/{maxTime} μs"
  )

main()
