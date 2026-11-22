pub const Event = @import("Event.zig");
pub const App = @import("App.zig");
pub const Window = @import("Window.zig");
pub const Context = @import("Context.zig");
pub const General = @import("General.zig");
pub const Vulkan = @import("Vulkan.zig");
pub const Config = @import("Config.zig");
pub const Backend = @import("Backend.zig");

const version = "v0.0.1-wl";

pub fn getVersion() []const u8 {
    return version;
}
