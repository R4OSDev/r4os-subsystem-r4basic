const r4os = @import("r4os");
const host = r4os.subsystem_host;
const runtime = r4os.subsystem_runtime;
const vm = @import("vm.zig");

pub const api = runtime;
pub const reset_error_out_of_memory: i32 = -9801;

pub const Adapter = struct {
    machine: *vm.Vm,

    pub fn init(machine: *vm.Vm) Adapter {
        return .{ .machine = machine };
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
    return switch (result.status) {
        .ready, .yielded => runtime.StepResult.waitUntil(guest_now_ns +| vm.execution_slice_interval_ns, false),
        .waiting => runtime.StepResult.waitUntil(
            if (result.wake_guest_ns == 0) guest_now_ns +| vm.input_poll_interval_ns else result.wake_guest_ns,
            false,
        ),
        .halted, .cancelled => runtime.StepResult.complete(self.machine.exit_code, false),
        .runtime_error => runtime.StepResult.fail(self.machine.exit_code),
    };
}

fn reset(context: *anyopaque) i32 {
    const self: *Adapter = @ptrCast(@alignCast(context));
    self.machine.reset() catch return reset_error_out_of_memory;
    return 0;
}

fn renderAudio(_: *anyopaque, out: []u8) i32 {
    @memset(out, 0);
    return 0;
}
