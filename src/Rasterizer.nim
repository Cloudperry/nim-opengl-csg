import std/[os, strformat, options, math, monotimes, sequtils, importutils, sugar]
import std/times except `getTime`
import pkg/[glm, cligen]
import sdl3
import ./glad/gl
import GlUtils, Slangc, Scene, Logger, Shapes, SdfScene

proc glGetProc(name: cstring): pointer {.cdecl.} =
  glGetProcAddress(name)

proc getFramebufferSize*(win: Window): tuple[w, h: int] =
  var w, h: cint
  discard getWindowSizeInPixels(win, w, h)
  return (w.int, h.int)

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
    cameraOpts: FpCameraOptions
    # Graphics
    vertexShaderText, fragmentShaderText: string
    camera: RasterizedCamera
    shouldClose: bool

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

proc updateCameraAspect(width, height: int) =
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
  state.fullscreen = (getWindowFlags(win) and WINDOW_FULLSCREEN) != 0

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

  let (width, height) = getFramebufferSize(win)
  updateCameraAspect(width, height)

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

proc uninit() =
  for i in 0 .. rasterizer.vertexArrays.high:
    rasterizer.vertexBuffers[i].cleanup()
    rasterizer.elementBuffers[i].cleanup()
    rasterizer.vertexArrays[i].cleanup()
  rasterizer.uniforms.cleanup()
  rasterizer.shader.cleanup()

proc setUniforms(m: Model) =
  rasterizer.uniforms.modelToWorldMat = m.transform.getTransformMat()

proc setUniforms(c: RasterizedCamera) =
  rasterizer.uniforms.worldToViewMat = c.viewMat
  rasterizer.uniforms.viewToClipMat = c.projectionMat

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

proc handleKeyDown(win: Window, scancode: Scancode, keymod: Keymod) =
  if scancode == SCANCODE_ESCAPE:
    state.shouldClose = true
  elif (scancode == SCANCODE_RETURN and (keymod and KMOD_ALT) != 0) or
       (scancode == SCANCODE_LALT and (keymod and KMOD_SHIFT) != 0):
    state.fullscreen = not state.fullscreen
    discard setWindowFullscreen(win, state.fullscreen)
    let (width, height) = getFramebufferSize(win)
    updateCameraAspect(width, height)

proc compileShaders(useSpirV: bool, slangPath = "") =
  let target = if useSpirV: SpirV else: Glsl
  let inFile = shadersDir / "RasterizedRenderer.slang"
  let vertOpts = initSlangcOptions(inFile = inFile, stage = Vertex, entryPoint = "vertexMain", target = target)
  state.vertexShaderText = compileShaderOrRaise(vertOpts, slangPath)

  let fragOpts = initSlangcOptions(inFile = inFile, stage = Fragment, entryPoint = "fragmentMain", target = target)
  state.fragmentShaderText = compileShaderOrRaise(fragOpts, slangPath)

proc initSdlAndGlad(): tuple[win: Window, glCtx: GLContext] =
  if not init(INIT_VIDEO):
    quit fmt"Error initialising SDL3: {getError()}"

  discard glSetAttribute(GL_CONTEXT_MAJOR_VERSION, 4)
  discard glSetAttribute(GL_CONTEXT_MINOR_VERSION, 6)
  discard glSetAttribute(GL_CONTEXT_PROFILE_MASK, GL_CONTEXT_PROFILE_CORE.cint)
  discard glSetAttribute(GL_DEPTH_SIZE, 24)

  var contextFlags = GL_CONTEXT_FORWARD_COMPATIBLE_FLAG.cint
  when not (defined(release) or defined(danger)):
    contextFlags = contextFlags or GL_CONTEXT_DEBUG_FLAG.cint
  discard glSetAttribute(GL_CONTEXT_FLAGS, contextFlags)

  let win = createWindow("Simple example", 1280, 720, WINDOW_OPENGL or WINDOW_RESIZABLE)
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
  discard glSetSwapInterval(1)
  return (win, glCtx)

proc main(slangPath = "", useSpirV = false) =
  compileShaders(useSpirV, slangPath)

  var (win, glCtx) = initSdlAndGlad()
  win.init(useSpirV)

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

when isMainModule:
  dispatch main
