import std/[strformat, math]
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
  ColorData* = object
    color*: array[4, float32]

  PushConstants* = object
    dataAddress*: uint64

proc checkVk*(res: VkResult, op: string) =
  if res != VK_SUCCESS:
    quit fmt"Vulkan error in {op}: {res.int32}"

proc findMemoryType(pDevice: VkPhysicalDevice, typeFilter: uint32, properties: uint32): uint32 =
  var memProps: VkPhysicalDeviceMemoryProperties
  vkGetPhysicalDeviceMemoryProperties(pDevice, memProps.addr)
  for i in 0'u32 ..< memProps.memoryTypeCount:
    if ((typeFilter shr i) and 1'u32) == 1'u32 and (memProps.memoryTypes[i].propertyFlags.uint32 and properties) == properties:
      return i
  quit "Failed to find suitable memory type"

proc main() =
  if not init(INIT_VIDEO):
    quit fmt"Error initializing SDL3: {getError()}"

  let win = createWindow("Basic Vulkan 1.4 Compute (Shader Object + Device Address)", 1280, 720, WINDOW_VULKAN or WINDOW_RESIZABLE)
  if win == nil:
    quit fmt"Error creating window: {getError()}"

  loadVulkan()
  doAssert vkInit()

  # 1. Instance creation
  var sdlExtCount: uint32
  let sdlExtPtr = vulkanGetInstanceExtensions(sdlExtCount.addr)

  var appInfo = VkApplicationInfo(
    sType: VK_STRUCTURE_TYPE_APPLICATION_INFO,
    pApplicationName: "Vulkan 1.4 SDF Sandbox",
    applicationVersion: vkMakeApiVersion(0, 1, 0, 0),
    pEngineName: "No Engine",
    engineVersion: vkMakeApiVersion(0, 1, 0, 0),
    apiVersion: VK_API_VERSION_1_4,
  )

  var instanceCI = VkInstanceCreateInfo(
    sType: VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
    pApplicationInfo: appInfo.addr,
    enabledExtensionCount: sdlExtCount,
    ppEnabledExtensionNames: sdlExtPtr,
  )

  var instance: VkInstance
  checkVk(vkCreateInstance(instanceCI.addr, nil, instance.addr), "CreateInstance")
  setInstance(cast[pointer](instance))
  loadVK_KHR_surface()

  # 2. Surface creation
  var surface: VkSurfaceKHR
  if not vulkanCreateSurface(win, instance, nil, surface.addr):
    quit fmt"Failed to create Vulkan surface: {getError()}"

  # 3. Physical Device Selection
  var deviceCount: uint32
  checkVk(vkEnumeratePhysicalDevices(instance, deviceCount.addr, nil), "EnumeratePhysicalDevices count")
  var devices = newSeq[VkPhysicalDevice](deviceCount)
  checkVk(vkEnumeratePhysicalDevices(instance, deviceCount.addr, devices[0].addr), "EnumeratePhysicalDevices")

  var pDevice: VkPhysicalDevice = VkPhysicalDevice(0)
  var queueFamilyIdx: uint32 = 0
  for dev in devices:
    var devProps: VkPhysicalDeviceProperties
    vkGetPhysicalDeviceProperties(dev, devProps.addr)
    echo fmt"Surface handle: {surface.uint64:X}"; echo fmt"Checking device: {cast[cstring](devProps.deviceName[0].unsafeAddr)}"
    var qCount: uint32
    vkGetPhysicalDeviceQueueFamilyProperties(dev, qCount.addr, nil)
    var qProps = newSeq[VkQueueFamilyProperties](qCount)
    vkGetPhysicalDeviceQueueFamilyProperties(dev, qCount.addr, qProps[0].addr)
    for i, q in qProps:
      var presentSupport: VkBool32 = VK_FALSE
      let sRes = vkGetPhysicalDeviceSurfaceSupportKHR(dev, i.uint32, surface, presentSupport.addr)
      echo fmt"  Queue {i}: flags={q.queueFlags.uint32:X}, presentSupport={presentSupport}, res={sRes.int32}"
      if ((q.queueFlags.uint32 and (VK_QUEUE_GRAPHICS_BIT or VK_QUEUE_COMPUTE_BIT)) != 0) and presentSupport == VK_TRUE:
        pDevice = dev
        queueFamilyIdx = i.uint32
        break
    if pDevice.int64 != 0: break

  if pDevice.int64 == 0:
    quit "Could not find a suitable physical device with graphics, compute, and present support"

  var devProps: VkPhysicalDeviceProperties
  vkGetPhysicalDeviceProperties(pDevice, devProps.addr)
  echo fmt"Selected GPU: {cast[cstring](devProps.deviceName[0].unsafeAddr)}"

  # 4. Device creation with modern features enabled:
  # VK_EXT_shader_object, bufferDeviceAddress, synchronization2, dynamicRendering, maintenance4, hostImageCopy, pushDescriptor
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
    timelineSemaphore: VK_TRUE,
  )
  var features2 = VkPhysicalDeviceFeatures2(
    sType: VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
    pNext: vk12Features.addr,
  )

  var qPriority = 1.0'f32
  var queueCI = VkDeviceQueueCreateInfo(
    sType: VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
    queueFamilyIndex: queueFamilyIdx,
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

  var device: VkDevice
  checkVk(vkCreateDevice(pDevice, deviceCI.addr, nil, device.addr), "CreateDevice")
  loadVK_KHR_swapchain()
  loadVK_EXT_shader_object()

  var queue: VkQueue
  vkGetDeviceQueue(device, queueFamilyIdx, 0, queue.addr)

  # 5. Load SPIR-V Shader Object
  let spvCode = readFile("shaders/BasicVulkan.spv")
  var pushRange = VkPushConstantRange(
    stageFlags: VkShaderStageFlags(VK_SHADER_STAGE_COMPUTE_BIT),
    offset: 0,
    size: sizeof(PushConstants).uint32,
  )

  # Descriptor Set Layout for storage image (binding 0)
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
  var dsLayout: VkDescriptorSetLayout
  checkVk(vkCreateDescriptorSetLayout(device, dsLayoutCI.addr, nil, dsLayout.addr), "CreateDescriptorSetLayout")

  var shaderCI = VkShaderCreateInfoEXT(
    sType: VK_STRUCTURE_TYPE_SHADER_CREATE_INFO_EXT,
    flags: VkShaderCreateFlagsEXT(0),
    stage: VK_SHADER_STAGE_COMPUTE_BIT,
    nextStage: VkShaderStageFlags(0),
    codeType: VK_SHADER_CODE_TYPE_SPIRV_EXT,
    codeSize: spvCode.len.csize_t,
    pCode: cast[pointer](spvCode.cstring),
    pName: "main",
    setLayoutCount: 1,
    pSetLayouts: dsLayout.addr,
    pushConstantRangeCount: 1,
    pPushConstantRanges: pushRange.addr,
  )

  var shader: VkShaderEXT
  checkVk(vkCreateShadersEXT(device, 1, shaderCI.addr, nil, shader.addr), "CreateShadersEXT")
  echo "Shader object created successfully!"

  # 6. Allocate Device Address Buffer for ColorData
  var bufCI = VkBufferCreateInfo(
    sType: VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
    size: sizeof(ColorData).VkDeviceSize,
    usage: VkBufferUsageFlags(VK_BUFFER_USAGE_STORAGE_BUFFER_BIT or VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT),
    sharingMode: VK_SHARING_MODE_EXCLUSIVE,
  )
  var colorBuffer: VkBuffer
  checkVk(vkCreateBuffer(device, bufCI.addr, nil, colorBuffer.addr), "CreateBuffer")

  var memReqs: VkMemoryRequirements
  vkGetBufferMemoryRequirements(device, colorBuffer, memReqs.addr)

  var allocFlagsInfo = VkMemoryAllocateFlagsInfo(
    sType: VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_FLAGS_INFO,
    flags: VkMemoryAllocateFlags(VK_MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT),
  )
  var allocInfo = VkMemoryAllocateInfo(
    sType: VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
    pNext: allocFlagsInfo.addr,
    allocationSize: memReqs.size,
    memoryTypeIndex: findMemoryType(pDevice, memReqs.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT or VK_MEMORY_PROPERTY_HOST_COHERENT_BIT),
  )
  var bufferMemory: VkDeviceMemory
  checkVk(vkAllocateMemory(device, allocInfo.addr, nil, bufferMemory.addr), "AllocateMemory")
  checkVk(vkBindBufferMemory(device, colorBuffer, bufferMemory, 0), "BindBufferMemory")

  # Fill the buffer with an orange/coral color: (1.0, 0.45, 0.1, 1.0)
  var mapped: pointer
  checkVk(vkMapMemory(device, bufferMemory, 0.VkDeviceSize, sizeof(ColorData).VkDeviceSize, VkMemoryMapFlags(0), mapped.addr), "MapMemory")
  var initialColor = ColorData(color: [1.0'f32, 0.45'f32, 0.1'f32, 1.0'f32])
  copyMem(mapped, initialColor.addr, sizeof(ColorData))
  vkUnmapMemory(device, bufferMemory)

  # Query device address
  var bdaInfo = VkBufferDeviceAddressInfo(
    sType: VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO,
    buffer: colorBuffer,
  )
  let devAddress = vkGetBufferDeviceAddress(device, bdaInfo.addr)
  echo fmt"Buffer Device Address: 0x{devAddress:X}"

  # 7. Pipeline Layout for Push Constants & Push Descriptors
  var pipeLayoutCI = VkPipelineLayoutCreateInfo(
    sType: VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
    setLayoutCount: 1,
    pSetLayouts: dsLayout.addr,
    pushConstantRangeCount: 1,
    pPushConstantRanges: pushRange.addr,
  )
  var pipeLayout: VkPipelineLayout
  checkVk(vkCreatePipelineLayout(device, pipeLayoutCI.addr, nil, pipeLayout.addr), "CreatePipelineLayout")

  # 8. Command Pool & Command Buffer
  var cmdPoolCI = VkCommandPoolCreateInfo(
    sType: VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
    flags: VkCommandPoolCreateFlags(VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT),
    queueFamilyIndex: queueFamilyIdx,
  )
  var cmdPool: VkCommandPool
  checkVk(vkCreateCommandPool(device, cmdPoolCI.addr, nil, cmdPool.addr), "CreateCommandPool")

  var cmdAllocInfo = VkCommandBufferAllocateInfo(
    sType: VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
    commandPool: cmdPool,
    level: VK_COMMAND_BUFFER_LEVEL_PRIMARY,
    commandBufferCount: 1,
  )
  var cmdBuffer: VkCommandBuffer
  checkVk(vkAllocateCommandBuffers(device, cmdAllocInfo.addr, cmdBuffer.addr), "AllocateCommandBuffers")

  # 9. Sync objects
  var semCI = VkSemaphoreCreateInfo(sType: VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO)
  var fenceCI = VkFenceCreateInfo(sType: VK_STRUCTURE_TYPE_FENCE_CREATE_INFO, flags: VkFenceCreateFlags(VK_FENCE_CREATE_SIGNALED_BIT))
  var imgAvailableSem, renderFinishedSem: VkSemaphore
  var inFlightFence: VkFence
  checkVk(vkCreateSemaphore(device, semCI.addr, nil, imgAvailableSem.addr), "CreateSemaphore")
  checkVk(vkCreateSemaphore(device, semCI.addr, nil, renderFinishedSem.addr), "CreateSemaphore")
  checkVk(vkCreateFence(device, fenceCI.addr, nil, inFlightFence.addr), "CreateFence")

  # 10. Swapchain setup
  var surfCaps: VkSurfaceCapabilitiesKHR
  checkVk(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(pDevice, surface, surfCaps.addr), "SurfaceCaps")

  var formatCount: uint32
  checkVk(vkGetPhysicalDeviceSurfaceFormatsKHR(pDevice, surface, formatCount.addr, nil), "SurfaceFormats count")
  var surfFormats = newSeq[VkSurfaceFormatKHR](formatCount)
  checkVk(vkGetPhysicalDeviceSurfaceFormatsKHR(pDevice, surface, formatCount.addr, surfFormats[0].addr), "SurfaceFormats")

  var chosenFormat = surfFormats[0]
  for f in surfFormats:
    if f.format == VK_FORMAT_B8G8R8A8_UNORM or f.format == VK_FORMAT_B8G8R8A8_SRGB or f.format == VK_FORMAT_R8G8B8A8_UNORM:
      chosenFormat = f
      break

  var w, h: cint
  discard getWindowSizeInPixels(win, w, h)
  var extent = VkExtent2D(width: w.uint32, height: h.uint32)

  var swapchainCI = VkSwapchainCreateInfoKHR(
    sType: VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
    surface: surface,
    minImageCount: max(2'u32, surfCaps.minImageCount),
    imageFormat: chosenFormat.format,
    imageColorSpace: chosenFormat.colorSpace,
    imageExtent: extent,
    imageArrayLayers: 1,
    imageUsage: VkImageUsageFlags(VK_IMAGE_USAGE_TRANSFER_DST_BIT or VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT),
    imageSharingMode: VK_SHARING_MODE_EXCLUSIVE,
    preTransform: surfCaps.currentTransform,
    compositeAlpha: VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
    presentMode: VK_PRESENT_MODE_FIFO_KHR,
    clipped: VK_TRUE,
  )
  var swapchain: VkSwapchainKHR
  checkVk(vkCreateSwapchainKHR(device, swapchainCI.addr, nil, swapchain.addr), "CreateSwapchain")

  var swapImgCount: uint32
  checkVk(vkGetSwapchainImagesKHR(device, swapchain, swapImgCount.addr, nil), "SwapchainImages count")
  var swapchainImages = newSeq[VkImage](swapImgCount)
  checkVk(vkGetSwapchainImagesKHR(device, swapchain, swapImgCount.addr, swapchainImages[0].addr), "SwapchainImages")

  # 11. Create Offscreen Compute Target Image (RGBA8)
  var offImgCI = VkImageCreateInfo(
    sType: VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
    imageType: VK_IMAGE_TYPE_2D,
    format: VK_FORMAT_R8G8B8A8_UNORM,
    extent: VkExtent3D(width: extent.width, height: extent.height, depth: 1),
    mipLevels: 1,
    arrayLayers: 1,
    samples: VK_SAMPLE_COUNT_1_BIT,
    tiling: VK_IMAGE_TILING_OPTIMAL,
    usage: VkImageUsageFlags(VK_IMAGE_USAGE_STORAGE_BIT or VK_IMAGE_USAGE_TRANSFER_SRC_BIT),
    sharingMode: VK_SHARING_MODE_EXCLUSIVE,
    initialLayout: VK_IMAGE_LAYOUT_UNDEFINED,
  )
  var offscreenImage: VkImage
  checkVk(vkCreateImage(device, offImgCI.addr, nil, offscreenImage.addr), "CreateImage")

  var offMemReqs: VkMemoryRequirements
  vkGetImageMemoryRequirements(device, offscreenImage, offMemReqs.addr)
  var offAllocInfo = VkMemoryAllocateInfo(
    sType: VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
    allocationSize: offMemReqs.size,
    memoryTypeIndex: findMemoryType(pDevice, offMemReqs.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT),
  )
  var offscreenMemory: VkDeviceMemory
  checkVk(vkAllocateMemory(device, offAllocInfo.addr, nil, offscreenMemory.addr), "AllocateImageMemory")
  checkVk(vkBindImageMemory(device, offscreenImage, offscreenMemory, 0), "BindImageMemory")

  var viewCI = VkImageViewCreateInfo(
    sType: VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
    image: offscreenImage,
    viewType: VK_IMAGE_VIEW_TYPE_2D,
    format: VK_FORMAT_R8G8B8A8_UNORM,
    subresourceRange: VkImageSubresourceRange(
      aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT),
      baseMipLevel: 0,
      levelCount: 1,
      baseArrayLayer: 0,
      layerCount: 1,
    ),
  )
  var offscreenView: VkImageView
  checkVk(vkCreateImageView(device, viewCI.addr, nil, offscreenView.addr), "CreateImageView")

  echo "Setup completed successfully. Entering main loop..."

  var running = true
  var frameCount = 0
  while running:
    var event: Event
    while pollEvent(event):
      case event.type:
      of EVENT_QUIT:
        running = false
      of EVENT_KEY_DOWN:
        if event.key.scancode == SCANCODE_ESCAPE:
          running = false
      else:
        discard

    # Dynamic color animation via device address pointer!
    inc frameCount
    let t = frameCount.float32 * 0.03
    var curColor = ColorData(color: [
      (0.5 + 0.5 * sin(t)).float32,
      (0.5 + 0.5 * sin(t + 2.094)).float32,
      (0.5 + 0.5 * sin(t + 4.188)).float32,
      1.0'f32
    ])
    checkVk(vkMapMemory(device, bufferMemory, 0.VkDeviceSize, sizeof(ColorData).VkDeviceSize, VkMemoryMapFlags(0), mapped.addr), "MapMemory Loop")
    copyMem(mapped, curColor.addr, sizeof(ColorData))
    vkUnmapMemory(device, bufferMemory)

    checkVk(vkWaitForFences(device, 1, inFlightFence.addr, VK_TRUE, uint64.high), "WaitForFences")
    checkVk(vkResetFences(device, 1, inFlightFence.addr), "ResetFences")

    var imageIndex: uint32
    let acqRes = vkAcquireNextImageKHR(device, swapchain, uint64.high, imgAvailableSem, VkFence(0), imageIndex.addr)
    if acqRes != VK_SUCCESS:
      continue

    checkVk(vkResetCommandBuffer(cmdBuffer, VkCommandBufferResetFlags(0)), "ResetCommandBuffer")
    var beginInfo = VkCommandBufferBeginInfo(sType: VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO)
    checkVk(vkBeginCommandBuffer(cmdBuffer, beginInfo.addr), "BeginCommandBuffer")

    # 1. Transition offscreen image to GENERAL for compute write
    var b1 = VkImageMemoryBarrier2(
      sType: VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
      srcStageMask: VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_NONE),
      srcAccessMask: VkAccessFlags2(VK_ACCESS_2_NONE),
      dstStageMask: VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT),
      dstAccessMask: VkAccessFlags2(VK_ACCESS_2_SHADER_STORAGE_WRITE_BIT),
      oldLayout: VK_IMAGE_LAYOUT_UNDEFINED,
      newLayout: VK_IMAGE_LAYOUT_GENERAL,
      image: offscreenImage,
      subresourceRange: VkImageSubresourceRange(
        aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT),
        baseMipLevel: 0, levelCount: 1, baseArrayLayer: 0, layerCount: 1,
      ),
    )
    var dep1 = VkDependencyInfo(sType: VK_STRUCTURE_TYPE_DEPENDENCY_INFO, imageMemoryBarrierCount: 1, pImageMemoryBarriers: b1.addr)
    vkCmdPipelineBarrier2(cmdBuffer, dep1.addr)

    # 2. Bind Shader Object
    var stage = VK_SHADER_STAGE_COMPUTE_BIT
    vkCmdBindShadersEXT(cmdBuffer, 1, stage.addr, shader.addr)

    # 3. Push Descriptor (Offscreen storage image)
    var imgDescInfo = VkDescriptorImageInfo(
      imageView: offscreenView,
      imageLayout: VK_IMAGE_LAYOUT_GENERAL,
    )
    var writeDesc = VkWriteDescriptorSet(
      sType: VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
      dstBinding: 0,
      descriptorCount: 1,
      descriptorType: VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,
      pImageInfo: imgDescInfo.addr,
    )
    vkCmdPushDescriptorSet(cmdBuffer, VK_PIPELINE_BIND_POINT_COMPUTE, pipeLayout, 0, 1, writeDesc.addr)

    # 4. Push Constants (Buffer Device Address)
    var pushVal = PushConstants(dataAddress: devAddress)
    vkCmdPushConstants(cmdBuffer, pipeLayout, VkShaderStageFlags(VK_SHADER_STAGE_COMPUTE_BIT), 0, sizeof(PushConstants).uint32, pushVal.addr)

    # 5. Dispatch Compute Shader
    vkCmdDispatch(cmdBuffer, (extent.width + 7) div 8, (extent.height + 7) div 8, 1)

    # 6. Barrier: Transition offscreen image to TRANSFER_SRC and swapchain image to TRANSFER_DST
    var barriers = [
      VkImageMemoryBarrier2(
        sType: VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
        srcStageMask: VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT),
        srcAccessMask: VkAccessFlags2(VK_ACCESS_2_SHADER_STORAGE_WRITE_BIT),
        dstStageMask: VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_BLIT_BIT),
        dstAccessMask: VkAccessFlags2(VK_ACCESS_2_TRANSFER_READ_BIT),
        oldLayout: VK_IMAGE_LAYOUT_GENERAL,
        newLayout: VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        image: offscreenImage,
        subresourceRange: VkImageSubresourceRange(
          aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT),
          baseMipLevel: 0, levelCount: 1, baseArrayLayer: 0, layerCount: 1,
        ),
      ),
      VkImageMemoryBarrier2(
        sType: VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
        srcStageMask: VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_NONE),
        srcAccessMask: VkAccessFlags2(VK_ACCESS_2_NONE),
        dstStageMask: VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_BLIT_BIT),
        dstAccessMask: VkAccessFlags2(VK_ACCESS_2_TRANSFER_WRITE_BIT),
        oldLayout: VK_IMAGE_LAYOUT_UNDEFINED,
        newLayout: VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        image: swapchainImages[imageIndex],
        subresourceRange: VkImageSubresourceRange(
          aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT),
          baseMipLevel: 0, levelCount: 1, baseArrayLayer: 0, layerCount: 1,
        ),
      )
    ]
    var dep2 = VkDependencyInfo(sType: VK_STRUCTURE_TYPE_DEPENDENCY_INFO, imageMemoryBarrierCount: 2, pImageMemoryBarriers: barriers[0].addr)
    vkCmdPipelineBarrier2(cmdBuffer, dep2.addr)

    # 7. Hardware Blit from offscreen image to swapchain
    var blitRegion = VkImageBlit2(
      sType: VK_STRUCTURE_TYPE_IMAGE_BLIT_2,
      srcSubresource: VkImageSubresourceLayers(
        aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT),
        mipLevel: 0, baseArrayLayer: 0, layerCount: 1,
      ),
      srcOffsets: [VkOffset3D(x: 0, y: 0, z: 0), VkOffset3D(x: extent.width.int32, y: extent.height.int32, z: 1)],
      dstSubresource: VkImageSubresourceLayers(
        aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT),
        mipLevel: 0, baseArrayLayer: 0, layerCount: 1,
      ),
      dstOffsets: [VkOffset3D(x: 0, y: 0, z: 0), VkOffset3D(x: extent.width.int32, y: extent.height.int32, z: 1)],
    )
    var blitInfo = VkBlitImageInfo2(
      sType: VK_STRUCTURE_TYPE_BLIT_IMAGE_INFO_2,
      srcImage: offscreenImage,
      srcImageLayout: VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
      dstImage: swapchainImages[imageIndex],
      dstImageLayout: VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
      regionCount: 1,
      pRegions: blitRegion.addr,
      filter: VK_FILTER_NEAREST,
    )
    vkCmdBlitImage2(cmdBuffer, blitInfo.addr)

    # 8. Barrier: Transition swapchain image to PRESENT_SRC
    var b3 = VkImageMemoryBarrier2(
      sType: VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
      srcStageMask: VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_BLIT_BIT),
      srcAccessMask: VkAccessFlags2(VK_ACCESS_2_TRANSFER_WRITE_BIT),
      dstStageMask: VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_NONE),
      dstAccessMask: VkAccessFlags2(VK_ACCESS_2_NONE),
      oldLayout: VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
      newLayout: VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
      image: swapchainImages[imageIndex],
      subresourceRange: VkImageSubresourceRange(
        aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT),
        baseMipLevel: 0, levelCount: 1, baseArrayLayer: 0, layerCount: 1,
      ),
    )
    var dep3 = VkDependencyInfo(sType: VK_STRUCTURE_TYPE_DEPENDENCY_INFO, imageMemoryBarrierCount: 1, pImageMemoryBarriers: b3.addr)
    vkCmdPipelineBarrier2(cmdBuffer, dep3.addr)

    checkVk(vkEndCommandBuffer(cmdBuffer), "EndCommandBuffer")

    # 9. Submit & Present
    var waitStage = VkPipelineStageFlags(VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT)
    var submitInfo = VkSubmitInfo(
      sType: VK_STRUCTURE_TYPE_SUBMIT_INFO,
      waitSemaphoreCount: 1,
      pWaitSemaphores: imgAvailableSem.addr,
      pWaitDstStageMask: waitStage.addr,
      commandBufferCount: 1,
      pCommandBuffers: cmdBuffer.addr,
      signalSemaphoreCount: 1,
      pSignalSemaphores: renderFinishedSem.addr,
    )
    checkVk(vkQueueSubmit(queue, 1, submitInfo.addr, inFlightFence), "QueueSubmit")

    var presentInfo = VkPresentInfoKHR(
      sType: VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
      waitSemaphoreCount: 1,
      pWaitSemaphores: renderFinishedSem.addr,
      swapchainCount: 1,
      pSwapchains: swapchain.addr,
      pImageIndices: imageIndex.addr,
    )
    discard vkQueuePresentKHR(queue, presentInfo.addr)

  discard vkDeviceWaitIdle(device)
  echo "Exited cleanly!"

when isMainModule:
  main()
