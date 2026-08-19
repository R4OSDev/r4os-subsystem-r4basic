const r4os = @import("r4os");
const host = r4os.subsystem_host;
const runtime = r4os.subsystem_runtime;
const vm = @import("vm.zig");

pub const api = runtime;
pub const reset_error_out_of_memory: i32 = -9801;

pub const Adapter = struct {
    machine: *vm.Vm,
    presented_mode_revision: u64 = 0,
    presented_content_revision: u64 = 0,
    next_video_guest_ns: u64 = 0,

    pub fn init(machine: *vm.Vm) Adapter {
        return .{ .machine = machine };
    }

    pub fn syncVideo(self: *Adapter, presenter: *host.Presenter) host.Error!bool {
        const view = self.machine.graphicsView() orelse {
            self.presented_mode_revision = 0;
            return false;
        };
        if (self.presented_mode_revision != view.mode_revision) {
            const surface = try host.Surface.initIndexed8(view.pixels, view.palette, view.width, view.height);
            try presenter.setSurface(surface);
            self.presented_mode_revision = view.mode_revision;
            self.presented_content_revision = view.content_revision;
            _ = self.machine.takeGraphicsDamage();
            return true;
        }
        const damage = self.machine.takeGraphicsDamage() orelse return false;
        presenter.invalidate(.{ .x = damage.x, .y = damage.y, .w = damage.w, .h = damage.h });
        self.presented_content_revision = view.content_revision;
        return true;
    }

    pub fn driver(self: *Adapter) runtime.GuestDriver {
        return .{
            .context = self,
            .step_fn = step,
            .reset_fn = reset,
            .render_audio_fn = renderAudio,
        };
    }

    pub fn handleInput(self: *Adapter, event: host.InputEvent) bool {
        return switch (event) {
            .close => blk: {
                self.machine.requestCancel();
                break :blk true;
            },
            .focus => |focus| blk: {
                self.machine.setInputFocused(focus.focused);
                break :blk true;
            },
            .key_down => |key| self.machine.enqueueKeyCode(key.code) catch false,
            .text => |text_event| self.machine.enqueueTextCodepoint(text_event.codepoint) catch false,
            .resize, .mouse => false,
        };
    }
};

fn step(context: *anyopaque, budget: u32, guest_now_ns: u64) runtime.StepResult {
    const self: *Adapter = @ptrCast(@alignCast(context));
    self.machine.setGuestTime(guest_now_ns);
    const result = self.machine.runSlice(@min(budget, vm.default_instruction_budget));
    const terminal = result.status == .halted or result.status == .cancelled or result.status == .runtime_error;
    const frame_ready = frameReady(self, guest_now_ns, terminal);
    return switch (result.status) {
        .ready, .yielded => runtime.StepResult.waitUntil(guest_now_ns +| vm.execution_slice_interval_ns, frame_ready),
        .waiting => runtime.StepResult.waitUntil(
            if (result.wake_guest_ns == 0) guest_now_ns +| vm.input_poll_interval_ns else result.wake_guest_ns,
            frame_ready,
        ),
        .halted, .cancelled => runtime.StepResult.complete(self.machine.exit_code, frame_ready),
        .runtime_error => runtime.StepResult.fail(self.machine.exit_code),
    };
}

fn frameReady(self: *Adapter, guest_now_ns: u64, terminal: bool) bool {
    const view = self.machine.graphicsView() orelse return false;
    const changed = self.presented_mode_revision != view.mode_revision or
        self.presented_content_revision != view.content_revision;
    if (!changed or (!terminal and guest_now_ns < self.next_video_guest_ns)) return false;
    self.next_video_guest_ns = guest_now_ns +| 33 * @import("std").time.ns_per_ms;
    return true;
}

fn reset(context: *anyopaque) i32 {
    const self: *Adapter = @ptrCast(@alignCast(context));
    self.machine.reset() catch return reset_error_out_of_memory;
    self.machine.prepareHostDisplay() catch return reset_error_out_of_memory;
    self.presented_mode_revision = 0;
    self.presented_content_revision = 0;
    self.next_video_guest_ns = 0;
    return 0;
}

fn renderAudio(context: *anyopaque, out: []u8) i32 {
    const self: *Adapter = @ptrCast(@alignCast(context));
    return self.machine.renderAudio(out);
}
