# Vulkan 1.4 Port Migration TODO

This checklist tracks the implementation of the Vulkan 1.4 compute stream port on branch `vulkan-port`, mapped against the checkpoints defined in `vulkan_port_plan.md` and ongoing implementation reviews.

---

## Checkpoint Progress

### [x] Checkpoint 0: Baseline Capture & Automated Diff Harness
- [x] Capture golden `.ppm` images from OpenGL compute baseline (`BasicLit`, `ShadowedLit`, `Unlit`, `DebugNormals`, `DebugSteps`).
- [x] Create Python parity comparison tool (`tests/diff_images.py`) with MSE/PSNR calculation and delta heatmap generation.
- [x] Verify comparison script against golden references.

### [x] Checkpoint 1: Co-Design & Finalization of GFX RHI + Slang Integration via 2D Test & Particle Simulation
- [x] Implement lightweight `GpuStream.nim` RHI (device initialization, stream recording, memory slice allocation with BDA).
- [x] Implement compile-time `SlangIntegration.nim` using `treeform/jsony` to parse reflection JSON and synthesize Nim types.
- [x] Update `Slangc.nim` with `ShaderDataLayout` options (`CLayout`, `Scalar`, etc.) and target-aware profile handling (omit GLSL profiles when compiling for Vulkan SPIR-V).
- [x] Support headless screenshot readback and automated window presentation.
- [x] Implement robust surface lifecycle, leak-free device probing, and window resize handling (`target.resize(w, h)`).
- [x] Decouple `stream.dispatch` from `GpuTarget` for general compute (pure BDA dispatches, multi-pass pipelines).
- [x] Implement `bindTarget`, `clearTarget`, and `barrierComputeToCompute` / `barrier` for multi-pass compute pipelines.
- [x] Implement multi-pass compute particle simulation example app (`tests/test_checkpoint1.nim`) with 200,000 GPU-simulated particles, organic harmonic flow field, smooth cosine color palette fading, and compute rasterization.
- [ ] Add layout validation tag/flag to shader output compiled through the Nim Slang API (validate at load time so layouts cannot silently mismatch).

### [ ] Checkpoint 2: Full SDF Slang Shader BDA Migration & Reflection Test
- [ ] Refactor `shaders/SdfRenderer.slang` to use 64-bit BDA pointers in push constants (`SdfPushParams`).
- [ ] Replace structured buffer indexing with direct pointer dereferencing in Slang.
- [ ] Invoke `importSlangShader` on the full SDF shader and verify type generation for `SceneUniforms`, `DebugSettings`, `Material`, `SdfInstruction`, `PointLight`, and `SdfPushParams`.
- [ ] Verify SPIR-V compilation with `VK_EXT_shader_object` compatibility.

### [ ] Checkpoint 3: SdfRenderer CPU-Side Port & Visual Parity Verification
- [ ] Replace OpenGL allocations with `GpuSlice[T]` in `SdfRenderer.nim``.
- [ ] Wire camera uniforms, dynamic objects, and CSG instruction buffer into mapped VRAM.
- [ ] Record dispatches and present passes on `GpuStream`.
- [ ] Run automated visual diff (`tests/diff_images.py`) against all 5 golden images (target: MSE < 0.5).

### [ ] Checkpoint 4: End-to-End Automated Testing (Input & Resizing) & Merging
- [ ] Automated input tests (camera movement, mode switching hotkeys).
- [ ] Window resizing validation under Wayland / X11 (swapchain recreation).
- [ ] Remove legacy OpenGL files (`src/GlUtils.nim`, `src/glad/`).
- [ ] Update Nimble configuration and merge `vulkan-port` branch back to `dev`.

---

## Implementation Review & Issues Log

The following issues were identified during architectural and system reviews:

### 🔴 Critical Issues
- [x] **Color Channel Inversion Hazard with `vkCmdCopyImage2`**:
  - *Identified*: `GpuTarget.storageImage` was fixed to `VK_FORMAT_R8G8B8A8_UNORM`. When swapchains negotiated `VK_FORMAT_B8G8R8A8_UNORM`, raw block copying swapped red and blue channels.
  - *Fix Applied*: Storage image format now matches `swapchain.format` directly, and readback PPM logic swizzles BGRA to RGB when needed.
- [x] **Unconditional `{.packed.}` in Slang Macro**:
  - *Identified*: Naked `{.packed.}` without matching layout rules caused potential padding misalignments between Slang std430 vectors and Nim objects.
  - *Fix Applied*: Shaders are compiled via `Slangc.nim` using `-fvk-use-c-layout` (matching standard C struct ABI). Slang integration macro generates standard Nim objects matching the C struct ABI without manual padding or `{.packed.}`.
- [x] **Semaphore Wait Stage in `present`**:
  - *Identified*: `imageAvailableSem` was waited on at `COMPUTE_SHADER_BIT`, causing compute dispatches to stall unnecessarily on swapchain image acquisition.
  - *Fix Applied*: Upgraded submission to `vkQueueSubmit2` and set semaphore wait stage strictly to `VK_PIPELINE_STAGE_2_TRANSFER_BIT`.

### 🟠 High Priority / Ergonomics
- [x] **`dispatch` Hardcoded to `GpuTarget` & Multi-Pass Support**:
  - *Identified*: `stream.dispatch` previously required passing `target: GpuTarget` and automatically bound descriptor binding 0 to `target.storageView`. Multi-pass compute pipelines require pure buffer-to-buffer dispatches, multiple targets, and image clearing.
  - *Fix Applied*: Decoupled `stream.dispatch` into:
    - Pure general compute: `proc dispatch*[PushT: object](stream: GpuStream, shader: ComputeShader, pushConstants: PushT, workgroupsX: uint32, workgroupsY: uint32 = 1, workgroupsZ: uint32 = 1)`
    - Convenience target dispatch: `proc dispatch*[PushT: object](stream: GpuStream, shader: ComputeShader, target: GpuTarget, pushConstants: PushT, ...)`
    - Target binding: `proc bindTarget*(stream: GpuStream, target: GpuTarget, binding: uint32 = 0)`
    - Fast target clearing: `proc clearTarget*(stream: GpuStream, target: GpuTarget, r, g, b, a: float32 = 0.0f32)` via `vkCmdClearColorImage`
    - Memory synchronization: `proc barrierComputeToCompute*(stream: GpuStream)` / `barrier*` via `vkCmdPipelineBarrier2`
    - Target layout tracking: `target.currentLayout: VkImageLayout` tracking layouts across passes, transitions, and presentations.
- [x] **Surface Leak & Missing Resize Support**:
  - *Identified*: Temporary probe surface created during `initGpuDevice` was never destroyed, leaking a `VkSurfaceKHR`. Window resizing caused `beginFrame` to spin without swapchain recreation.
  - *Fix Applied*: Probe surface in `initGpuDevice` is destroyed immediately after queue selection (`vkDestroySurfaceKHR`). Persistent surface is owned by `GpuTarget`. Implemented `target.resize(newWidth, newHeight)` and `target.resize(win)` with swapchain & storage image recreation, zero-extent minimization handling, graceful `VK_ERROR_OUT_OF_DATE_KHR` / `VK_SUBOPTIMAL_KHR` handling in `beginFrame` and `present`, clean `destroy` procs for `GpuDevice`, `GpuTarget`, `GpuStream`, and `ComputeShader`.
- [x] **Hardcoded `"main"` in `loadComputeShader`**:
  - *Identified*: The `entryName` argument in `loadComputeShader` was ignored and `"main"` was hardcoded in `VkShaderCreateInfoEXT`.
  - *Fix Applied*: `entryName.cstring` is passed to `pName` in `VkShaderCreateInfoEXT`.

---

## Future Work
- [ ] **Compile-Time Struct Layout Verification**:
  - Add compile-time verification in `importSlangShader` (`offsetOf(NimType, field) == slangField.binding.offset` and `sizeof(NimType) == slangStruct.sizes[0].value`) with clear compiler diagnostics.
- [ ] **Zero-Copy Swapchain Storage Image**:
  - Investigate direct rendering into swapchain images created with `VK_IMAGE_USAGE_STORAGE_BIT` where supported by drivers/WSI, bypassing the `vkCmdCopyImage2` present step.
- [ ] **`VK_EXT_descriptor_heap` Support for Many Image Targets / Bindless**:
  - Add support for `VK_EXT_descriptor_heap` (`SPV_EXT_descriptor_heap`) if the compute pipeline expands to require many dynamic image/texture targets or bindless material resources, replacing push descriptors with D3D12-style `ResourceDescriptorHeap[i]` access in Slang.
