import
  std/[os, strformat, strutils, options, math, monotimes, sequtils, importutils, sugar]
import std/times except `getTime`
import pkg/[glm, confutils]
import sdl3
import ./glad/gl
import GlUtils, Slangc, Scene, Logger, Shapes, SdfScene

proc glGetProc(name: cstring): pointer {.cdecl.} =
  glGetProcAddress(name)

proc getFramebufferSize*(win: Window): tuple[w, h: int] =
  var w, h: cint
  discard getWindowSizeInPixels(win, w, h)
  return (w.int, h.int)

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
    cameraOpts: FpCameraOptions
    # Graphics
    computeShaderText: string
    camera: RasterizedCamera
    cameraLocked: bool
    lockTime: float32
    shouldClose: bool

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
    outputTexture: GLuint
    blitFbo: GLuint
    fbWidth, fbHeight: int32
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
    color: vec3f(1.0, 0.55, 0.15),
    constTerm: 1,
    linearFalloff: 0.5,
    expFalloff: 1 / 20,
  )
  sdfRenderer.pointLights.add PointLight(
    position: vec3f(-3, 1.5, 3),
    color: vec3f(0.95, 0.90, 0.42),
    constTerm: 1,
    linearFalloff: 0.5,
    expFalloff: 1 / 20,
  )
  sdfRenderer.pointLights.add PointLight(
    position: vec3f(0, 1.5, -5),
    color: vec3f(0.30, 0.60, 1.0),
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
  sdfRenderer.sceneBuilder.useMaterial(palette.wood)
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

proc initComputeShaderProg(computeSrc: string, useSpirV: bool): ShaderRef =
  result = new ShaderRef
  var computeShader: GLuint = glCreateShader(GL_COMPUTE_SHADER)
  if not useSpirV:
    glShaderSourceStr(computeShader, 1, computeSrc)
    glCompileShader(computeShader)
  else:
    glShaderBinaryStr(1, addr computeShader, computeSrc)
    glSpecializeShader(
      computeShader, "main", 0, cast[ptr GLuint](nil), cast[ptr GLuint](nil)
    )
  checkErrorAndRaise(computeShader)
  result.id = glCreateProgram()
  glAttachShader(result.id, computeShader)
  glLinkProgram(result.id)
  checkLinkErrorAndRaise(result.id)
  glDeleteShader(computeShader)

# Creates (or recreates on resize) the linear color texture that the compute shader renders into, plus a framebuffer
# with that texture attached so it can be blitted to the default framebuffer.
proc initOutputTexture(width, height: int32) =
  if sdfRenderer.outputTexture != 0:
    glDeleteTextures(1, addr sdfRenderer.outputTexture)
  glGenTextures(1, addr sdfRenderer.outputTexture)
  glBindTexture(GL_TEXTURE_2D, sdfRenderer.outputTexture)
  glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA32F, width, height)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GLint(GL_NEAREST))
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GLint(GL_NEAREST))
  glBindTexture(GL_TEXTURE_2D, 0)

  if sdfRenderer.blitFbo == 0:
    glGenFramebuffers(1, addr sdfRenderer.blitFbo)
  glBindFramebuffer(GL_READ_FRAMEBUFFER, sdfRenderer.blitFbo)
  glFramebufferTexture2D(
    GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, sdfRenderer.outputTexture,
    0,
  )
  glBindFramebuffer(GL_READ_FRAMEBUFFER, 0)
  sdfRenderer.fbWidth = width
  sdfRenderer.fbHeight = height

proc init(
    win: Window,
    useSpirV: bool,
    cameraLockPos: Vec3f,
    cameraLockYaw, cameraLockPitch, lockTime: float32,
    slangToGlslTime: Duration,
) =
  state.fullscreen = (getWindowFlags(win) and WINDOW_FULLSCREEN) != 0

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
  let (width, height) = getFramebufferSize(win)
  updateCameraAspect(width, height)

  let shaderCompileStart = getMonoTime()
  sdfRenderer.shader = initComputeShaderProg(state.computeShaderText, useSpirV)
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

  initOutputTexture(width.int32, height.int32)

  glEnable(GL_FRAMEBUFFER_SRGB)

proc uninit() =
  glDeleteTextures(1, addr sdfRenderer.outputTexture)
  glDeleteFramebuffers(1, addr sdfRenderer.blitFbo)
  sdfRenderer.sceneUbo.cleanup()
  sdfRenderer.shader.cleanup()

proc update(win: Window, frame: var FrameState) =
  if not state.cameraLocked:
    var numKeys: cint
    let keyState = getKeyboardState(numKeys)
    var moveDirection = vec3f(0)
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
        getTicks().float32 / 1000.0
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
  let (width, height) = getFramebufferSize(win)
  if width.int32 != sdfRenderer.fbWidth or height.int32 != sdfRenderer.fbHeight:
    initOutputTexture(width.int32, height.int32)

  sdfRenderer.shader.use()
  sdfRenderer.sceneUbo.use(sdfRenderer.shader)
  sdfRenderer.sceneUbo.aspect = width / height
  sdfRenderer.sceneUbo.hitColor = vec3f(1, 1, 1)
  sdfRenderer.sceneUbo.bgColor = vec3f(0.2, 0.3, 0.3)
  sdfRenderer.sceneUbo.fov = 80
  state.camera.setUniforms()

  sdfRenderer.sceneProgramInputs.uploadField(args)
  sdfRenderer.sceneProgram.upload()

  # Render the scene into the output texture with the compute shader
  glBindImageTexture(
    3.GLuint, sdfRenderer.outputTexture, 0.GLint, false, 0.GLint, GL_WRITE_ONLY,
    GL_RGBA32F,
  )
  let groupsX = GLuint((width + 7) div 8)
  let groupsY = GLuint((height + 7) div 8)
  glDispatchCompute(groupsX, groupsY, 1)
  glMemoryBarrier(GL_FRAMEBUFFER_BARRIER_BIT)

  # Blit the rendered image to the default framebuffer for display
  glBindFramebuffer(GL_READ_FRAMEBUFFER, sdfRenderer.blitFbo)
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0)
  glBlitFramebuffer(
    0, 0, width.GLint, height.GLint, 0, 0, width.GLint, height.GLint,
    GL_COLOR_BUFFER_BIT, GL_NEAREST,
  )
  glBindFramebuffer(GL_READ_FRAMEBUFFER, 0)

proc handleKeyDown(win: Window, scancode: Scancode, keymod: Keymod) =
  if scancode == SCANCODE_ESCAPE:
    state.shouldClose = true
  elif (scancode == SCANCODE_RETURN and (keymod and KMOD_ALT) != 0) or
       (scancode == SCANCODE_LALT and (keymod and KMOD_SHIFT) != 0):
    state.fullscreen = not state.fullscreen
    discard setWindowFullscreen(win, state.fullscreen)
    let (width, height) = getFramebufferSize(win)
    updateCameraAspect(width, height)
  elif scancode == SCANCODE_F1:
    sdfRenderer.debugOptUbo.mode = BasicLitScene
  elif scancode == SCANCODE_F2:
    sdfRenderer.debugOptUbo.mode = ShadowedLitScene
  elif scancode == SCANCODE_F3:
    sdfRenderer.debugOptUbo.mode = UnlitScene
  elif scancode == SCANCODE_F5:
    sdfRenderer.debugOptUbo.mode = DebugNormals
  elif scancode == SCANCODE_F6:
    sdfRenderer.debugOptUbo.mode = DebugStepCounts
  elif scancode == SCANCODE_P:
    let pos = state.camera.pos
    let curTime = getTicks().float32 / 1000.0
    logger.log fmt"Position (X, Y, Z): ({pos.x}, {pos.y}, {pos.z})"
    logger.log fmt"Orientation (Yaw, Pitch): ({state.camera.yaw}, {state.camera.pitch})"
    logger.log fmt"Time: {curTime}"
    logger.log fmt"CLI args for this perspective and time: --camLockX={pos.x} --camLockY={pos.y} --camLockZ={pos.z} " &
      fmt"--camLockYaw={state.camera.yaw} --camLockPitch={state.camera.pitch} --lockTime={curTime}"

proc compileShaders(useSpirV: bool, slangPath = "") =
  let target = if useSpirV: SpirV else: Glsl
  let opts = initSlangcOptions(
    inFile = shadersDir / "SdfRenderer.slang", stage = Compute, target = target
  )
  state.computeShaderText = compileShaderOrRaise(opts, slangPath)
  if not useSpirV:
    state.computeShaderText = state.computeShaderText.replace(
      "#extension GL_EXT_samplerless_texture_functions : require\n", ""
    )

proc initSdlAndGlad(conf: Config): tuple[win: Window, glCtx: GLContext] =
  if not init(INIT_VIDEO):
    quit fmt"Error initialising SDL3: {getError()}"

  discard glSetAttribute(GL_CONTEXT_MAJOR_VERSION, 4)
  discard glSetAttribute(GL_CONTEXT_MINOR_VERSION, 6)
  discard glSetAttribute(GL_CONTEXT_PROFILE_MASK, GL_CONTEXT_PROFILE_CORE.cint)

  var contextFlags = GL_CONTEXT_FORWARD_COMPATIBLE_FLAG.cint
  when not (defined(release) or defined(danger)):
    contextFlags = contextFlags or GL_CONTEXT_DEBUG_FLAG.cint
  discard glSetAttribute(GL_CONTEXT_FLAGS, contextFlags)

  let win = createWindow("OpenGL SDF raymarching", 1280, 720, WINDOW_OPENGL or WINDOW_RESIZABLE)
  if win == nil:
    quit fmt"Error creating SDL3 window: {getError()}"
  let glCtx = glCreateContext(win)
  if glCtx == nil:
    quit fmt"Error creating OpenGL context: {getError()}"

  if not gladLoadGL(glGetProc):
    quit "Error initialising OpenGL via glad"

  when not (defined(release) or defined(danger)):
    setupGlDebugLogging()

  discard setWindowRelativeMouseMode(win, true)
  discard glSetSwapInterval(conf.swapInterval.cint)
  return (win, glCtx)

proc main() =
  let conf = Config.load(copyrightBanner = "Sphere tracing renderer")
  sdfRenderer.scene = conf.scene
  let slangToGlslStart = getMonoTime()
  compileShaders(conf.useSpirV, conf.slangBinPath)
  let slangToGlslEnd = getMonoTime()
  let slangToGlslTime = slangToGlslEnd - slangToGlslStart

  var (win, glCtx) = initSdlAndGlad(conf)
  let cameraPos = vec3f(conf.camLockX, conf.camLockY, conf.camLockZ)
  win.init(
    conf.useSpirV, cameraPos, conf.camLockYaw, conf.camLockPitch, conf.lockTime,
    slangToGlslTime,
  )
  sdfRenderer.debugOptUbo.mode = conf.renderMode

  var frame = FrameState()
  var prevFrameStart = getMonoTime()

  while not state.shouldClose:
    frame = FrameState()
    let currFrameStart = getMonoTime()
    let frameDuration = currFrameStart - prevFrameStart
    frame.deltaTime =
      frameDuration.inNanoseconds() / initDuration(seconds = 1).inNanoseconds()
    prevFrameStart = currFrameStart

    var event: Event
    while pollEvent(event):
      case event.type:
      of EVENT_QUIT:
        state.shouldClose = true
      of EVENT_WINDOW_PIXEL_SIZE_CHANGED, EVENT_WINDOW_RESIZED:
        let (w, h) = getFramebufferSize(win)
        updateCameraAspect(w, h)
      of EVENT_MOUSE_MOTION:
        frame.cursorDeltaX += event.motion.xrel.float
        frame.cursorDeltaY += event.motion.yrel.float
      of EVENT_KEY_DOWN:
        handleKeyDown(win, event.key.scancode, event.key.`mod`)
      else:
        discard

    win.update(frame)
    let updateEnd = getMonoTime()
    win.draw()
    discard glSwapWindow(win)

    let currFrameEnd = getMonoTime()
    logger.logPerf(
      updateEnd - currFrameStart,
      currFrameEnd - updateEnd,
      currFrameEnd - currFrameStart,
    )

  uninit()
  discard glDestroyContext(glCtx)
  destroyWindow(win)

  let stats = logger.getStatsForRange(0, 999)
  let fpsAvg = inNanoseconds(initDuration(seconds = 1)) / inNanoseconds(stats.avgFrame)
  let avgFrameUs = inMicroseconds(stats.avgFrame)
  let (minTime, maxTime) =
    (inMicroseconds(stats.minFrame), inMicroseconds(stats.maxFrame))
  let bufferDurationSec = inSeconds(stats.bufferDuration)
  logger.log fmt"Average frame time of last {bufferDurationSec} seconds: {avgFrameUs} µs ({fpsAvg:.2f} FPS)"
  logger.log fmt"Min frame time of last {bufferDurationSec} seconds: {minTime} µs ({fpsAvg:.2f} FPS)"
  logger.log fmt"Max frame time of last {bufferDurationSec} seconds: {maxTime} µs ({fpsAvg:.2f} FPS)"

when isMainModule:
  main()
