import std/[os, strformat, options, math, monotimes, sequtils, importutils, sugar]
import std/times except `getTime`
import pkg/[glm, glfw, cligen]
from pkg/glfw/wrapper import `rawMouseMotionSupported`
import ./glad/gl
import GlUtils, Slangc, Scene, Logger, Shapes, SdfScene

makeGlObjects(RaiseError, std140Alignment):
  type GpuSceneUniforms = object
    cameraPos: Vec3f
    # Just one model to world transform for now, separate transforms for each model will be needed later
    modelToWorldMat, worldToViewMat, viewToClipMat: Mat4f
    mainLightDirection: Vec3f
    mainLightColor: Vec3f
    ambientLightColor: Vec3f

type
  RendererMode = enum
    Rasterizer
    SdfRenderer

  EngineState = object # Window/input
    fullscreen: bool
    monitor: Monitor
    prevWinProps: tuple[x, y, w, h, refreshRate: int]
    cameraOpts: FpCameraOptions
    prevCursorX, prevCursorY: float
    # Graphics
    vertexShaderText, fragmentShaderText: string
    camera: RasterizedCamera

  FrameState = object
    cursorDeltaX, cursorDeltaY, deltaTime: float

  RasterizerState = object # Renderer state and wrapper objects
    shader: ShaderRef
    uniforms: ShaderDataBufferRef[GpuSceneUniforms]
    vertexBuffers: seq[VertexBufferRef[ColoredVertex]]
    elementBuffers: seq[ElementBufferRef]
    vertexArrays: seq[VertexArrayRef]
    scene: Scene[ColoredVertex]

const
  shapeColor = vec3f(1.0)
  shadersDir = currentSourcePath().parentDir().parentDir() / "shaders"

var
  state = EngineState()
  logger = Logger()
  rasterizer = RasterizerState()

proc updateCameraAspect(win: Window, width, height: int) =
  var ratio = width / height
  case state.camera.kind
  of Perspective:
    state.camera.setPerspective(
      state.camera.verticalFov, ratio, state.camera.nearClip, state.camera.farClip
    )
  of Orthographic:
    state.camera.setOrthographic(
      state.camera.frustumLength, ratio, state.camera.nearClip, state.camera.farClip
    )

  glViewport(0, 0, width, height)

proc makeGlBuffers[T](s: Scene[T]) =
  rasterizer.vertexBuffers.setLen s.models.len
  rasterizer.elementBuffers.setLen s.models.len
  rasterizer.vertexArrays.setLen s.models.len

  for i, model in s.models:
    rasterizer.vertexBuffers[i] = initVertexBuffer (model.vertices, GL_STATIC_DRAW).some
    rasterizer.elementBuffers[i] =
      initElementBuffer (model.indices, GL_STATIC_DRAW).some
    rasterizer.vertexArrays[i] = initVertexArray()
    rasterizer.vertexArrays[i].use()
    rasterizer.vertexBuffers[i].use()
    rasterizer.vertexArrays[i].attachElementBuffer(rasterizer.elementBuffers[i])

proc setSceneUniforms[T](s: Scene[T]) =
  rasterizer.uniforms.mainLightDirection = s.dirLight.direction
  rasterizer.uniforms.mainLightColor = s.dirLight.color
  rasterizer.uniforms.ambientLightColor = s.ambientLightColor

proc init(win: Window, useSpirV: bool) =
  let monitorSize = (state.monitor.workArea.w, state.monitor.workArea.h)
  state.fullscreen = win.size == monitorSize
  (state.prevCursorX, state.prevCursorY) = win.cursorPos

  # Set camera options to defaults. Mouse sensitivity is fast on a gaming mouse, but might be too slow for a normal mouse.
  state.cameraOpts = FpCameraOptions()
  state.camera = initPerspectiveCamera(80, 150 / 100, 0.1, 100, true)
  state.camera.pos = vec3f(0, 0, 0)
  state.camera.updateTransform()

  logger = stdout.initLogger()
  let
    cube = makeCube(shapeColor)
    pyramid = makePyramid(shapeColor)
    sphere = makeSphere(0.5, 16, 16, shapeColor)
    cubeModel = initModel(
      cube.vertices,
      cube.indices,
      transform = Transform(pos: vec3f(0, 0, -2), scale: vec3f(1, 1, 1)),
    )
    pyramidModel = initModel(
      pyramid.vertices,
      pyramid.indices,
      transform = Transform(pos: vec3f(-2, 0, -2), scale: vec3f(1, 1, 1)),
    )
    sphereModel = initModel(
      sphere.vertices,
      sphere.indices,
      transform = Transform(pos: vec3f(2, 0, -2), scale: vec3f(1, 1, 1)),
    )

  let (width, height) = glfw.framebufferSize(win)
  win.updateCameraAspect(width, height)

  rasterizer.scene = initScene(
    state.camera,
    @[cubeModel, pyramidModel, sphereModel],
    DirectionalLight(
      direction: vec3f(-5, -5, -3).normalize(), color: vec3f(1, 0.6, 0.3)
    ).some,
    vec3f(0.1).some,
  )

  # Compile and link shader and check errors
  if not useSpirV:
    rasterizer.shader = initShaderProg(state.vertexShaderText, state.fragmentShaderText)
  else:
    rasterizer.shader =
      initBinShaderProg(state.vertexShaderText, state.fragmentShaderText)
  # Get used uniforms/attributes. Bare uniforms don't work in Slang so this uses UBOs.
  rasterizer.uniforms = initShaderDataBuffer[GpuSceneUniforms](
    rasterizer.shader, 0, GL_UNIFORM_BUFFER, GL_DYNAMIC_DRAW
  )

  # Set up OpenGL buffers for passing vertex data to shaders
  rasterizer.scene.makeGlBuffers()
  rasterizer.scene.setSceneUniforms()

  # Enable backface culling
  glEnable(GL_CULL_FACE)
  glCullFace(GL_BACK)
  glFrontFace(GL_CCW)

  # Enable depth buffer to for correct occlusion when rendering multiple objects 
  glEnable(GL_DEPTH_TEST)
  glDepthFunc(GL_LESS)

proc update(win: Window, frame: var FrameState) =
  let cursorPos = win.cursorPos
  (frame.cursorDeltaX, frame.cursorDeltaY) =
    (cursorPos.x - state.prevCursorX, cursorPos.y - state.prevCursorY)
  (state.prevCursorX, state.prevCursorY) = cursorPos

  # Keyboard input
  var moveDirection = vec3f(0)
  if win.isKeyDown(keyComma):
    moveDirection.z -= 1
  elif win.isKeyDown(keyO):
    moveDirection.z += 1
  if win.isKeyDown(keyE):
    moveDirection.x += 1
  elif win.isKeyDown(keyA):
    moveDirection.x -= 1
  if win.isKeyDown(keySpace):
    moveDirection.y += 1
  elif win.isKeyDown(keyBackslash):
    moveDirection.y -= 1

  state.camera.doFirstPersonCameraMovement(
    state.cameraOpts, moveDirection, frame.cursorDeltaX, frame.cursorDeltaY,
    frame.deltaTime,
  )

proc uninit() =
  for i in 0 .. rasterizer.vertexArrays.high:
    rasterizer.vertexBuffers[i].cleanup()
    rasterizer.elementBuffers[i].cleanup()
    rasterizer.vertexArrays[i].cleanup()
  rasterizer.uniforms.cleanup()
  rasterizer.shader.cleanup()

proc setUniforms(m: Model) =
  rasterizer.uniforms.modelToWorldMat = m.transform.getTransformMat()

proc setUniforms(c: RasterizedCamera)
proc draw(win: Window) =
  glClearColor(0.2, 0.3, 0.3, 1.0)
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)

  rasterizer.shader.use()
  rasterizer.uniforms.use(rasterizer.shader)
  state.camera.setUniforms()

  for i in 0 .. rasterizer.vertexArrays.high:
    rasterizer.vertexArrays[i].use()
    rasterizer.scene.models[i].setUniforms()
    glDrawElements(
      GL_TRIANGLES,
      rasterizer.scene.models[i].indices.len,
      GL_UNSIGNED_INT,
      cast[pointer](0),
    )

proc sizeCb(win: Window, size: tuple[w, h: int32]) =
  win.updateCameraAspect(size.w, size.h)

proc setUniforms(c: RasterizedCamera) =
  rasterizer.uniforms.worldToViewMat = c.viewMat
  rasterizer.uniforms.viewToClipMat = c.projectionMat

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
  win.updateCameraAspect(width, height)

proc positionCb(win: Window, pos: tuple[x, y: int32]) =
  let newMonitor = win.monitor
  privateAccess(newMonitor.type)
  if newMonitor.handle != nil:
    # Linux Wayland sometimes gave nil monitors for win.monitor, check that its not nil
    state.monitor = newMonitor

proc compileShaders(useSpirV: bool, slangPath = "") =
  # TODO: Fields are set using setter procs here to make sure the output file field gets updated. Make the API
  # in Slangc better by adding init proc.
  var opts = SlangcOptions(entryPoint: "vertexMain")
  if not useSpirV:
    opts.target = Glsl
  else:
    opts.target = SpirV
  opts.stage = Vertex
  opts.inFile = shadersDir / "RasterizedRenderer.slang"
  if slangPath.len > 0:
    opts.slangPath = slangPath
  state.vertexShaderText = compileShaderOrRaise(opts)

  opts.stage = Fragment
  opts.entryPoint = "fragmentMain"
  state.fragmentShaderText = compileShaderOrRaise(opts)

proc initGlfwAndGlad(): tuple[win: Window, cfg: OpenglWindowConfig] =
  # GLFW window and OpenGL context init
  glfw.initialize()
  var cfg = DefaultOpenglWindowConfig
  cfg.size = (w: 640, h: 480)
  cfg.title = "Simple example"
  cfg.resizable = true
  cfg.version = glv46
  cfg.forwardCompat = true
  cfg.profile = opCoreProfile
  cfg.debugContext = not (defined(release) or defined(danger))
  cfg.bits.depth = 24.some

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

  glfw.swapInterval(1)
  return (win, cfg)

proc main(slangPath = "", useSpirV = false) =
  compileShaders(useSpirV, slangPath)

  var (win, cfg) = initGlfwAndGlad()
  win.init(useSpirV)

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

when isMainModule:
  dispatch main
