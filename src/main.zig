const r4os = @import("r4os");
const frontend = @import("frontend.zig");

pub fn r4_app_main(app: *r4os.App) i32 {
    _ = frontend.contract_version;
    if (app.profile != .desktop) return 64;
    return 0;
}
