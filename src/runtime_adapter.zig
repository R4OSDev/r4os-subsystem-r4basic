const runtime = @import("r4os").subsystem_runtime;
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
};

fn step(context: *anyopaque, budget: u32, guest_now_ns: u64) runtime.StepResult {
    _ = guest_now_ns;
    const self: *Adapter = @ptrCast(@alignCast(context));
    const result = self.machine.runSlice(budget);
    return switch (result.status) {
        .ready, .yielded => runtime.StepResult.progress(false),
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
