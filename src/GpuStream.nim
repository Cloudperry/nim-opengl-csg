## GpuStream: Minimal Vulkan 1.4 Compute Stream & Direct Memory Abstraction
## Provides GpuDevice, GpuSlice[T], GpuTarget, ComputeShader, and GpuStream.

import std/[strformat, math, strutils]
import sdl3
import vk14

when defined(windows):
  const SdlLib = "SDL3.dll"
elif defined(macosx):
  const SdlLib = "libSDL3.dylib"
else:
  const SdlLib = "libSDL3.so"

proc vulkanGetInstanceExtensions(count: ptr uint32): cstringArray {.cdecl, dynlib: SdlLib, importc: "SDL_Vulkan_GetInstanceExtensions".}
proc vulkanCreateSurface(window: sdl3.Window, instance: VkInstance, allocator: pointer, surface: ptr VkSurfaceKHR): bool {.cdecl, dynlib: SdlLib, importc: "SDL_Vulkan_CreateSurface".}
proc vulkanDestroySurface(instance: VkInstance, surface: VkSurfaceKHR, allocator: pointer) {.cdecl, dynlib: SdlLib, importc: "SDL_Vulkan_DestroySurface".}

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
    surface*: VkSurfaceKHR
    storageImage*: VkImage
    storageMemory*: VkDeviceMemory
    storageView*: VkImageView
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

  # 2. Surface for physical device selection
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

  if result.physicalDevice.int64 == 0:
    quit "Could not find a physical device with graphics, compute, and presentation support"

  # Destroy temp surface (actual surface is managed in GpuTarget)
  vulkanDestroySurface(result.instance, tempSurface, nil)

  # 4. Logical Device with modern features
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

  # 5. Push Descriptor Set Layout for storage image (binding 0)
  var layoutBinding = VkDescriptorSetLayoutBinding(
    binding: 0,
    descriptorType: VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,
    descriptorCount: 1,
    stageFlags: VkShaderStageFlags(VK_SHADER_STAGE_COMPUTE_BIT),
  )
  var dsLayoutCI = VkDescriptorSetLayoutCreateInfo(
    sType: VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
    flags: VkDescriptorSetLayoutCreateFlags(VK_DESCRIPTOR_SET_LAYOUT_CREATE_PUSH_DESCRIPTOR_BIT_KHR),
    bindingCount: 1,
    pBindings: layoutBinding.addr,
  )
  checkVkErr(vkCreateDescriptorSetLayout(result.device, dsLayoutCI.addr, nil, result.descriptorLayout.addr), "CreateDescriptorSetLayout")

  # 6. Pipeline Layout (Push constants + push descriptors)
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

  # 7. Command Pool
  var cmdPoolCI = VkCommandPoolCreateInfo(
    sType: VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
    flags: VkCommandPoolCreateFlags(VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT),
    queueFamilyIndex: result.queueFamilyIndex,
  )
  checkVkErr(vkCreateCommandPool(result.device, cmdPoolCI.addr, nil, result.cmdPool.addr), "CreateCommandPool")

# Memory / GpuSlice API
proc allocSlice*[T](device: GpuDevice, count: int): GpuSlice[T] =
  result.len = count
  let byteSize = (sizeof(T) * count).VkDeviceSize

  var bufCI = VkBufferCreateInfo(
    sType: VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
    size: byteSize,
    usage: VkBufferUsageFlags(VK_BUFFER_USAGE_STORAGE_BUFFER_BIT or VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT),
    sharingMode: VK_SHARING_MODE_EXCLUSIVE,
  )
  checkVkErr(vkCreateBuffer(device.device, bufCI.addr, nil, result.buffer.addr), "CreateBuffer")

  var memReqs: VkMemoryRequirements
  vkGetBufferMemoryRequirements(device.device, result.buffer, memReqs.addr)

  var allocFlagsInfo = VkMemoryAllocateFlagsInfo(
    sType: VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_FLAGS_INFO,
    flags: VkMemoryAllocateFlags(VK_MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT),
  )
  var allocInfo = VkMemoryAllocateInfo(
    sType: VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
    pNext: allocFlagsInfo.addr,
    allocationSize: memReqs.size,
    memoryTypeIndex: findMemoryType(device.physicalDevice, memReqs.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT or VK_MEMORY_PROPERTY_HOST_COHERENT_BIT),
  )
  checkVkErr(vkAllocateMemory(device.device, allocInfo.addr, nil, result.memory.addr), "AllocateMemory")
  checkVkErr(vkBindBufferMemory(device.device, result.buffer, result.memory, 0), "BindBufferMemory")

  var mapped: pointer
  checkVkErr(vkMapMemory(device.device, result.memory, 0.VkDeviceSize, byteSize, VkMemoryMapFlags(0), mapped.addr), "MapMemory")
  result.hostPtr = cast[ptr UncheckedArray[T]](mapped)

  var bdaInfo = VkBufferDeviceAddressInfo(
    sType: VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO,
    buffer: result.buffer,
  )
  result.deviceAddress = vkGetBufferDeviceAddress(device.device, bdaInfo.addr)

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

template `[]`*[T](slice: GpuSlice[T], index: int): lent T =
  slice.hostPtr[index]

template `[]=`*[T](slice: var GpuSlice[T], index: int, val: T) =
  slice.hostPtr[index] = val

proc writeSlice*[T](slice: var GpuSlice[T], data: openArray[T], dstOffset = 0) =
  copyMem(slice.hostPtr[dstOffset].addr, data[0].unsafeAddr, sizeof(T) * data.len)

# Target & Swapchain API
proc createTarget*(device: GpuDevice, win: sdl3.Window, width, height: int32): GpuTarget =
  new(result)
  result.width = width
  result.height = height

  if not vulkanCreateSurface(win, device.instance, nil, result.surface.addr):
    quit "Failed to create Vulkan surface for GpuTarget"

  var surfCaps: VkSurfaceCapabilitiesKHR
  checkVkErr(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(device.physicalDevice, result.surface, surfCaps.addr), "SurfaceCaps")

  var formatCount: uint32
  checkVkErr(vkGetPhysicalDeviceSurfaceFormatsKHR(device.physicalDevice, result.surface, formatCount.addr, nil), "SurfaceFormats count")
  var surfFormats = newSeq[VkSurfaceFormatKHR](formatCount)
  checkVkErr(vkGetPhysicalDeviceSurfaceFormatsKHR(device.physicalDevice, result.surface, formatCount.addr, surfFormats[0].addr), "SurfaceFormats")

  var chosenFormat = surfFormats[0]
  for f in surfFormats:
    if f.format == VK_FORMAT_B8G8R8A8_UNORM or f.format == VK_FORMAT_R8G8B8A8_UNORM:
      chosenFormat = f
      break
  result.format = chosenFormat.format

  var swapchainCI = VkSwapchainCreateInfoKHR(
    sType: VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
    surface: result.surface,
    minImageCount: max(2'u32, surfCaps.minImageCount),
    imageFormat: chosenFormat.format,
    imageColorSpace: chosenFormat.colorSpace,
    imageExtent: VkExtent2D(width: width.uint32, height: height.uint32),
    imageArrayLayers: 1,
    imageUsage: VkImageUsageFlags(VK_IMAGE_USAGE_TRANSFER_DST_BIT or VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT),
    imageSharingMode: VK_SHARING_MODE_EXCLUSIVE,
    preTransform: surfCaps.currentTransform,
    compositeAlpha: VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
    presentMode: VK_PRESENT_MODE_FIFO_KHR,
    clipped: VK_TRUE,
  )
  checkVkErr(vkCreateSwapchainKHR(device.device, swapchainCI.addr, nil, result.swapchain.addr), "CreateSwapchain")

  var swapImgCount: uint32
  checkVkErr(vkGetSwapchainImagesKHR(device.device, result.swapchain, swapImgCount.addr, nil), "SwapchainImages count")
  result.swapchainImages = newSeq[VkImage](swapImgCount)
  checkVkErr(vkGetSwapchainImagesKHR(device.device, result.swapchain, swapImgCount.addr, result.swapchainImages[0].addr), "SwapchainImages")

  # Storage image follows swapchain format exactly to eliminate color channel mismatch in vkCmdCopyImage2
  var offImgCI = VkImageCreateInfo(
    sType: VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
    imageType: VK_IMAGE_TYPE_2D,
    format: result.format,
    extent: VkExtent3D(width: width.uint32, height: height.uint32, depth: 1),
    mipLevels: 1,
    arrayLayers: 1,
    samples: VK_SAMPLE_COUNT_1_BIT,
    tiling: VK_IMAGE_TILING_OPTIMAL,
    usage: VkImageUsageFlags(VK_IMAGE_USAGE_STORAGE_BIT or VK_IMAGE_USAGE_TRANSFER_SRC_BIT),
    sharingMode: VK_SHARING_MODE_EXCLUSIVE,
    initialLayout: VK_IMAGE_LAYOUT_UNDEFINED,
  )
  checkVkErr(vkCreateImage(device.device, offImgCI.addr, nil, result.storageImage.addr), "CreateStorageImage")

  var offMemReqs: VkMemoryRequirements
  vkGetImageMemoryRequirements(device.device, result.storageImage, offMemReqs.addr)
  var offAllocInfo = VkMemoryAllocateInfo(
    sType: VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
    allocationSize: offMemReqs.size,
    memoryTypeIndex: findMemoryType(device.physicalDevice, offMemReqs.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT),
  )
  checkVkErr(vkAllocateMemory(device.device, offAllocInfo.addr, nil, result.storageMemory.addr), "AllocateStorageMemory")
  checkVkErr(vkBindImageMemory(device.device, result.storageImage, result.storageMemory, 0), "BindStorageMemory")

  var viewCI = VkImageViewCreateInfo(
    sType: VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
    image: result.storageImage,
    viewType: VK_IMAGE_VIEW_TYPE_2D,
    format: result.format,
    subresourceRange: VkImageSubresourceRange(
      aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT),
      baseMipLevel: 0,
      levelCount: 1,
      baseArrayLayer: 0,
      layerCount: 1,
    ),
  )
  checkVkErr(vkCreateImageView(device.device, viewCI.addr, nil, result.storageView.addr), "CreateStorageImageView")

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

# GpuStream Execution
proc initGpuStream*(device: GpuDevice): GpuStream =
  new(result)
  result.device = device

  var cmdPoolCI = VkCommandPoolCreateInfo(
    sType: VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
    flags: VkCommandPoolCreateFlags(VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT),
    queueFamilyIndex: device.queueFamilyIndex,
  )
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

proc beginFrame*(stream: GpuStream, target: GpuTarget): bool =
  checkVkErr(vkWaitForFences(stream.device.device, 1, stream.inFlightFence.addr, VK_TRUE, uint64.high), "WaitForFences")
  checkVkErr(vkResetFences(stream.device.device, 1, stream.inFlightFence.addr), "ResetFences")

  let acqRes = vkAcquireNextImageKHR(stream.device.device, target.swapchain, uint64.high, stream.imageAvailableSem, VkFence(0), target.currentSwapImageIndex.addr)
  if acqRes != VK_SUCCESS:
    return false

  checkVkErr(vkResetCommandBuffer(stream.cmdBuffer, VkCommandBufferResetFlags(0)), "ResetCommandBuffer")
  var beginInfo = VkCommandBufferBeginInfo(sType: VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO)
  checkVkErr(vkBeginCommandBuffer(stream.cmdBuffer, beginInfo.addr), "BeginCommandBuffer")
  return true

proc dispatch*[PushT: object](
  stream: GpuStream,
  shader: ComputeShader,
  target: GpuTarget,
  pushConstants: PushT,
  workgroupsX, workgroupsY, workgroupsZ: uint32
) =
  # 1. Transition storage image to GENERAL for compute write
  var b1 = VkImageMemoryBarrier2(
    sType: VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
    srcStageMask: VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_NONE),
    srcAccessMask: VkAccessFlags2(VK_ACCESS_2_NONE),
    dstStageMask: VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT),
    dstAccessMask: VkAccessFlags2(VK_ACCESS_2_SHADER_STORAGE_WRITE_BIT),
    oldLayout: VK_IMAGE_LAYOUT_UNDEFINED,
    newLayout: VK_IMAGE_LAYOUT_GENERAL,
    image: target.storageImage,
    subresourceRange: VkImageSubresourceRange(
      aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT),
      baseMipLevel: 0, levelCount: 1, baseArrayLayer: 0, layerCount: 1,
    ),
  )
  var dep1 = VkDependencyInfo(sType: VK_STRUCTURE_TYPE_DEPENDENCY_INFO, imageMemoryBarrierCount: 1, pImageMemoryBarriers: b1.addr)
  vkCmdPipelineBarrier2(stream.cmdBuffer, dep1.addr)

  # 2. Bind Shader Object
  var stage = VK_SHADER_STAGE_COMPUTE_BIT
  vkCmdBindShadersEXT(stream.cmdBuffer, 1, stage.addr, shader.handle.addr)

  # 3. Push Descriptors (Target storage image at binding 0)
  var imgDescInfo = VkDescriptorImageInfo(
    imageView: target.storageView,
    imageLayout: VK_IMAGE_LAYOUT_GENERAL,
  )
  var writeDesc = VkWriteDescriptorSet(
    sType: VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
    dstBinding: 0,
    descriptorCount: 1,
    descriptorType: VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,
    pImageInfo: imgDescInfo.addr,
  )
  vkCmdPushDescriptorSet(stream.cmdBuffer, VK_PIPELINE_BIND_POINT_COMPUTE, stream.device.computeLayout, 0, 1, writeDesc.addr)

  # 4. Push Constants
  var pushCopy = pushConstants
  vkCmdPushConstants(
    stream.cmdBuffer,
    stream.device.computeLayout,
    VkShaderStageFlags(VK_SHADER_STAGE_COMPUTE_BIT),
    0,
    sizeof(PushT).uint32,
    pushCopy.addr,
  )

  # 5. Dispatch
  vkCmdDispatch(stream.cmdBuffer, workgroupsX, workgroupsY, workgroupsZ)

proc present*(stream: GpuStream, target: GpuTarget) =
  # 1. Barrier: Transition storage image to TRANSFER_SRC and swapchain image to TRANSFER_DST
  var barriers = [
    VkImageMemoryBarrier2(
      sType: VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
      srcStageMask: VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT),
      srcAccessMask: VkAccessFlags2(VK_ACCESS_2_SHADER_STORAGE_WRITE_BIT),
      dstStageMask: VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_TRANSFER_BIT),
      dstAccessMask: VkAccessFlags2(VK_ACCESS_2_TRANSFER_READ_BIT),
      oldLayout: VK_IMAGE_LAYOUT_GENERAL,
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
  discard vkQueuePresentKHR(stream.device.queue, presentInfo.addr)

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
    memoryTypeIndex: findMemoryType(stream.device.physicalDevice, memReqs.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT or VK_MEMORY_PROPERTY_HOST_COHERENT_BIT),
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
    oldLayout: VK_IMAGE_LAYOUT_GENERAL,
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
