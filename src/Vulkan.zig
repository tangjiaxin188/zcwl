//! Minimal Vulkan WSI types. The library never owns Vulkan objects and does
//! not require the Vulkan SDK; these types are ABI-compatible aliases.
const General = @import("General.zig");

/// VkInstance handle.
pub const Instance = *anyopaque;

/// Raw VkSurfaceKHR value (pointer-sized on 64-bit targets).
pub const SurfaceKHR = u64;

/// Optional VkAllocationCallbacks.
pub const AllocationCallbacks = anyopaque;

/// PFN_vkGetInstanceProcAddr supplied by the caller's Vulkan loader.
pub const GetInstanceProcAddr = *const fn (
    instance: ?Instance,
    name: [*:0]const u8,
) callconv(.c) ?General.ProcAddr;
