import std/[strformat, options, math]
import pkg/vmath

# ======================================== Camera handling and basic transforms ========================================
const degToRad = PI / 180

type
  Transform* = object
    pos*: Vec3
    scale*: Vec3 = vec3(1.0, 1.0, 1.0)
    rotation*: Vec3

  ProjectionKind* = enum
    Orthographic
    Perspective

  FpCameraOptions* = object
    # Pitch/yaw scaling to match Source engine. In this engine,
    # transforms use radian rotations so Source engine constants need to be scaled.
    pitchScale*: float = 0.022 * degToRad
    yawScale*: float = 0.022 * degToRad
    sensitivity*: float = 2
    moveSpeed*: float = 3

  # TODO: Focal length sensitivity scaling for intuitive feeling sensitivity while scoping/changing FOV
  RasterizedCamera* = object
    pos*: Vec3
    # Positive yaw means turning left and positive pitch means turning up
    yaw*: float32 = 0 # Start the camera looking forward (toward -Z)
    pitch*: float32 = 0
    viewMat*, projectionMat*: Mat4
    aspectRatio*, nearClip*, farClip*: float32
    # Quick hack for updating matrices only when they are needed by the rasterizer. Think about it later,
    # if the camera class should be split for ray tracing and rasterization.
    rasterizerOn*: bool
    forward*: Vec3 = vec3(0, 0, -1)
    right*: Vec3 = vec3(1, 0, 0)
    up*: Vec3 = vec3(0, 1, 0)
    case kind*: ProjectionKind
    of Orthographic:
      frustumLength*: float32
    of Perspective:
      verticalFov*: float32

proc perspectiveRH*[T: SomeFloat](fovy, aspect, zNear, zFar: T): Mat4 =
  let tanHalfFovy = tan(fovy / T(2))
  result = mat4()
  result[0, 0] = -T(1) / (aspect * tanHalfFovy)
  result[1, 1] = -T(1) / (tanHalfFovy)
  result[2, 3] = T(-1)

  result[2, 2] = -(zFar + zNear) / (zFar - zNear)
  result[3, 2] = -(T(2) * zFar * zNear) / (zFar - zNear)

proc updateProjectionMat*(c: var RasterizedCamera) =
  if c.rasterizerOn:
    case c.kind
    of Orthographic:
      let (frustumW, frustumH) = (c.frustumLength * c.aspectRatio, c.frustumLength)
      c.projectionMat = ortho(
        -frustumW / 2, frustumW / 2, -frustumH / 2, frustumH / 2, c.nearClip, c.farClip
      )
    of Perspective:
      c.projectionMat = perspective(c.verticalFov, c.aspectRatio, c.nearClip, c.farClip)

proc initPerspectiveCamera*(
    verticalFov, aspectRatio, nearClip, farClip: float32, rasterizerOn: bool
): RasterizedCamera =
  result = RasterizedCamera(
    kind: Perspective,
    aspectRatio: aspectRatio,
    verticalFov: verticalFov,
    nearClip: nearClip,
    farClip: farClip,
    rasterizerOn: rasterizerOn,
  )
  result.updateProjectionMat()

proc setPerspective*(
    c: var RasterizedCamera, verticalFov, aspectRatio, nearClip, farClip: float32
) =
  c.kind = Perspective
  c.verticalFov = verticalFov
  c.aspectRatio = aspectRatio
  c.nearClip = nearClip
  c.farClip = farClip
  c.updateProjectionMat()

proc initOrthographicCamera*(
    frustumLength, aspectRatio, nearClip, farClip: float32
): RasterizedCamera =
  result = RasterizedCamera(
    kind: Orthographic,
    aspectRatio: aspectRatio,
    frustumLength: frustumLength,
    nearClip: nearClip,
    farClip: farClip,
  )
  result.updateProjectionMat()

proc setOrthographic*(
    c: var RasterizedCamera, frustumLength, aspectRatio, nearClip, farClip: float32
) =
  c.kind = Orthographic
  c.frustumLength = frustumLength
  c.aspectRatio = aspectRatio
  c.nearClip = nearClip
  c.farClip = farClip
  c.updateProjectionMat()

proc getTransformMat*(t: Transform): Mat4 =
  var scaleMat, translateMat, rotateMat = mat4()
  # Scaling
  scaleMat[0, 0] = t.scale.x
  scaleMat[1, 1] = t.scale.y
  scaleMat[2, 2] = t.scale.z

  # Rotation in X -> Y -> Z order (pitch -> yaw -> roll)
  let (cx, cy, cz) = (cos(t.rotation.x), cos(t.rotation.y), cos(t.rotation.z))
  let (sx, sy, sz) = (sin(t.rotation.x), sin(t.rotation.y), sin(t.rotation.z))
  rotateMat[0, 0] = cy * cz
  rotateMat[0, 1] = sx * sy * cz + cx * sz
  rotateMat[0, 2] = -cx * sy * cz + sx * sz
  rotateMat[0, 3] = 0.0

  rotateMat[1, 0] = -cy * sz
  rotateMat[1, 1] = -sx * sy * sz + cx * cz
  rotateMat[1, 2] = cx * sy * sz + sx * cz
  rotateMat[1, 3] = 0.0

  rotateMat[2, 0] = sy
  rotateMat[2, 1] = -sx * cy
  rotateMat[2, 2] = cx * cy
  rotateMat[2, 3] = 0.0

  # Translation
  translateMat[3, 0] = t.pos.x
  translateMat[3, 1] = t.pos.y
  translateMat[3, 2] = t.pos.z
  return translateMat * rotateMat * scaleMat

proc getLocalDirections*(c: RasterizedCamera): tuple[forward, right, up: Vec3] =
  let
    cosPitch = cos(c.pitch)
    sinPitch = sin(c.pitch)
    # Make camera look forward (-Z) when yaw is 0
    cosYaw = cos(c.yaw + PI / 2)
    sinYaw = sin(c.yaw + PI / 2)
    forward = vec3(cosPitch * -cosYaw, sinPitch, cosPitch * -sinYaw).normalize()
    right = cross(forward, vec3(0, 1, 0)).normalize()
    up = cross(right, forward)
  return (forward, right, up)

proc getCameraViewMat(c: RasterizedCamera): Mat4 =
  let (forward, _, up) = c.getLocalDirections()
  return lookAt(c.pos, c.pos + forward, up)

proc updateTransform*(c: var RasterizedCamera) =
  if c.rasterizerOn:
    c.viewMat = c.getCameraViewMat()

proc moveLocally*(
    c: var RasterizedCamera, co: FpCameraOptions, moveDirection: Vec3, dt: float
) =
  let moveBy = moveDirection.normalize() * co.moveSpeed * dt
  let (forward, right, up) = c.getLocalDirections()
  let moveByWorldSpace = moveBy.x * right + moveBy.y * up - moveBy.z * forward
  c.pos += moveByWorldSpace

proc rotate*(c: var RasterizedCamera, co: FpCameraOptions, deltaX, deltaY: float) =
  let deltaYaw = deltaX * co.yawScale * co.sensitivity
  let deltaPitch = deltaY * co.pitchScale * co.sensitivity

  c.yaw += deltaYaw
  c.pitch += deltaPitch

  # Prevent vertical flipping
  c.pitch = c.pitch.clamp(-PI / 2 + PI / 256, PI / 2 - PI / 256)
  # Keep yaw in -180 .. 180 degrees
  if c.yaw > PI:
    c.yaw -= 2 * PI
  if c.yaw < -PI:
    c.yaw += 2 * PI

proc doFirstPersonCameraMovement*(
    c: var RasterizedCamera,
    co: FpCameraOptions,
    moveDirection: Vec3,
    deltaX, deltaY, dt: float,
) =
  var tChanged = false
  if moveDirection != vec3(0):
    # Quick and messy fix for weird feeling vertical movement (doesn't use "correct" move speed)
    let moveDirectionPlane = vec3(moveDirection.x, 0, moveDirection.z)
    if moveDirectionPlane != vec3(0):
      c.moveLocally(co, moveDirectionPlane, dt)
    c.pos.y += moveDirection.y * co.moveSpeed * dt
    tChanged = true
  if (deltaX, deltaY) != (0.0, 0.0):
    c.rotate(co, deltaX, -deltaY)
    tChanged = true

  if tChanged:
    c.updateTransform()
    (c.forward, c.right, c.up) = c.getLocalDirections()

# ======================================== Models and rasterized scene representation ========================================
# TODO: Proper DAG-based scene graph with model hierarchies
type
  ColoredVertex* = object
    pos*, color*, normal*: Vec3

  # TODO: Add models with textures
  TexturedVertex* = object
    pos*, normal*: Vec3
    uv*: Vec2

  Model*[T] = object
    transform*: Transform
    vertices*: seq[T]
    indices*: seq[uint32]
      # Indices can be left empty and it means the model has a raw triangle vertex list

  DirectionalLight* = object
    direction*: Vec3 # This should always be normalized
    color*: Vec3

  Scene*[T] = object
    cam*: RasterizedCamera
    models*: seq[Model[T]]
    dirLight*: DirectionalLight
    ambientLightColor*: Vec3

proc posColorNorm*(pos, color, normal: Vec3): ColoredVertex =
  ColoredVertex(pos: pos, color: color, normal: normal)

proc posUvNorm*(pos: Vec3, uv: Vec2, normal: Vec3): TexturedVertex =
  TexturedVertex(pos: pos, uv: uv, normal: normal)

proc initModel*[T](
    vertices: seq[T], indices: seq[uint32] = @[], transform = Transform()
): Model[T] =
  Model[T](vertices: vertices, indices: indices, transform: transform)

proc initScene*[T](
    cam: RasterizedCamera,
    models: seq[Model[T]] = @[],
    dirLight = DirectionalLight.none,
    ambientLight = Vec3.none,
): Scene[T] =
  result = Scene[T](cam: cam, models: models)
