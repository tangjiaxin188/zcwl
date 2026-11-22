//! Vulkan WSI: create a `VkSurfaceKHR` from an existing Wayland surface.
//!
//! The application owns the VkInstance/device/swapchain and supplies its own
//! `vkGetInstanceProcAddr`; this module only calls
//! `vkCreateWaylandSurfaceKHR`.

const std = @import("std");
const Vulkan = @import("../../Vulkan.zig");
const c = @import("protocols.zig").c;

const VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR: c_uint = 1000006000;

const WaylandSurfaceCreateInfo = extern struct {
    s_type: c_uint = VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR,
    p_next: ?*const anyopaque = null,
    flags: c_uint = 0,
    display: ?*c.struct_wl_display,
    surface: ?*c.struct_wl_surface,
};

const CreateWaylandSurface = *const fn (
    instance: Vulkan.Instance,
    create_info: *const WaylandSurfaceCreateInfo,
    allocator: ?*const anyopaque,
    surface: *Vulkan.SurfaceKHR,
) callconv(.c) c_int;

pub fn createSurface(
    display: *c.struct_wl_display,
    surface: *c.struct_wl_surface,
    instance: Vulkan.Instance,
    get_instance_proc_addr: Vulkan.GetInstanceProcAddr,
    allocator: ?*const Vulkan.AllocationCallbacks,
) !Vulkan.SurfaceKHR {
    const proc = get_instance_proc_addr(instance, "vkCreateWaylandSurfaceKHR") orelse return error.Unsupported;
    const create: CreateWaylandSurface = @ptrCast(proc);

    const info = WaylandSurfaceCreateInfo{
        .display = display,
        .surface = surface,
    };
    var result: Vulkan.SurfaceKHR = 0;
    const vk_result = create(instance, &info, allocator, &result);
    if (vk_result != 0) return error.VulkanSurfaceFailed;
    return result;
}
