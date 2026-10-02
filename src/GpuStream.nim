import std/[strformat, strutils]
import sdl3
import vk14

when defined(windows):
  const SdlLib = "SDL3.dll"
elif defined(macosx):
  const SdlLib = "libSDL3.dylib"
else:
  const SdlLib = "libSDL3.so(|.0)"

proc vulkanGetInstanceExtensions(count: ptr uint32): cstringArray {.cdecl, dynlib: SdlLib, importc: "SDL_Vulkan_GetInstanceExtensions".}
proc vulkanCreateSurface(window: sdl3.Window, instance: VkInstance, allocator: pointer, surface: ptr VkSurfaceKHR): bool {.cdecl, dynlib: SdlLib, importc: "SDL_Vulkan_CreateSurface".}

type
  GpuDevice* = ref object
    instance*: VkInstance
    physicalDevice*: VkPhysicalDevice
    device*: VkDevice
    queue*: VkQueue
    queueFamilyIndex*: uint32
    cmdPool*: VkCommandPool
    computeLayout*: VkPipelineLayout
    descriptorLayout*: VkDescriptorSetLayout

  GpuSlice*[T] = object
    ## Typed GPU memory slice with persistent host mapping and 64-bit device address.
    buffer*: VkBuffer
    memory*: VkDeviceMemory
    deviceAddress*: uint64
    hostPtr*: ptr UncheckedArray[T]
    len*: int

  GpuTarget* = ref object
    ## Offscreen storage image + swapchain backbuffer linkage.
    device*: GpuDevice
    surface*: VkSurfaceKHR
    storageImage*: VkImage
    storageMemory*: VkDeviceMemory
    storageView*: VkImageView
    currentLayout*: VkImageLayout
    width*, height*: int32
    format*: VkFormat
    swapchain*: VkSwapchainKHR
    swapchainImages*: seq[VkImage]
    currentSwapImageIndex*: uint32

  ComputeShader* = ref object
    device*: GpuDevice
    handle*: VkShaderEXT

  GpuStream* = ref object
    ## Lightweight queue command stream.
    device*: GpuDevice
    cmdBuffer*: VkCommandBuffer
    inFlightFence*: VkFence
    imageAvailableSem*: VkSemaphore
    renderFinishedSem*: VkSemaphore

proc checkVkErr*(res: VkResult, op: string) =
  if res != VK_SUCCESS:
    quit fmt"Vulkan error in {op}: {res.int32}"

proc findMemoryType*(pDevice: VkPhysicalDevice, typeFilter: uint32, properties: uint32): uint32 =
  var memProps: VkPhysicalDeviceMemoryProperties
  vkGetPhysicalDeviceMemoryProperties(pDevice, memProps.addr)
  for i in 0'u32 ..< memProps.memoryTypeCount:
    if ((typeFilter shr i) and 1'u32) == 1'u32 and (memProps.memoryTypes[i].propertyFlags.uint32 and properties) == properties:
      return i
  quit "Failed to find suitable memory type"

proc initGpuDevice*(win: sdl3.Window, maxPushConstantBytes: int = 128): GpuDevice =
  loadVulkan()
  doAssert vkInit()
  new(result)

  # 1. Instance
  var sdlExtCount: uint32
  let sdlExtPtr = vulkanGetInstanceExtensions(sdlExtCount.addr)

  var appInfo = VkApplicationInfo(
    sType: VK_STRUCTURE_TYPE_APPLICATION_INFO,
    pApplicationName: "Vulkan 1.4 Compute Stream",
    applicationVersion: vkMakeApiVersion(0, 1, 0, 0),
    pEngineName: "GpuStream",
    engineVersion: vkMakeApiVersion(0, 1, 0, 0),
    apiVersion: VK_API_VERSION_1_4,
  )

  var instanceCI = VkInstanceCreateInfo(
    sType: VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
    pApplicationInfo: appInfo.addr,
    enabledExtensionCount: sdlExtCount,
    ppEnabledExtensionNames: sdlExtPtr,
  )

  checkVkErr(vkCreateInstance(instanceCI.addr, nil, result.instance.addr), "CreateInstance")
  setInstance(cast[pointer](result.instance))
  loadVK_KHR_surface()

  # 2. Probe surface for physical device selection
  var tempSurface: VkSurfaceKHR
  if not vulkanCreateSurface(win, result.instance, nil, tempSurface.addr):
    quit fmt"Failed to create surface: {getError()}"

  # 3. Select Physical Device
  var devCount: uint32
  checkVkErr(vkEnumeratePhysicalDevices(result.instance, devCount.addr, nil), "EnumeratePhysicalDevices count")
  var devices = newSeq[VkPhysicalDevice](devCount)
  checkVkErr(vkEnumeratePhysicalDevices(result.instance, devCount.addr, devices[0].addr), "EnumeratePhysicalDevices")

  for dev in devices:
    var qCount: uint32
    vkGetPhysicalDeviceQueueFamilyProperties(dev, qCount.addr, nil)
    var qProps = newSeq[VkQueueFamilyProperties](qCount)
    vkGetPhysicalDeviceQueueFamilyProperties(dev, qCount.addr, qProps[0].addr)
    for i, q in qProps:
      var presentSupport: VkBool32 = VK_FALSE
      discard vkGetPhysicalDeviceSurfaceSupportKHR(dev, i.uint32, tempSurface, presentSupport.addr)
      if ((q.queueFlags.uint32 and (VK_QUEUE_GRAPHICS_BIT or VK_QUEUE_COMPUTE_BIT)) != 0) and presentSupport == VK_TRUE:
        result.physicalDevice = dev
        result.queueFamilyIndex = i.uint32
        break
    if result.physicalDevice.int64 != 0: break

  # Destroy probe surface immediately - physical device and queue family are selected!
  vkDestroySurfaceKHR(result.instance, tempSurface, nil)

  if result.physicalDevice.int64 == 0:
    quit "Could not find a physical device with graphics, compute, and presentation support"

  # 4. Device Features
  var shaderObjectFeatures = VkPhysicalDeviceShaderObjectFeaturesEXT(
    sType: VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SHADER_OBJECT_FEATURES_EXT,
    shaderObject: VK_TRUE,
  )
  var vk14Features = VkPhysicalDeviceVulkan14Features(
    sType: VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_4_FEATURES,
    pNext: shaderObjectFeatures.addr,
    pushDescriptor: VK_TRUE,
    hostImageCopy: VK_TRUE,
  )
  var vk13Features = VkPhysicalDeviceVulkan13Features(
    sType: VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
    pNext: vk14Features.addr,
    synchronization2: VK_TRUE,
    dynamicRendering: VK_TRUE,
    maintenance4: VK_TRUE,
  )
  var vk12Features = VkPhysicalDeviceVulkan12Features(
    sType: VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
    pNext: vk13Features.addr,
    bufferDeviceAddress: VK_TRUE,
    descriptorIndexing: VK_TRUE,
    scalarBlockLayout: VK_TRUE,
    timelineSemaphore: VK_TRUE,
  )
  var features2 = VkPhysicalDeviceFeatures2(
    sType: VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
    pNext: vk12Features.addr,
  )

  var qPriority = 1.0'f32
  var queueCI = VkDeviceQueueCreateInfo(
    sType: VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
    queueFamilyIndex: result.queueFamilyIndex,
    queueCount: 1,
    pQueuePriorities: qPriority.addr,
  )

  var deviceExts = @[
    cstring "VK_KHR_swapchain",
    cstring "VK_EXT_shader_object",
  ]

  var deviceCI = VkDeviceCreateInfo(
    sType: VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
    pNext: features2.addr,
    queueCreateInfoCount: 1,
    pQueueCreateInfos: queueCI.addr,
    enabledExtensionCount: deviceExts.len.uint32,
    ppEnabledExtensionNames: cast[cstringArray](deviceExts[0].unsafeAddr),
  )

  checkVkErr(vkCreateDevice(result.physicalDevice, deviceCI.addr, nil, result.device.addr), "CreateDevice")
  loadVK_KHR_swapchain()
  loadVK_EXT_shader_object()

  vkGetDeviceQueue(result.device, result.queueFamilyIndex, 0, result.queue.addr)

  # 5. Command Pool
  var cmdPoolCI = VkCommandPoolCreateInfo(
    sType: VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
    flags: VkCommandPoolCreateFlags(VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT),
    queueFamilyIndex: result.queueFamilyIndex,
  )
  checkVkErr(vkCreateCommandPool(result.device, cmdPoolCI.addr, nil, result.cmdPool.addr), "CreateCommandPool")

  # 6. Descriptor Set Layout (Push Descriptor for Storage Image binding 0)
  var layoutBinding = VkDescriptorSetLayoutBinding(
    binding: 0,
    descriptorType: VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,
    descriptorCount: 1,
    stageFlags: VkShaderStageFlags(VK_SHADER_STAGE_COMPUTE_BIT),
  )
  var descLayoutCI = VkDescriptorSetLayoutCreateInfo(
    sType: VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
    flags: VkDescriptorSetLayoutCreateFlags(VK_DESCRIPTOR_SET_LAYOUT_CREATE_PUSH_DESCRIPTOR_BIT_KHR),
    bindingCount: 1,
    pBindings: layoutBinding.addr,
  )
  checkVkErr(vkCreateDescriptorSetLayout(result.device, descLayoutCI.addr, nil, result.descriptorLayout.addr), "CreateDescriptorSetLayout")

  # 7. Pipeline Layout (1 Push Descriptor Set + 128 Push Constants)
  var pushRange = VkPushConstantRange(
    stageFlags: VkShaderStageFlags(VK_SHADER_STAGE_COMPUTE_BIT),
    offset: 0,
    size: maxPushConstantBytes.uint32,
  )
  var pipeLayoutCI = VkPipelineLayoutCreateInfo(
    sType: VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
    setLayoutCount: 1,
    pSetLayouts: result.descriptorLayout.addr,
    pushConstantRangeCount: 1,
    pPushConstantRanges: pushRange.addr,
  )
  checkVkErr(vkCreatePipelineLayout(result.device, pipeLayoutCI.addr, nil, result.computeLayout.addr), "CreatePipelineLayout")

# Device Destruction
proc destroy*(device: GpuDevice) =
  if device == nil: return
  if device.device.int64 != 0:
    discard vkDeviceWaitIdle(device.device)
    if device.computeLayout.int64 != 0:
      vkDestroyPipelineLayout(device.device, device.computeLayout, nil)
      device.computeLayout = VkPipelineLayout(0)
    if device.descriptorLayout.int64 != 0:
      vkDestroyDescriptorSetLayout(device.device, device.descriptorLayout, nil)
      device.descriptorLayout = VkDescriptorSetLayout(0)
    if device.cmdPool.int64 != 0:
      vkDestroyCommandPool(device.device, device.cmdPool, nil)
      device.cmdPool = VkCommandPool(0)
    vkDestroyDevice(device.device, nil)
    device.device = VkDevice(0)
  if device.instance.int64 != 0:
    vkDestroyInstance(device.instance, nil)
    device.instance = VkInstance(0)

# Typed GPU Memory Slice (Direct Memory / BDA)
proc allocSlice*[T](device: GpuDevice, count: int): GpuSlice[T] =
  result.len = count
  let sizeBytes = (sizeof(T) * count).VkDeviceSize

  var bufCI = VkBufferCreateInfo(
    sType: VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
    size: sizeBytes,
    usage: VkBufferUsageFlags(VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT or VK_BUFFER_USAGE_STORAGE_BUFFER_BIT),
    sharingMode: VK_SHARING_MODE_EXCLUSIVE,
  )
  checkVkErr(vkCreateBuffer(device.device, bufCI.addr, nil, result.buffer.addr), "CreateBuffer")

  var memReqs: VkMemoryRequirements
  vkGetBufferMemoryRequirements(device.device, result.buffer, memReqs.addr)

  # Host-visible + coherent + device-local where supported
  var memTypeIdx = findMemoryType(device.physicalDevice, memReqs.memoryTypeBits, (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT.uint32 or VK_MEMORY_PROPERTY_HOST_COHERENT_BIT.uint32))

  var allocFlags = VkMemoryAllocateFlagsInfo(
    sType: VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_FLAGS_INFO,
    flags: VkMemoryAllocateFlags(VK_MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT),
  )
  var allocInfo = VkMemoryAllocateInfo(
    sType: VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
    pNext: allocFlags.addr,
    allocationSize: memReqs.size,
    memoryTypeIndex: memTypeIdx,
  )
  checkVkErr(vkAllocateMemory(device.device, allocInfo.addr, nil, result.memory.addr), "AllocateMemory")
  checkVkErr(vkBindBufferMemory(device.device, result.buffer, result.memory, 0), "BindBufferMemory")

  # Map host pointer permanently
  var mapped: pointer
  checkVkErr(vkMapMemory(device.device, result.memory, 0.VkDeviceSize, sizeBytes, VkMemoryMapFlags(0), mapped.addr), "MapMemory")
  result.hostPtr = cast[ptr UncheckedArray[T]](mapped)

  # Retrieve 64-bit GPU virtual address
  var addrInfo = VkBufferDeviceAddressInfo(
    sType: VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO,
    buffer: result.buffer,
  )
  result.deviceAddress = vkGetBufferDeviceAddress(device.device, addrInfo.addr)

proc dealloc*[T](device: GpuDevice, slice: var GpuSlice[T]) =
  if slice.memory.int64 != 0:
    vkUnmapMemory(device.device, slice.memory)
    vkFreeMemory(device.device, slice.memory, nil)
    slice.memory = VkDeviceMemory(0)
  if slice.buffer.int64 != 0:
    vkDestroyBuffer(device.device, slice.buffer, nil)
    slice.buffer = VkBuffer(0)
  slice.hostPtr = nil
  slice.len = 0
  slice.deviceAddress = 0

template `[]`*[T](slice: GpuSlice[T], index: int): lent T =
  slice.hostPtr[index]

template `[]=`*[T](slice: var GpuSlice[T], index: int, val: T) =
  slice.hostPtr[index] = val

proc writeSlice*[T](slice: var GpuSlice[T], data: openArray[T], dstOffset = 0) =
  copyMem(slice.hostPtr[dstOffset].addr, data[0].unsafeAddr, sizeof(T) * data.len)

# Target & Swapchain Helper Procedures
proc destroyStorage(target: GpuTarget) =
  if target == nil or target.device == nil or target.device.device.int64 == 0: return
  if target.storageView.int64 != 0:
    vkDestroyImageView(target.device.device, target.storageView, nil)
    target.storageView = VkImageView(0)
  if target.storageImage.int64 != 0:
    vkDestroyImage(target.device.device, target.storageImage, nil)
    target.storageImage = VkImage(0)
  if target.storageMemory.int64 != 0:
    vkFreeMemory(target.device.device, target.storageMemory, nil)
    target.storageMemory = VkDeviceMemory(0)
  target.currentLayout = VK_IMAGE_LAYOUT_UNDEFINED

proc destroySwapchain(target: GpuTarget) =
  if target == nil or target.device == nil or target.device.device.int64 == 0: return
  if target.swapchain.int64 != 0:
    vkDestroySwapchainKHR(target.device.device, target.swapchain, nil)
    target.swapchain = VkSwapchainKHR(0)
  target.swapchainImages.setLen(0)

proc initSwapchainAndStorage(target: GpuTarget, width, height: int32) =
  var surfCaps: VkSurfaceCapabilitiesKHR
  checkVkErr(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(target.device.physicalDevice, target.surface, surfCaps.addr), "SurfaceCaps")

  var actualWidth = width.uint32
  var actualHeight = height.uint32
  if surfCaps.currentExtent.width != uint32.high and surfCaps.currentExtent.width != 0:
    actualWidth = surfCaps.currentExtent.width
    actualHeight = surfCaps.currentExtent.height
  else:
    actualWidth = clamp(actualWidth, surfCaps.minImageExtent.width, surfCaps.maxImageExtent.width)
    actualHeight = clamp(actualHeight, surfCaps.minImageExtent.height, surfCaps.maxImageExtent.height)

  if actualWidth == 0 or actualHeight == 0:
    target.width = 0
    target.height = 0
    target.currentLayout = VK_IMAGE_LAYOUT_UNDEFINED
    return

  var formatCount: uint32
  checkVkErr(vkGetPhysicalDeviceSurfaceFormatsKHR(target.device.physicalDevice, target.surface, formatCount.addr, nil), "SurfaceFormats count")
  var surfFormats = newSeq[VkSurfaceFormatKHR](formatCount)
  checkVkErr(vkGetPhysicalDeviceSurfaceFormatsKHR(target.device.physicalDevice, target.surface, formatCount.addr, surfFormats[0].addr), "SurfaceFormats")

  var chosenFormat = surfFormats[0]
  for f in surfFormats:
    if f.format == VK_FORMAT_B8G8R8A8_UNORM or f.format == VK_FORMAT_R8G8B8A8_UNORM:
      chosenFormat = f
      break
  target.format = chosenFormat.format

  let oldSwapchain = target.swapchain

  var swapchainCI = VkSwapchainCreateInfoKHR(
    sType: VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
    surface: target.surface,
    minImageCount: max(2'u32, surfCaps.minImageCount),
    imageFormat: chosenFormat.format,
    imageColorSpace: chosenFormat.colorSpace,
    imageExtent: VkExtent2D(width: actualWidth, height: actualHeight),
    imageArrayLayers: 1,
    imageUsage: VkImageUsageFlags(VK_IMAGE_USAGE_TRANSFER_DST_BIT or VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT),
    imageSharingMode: VK_SHARING_MODE_EXCLUSIVE,
    preTransform: surfCaps.currentTransform,
    compositeAlpha: VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
    presentMode: VK_PRESENT_MODE_FIFO_KHR,
    clipped: VK_TRUE,
    oldSwapchain: oldSwapchain,
  )
  checkVkErr(vkCreateSwapchainKHR(target.device.device, swapchainCI.addr, nil, target.swapchain.addr), "CreateSwapchain")

  if oldSwapchain.int64 != 0:
    vkDestroySwapchainKHR(target.device.device, oldSwapchain, nil)

  var swapImgCount: uint32
  checkVkErr(vkGetSwapchainImagesKHR(target.device.device, target.swapchain, swapImgCount.addr, nil), "SwapchainImages count")
  target.swapchainImages = newSeq[VkImage](swapImgCount)
  checkVkErr(vkGetSwapchainImagesKHR(target.device.device, target.swapchain, swapImgCount.addr, target.swapchainImages[0].addr), "SwapchainImages")

  # Storage image follows swapchain format exactly to eliminate color channel mismatch in vkCmdCopyImage2
  # Added VK_IMAGE_USAGE_TRANSFER_DST_BIT to allow vkCmdClearColorImage clears
  var offImgCI = VkImageCreateInfo(
    sType: VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
    imageType: VK_IMAGE_TYPE_2D,
    format: target.format,
    extent: VkExtent3D(width: actualWidth, height: actualHeight, depth: 1),
    mipLevels: 1,
    arrayLayers: 1,
    samples: VK_SAMPLE_COUNT_1_BIT,
    tiling: VK_IMAGE_TILING_OPTIMAL,
    usage: VkImageUsageFlags(VK_IMAGE_USAGE_STORAGE_BIT or VK_IMAGE_USAGE_TRANSFER_SRC_BIT or VK_IMAGE_USAGE_TRANSFER_DST_BIT),
    sharingMode: VK_SHARING_MODE_EXCLUSIVE,
    initialLayout: VK_IMAGE_LAYOUT_UNDEFINED,
  )
  checkVkErr(vkCreateImage(target.device.device, offImgCI.addr, nil, target.storageImage.addr), "CreateStorageImage")

  var offMemReqs: VkMemoryRequirements
  vkGetImageMemoryRequirements(target.device.device, target.storageImage, offMemReqs.addr)
  var offAllocInfo = VkMemoryAllocateInfo(
    sType: VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
    allocationSize: offMemReqs.size,
    memoryTypeIndex: findMemoryType(target.device.physicalDevice, offMemReqs.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT.uint32),
  )
  checkVkErr(vkAllocateMemory(target.device.device, offAllocInfo.addr, nil, target.storageMemory.addr), "AllocateStorageMemory")
  checkVkErr(vkBindImageMemory(target.device.device, target.storageImage, target.storageMemory, 0), "BindStorageMemory")

  var viewCI = VkImageViewCreateInfo(
    sType: VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
    image: target.storageImage,
    viewType: VK_IMAGE_VIEW_TYPE_2D,
    format: target.format,
    subresourceRange: VkImageSubresourceRange(
      aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT),
      baseMipLevel: 0,
      levelCount: 1,
      baseArrayLayer: 0,
      layerCount: 1,
    ),
  )
  checkVkErr(vkCreateImageView(target.device.device, viewCI.addr, nil, target.storageView.addr), "CreateStorageImageView")

  target.width = actualWidth.int32
  target.height = actualHeight.int32
  target.currentLayout = VK_IMAGE_LAYOUT_UNDEFINED

# Target & Swapchain API
proc createTarget*(device: GpuDevice, win: sdl3.Window, width, height: int32): GpuTarget =
  new(result)
  result.device = device

  if not vulkanCreateSurface(win, device.instance, nil, result.surface.addr):
    quit "Failed to create Vulkan surface for GpuTarget"

  result.initSwapchainAndStorage(width, height)

proc resize*(target: GpuTarget, newWidth, newHeight: int32, force: bool = false) =
  if target == nil or target.device == nil: return
  if newWidth <= 0 or newHeight <= 0:
    target.width = 0
    target.height = 0
    return
  if not force and target.width == newWidth and target.height == newHeight:
    return
  checkVkErr(vkDeviceWaitIdle(target.device.device), "DeviceWaitIdle before resize")
  target.destroyStorage()
  target.initSwapchainAndStorage(newWidth, newHeight)

proc resize*(target: GpuTarget, win: sdl3.Window, force: bool = false) =
  var w, h: cint
  if getWindowSizeInPixels(win, w, h):
    target.resize(w.int32, h.int32, force)

proc destroy*(target: GpuTarget) =
  if target == nil: return
  if target.device != nil and target.device.device.int64 != 0:
    discard vkDeviceWaitIdle(target.device.device)
    target.destroyStorage()
    target.destroySwapchain()
    if target.surface.int64 != 0:
      vkDestroySurfaceKHR(target.device.instance, target.surface, nil)
      target.surface = VkSurfaceKHR(0)

# Compute Shader
proc loadComputeShader*(device: GpuDevice, spvCode: string, entryName: string = "main"): ComputeShader =
  new(result)
  result.device = device

  var pushRange = VkPushConstantRange(
    stageFlags: VkShaderStageFlags(VK_SHADER_STAGE_COMPUTE_BIT),
    offset: 0,
    size: 128,
  )

  var shaderCI = VkShaderCreateInfoEXT(
    sType: VK_STRUCTURE_TYPE_SHADER_CREATE_INFO_EXT,
    flags: VkShaderCreateFlagsEXT(0),
    stage: VK_SHADER_STAGE_COMPUTE_BIT,
    nextStage: VkShaderStageFlags(0),
    codeType: VK_SHADER_CODE_TYPE_SPIRV_EXT,
    codeSize: spvCode.len.csize_t,
    pCode: cast[pointer](spvCode.cstring),
    pName: entryName.cstring,
    setLayoutCount: 1,
    pSetLayouts: device.descriptorLayout.addr,
    pushConstantRangeCount: 1,
    pPushConstantRanges: pushRange.addr,
  )
  checkVkErr(vkCreateShadersEXT(device.device, 1, shaderCI.addr, nil, result.handle.addr), "CreateShadersEXT")

proc destroy*(shader: ComputeShader) =
  if shader == nil: return
  if shader.device != nil and shader.device.device.int64 != 0 and shader.handle.int64 != 0:
    vkDestroyShaderEXT(shader.device.device, shader.handle, nil)
    shader.handle = VkShaderEXT(0)

# GpuStream Execution
proc initGpuStream*(device: GpuDevice): GpuStream =
  new(result)
  result.device = device

  var cmdAllocInfo = VkCommandBufferAllocateInfo(
    sType: VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
    commandPool: device.cmdPool,
    level: VK_COMMAND_BUFFER_LEVEL_PRIMARY,
    commandBufferCount: 1,
  )
  checkVkErr(vkAllocateCommandBuffers(device.device, cmdAllocInfo.addr, result.cmdBuffer.addr), "AllocateCommandBuffer")

  var semCI = VkSemaphoreCreateInfo(sType: VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO)
  var fenceCI = VkFenceCreateInfo(sType: VK_STRUCTURE_TYPE_FENCE_CREATE_INFO, flags: VkFenceCreateFlags(VK_FENCE_CREATE_SIGNALED_BIT))

  checkVkErr(vkCreateSemaphore(device.device, semCI.addr, nil, result.imageAvailableSem.addr), "CreateSemaphore")
  checkVkErr(vkCreateSemaphore(device.device, semCI.addr, nil, result.renderFinishedSem.addr), "CreateSemaphore")
  checkVkErr(vkCreateFence(device.device, fenceCI.addr, nil, result.inFlightFence.addr), "CreateFence")

proc destroy*(stream: GpuStream) =
  if stream == nil: return
  if stream.device != nil and stream.device.device.int64 != 0:
    discard vkDeviceWaitIdle(stream.device.device)
    if stream.imageAvailableSem.int64 != 0:
      vkDestroySemaphore(stream.device.device, stream.imageAvailableSem, nil)
      stream.imageAvailableSem = VkSemaphore(0)
    if stream.renderFinishedSem.int64 != 0:
      vkDestroySemaphore(stream.device.device, stream.renderFinishedSem, nil)
      stream.renderFinishedSem = VkSemaphore(0)
    if stream.inFlightFence.int64 != 0:
      vkDestroyFence(stream.device.device, stream.inFlightFence, nil)
      stream.inFlightFence = VkFence(0)
    if stream.cmdBuffer.int64 != 0:
      var buf = stream.cmdBuffer
      vkFreeCommandBuffers(stream.device.device, stream.device.cmdPool, 1, buf.addr)
      stream.cmdBuffer = VkCommandBuffer(0)

proc beginFrame*(stream: GpuStream, target: GpuTarget): bool =
  if target.width <= 0 or target.height <= 0 or target.swapchain.int64 == 0:
    return false

  checkVkErr(vkWaitForFences(stream.device.device, 1, stream.inFlightFence.addr, VK_TRUE, uint64.high), "WaitForFences")

  let acqRes = vkAcquireNextImageKHR(stream.device.device, target.swapchain, uint64.high, stream.imageAvailableSem, VkFence(0), target.currentSwapImageIndex.addr)
  if acqRes == VK_ERROR_OUT_OF_DATE_KHR:
    return false
  elif acqRes != VK_SUCCESS and acqRes != VK_SUBOPTIMAL_KHR:
    quit fmt"Vulkan error in vkAcquireNextImageKHR: {acqRes.int32}"

  checkVkErr(vkResetFences(stream.device.device, 1, stream.inFlightFence.addr), "ResetFences")
  checkVkErr(vkResetCommandBuffer(stream.cmdBuffer, VkCommandBufferResetFlags(0)), "ResetCommandBuffer")
  var beginInfo = VkCommandBufferBeginInfo(sType: VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO)
  checkVkErr(vkBeginCommandBuffer(stream.cmdBuffer, beginInfo.addr), "BeginCommandBuffer")
  return true

proc bindTarget*(stream: GpuStream, target: GpuTarget, binding: uint32 = 0) =
  ## Transitions target.storageImage to GENERAL if needed, and pushes it to descriptor set 0 at the specified binding.
  if target.currentLayout != VK_IMAGE_LAYOUT_GENERAL:
    var srcStage = VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_NONE)
    var srcAccess = VkAccessFlags2(VK_ACCESS_2_NONE)
    if target.currentLayout == VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL:
      srcStage = VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_TRANSFER_BIT)
      srcAccess = VkAccessFlags2(VK_ACCESS_2_TRANSFER_WRITE_BIT)
    elif target.currentLayout == VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL:
      srcStage = VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_TRANSFER_BIT)
      srcAccess = VkAccessFlags2(VK_ACCESS_2_TRANSFER_READ_BIT)

    var b = VkImageMemoryBarrier2(
      sType: VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
      srcStageMask: srcStage,
      srcAccessMask: srcAccess,
      dstStageMask: VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT),
      dstAccessMask: VkAccessFlags2(VK_ACCESS_2_SHADER_STORAGE_WRITE_BIT or VK_ACCESS_2_SHADER_STORAGE_READ_BIT),
      oldLayout: target.currentLayout,
      newLayout: VK_IMAGE_LAYOUT_GENERAL,
      image: target.storageImage,
      subresourceRange: VkImageSubresourceRange(
        aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT),
        baseMipLevel: 0, levelCount: 1, baseArrayLayer: 0, layerCount: 1,
      ),
    )
    var dep = VkDependencyInfo(sType: VK_STRUCTURE_TYPE_DEPENDENCY_INFO, imageMemoryBarrierCount: 1, pImageMemoryBarriers: b.addr)
    vkCmdPipelineBarrier2(stream.cmdBuffer, dep.addr)
    target.currentLayout = VK_IMAGE_LAYOUT_GENERAL

  var imgDescInfo = VkDescriptorImageInfo(
    imageView: target.storageView,
    imageLayout: VK_IMAGE_LAYOUT_GENERAL,
  )
  var writeDesc = VkWriteDescriptorSet(
    sType: VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
    dstBinding: binding,
    descriptorCount: 1,
    descriptorType: VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,
    pImageInfo: imgDescInfo.addr,
  )
  vkCmdPushDescriptorSet(stream.cmdBuffer, VK_PIPELINE_BIND_POINT_COMPUTE, stream.device.computeLayout, 0, 1, writeDesc.addr)

proc clearTarget*(stream: GpuStream, target: GpuTarget, r: float32 = 0.0f32, g: float32 = 0.0f32, b: float32 = 0.0f32, a: float32 = 1.0f32) =
  ## Clears target.storageImage with a solid color using vkCmdClearColorImage.
  var srcStage = VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_NONE)
  var srcAccess = VkAccessFlags2(VK_ACCESS_2_NONE)
  if target.currentLayout == VK_IMAGE_LAYOUT_GENERAL:
    srcStage = VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT)
    srcAccess = VkAccessFlags2(VK_ACCESS_2_SHADER_STORAGE_WRITE_BIT)
  elif target.currentLayout == VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL or target.currentLayout == VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL:
    srcStage = VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_TRANSFER_BIT)
    srcAccess = VkAccessFlags2(VK_ACCESS_2_TRANSFER_WRITE_BIT or VK_ACCESS_2_TRANSFER_READ_BIT)

  var toDst = VkImageMemoryBarrier2(
    sType: VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
    srcStageMask: srcStage,
    srcAccessMask: srcAccess,
    dstStageMask: VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_TRANSFER_BIT),
    dstAccessMask: VkAccessFlags2(VK_ACCESS_2_TRANSFER_WRITE_BIT),
    oldLayout: target.currentLayout,
    newLayout: VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
    image: target.storageImage,
    subresourceRange: VkImageSubresourceRange(
      aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT),
      baseMipLevel: 0, levelCount: 1, baseArrayLayer: 0, layerCount: 1,
    ),
  )
  var depDst = VkDependencyInfo(sType: VK_STRUCTURE_TYPE_DEPENDENCY_INFO, imageMemoryBarrierCount: 1, pImageMemoryBarriers: toDst.addr)
  vkCmdPipelineBarrier2(stream.cmdBuffer, depDst.addr)

  var clearColor = VkClearColorValue(float32: [r, g, b, a])
  var range = VkImageSubresourceRange(
    aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT),
    baseMipLevel: 0, levelCount: 1, baseArrayLayer: 0, layerCount: 1,
  )
  vkCmdClearColorImage(stream.cmdBuffer, target.storageImage, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, clearColor.addr, 1, range.addr)
  target.currentLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL

proc barrierComputeToCompute*(stream: GpuStream) =
  ## Inserts a pipeline memory barrier ensuring all previous compute shader writes
  ## (SSBO / BDA memory and images) are visible to subsequent compute reads/writes.
  var memBarrier = VkMemoryBarrier2(
    sType: VK_STRUCTURE_TYPE_MEMORY_BARRIER_2,
    srcStageMask: VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT),
    srcAccessMask: VkAccessFlags2(VK_ACCESS_2_SHADER_STORAGE_WRITE_BIT or VK_ACCESS_2_SHADER_WRITE_BIT),
    dstStageMask: VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT),
    dstAccessMask: VkAccessFlags2(VK_ACCESS_2_SHADER_STORAGE_READ_BIT or VK_ACCESS_2_SHADER_STORAGE_WRITE_BIT or VK_ACCESS_2_SHADER_READ_BIT),
  )
  var dep = VkDependencyInfo(
    sType: VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
    memoryBarrierCount: 1,
    pMemoryBarriers: memBarrier.addr,
  )
  vkCmdPipelineBarrier2(stream.cmdBuffer, dep.addr)

proc barrier*(stream: GpuStream) =
  ## Alias for barrierComputeToCompute.
  stream.barrierComputeToCompute()

proc dispatch*[PushT: object](
  stream: GpuStream,
  shader: ComputeShader,
  pushConstants: PushT,
  workgroupsX: uint32,
  workgroupsY: uint32 = 1,
  workgroupsZ: uint32 = 1,
) =
  ## Dispatches a compute shader with push constants (pure BDA or previously bound descriptors).
  var stage = VK_SHADER_STAGE_COMPUTE_BIT
  vkCmdBindShadersEXT(stream.cmdBuffer, 1, stage.addr, shader.handle.addr)

  var pushCopy = pushConstants
  vkCmdPushConstants(
    stream.cmdBuffer,
    stream.device.computeLayout,
    VkShaderStageFlags(VK_SHADER_STAGE_COMPUTE_BIT),
    0,
    sizeof(PushT).uint32,
    pushCopy.addr,
  )

  vkCmdDispatch(stream.cmdBuffer, workgroupsX, workgroupsY, workgroupsZ)

proc dispatch*[PushT: object](
  stream: GpuStream,
  shader: ComputeShader,
  target: GpuTarget,
  pushConstants: PushT,
  workgroupsX: uint32,
  workgroupsY: uint32 = 1,
  workgroupsZ: uint32 = 1,
) =
  ## Convenience dispatch that automatically binds target to descriptor binding 0 and dispatches.
  stream.bindTarget(target, 0)
  stream.dispatch(shader, pushConstants, workgroupsX, workgroupsY, workgroupsZ)

proc present*(stream: GpuStream, target: GpuTarget): bool {.discardable.} =
  var srcStage = VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_NONE)
  var srcAccess = VkAccessFlags2(VK_ACCESS_2_NONE)
  if target.currentLayout == VK_IMAGE_LAYOUT_GENERAL:
    srcStage = VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT)
    srcAccess = VkAccessFlags2(VK_ACCESS_2_SHADER_STORAGE_WRITE_BIT)
  elif target.currentLayout == VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL:
    srcStage = VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_TRANSFER_BIT)
    srcAccess = VkAccessFlags2(VK_ACCESS_2_TRANSFER_WRITE_BIT)
  elif target.currentLayout == VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL:
    srcStage = VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_TRANSFER_BIT)
    srcAccess = VkAccessFlags2(VK_ACCESS_2_TRANSFER_READ_BIT)

  # 1. Barrier: Transition storage image to TRANSFER_SRC and swapchain image to TRANSFER_DST
  var barriers = [
    VkImageMemoryBarrier2(
      sType: VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
      srcStageMask: srcStage,
      srcAccessMask: srcAccess,
      dstStageMask: VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_TRANSFER_BIT),
      dstAccessMask: VkAccessFlags2(VK_ACCESS_2_TRANSFER_READ_BIT),
      oldLayout: target.currentLayout,
      newLayout: VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
      image: target.storageImage,
      subresourceRange: VkImageSubresourceRange(
        aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT),
        baseMipLevel: 0, levelCount: 1, baseArrayLayer: 0, layerCount: 1,
      ),
    ),
    VkImageMemoryBarrier2(
      sType: VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
      srcStageMask: VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_NONE),
      srcAccessMask: VkAccessFlags2(VK_ACCESS_2_NONE),
      dstStageMask: VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_TRANSFER_BIT),
      dstAccessMask: VkAccessFlags2(VK_ACCESS_2_TRANSFER_WRITE_BIT),
      oldLayout: VK_IMAGE_LAYOUT_UNDEFINED,
      newLayout: VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
      image: target.swapchainImages[target.currentSwapImageIndex],
      subresourceRange: VkImageSubresourceRange(
        aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT),
        baseMipLevel: 0, levelCount: 1, baseArrayLayer: 0, layerCount: 1,
      ),
    )
  ]
  var dep2 = VkDependencyInfo(sType: VK_STRUCTURE_TYPE_DEPENDENCY_INFO, imageMemoryBarrierCount: 2, pImageMemoryBarriers: barriers[0].addr)
  vkCmdPipelineBarrier2(stream.cmdBuffer, dep2.addr)
  target.currentLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL

  # 2. vkCmdCopyImage2 (Direct VRAM copy between matching image formats)
  var copyRegion = VkImageCopy2(
    sType: VK_STRUCTURE_TYPE_IMAGE_COPY_2,
    srcSubresource: VkImageSubresourceLayers(
      aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT),
      mipLevel: 0, baseArrayLayer: 0, layerCount: 1,
    ),
    srcOffset: VkOffset3D(x: 0, y: 0, z: 0),
    dstSubresource: VkImageSubresourceLayers(
      aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT),
      mipLevel: 0, baseArrayLayer: 0, layerCount: 1,
    ),
    dstOffset: VkOffset3D(x: 0, y: 0, z: 0),
    extent: VkExtent3D(width: target.width.uint32, height: target.height.uint32, depth: 1),
  )
  var copyInfo = VkCopyImageInfo2(
    sType: VK_STRUCTURE_TYPE_COPY_IMAGE_INFO_2,
    srcImage: target.storageImage,
    srcImageLayout: VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
    dstImage: target.swapchainImages[target.currentSwapImageIndex],
    dstImageLayout: VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
    regionCount: 1,
    pRegions: copyRegion.addr,
  )
  vkCmdCopyImage2(stream.cmdBuffer, copyInfo.addr)

  # 3. Barrier: Transition swapchain image to PRESENT_SRC
  var b3 = VkImageMemoryBarrier2(
    sType: VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
    srcStageMask: VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_TRANSFER_BIT),
    srcAccessMask: VkAccessFlags2(VK_ACCESS_2_TRANSFER_WRITE_BIT),
    dstStageMask: VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_NONE),
    dstAccessMask: VkAccessFlags2(VK_ACCESS_2_NONE),
    oldLayout: VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
    newLayout: VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
    image: target.swapchainImages[target.currentSwapImageIndex],
    subresourceRange: VkImageSubresourceRange(
      aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT),
      baseMipLevel: 0, levelCount: 1, baseArrayLayer: 0, layerCount: 1,
    ),
  )
  var dep3 = VkDependencyInfo(sType: VK_STRUCTURE_TYPE_DEPENDENCY_INFO, imageMemoryBarrierCount: 1, pImageMemoryBarriers: b3.addr)
  vkCmdPipelineBarrier2(stream.cmdBuffer, dep3.addr)

  checkVkErr(vkEndCommandBuffer(stream.cmdBuffer), "EndCommandBuffer")

  # 4. Modern Submit2: Only the TRANSFER stage waits for the swapchain image acquisition semaphore!
  var waitInfo = VkSemaphoreSubmitInfo(
    sType: VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
    semaphore: stream.imageAvailableSem,
    stageMask: VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_TRANSFER_BIT),
  )
  var signalInfo = VkSemaphoreSubmitInfo(
    sType: VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
    semaphore: stream.renderFinishedSem,
    stageMask: VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT),
  )
  var cmdSubmitInfo = VkCommandBufferSubmitInfo(
    sType: VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO,
    commandBuffer: stream.cmdBuffer,
  )
  var submitInfo2 = VkSubmitInfo2(
    sType: VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
    waitSemaphoreInfoCount: 1,
    pWaitSemaphoreInfos: waitInfo.addr,
    commandBufferInfoCount: 1,
    pCommandBufferInfos: cmdSubmitInfo.addr,
    signalSemaphoreInfoCount: 1,
    pSignalSemaphoreInfos: signalInfo.addr,
  )
  checkVkErr(vkQueueSubmit2(stream.device.queue, 1, submitInfo2.addr, stream.inFlightFence), "QueueSubmit2")

  var presentInfo = VkPresentInfoKHR(
    sType: VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
    waitSemaphoreCount: 1,
    pWaitSemaphores: stream.renderFinishedSem.addr,
    swapchainCount: 1,
    pSwapchains: target.swapchain.addr,
    pImageIndices: target.currentSwapImageIndex.addr,
  )
  let presRes = vkQueuePresentKHR(stream.device.queue, presentInfo.addr)
  if presRes == VK_ERROR_OUT_OF_DATE_KHR or presRes == VK_SUBOPTIMAL_KHR:
    return false
  elif presRes != VK_SUCCESS:
    quit fmt"Vulkan error in vkQueuePresentKHR: {presRes.int32}"
  return true

proc readbackTargetPPM*(stream: GpuStream, target: GpuTarget, outputPath: string) =
  ## Headless/debug capture helper: reads back target.storageImage and saves to PPM.
  checkVkErr(vkEndCommandBuffer(stream.cmdBuffer), "EndCommandBuffer before readback")

  var cmdSubmitInfo = VkCommandBufferSubmitInfo(
    sType: VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO,
    commandBuffer: stream.cmdBuffer,
  )
  var submitInfo2 = VkSubmitInfo2(
    sType: VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
    commandBufferInfoCount: 1,
    pCommandBufferInfos: cmdSubmitInfo.addr,
  )
  checkVkErr(vkQueueSubmit2(stream.device.queue, 1, submitInfo2.addr, stream.inFlightFence), "QueueSubmit2 compute")

  let rowPitch = target.width * 4
  let totalBytes = (rowPitch * target.height).VkDeviceSize

  var bufCI = VkBufferCreateInfo(
    sType: VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
    size: totalBytes,
    usage: VkBufferUsageFlags(VK_BUFFER_USAGE_TRANSFER_DST_BIT),
    sharingMode: VK_SHARING_MODE_EXCLUSIVE,
  )
  var readbackBuf: VkBuffer
  checkVkErr(vkCreateBuffer(stream.device.device, bufCI.addr, nil, readbackBuf.addr), "CreateReadbackBuffer")

  var memReqs: VkMemoryRequirements
  vkGetBufferMemoryRequirements(stream.device.device, readbackBuf, memReqs.addr)
  var allocInfo = VkMemoryAllocateInfo(
    sType: VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
    allocationSize: memReqs.size,
    memoryTypeIndex: findMemoryType(stream.device.physicalDevice, memReqs.memoryTypeBits, (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT.uint32 or VK_MEMORY_PROPERTY_HOST_COHERENT_BIT.uint32)),
  )
  var readbackMem: VkDeviceMemory
  checkVkErr(vkAllocateMemory(stream.device.device, allocInfo.addr, nil, readbackMem.addr), "AllocateReadbackMem")
  checkVkErr(vkBindBufferMemory(stream.device.device, readbackBuf, readbackMem, 0), "BindReadbackMem")

  checkVkErr(vkWaitForFences(stream.device.device, 1, stream.inFlightFence.addr, VK_TRUE, uint64.high), "WaitForFences")
  checkVkErr(vkResetCommandBuffer(stream.cmdBuffer, VkCommandBufferResetFlags(0)), "ResetCommandBuffer")
  var beginInfo = VkCommandBufferBeginInfo(sType: VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO)
  checkVkErr(vkBeginCommandBuffer(stream.cmdBuffer, beginInfo.addr), "BeginCommandBuffer")

  var b = VkImageMemoryBarrier2(
    sType: VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
    srcStageMask: VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT),
    srcAccessMask: VkAccessFlags2(VK_ACCESS_2_MEMORY_WRITE_BIT),
    dstStageMask: VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_TRANSFER_BIT),
    dstAccessMask: VkAccessFlags2(VK_ACCESS_2_TRANSFER_READ_BIT),
    oldLayout: target.currentLayout,
    newLayout: VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
    image: target.storageImage,
    subresourceRange: VkImageSubresourceRange(
      aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT),
      baseMipLevel: 0, levelCount: 1, baseArrayLayer: 0, layerCount: 1,
    ),
  )
  var dep = VkDependencyInfo(sType: VK_STRUCTURE_TYPE_DEPENDENCY_INFO, imageMemoryBarrierCount: 1, pImageMemoryBarriers: b.addr)
  vkCmdPipelineBarrier2(stream.cmdBuffer, dep.addr)

  var copyRegion = VkBufferImageCopy2(
    sType: VK_STRUCTURE_TYPE_BUFFER_IMAGE_COPY_2,
    bufferOffset: 0,
    bufferRowLength: target.width.uint32,
    bufferImageHeight: target.height.uint32,
    imageSubresource: VkImageSubresourceLayers(
      aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT),
      mipLevel: 0, baseArrayLayer: 0, layerCount: 1,
    ),
    imageOffset: VkOffset3D(x: 0, y: 0, z: 0),
    imageExtent: VkExtent3D(width: target.width.uint32, height: target.height.uint32, depth: 1),
  )
  var copyInfo = VkCopyImageToBufferInfo2(
    sType: VK_STRUCTURE_TYPE_COPY_IMAGE_TO_BUFFER_INFO_2,
    srcImage: target.storageImage,
    srcImageLayout: VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
    dstBuffer: readbackBuf,
    regionCount: 1,
    pRegions: copyRegion.addr,
  )
  vkCmdCopyImageToBuffer2(stream.cmdBuffer, copyInfo.addr)
  checkVkErr(vkEndCommandBuffer(stream.cmdBuffer), "EndCommandBuffer")

  var cmdSubmitInfo2 = VkCommandBufferSubmitInfo(
    sType: VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO,
    commandBuffer: stream.cmdBuffer,
  )
  var submitInfoCopy = VkSubmitInfo2(
    sType: VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
    commandBufferInfoCount: 1,
    pCommandBufferInfos: cmdSubmitInfo2.addr,
  )
  checkVkErr(vkQueueSubmit2(stream.device.queue, 1, submitInfoCopy.addr, VkFence(0)), "QueueSubmit2 copy")
  checkVkErr(vkQueueWaitIdle(stream.device.queue), "QueueWaitIdle")

  var mapped: pointer
  checkVkErr(vkMapMemory(stream.device.device, readbackMem, 0.VkDeviceSize, totalBytes, VkMemoryMapFlags(0), mapped.addr), "MapMemory")

  let fullPath = if outputPath.endsWith(".ppm"): outputPath else: outputPath & ".ppm"
  var f = open(fullPath, fmWrite)
  f.writeLine(fmt"P6" & "\n" & fmt"{target.width} {target.height}" & "\n255")
  var rawBytes = cast[ptr UncheckedArray[uint8]](mapped)
  let isBgra = (target.format == VK_FORMAT_B8G8R8A8_UNORM)

  for y in 0 ..< target.height:
    for x in 0 ..< target.width:
      let idx = (y * target.width + x) * 4
      var rgb = if isBgra:
        [rawBytes[idx + 2], rawBytes[idx + 1], rawBytes[idx]]
      else:
        [rawBytes[idx], rawBytes[idx + 1], rawBytes[idx + 2]]
      discard f.writeBuffer(rgb[0].addr, 3)
  f.close()

  vkUnmapMemory(stream.device.device, readbackMem)
  vkFreeMemory(stream.device.device, readbackMem, nil)
  vkDestroyBuffer(stream.device.device, readbackBuf, nil)
