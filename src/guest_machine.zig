const std = @import("std");

pub const memory_bytes: usize = 1024 * 1024;
pub const port_count: usize = 65_536;
pub const default_data_segment: u16 = 0x2000;
pub const default_stack_segment: u16 = 0xF000;
pub const default_stack_pointer: u16 = 0xFFFE;
pub const default_instruction_budget: u32 = 65_536;

pub const Address = struct {
    segment: u16,
    offset: u16,

    pub fn physical(self: Address) usize {
        return (@as(usize, self.segment) * 16 + @as(usize, self.offset)) & (memory_bytes - 1);
    }
};

pub const PortError = error{Unavailable};

const PortEntry = struct {
    port: u16,
    value: u8,
};

pub const Registers = struct {
    ax: u16 = 0,
    bx: u16 = 0,
    cx: u16 = 0,
    dx: u16 = 0,
    bp: u16 = 0,
    si: u16 = 0,
    di: u16 = 0,
    sp: u16 = default_stack_pointer,
    cs: u16 = 0,
    ds: u16 = default_data_segment,
    es: u16 = default_data_segment,
    ss: u16 = default_stack_segment,
    ip: u16 = 0,
    flags: u16 = flag_reserved,
};

pub const flag_carry: u16 = 1 << 0;
pub const flag_parity: u16 = 1 << 2;
pub const flag_auxiliary: u16 = 1 << 4;
pub const flag_zero: u16 = 1 << 6;
pub const flag_sign: u16 = 1 << 7;
pub const flag_trap: u16 = 1 << 8;
pub const flag_interrupt: u16 = 1 << 9;
pub const flag_direction: u16 = 1 << 10;
pub const flag_overflow: u16 = 1 << 11;
pub const flag_reserved: u16 = 1 << 1;

pub const InterruptResult = enum { handled, unavailable };
pub const InterruptHandler = *const fn (?*anyopaque, u8, *Registers, *Machine) InterruptResult;

pub const ExecuteOptions = struct {
    instruction_budget: u32 = default_instruction_budget,
    stop_address: ?Address = null,
    context: ?*anyopaque = null,
    should_cancel: *const fn (?*anyopaque) bool = neverCancel,
    interrupt: InterruptHandler = unavailableInterrupt,
};

pub const ExecuteError = error{
    OutOfMemory,
    InstructionBudget,
    Cancelled,
    InvalidInstruction,
    DivideError,
    PortUnavailable,
    InterruptUnavailable,
};

pub const ExecuteResult = struct {
    registers: Registers,
    instructions: u32,
    halted: bool,
};

pub const Machine = struct {
    allocator: std.mem.Allocator,
    memory: ?[]u8 = null,
    ports: std.ArrayList(PortEntry) = .empty,
    port_generation: u64 = 0,
    far_heap_bytes: u32 = 512 * 1024,

    pub fn init(allocator: std.mem.Allocator) Machine {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Machine) void {
        if (self.memory) |bytes| self.allocator.free(bytes);
        self.ports.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn reset(self: *Machine) void {
        if (self.memory) |bytes| {
            self.allocator.free(bytes);
            self.memory = null;
        }
        self.ports.clearRetainingCapacity();
        self.port_generation = 0;
        self.far_heap_bytes = 512 * 1024;
    }

    pub fn ensureMemory(self: *Machine) error{OutOfMemory}![]u8 {
        if (self.memory == null) {
            const bytes = self.allocator.alloc(u8, memory_bytes) catch return error.OutOfMemory;
            @memset(bytes, 0);
            self.memory = bytes;
        }
        return self.memory.?;
    }

    pub fn readByte(self: *Machine, address: Address) error{OutOfMemory}!u8 {
        return (try self.ensureMemory())[address.physical()];
    }

    pub fn readExistingByte(self: *const Machine, address: Address) u8 {
        const bytes = self.memory orelse return 0;
        return bytes[address.physical()];
    }

    pub fn writeByte(self: *Machine, address: Address, value: u8) error{OutOfMemory}!void {
        (try self.ensureMemory())[address.physical()] = value;
    }

    pub fn readWord(self: *Machine, address: Address) error{OutOfMemory}!u16 {
        const low = try self.readByte(address);
        const high = try self.readByte(.{ .segment = address.segment, .offset = address.offset +% 1 });
        return @as(u16, low) | (@as(u16, high) << 8);
    }

    pub fn writeWord(self: *Machine, address: Address, value: u16) error{OutOfMemory}!void {
        try self.writeByte(address, @truncate(value));
        try self.writeByte(.{ .segment = address.segment, .offset = address.offset +% 1 }, @truncate(value >> 8));
    }

    pub fn readRange(self: *Machine, address: Address, out: []u8) error{ OutOfMemory, InvalidRange }!void {
        if (out.len > memory_bytes) return error.InvalidRange;
        const memory = try self.ensureMemory();
        var physical = address.physical();
        for (out) |*byte| {
            byte.* = memory[physical];
            physical = (physical + 1) & (memory_bytes - 1);
        }
    }

    pub fn writeRange(self: *Machine, address: Address, bytes: []const u8) error{ OutOfMemory, InvalidRange }!void {
        if (bytes.len > memory_bytes) return error.InvalidRange;
        const memory = try self.ensureMemory();
        var physical = address.physical();
        for (bytes) |byte| {
            memory[physical] = byte;
            physical = (physical + 1) & (memory_bytes - 1);
        }
    }

    pub fn definePort(self: *Machine, port: u16, initial: u8) error{OutOfMemory}!void {
        if (self.portIndex(port)) |index| {
            self.ports.items[index].value = initial;
            return;
        }
        self.ports.append(self.allocator, .{ .port = port, .value = initial }) catch return error.OutOfMemory;
    }

    pub fn removePort(self: *Machine, port: u16) void {
        const index = self.portIndex(port) orelse return;
        _ = self.ports.swapRemove(index);
    }

    pub fn hasPort(self: *const Machine, port: u16) bool {
        return self.portIndex(port) != null;
    }

    pub fn readPort(self: *const Machine, port: u16) PortError!u8 {
        const index = self.portIndex(port) orelse return error.Unavailable;
        return self.ports.items[index].value;
    }

    pub fn writePort(self: *Machine, port: u16, value: u8) PortError!void {
        const index = self.portIndex(port) orelse return error.Unavailable;
        if (self.ports.items[index].value != value) {
            self.ports.items[index].value = value;
            self.port_generation +%= 1;
        }
    }

    fn portIndex(self: *const Machine, port: u16) ?usize {
        for (self.ports.items, 0..) |entry, index| if (entry.port == port) return index;
        return null;
    }

    pub fn setFarHeap(self: *Machine, delta: i32) u32 {
        if (delta < 0) {
            self.far_heap_bytes -|= @intCast(-@as(i64, delta));
        } else {
            self.far_heap_bytes = @min(@as(u32, memory_bytes), self.far_heap_bytes +| @as(u32, @intCast(delta)));
        }
        return self.far_heap_bytes;
    }

    pub fn execute(self: *Machine, initial: Registers, options: ExecuteOptions) ExecuteError!ExecuteResult {
        var cpu = Cpu{ .machine = self, .registers = initial, .options = options };
        return cpu.run();
    }
};

const Repeat = enum { none, while_equal, while_not_equal };
const Operand = union(enum) {
    register: u3,
    memory: Address,
};

const Cpu = struct {
    machine: *Machine,
    registers: Registers,
    options: ExecuteOptions,
    instructions: u32 = 0,
    segment_override: ?u16 = null,
    repeat: Repeat = .none,

    fn run(self: *Cpu) ExecuteError!ExecuteResult {
        while (true) {
            if (self.options.stop_address) |stop| {
                if (self.registers.cs == stop.segment and self.registers.ip == stop.offset) {
                    return .{ .registers = self.registers, .instructions = self.instructions, .halted = false };
                }
            }
            if (self.instructions >= self.options.instruction_budget) return error.InstructionBudget;
            if (self.options.should_cancel(self.options.context)) return error.Cancelled;
            self.instructions += 1;
            self.segment_override = null;
            self.repeat = .none;
            var opcode = try self.fetch8();
            while (true) switch (opcode) {
                0x26 => { self.segment_override = self.registers.es; opcode = try self.fetch8(); },
                0x2E => { self.segment_override = self.registers.cs; opcode = try self.fetch8(); },
                0x36 => { self.segment_override = self.registers.ss; opcode = try self.fetch8(); },
                0x3E => { self.segment_override = self.registers.ds; opcode = try self.fetch8(); },
                0xF0 => opcode = try self.fetch8(),
                0xF2 => { self.repeat = .while_not_equal; opcode = try self.fetch8(); },
                0xF3 => { self.repeat = .while_equal; opcode = try self.fetch8(); },
                else => break,
            };
            if (try self.step(opcode)) |halted| {
                return .{ .registers = self.registers, .instructions = self.instructions, .halted = halted };
            }
        }
    }

    fn step(self: *Cpu, opcode: u8) ExecuteError!?bool {
        if (opcode >= 0x40 and opcode <= 0x47) {
            const index: u3 = @truncate(opcode);
            const before = self.getReg16(index);
            self.setReg16(index, self.add16(before, 1, false));
            return null;
        }
        if (opcode >= 0x48 and opcode <= 0x4F) {
            const index: u3 = @truncate(opcode);
            const before = self.getReg16(index);
            self.setReg16(index, self.sub16(before, 1, false));
            return null;
        }
        if (opcode >= 0x50 and opcode <= 0x57) {
            try self.push16(self.getReg16(@truncate(opcode)));
            return null;
        }
        if (opcode >= 0x58 and opcode <= 0x5F) {
            self.setReg16(@truncate(opcode), try self.pop16());
            return null;
        }
        if (opcode >= 0x70 and opcode <= 0x7F) {
            const displacement: i8 = @bitCast(try self.fetch8());
            if (self.condition(@truncate(opcode))) self.registers.ip +%= @bitCast(@as(i16, displacement));
            return null;
        }
        if (opcode >= 0x90 and opcode <= 0x97) {
            const index: u3 = @truncate(opcode);
            if (index != 0) {
                const other = self.getReg16(index);
                self.setReg16(index, self.registers.ax);
                self.registers.ax = other;
            }
            return null;
        }
        if (opcode >= 0xB0 and opcode <= 0xB7) {
            self.setReg8(@truncate(opcode), try self.fetch8());
            return null;
        }
        if (opcode >= 0xB8 and opcode <= 0xBF) {
            self.setReg16(@truncate(opcode), try self.fetch16());
            return null;
        }
        switch (opcode) {
            0x00...0x05, 0x08...0x0D, 0x10...0x15, 0x18...0x1D,
            0x20...0x25, 0x28...0x2D, 0x30...0x35, 0x38...0x3D,
            => try self.aluOpcode(opcode),
            0x06 => try self.push16(self.registers.es),
            0x07 => self.registers.es = try self.pop16(),
            0x0E => try self.push16(self.registers.cs),
            0x16 => try self.push16(self.registers.ss),
            0x17 => self.registers.ss = try self.pop16(),
            0x1E => try self.push16(self.registers.ds),
            0x1F => self.registers.ds = try self.pop16(),
            0x60 => try self.pushAll(),
            0x61 => try self.popAll(),
            0x68 => try self.push16(try self.fetch16()),
            0x6A => try self.push16(@bitCast(@as(i16, @as(i8, @bitCast(try self.fetch8()))))),
            0x80, 0x81, 0x83 => try self.aluGroup(opcode),
            0x84, 0x85 => try self.testOperands(opcode == 0x84),
            0x86, 0x87 => try self.exchangeOperands(opcode == 0x86),
            0x88, 0x89, 0x8A, 0x8B => try self.moveOperands(opcode),
            0x8C => try self.moveSegment(false),
            0x8D => try self.loadEffectiveAddress(),
            0x8E => try self.moveSegment(true),
            0x8F => { const modrm = try self.fetch8(); if (((modrm >> 3) & 7) != 0) return error.InvalidInstruction; try self.write16(try self.decodeOperand(modrm), try self.pop16()); },
            0x98 => self.registers.ax = @bitCast(@as(i16, @as(i8, @bitCast(@as(u8, @truncate(self.registers.ax)))))),
            0x99 => self.registers.dx = if ((self.registers.ax & 0x8000) != 0) 0xFFFF else 0,
            0x9A => { const ip = try self.fetch16(); const cs = try self.fetch16(); try self.push16(self.registers.cs); try self.push16(self.registers.ip); self.registers.cs = cs; self.registers.ip = ip; },
            0x9C => try self.push16(self.registers.flags | flag_reserved),
            0x9D => self.registers.flags = (try self.pop16()) | flag_reserved,
            0x9E => self.registers.flags = (self.registers.flags & 0xFF00) | (@as(u16, @truncate(self.registers.ax >> 8)) & 0xD5) | flag_reserved,
            0x9F => self.registers.ax = (self.registers.ax & 0x00FF) | ((self.registers.flags & 0x00FF) << 8),
            0xA0 => self.setReg8(0, self.machine.readByte(.{ .segment = self.dataSegment(), .offset = try self.fetch16() }) catch return error.OutOfMemory),
            0xA1 => self.registers.ax = self.machine.readWord(.{ .segment = self.dataSegment(), .offset = try self.fetch16() }) catch return error.OutOfMemory,
            0xA2 => self.machine.writeByte(.{ .segment = self.dataSegment(), .offset = try self.fetch16() }, self.getReg8(0)) catch return error.OutOfMemory,
            0xA3 => self.machine.writeWord(.{ .segment = self.dataSegment(), .offset = try self.fetch16() }, self.registers.ax) catch return error.OutOfMemory,
            0xA4...0xA7, 0xAA...0xAF => try self.stringInstruction(opcode),
            0xA8 => { const value = try self.fetch8(); self.logicalFlags8(self.getReg8(0) & value); },
            0xA9 => { const value = try self.fetch16(); self.logicalFlags16(self.registers.ax & value); },
            0xC0, 0xC1, 0xD0, 0xD1, 0xD2, 0xD3 => try self.shiftGroup(opcode),
            0xC2 => { const count = try self.fetch16(); self.registers.ip = try self.pop16(); self.registers.sp +%= count; },
            0xC3 => self.registers.ip = try self.pop16(),
            0xC4, 0xC5 => try self.loadFarPointer(opcode == 0xC4),
            0xC6, 0xC7 => try self.moveImmediate(opcode == 0xC6),
            0xCA => { const count = try self.fetch16(); self.registers.ip = try self.pop16(); self.registers.cs = try self.pop16(); self.registers.sp +%= count; },
            0xCB => { self.registers.ip = try self.pop16(); self.registers.cs = try self.pop16(); },
            0xCC => try self.interrupt(3),
            0xCD => try self.interrupt(try self.fetch8()),
            0xCE => if (self.flag(flag_overflow)) try self.interrupt(4),
            0xCF => { self.registers.ip = try self.pop16(); self.registers.cs = try self.pop16(); self.registers.flags = (try self.pop16()) | flag_reserved; },
            0xE0, 0xE1, 0xE2 => { const displacement: i8 = @bitCast(try self.fetch8()); self.registers.cx -%= 1; const take = switch (opcode) { 0xE0 => self.registers.cx != 0 and !self.flag(flag_zero), 0xE1 => self.registers.cx != 0 and self.flag(flag_zero), else => self.registers.cx != 0 }; if (take) self.registers.ip +%= @bitCast(@as(i16, displacement)); },
            0xE3 => { const displacement: i8 = @bitCast(try self.fetch8()); if (self.registers.cx == 0) self.registers.ip +%= @bitCast(@as(i16, displacement)); },
            0xE4 => self.setReg8(0, self.machine.readPort(try self.fetch8()) catch return error.PortUnavailable),
            0xE5 => self.registers.ax = try self.readPortWord(try self.fetch8()),
            0xE6 => self.machine.writePort(try self.fetch8(), self.getReg8(0)) catch return error.PortUnavailable,
            0xE7 => try self.writePortWord(try self.fetch8(), self.registers.ax),
            0xE8 => { const displacement: i16 = @bitCast(try self.fetch16()); try self.push16(self.registers.ip); self.registers.ip +%= @bitCast(displacement); },
            0xE9 => { const displacement: i16 = @bitCast(try self.fetch16()); self.registers.ip +%= @bitCast(displacement); },
            0xEA => { const ip = try self.fetch16(); const cs = try self.fetch16(); self.registers.ip = ip; self.registers.cs = cs; },
            0xEB => { const displacement: i8 = @bitCast(try self.fetch8()); self.registers.ip +%= @bitCast(@as(i16, displacement)); },
            0xEC => self.setReg8(0, self.machine.readPort(self.registers.dx) catch return error.PortUnavailable),
            0xED => self.registers.ax = try self.readPortWord(self.registers.dx),
            0xEE => self.machine.writePort(self.registers.dx, self.getReg8(0)) catch return error.PortUnavailable,
            0xEF => try self.writePortWord(self.registers.dx, self.registers.ax),
            0xF4 => return true,
            0xF5 => self.setFlag(flag_carry, !self.flag(flag_carry)),
            0xF6, 0xF7 => try self.unaryGroup(opcode == 0xF6),
            0xF8 => self.setFlag(flag_carry, false),
            0xF9 => self.setFlag(flag_carry, true),
            0xFA => self.setFlag(flag_interrupt, false),
            0xFB => self.setFlag(flag_interrupt, true),
            0xFC => self.setFlag(flag_direction, false),
            0xFD => self.setFlag(flag_direction, true),
            0xFE, 0xFF => try self.controlGroup(opcode == 0xFE),
            else => return error.InvalidInstruction,
        }
        return null;
    }

    fn fetch8(self: *Cpu) ExecuteError!u8 {
        const value = self.machine.readByte(.{ .segment = self.registers.cs, .offset = self.registers.ip }) catch return error.OutOfMemory;
        self.registers.ip +%= 1;
        return value;
    }

    fn fetch16(self: *Cpu) ExecuteError!u16 {
        const low = try self.fetch8();
        const high = try self.fetch8();
        return @as(u16, low) | (@as(u16, high) << 8);
    }

    fn push16(self: *Cpu, value: u16) ExecuteError!void {
        self.registers.sp -%= 2;
        self.machine.writeWord(.{ .segment = self.registers.ss, .offset = self.registers.sp }, value) catch return error.OutOfMemory;
    }

    fn pop16(self: *Cpu) ExecuteError!u16 {
        const value = self.machine.readWord(.{ .segment = self.registers.ss, .offset = self.registers.sp }) catch return error.OutOfMemory;
        self.registers.sp +%= 2;
        return value;
    }

    fn getReg16(self: *const Cpu, index: u3) u16 {
        return switch (index) { 0 => self.registers.ax, 1 => self.registers.cx, 2 => self.registers.dx, 3 => self.registers.bx, 4 => self.registers.sp, 5 => self.registers.bp, 6 => self.registers.si, 7 => self.registers.di };
    }

    fn setReg16(self: *Cpu, index: u3, value: u16) void {
        switch (index) { 0 => self.registers.ax = value, 1 => self.registers.cx = value, 2 => self.registers.dx = value, 3 => self.registers.bx = value, 4 => self.registers.sp = value, 5 => self.registers.bp = value, 6 => self.registers.si = value, 7 => self.registers.di = value }
    }

    fn getReg8(self: *const Cpu, index: u3) u8 {
        const word = self.getReg16(index & 3);
        return if (index < 4) @truncate(word) else @truncate(word >> 8);
    }

    fn setReg8(self: *Cpu, index: u3, value: u8) void {
        const register = index & 3;
        const word = self.getReg16(register);
        self.setReg16(register, if (index < 4) (word & 0xFF00) | value else (word & 0x00FF) | (@as(u16, value) << 8));
    }

    fn decodeOperand(self: *Cpu, modrm: u8) ExecuteError!Operand {
        const mode = modrm >> 6;
        const rm: u3 = @truncate(modrm);
        if (mode == 3) return .{ .register = rm };
        var base: u16 = switch (rm) {
            0 => self.registers.bx +% self.registers.si,
            1 => self.registers.bx +% self.registers.di,
            2 => self.registers.bp +% self.registers.si,
            3 => self.registers.bp +% self.registers.di,
            4 => self.registers.si,
            5 => self.registers.di,
            6 => if (mode == 0) 0 else self.registers.bp,
            7 => self.registers.bx,
        };
        if (mode == 0 and rm == 6) base = try self.fetch16() else if (mode == 1) {
            const displacement: i8 = @bitCast(try self.fetch8());
            base +%= @bitCast(@as(i16, displacement));
        } else if (mode == 2) base +%= try self.fetch16();
        const uses_stack = rm == 2 or rm == 3 or (rm == 6 and mode != 0);
        return .{ .memory = .{ .segment = self.segment_override orelse if (uses_stack) self.registers.ss else self.registers.ds, .offset = base } };
    }

    fn read8(self: *Cpu, operand: Operand) ExecuteError!u8 { return switch (operand) { .register => |index| self.getReg8(index), .memory => |address| self.machine.readByte(address) catch return error.OutOfMemory }; }
    fn read16(self: *Cpu, operand: Operand) ExecuteError!u16 { return switch (operand) { .register => |index| self.getReg16(index), .memory => |address| self.machine.readWord(address) catch return error.OutOfMemory }; }
    fn write8(self: *Cpu, operand: Operand, value: u8) ExecuteError!void { switch (operand) { .register => |index| self.setReg8(index, value), .memory => |address| self.machine.writeByte(address, value) catch return error.OutOfMemory } }
    fn write16(self: *Cpu, operand: Operand, value: u16) ExecuteError!void { switch (operand) { .register => |index| self.setReg16(index, value), .memory => |address| self.machine.writeWord(address, value) catch return error.OutOfMemory } }

    fn dataSegment(self: *const Cpu) u16 { return self.segment_override orelse self.registers.ds; }
    fn flag(self: *const Cpu, bit: u16) bool { return (self.registers.flags & bit) != 0; }
    fn setFlag(self: *Cpu, bit: u16, enabled: bool) void { if (enabled) self.registers.flags |= bit else self.registers.flags &= ~bit; self.registers.flags |= flag_reserved; }

    fn parity(value: u8) bool { return @popCount(value) % 2 == 0; }
    fn commonFlags8(self: *Cpu, value: u8) void { self.setFlag(flag_zero, value == 0); self.setFlag(flag_sign, (value & 0x80) != 0); self.setFlag(flag_parity, parity(value)); }
    fn commonFlags16(self: *Cpu, value: u16) void { self.setFlag(flag_zero, value == 0); self.setFlag(flag_sign, (value & 0x8000) != 0); self.setFlag(flag_parity, parity(@truncate(value))); }
    fn logicalFlags8(self: *Cpu, value: u8) void { self.setFlag(flag_carry, false); self.setFlag(flag_overflow, false); self.setFlag(flag_auxiliary, false); self.commonFlags8(value); }
    fn logicalFlags16(self: *Cpu, value: u16) void { self.setFlag(flag_carry, false); self.setFlag(flag_overflow, false); self.setFlag(flag_auxiliary, false); self.commonFlags16(value); }

    fn add8(self: *Cpu, left: u8, right: u8, with_carry: bool) u8 {
        const carry: u16 = @intFromBool(with_carry and self.flag(flag_carry));
        const wide = @as(u16, left) + @as(u16, right) + carry;
        const value: u8 = @truncate(wide);
        self.setFlag(flag_carry, wide > 0xFF);
        self.setFlag(flag_auxiliary, (@as(u16, left & 0xF) + @as(u16, right & 0xF) + carry) > 0xF);
        self.setFlag(flag_overflow, ((~(left ^ right) & (left ^ value)) & 0x80) != 0);
        self.commonFlags8(value); return value;
    }
    fn add16(self: *Cpu, left: u16, right: u16, with_carry: bool) u16 {
        const carry: u32 = @intFromBool(with_carry and self.flag(flag_carry));
        const wide = @as(u32, left) + @as(u32, right) + carry;
        const value: u16 = @truncate(wide);
        self.setFlag(flag_carry, wide > 0xFFFF);
        self.setFlag(flag_auxiliary, (@as(u32, left & 0xF) + @as(u32, right & 0xF) + carry) > 0xF);
        self.setFlag(flag_overflow, ((~(left ^ right) & (left ^ value)) & 0x8000) != 0);
        self.commonFlags16(value); return value;
    }
    fn sub8(self: *Cpu, left: u8, right: u8, with_borrow: bool) u8 {
        const borrow: u16 = @intFromBool(with_borrow and self.flag(flag_carry));
        const subtrahend = @as(u16, right) + borrow;
        const value: u8 = @truncate(@as(u16, left) -% subtrahend);
        self.setFlag(flag_carry, @as(u16, left) < subtrahend);
        self.setFlag(flag_auxiliary, @as(u16, left & 0xF) < @as(u16, right & 0xF) + borrow);
        self.setFlag(flag_overflow, (((left ^ right) & (left ^ value)) & 0x80) != 0);
        self.commonFlags8(value); return value;
    }
    fn sub16(self: *Cpu, left: u16, right: u16, with_borrow: bool) u16 {
        const borrow: u32 = @intFromBool(with_borrow and self.flag(flag_carry));
        const subtrahend = @as(u32, right) + borrow;
        const value: u16 = @truncate(@as(u32, left) -% subtrahend);
        self.setFlag(flag_carry, @as(u32, left) < subtrahend);
        self.setFlag(flag_auxiliary, @as(u32, left & 0xF) < @as(u32, right & 0xF) + borrow);
        self.setFlag(flag_overflow, (((left ^ right) & (left ^ value)) & 0x8000) != 0);
        self.commonFlags16(value); return value;
    }

    fn alu8(self: *Cpu, operation: u3, left: u8, right: u8) u8 { return switch (operation) { 0 => self.add8(left, right, false), 1 => blk: { const v = left | right; self.logicalFlags8(v); break :blk v; }, 2 => self.add8(left, right, true), 3 => self.sub8(left, right, true), 4 => blk: { const v = left & right; self.logicalFlags8(v); break :blk v; }, 5, 7 => self.sub8(left, right, false), 6 => blk: { const v = left ^ right; self.logicalFlags8(v); break :blk v; } }; }
    fn alu16(self: *Cpu, operation: u3, left: u16, right: u16) u16 { return switch (operation) { 0 => self.add16(left, right, false), 1 => blk: { const v = left | right; self.logicalFlags16(v); break :blk v; }, 2 => self.add16(left, right, true), 3 => self.sub16(left, right, true), 4 => blk: { const v = left & right; self.logicalFlags16(v); break :blk v; }, 5, 7 => self.sub16(left, right, false), 6 => blk: { const v = left ^ right; self.logicalFlags16(v); break :blk v; } }; }

    fn aluOpcode(self: *Cpu, opcode: u8) ExecuteError!void {
        const operation: u3 = @truncate(opcode >> 3);
        const form = opcode & 7;
        if (form <= 3) {
            const byte = (form & 1) == 0;
            const destination_reg = (form & 2) != 0;
            const modrm = try self.fetch8();
            const rm = try self.decodeOperand(modrm);
            const reg: u3 = @truncate(modrm >> 3);
            if (byte) {
                const left = if (destination_reg) self.getReg8(reg) else try self.read8(rm);
                const right = if (destination_reg) try self.read8(rm) else self.getReg8(reg);
                const result = self.alu8(operation, left, right);
                if (operation != 7) if (destination_reg) self.setReg8(reg, result) else try self.write8(rm, result);
            } else {
                const left = if (destination_reg) self.getReg16(reg) else try self.read16(rm);
                const right = if (destination_reg) try self.read16(rm) else self.getReg16(reg);
                const result = self.alu16(operation, left, right);
                if (operation != 7) if (destination_reg) self.setReg16(reg, result) else try self.write16(rm, result);
            }
        } else if (form == 4) {
            const result = self.alu8(operation, self.getReg8(0), try self.fetch8());
            if (operation != 7) self.setReg8(0, result);
        } else if (form == 5) {
            const result = self.alu16(operation, self.registers.ax, try self.fetch16());
            if (operation != 7) self.registers.ax = result;
        } else return error.InvalidInstruction;
    }

    fn aluGroup(self: *Cpu, opcode: u8) ExecuteError!void {
        const modrm = try self.fetch8(); const operation: u3 = @truncate(modrm >> 3); const operand = try self.decodeOperand(modrm);
        if (opcode == 0x80) { const result = self.alu8(operation, try self.read8(operand), try self.fetch8()); if (operation != 7) try self.write8(operand, result); }
        else { const immediate = if (opcode == 0x83) @as(u16, @bitCast(@as(i16, @as(i8, @bitCast(try self.fetch8()))))) else try self.fetch16(); const result = self.alu16(operation, try self.read16(operand), immediate); if (operation != 7) try self.write16(operand, result); }
    }

    fn testOperands(self: *Cpu, byte: bool) ExecuteError!void { const modrm = try self.fetch8(); const rm = try self.decodeOperand(modrm); const reg: u3 = @truncate(modrm >> 3); if (byte) self.logicalFlags8((try self.read8(rm)) & self.getReg8(reg)) else self.logicalFlags16((try self.read16(rm)) & self.getReg16(reg)); }
    fn exchangeOperands(self: *Cpu, byte: bool) ExecuteError!void { const modrm = try self.fetch8(); const rm = try self.decodeOperand(modrm); const reg: u3 = @truncate(modrm >> 3); if (byte) { const a = try self.read8(rm); const b = self.getReg8(reg); try self.write8(rm, b); self.setReg8(reg, a); } else { const a = try self.read16(rm); const b = self.getReg16(reg); try self.write16(rm, b); self.setReg16(reg, a); } }
    fn moveOperands(self: *Cpu, opcode: u8) ExecuteError!void { const modrm = try self.fetch8(); const rm = try self.decodeOperand(modrm); const reg: u3 = @truncate(modrm >> 3); const byte = (opcode & 1) == 0; const to_reg = (opcode & 2) != 0; if (byte) { if (to_reg) self.setReg8(reg, try self.read8(rm)) else try self.write8(rm, self.getReg8(reg)); } else { if (to_reg) self.setReg16(reg, try self.read16(rm)) else try self.write16(rm, self.getReg16(reg)); } }

    fn segment(self: *Cpu, index: u2) u16 { return switch (index) { 0 => self.registers.es, 1 => self.registers.cs, 2 => self.registers.ss, 3 => self.registers.ds }; }
    fn setSegment(self: *Cpu, index: u2, value: u16) ExecuteError!void { switch (index) { 0 => self.registers.es = value, 1 => return error.InvalidInstruction, 2 => self.registers.ss = value, 3 => self.registers.ds = value } }
    fn moveSegment(self: *Cpu, to_segment: bool) ExecuteError!void { const modrm = try self.fetch8(); const index: u2 = @truncate(modrm >> 3); const operand = try self.decodeOperand(modrm); if (to_segment) try self.setSegment(index, try self.read16(operand)) else try self.write16(operand, self.segment(index)); }
    fn loadEffectiveAddress(self: *Cpu) ExecuteError!void { const modrm = try self.fetch8(); const operand = try self.decodeOperand(modrm); const address = switch (operand) { .memory => |value| value, .register => return error.InvalidInstruction }; self.setReg16(@truncate(modrm >> 3), address.offset); }
    fn moveImmediate(self: *Cpu, byte: bool) ExecuteError!void { const modrm = try self.fetch8(); if (((modrm >> 3) & 7) != 0) return error.InvalidInstruction; const operand = try self.decodeOperand(modrm); if (byte) try self.write8(operand, try self.fetch8()) else try self.write16(operand, try self.fetch16()); }
    fn loadFarPointer(self: *Cpu, load_es: bool) ExecuteError!void { const modrm = try self.fetch8(); const operand = try self.decodeOperand(modrm); const address = switch (operand) { .memory => |value| value, .register => return error.InvalidInstruction }; self.setReg16(@truncate(modrm >> 3), self.machine.readWord(address) catch return error.OutOfMemory); const segment_value = self.machine.readWord(.{ .segment = address.segment, .offset = address.offset +% 2 }) catch return error.OutOfMemory; if (load_es) self.registers.es = segment_value else self.registers.ds = segment_value; }

    fn shiftGroup(self: *Cpu, opcode: u8) ExecuteError!void {
        const modrm = try self.fetch8(); const operation: u3 = @truncate(modrm >> 3); const operand = try self.decodeOperand(modrm); const byte = (opcode & 1) == 0;
        var count: u5 = switch (opcode) { 0xC0, 0xC1 => @truncate(try self.fetch8()), 0xD0, 0xD1 => 1, 0xD2, 0xD3 => @truncate(self.registers.cx), else => unreachable };
        if (count == 0) return;
        if (byte) { var value = try self.read8(operand); while (count != 0) : (count -= 1) value = try self.shift8(operation, value); try self.write8(operand, value); self.commonFlags8(value); }
        else { var value = try self.read16(operand); while (count != 0) : (count -= 1) value = try self.shift16(operation, value); try self.write16(operand, value); self.commonFlags16(value); }
    }
    fn shift8(self: *Cpu, operation: u3, value: u8) ExecuteError!u8 { const carry = self.flag(flag_carry); return switch (operation) { 0 => blk: { self.setFlag(flag_carry, (value & 0x80) != 0); break :blk (value << 1) | @intFromBool((value & 0x80) != 0); }, 1 => blk: { self.setFlag(flag_carry, (value & 1) != 0); break :blk (value >> 1) | (value << 7); }, 2 => blk: { self.setFlag(flag_carry, (value & 0x80) != 0); break :blk (value << 1) | @intFromBool(carry); }, 3 => blk: { self.setFlag(flag_carry, (value & 1) != 0); break :blk (value >> 1) | (@as(u8, @intFromBool(carry)) << 7); }, 4, 6 => blk: { self.setFlag(flag_carry, (value & 0x80) != 0); break :blk value << 1; }, 5 => blk: { self.setFlag(flag_carry, (value & 1) != 0); break :blk value >> 1; }, 7 => blk: { self.setFlag(flag_carry, (value & 1) != 0); break :blk @bitCast(@as(i8, @bitCast(value)) >> 1); } }; }
    fn shift16(self: *Cpu, operation: u3, value: u16) ExecuteError!u16 { const carry = self.flag(flag_carry); return switch (operation) { 0 => blk: { self.setFlag(flag_carry, (value & 0x8000) != 0); break :blk (value << 1) | @intFromBool((value & 0x8000) != 0); }, 1 => blk: { self.setFlag(flag_carry, (value & 1) != 0); break :blk (value >> 1) | (value << 15); }, 2 => blk: { self.setFlag(flag_carry, (value & 0x8000) != 0); break :blk (value << 1) | @intFromBool(carry); }, 3 => blk: { self.setFlag(flag_carry, (value & 1) != 0); break :blk (value >> 1) | (@as(u16, @intFromBool(carry)) << 15); }, 4, 6 => blk: { self.setFlag(flag_carry, (value & 0x8000) != 0); break :blk value << 1; }, 5 => blk: { self.setFlag(flag_carry, (value & 1) != 0); break :blk value >> 1; }, 7 => blk: { self.setFlag(flag_carry, (value & 1) != 0); break :blk @bitCast(@as(i16, @bitCast(value)) >> 1); } }; }

    fn unaryGroup(self: *Cpu, byte: bool) ExecuteError!void {
        const modrm = try self.fetch8(); const operation: u3 = @truncate(modrm >> 3); const operand = try self.decodeOperand(modrm);
        if (byte) { const value = try self.read8(operand); switch (operation) { 0, 1 => self.logicalFlags8(value & try self.fetch8()), 2 => try self.write8(operand, ~value), 3 => try self.write8(operand, self.sub8(0, value, false)), 4 => { const product = @as(u16, self.getReg8(0)) * value; self.registers.ax = product; self.setFlag(flag_carry, product > 0xFF); self.setFlag(flag_overflow, product > 0xFF); }, 5 => { const product = @as(i16, @as(i8, @bitCast(self.getReg8(0)))) * @as(i16, @as(i8, @bitCast(value))); self.registers.ax = @bitCast(product); const fits = product >= -128 and product <= 127; self.setFlag(flag_carry, !fits); self.setFlag(flag_overflow, !fits); }, 6 => { if (value == 0) return error.DivideError; const dividend = self.registers.ax; const quotient = dividend / value; if (quotient > 0xFF) return error.DivideError; self.setReg8(0, @truncate(quotient)); self.setReg8(4, @truncate(dividend % value)); }, 7 => { const divisor: i8 = @bitCast(value); if (divisor == 0) return error.DivideError; const dividend: i16 = @bitCast(self.registers.ax); const quotient = @divTrunc(dividend, divisor); if (quotient < -128 or quotient > 127) return error.DivideError; self.setReg8(0, @bitCast(@as(i8, @intCast(quotient)))); self.setReg8(4, @bitCast(@as(i8, @intCast(@rem(dividend, divisor))))); } } }
        else { const value = try self.read16(operand); switch (operation) { 0, 1 => self.logicalFlags16(value & try self.fetch16()), 2 => try self.write16(operand, ~value), 3 => try self.write16(operand, self.sub16(0, value, false)), 4 => { const product = @as(u32, self.registers.ax) * value; self.registers.ax = @truncate(product); self.registers.dx = @truncate(product >> 16); self.setFlag(flag_carry, self.registers.dx != 0); self.setFlag(flag_overflow, self.registers.dx != 0); }, 5 => { const product = @as(i32, @as(i16, @bitCast(self.registers.ax))) * @as(i32, @as(i16, @bitCast(value))); self.registers.ax = @bitCast(@as(i16, @truncate(product))); self.registers.dx = @bitCast(@as(i16, @truncate(product >> 16))); const fits = product >= -32768 and product <= 32767; self.setFlag(flag_carry, !fits); self.setFlag(flag_overflow, !fits); }, 6 => { if (value == 0) return error.DivideError; const dividend = (@as(u32, self.registers.dx) << 16) | self.registers.ax; const quotient = dividend / value; if (quotient > 0xFFFF) return error.DivideError; self.registers.ax = @truncate(quotient); self.registers.dx = @truncate(dividend % value); }, 7 => { const divisor: i16 = @bitCast(value); if (divisor == 0) return error.DivideError; const dividend: i32 = @bitCast((@as(u32, self.registers.dx) << 16) | self.registers.ax); const quotient = @divTrunc(dividend, divisor); if (quotient < -32768 or quotient > 32767) return error.DivideError; self.registers.ax = @bitCast(@as(i16, @intCast(quotient))); self.registers.dx = @bitCast(@as(i16, @intCast(@rem(dividend, divisor)))); } } }
    }

    fn controlGroup(self: *Cpu, byte: bool) ExecuteError!void {
        const modrm = try self.fetch8(); const operation: u3 = @truncate(modrm >> 3); const operand = try self.decodeOperand(modrm);
        if (byte) { const value = try self.read8(operand); const result = switch (operation) { 0 => self.add8(value, 1, false), 1 => self.sub8(value, 1, false), else => return error.InvalidInstruction }; try self.write8(operand, result); return; }
        switch (operation) {
            0 => try self.write16(operand, self.add16(try self.read16(operand), 1, false)),
            1 => try self.write16(operand, self.sub16(try self.read16(operand), 1, false)),
            2 => { const target = try self.read16(operand); try self.push16(self.registers.ip); self.registers.ip = target; },
            3 => { const address = switch (operand) { .memory => |value| value, .register => return error.InvalidInstruction }; const ip = self.machine.readWord(address) catch return error.OutOfMemory; const cs = self.machine.readWord(.{ .segment = address.segment, .offset = address.offset +% 2 }) catch return error.OutOfMemory; try self.push16(self.registers.cs); try self.push16(self.registers.ip); self.registers.cs = cs; self.registers.ip = ip; },
            4 => self.registers.ip = try self.read16(operand),
            5 => { const address = switch (operand) { .memory => |value| value, .register => return error.InvalidInstruction }; self.registers.ip = self.machine.readWord(address) catch return error.OutOfMemory; self.registers.cs = self.machine.readWord(.{ .segment = address.segment, .offset = address.offset +% 2 }) catch return error.OutOfMemory; },
            6 => try self.push16(try self.read16(operand)),
            else => return error.InvalidInstruction,
        }
    }

    fn condition(self: *const Cpu, code: u4) bool { const of = self.flag(flag_overflow); const cf = self.flag(flag_carry); const zf = self.flag(flag_zero); const sf = self.flag(flag_sign); const pf = self.flag(flag_parity); return switch (code) { 0 => of, 1 => !of, 2 => cf, 3 => !cf, 4 => zf, 5 => !zf, 6 => cf or zf, 7 => !cf and !zf, 8 => sf, 9 => !sf, 10 => pf, 11 => !pf, 12 => sf != of, 13 => sf == of, 14 => zf or sf != of, 15 => !zf and sf == of }; }

    fn stringInstruction(self: *Cpu, opcode: u8) ExecuteError!void {
        const word = (opcode & 1) != 0; var iterations: u32 = if (self.repeat == .none) 1 else self.registers.cx;
        while (iterations != 0) : (iterations -= 1) {
            const source = Address{ .segment = self.dataSegment(), .offset = self.registers.si }; const destination = Address{ .segment = self.registers.es, .offset = self.registers.di };
            switch (opcode) {
                0xA4 => self.machine.writeByte(destination, self.machine.readByte(source) catch return error.OutOfMemory) catch return error.OutOfMemory,
                0xA5 => self.machine.writeWord(destination, self.machine.readWord(source) catch return error.OutOfMemory) catch return error.OutOfMemory,
                0xA6 => _ = self.sub8(self.machine.readByte(source) catch return error.OutOfMemory, self.machine.readByte(destination) catch return error.OutOfMemory, false),
                0xA7 => _ = self.sub16(self.machine.readWord(source) catch return error.OutOfMemory, self.machine.readWord(destination) catch return error.OutOfMemory, false),
                0xAA => self.machine.writeByte(destination, self.getReg8(0)) catch return error.OutOfMemory,
                0xAB => self.machine.writeWord(destination, self.registers.ax) catch return error.OutOfMemory,
                0xAC => self.setReg8(0, self.machine.readByte(source) catch return error.OutOfMemory),
                0xAD => self.registers.ax = self.machine.readWord(source) catch return error.OutOfMemory,
                0xAE => _ = self.sub8(self.getReg8(0), self.machine.readByte(destination) catch return error.OutOfMemory, false),
                0xAF => _ = self.sub16(self.registers.ax, self.machine.readWord(destination) catch return error.OutOfMemory, false),
                else => unreachable,
            }
            const amount: u16 = if (word) 2 else 1; const delta: u16 = if (self.flag(flag_direction)) 0 -% amount else amount;
            if (opcode <= 0xA7 or opcode == 0xAC or opcode == 0xAD) self.registers.si +%= delta;
            if ((opcode >= 0xA4 and opcode <= 0xA7) or opcode >= 0xAA) self.registers.di +%= delta;
            if (self.repeat != .none) { self.registers.cx -%= 1; if ((opcode == 0xA6 or opcode == 0xA7 or opcode == 0xAE or opcode == 0xAF) and ((self.repeat == .while_equal and !self.flag(flag_zero)) or (self.repeat == .while_not_equal and self.flag(flag_zero)))) break; }
        }
    }

    fn interrupt(self: *Cpu, number: u8) ExecuteError!void { if (self.options.interrupt(self.options.context, number, &self.registers, self.machine) == .unavailable) return error.InterruptUnavailable; }
    fn readPortWord(self: *Cpu, port: u16) ExecuteError!u16 { const low = self.machine.readPort(port) catch return error.PortUnavailable; const high = self.machine.readPort(port +% 1) catch return error.PortUnavailable; return @as(u16, low) | (@as(u16, high) << 8); }
    fn writePortWord(self: *Cpu, port: u16, value: u16) ExecuteError!void { self.machine.writePort(port, @truncate(value)) catch return error.PortUnavailable; self.machine.writePort(port +% 1, @truncate(value >> 8)) catch return error.PortUnavailable; }
    fn pushAll(self: *Cpu) ExecuteError!void { const original_sp = self.registers.sp; try self.push16(self.registers.ax); try self.push16(self.registers.cx); try self.push16(self.registers.dx); try self.push16(self.registers.bx); try self.push16(original_sp); try self.push16(self.registers.bp); try self.push16(self.registers.si); try self.push16(self.registers.di); }
    fn popAll(self: *Cpu) ExecuteError!void { self.registers.di = try self.pop16(); self.registers.si = try self.pop16(); self.registers.bp = try self.pop16(); _ = try self.pop16(); self.registers.bx = try self.pop16(); self.registers.dx = try self.pop16(); self.registers.cx = try self.pop16(); self.registers.ax = try self.pop16(); }
};

fn neverCancel(_: ?*anyopaque) bool { return false; }
fn unavailableInterrupt(_: ?*anyopaque, _: u8, _: *Registers, _: *Machine) InterruptResult { return .unavailable; }

test "20-bit physical addresses wrap at exactly one R4OS megabyte" {
    var machine = Machine.init(std.testing.allocator);
    defer machine.deinit();
    try machine.writeByte(.{ .segment = 0xFFFF, .offset = 0x0010 }, 0xA5);
    try std.testing.expectEqual(@as(u8, 0xA5), try machine.readByte(.{ .segment = 0, .offset = 0 }));
    var around = [_]u8{ 1, 2, 3, 4 };
    try machine.writeRange(.{ .segment = 0xFFFF, .offset = 0x000E }, &around);
    var result = [_]u8{0} ** 4;
    try machine.readRange(.{ .segment = 0xFFFF, .offset = 0x000E }, &result);
    try std.testing.expectEqualSlices(u8, &around, &result);
}

test "virtual ports are explicit isolated and generation tracked" {
    var first = Machine.init(std.testing.allocator);
    defer first.deinit();
    var second = Machine.init(std.testing.allocator);
    defer second.deinit();
    try std.testing.expectError(error.Unavailable, first.readPort(0x61));
    try first.definePort(0x61, 0);
    try first.writePort(0x61, 3);
    try std.testing.expectEqual(@as(u8, 3), try first.readPort(0x61));
    try std.testing.expectEqual(@as(u64, 1), first.port_generation);
    try std.testing.expectError(error.Unavailable, second.readPort(0x61));
}

test "bounded 16-bit execution supports the canonical CALL ABSOLUTE routine" {
    var machine = Machine.init(std.testing.allocator);
    defer machine.deinit();
    const code = [_]u8{ 0x55, 0x8B, 0xEC, 0xCD, 0x11, 0x8B, 0x5E, 0x06, 0x89, 0x07, 0x5D, 0xCA, 0x02, 0x00 };
    try machine.writeRange(.{ .segment = 0x3000, .offset = 0x0100 }, &code);
    try machine.writeWord(.{ .segment = default_data_segment, .offset = 0x0200 }, 0);
    var registers = Registers{ .cs = 0x3000, .ip = 0x0100 };
    registers.sp -%= 2;
    try machine.writeWord(.{ .segment = registers.ss, .offset = registers.sp }, 0x0200);
    registers.sp -%= 2;
    try machine.writeWord(.{ .segment = registers.ss, .offset = registers.sp }, 0xFFFF);
    registers.sp -%= 2;
    try machine.writeWord(.{ .segment = registers.ss, .offset = registers.sp }, 0xFFFF);
    const Handler = struct { fn run(_: ?*anyopaque, number: u8, output: *Registers, _: *Machine) InterruptResult { if (number != 0x11) return .unavailable; output.ax = 0x1234; return .handled; } };
    const result = try machine.execute(registers, .{ .stop_address = .{ .segment = 0xFFFF, .offset = 0xFFFF }, .interrupt = Handler.run });
    try std.testing.expectEqual(@as(u16, 0x1234), try machine.readWord(.{ .segment = default_data_segment, .offset = 0x0200 }));
    try std.testing.expect(result.instructions < 32);
}

test "guest execution is budgeted cancellable and cannot reach host ports" {
    var machine = Machine.init(std.testing.allocator);
    defer machine.deinit();
    try machine.writeRange(.{ .segment = 0x1000, .offset = 0 }, &[_]u8{ 0xEB, 0xFE });
    try std.testing.expectError(error.InstructionBudget, machine.execute(.{ .cs = 0x1000 }, .{ .instruction_budget = 8 }));
    try machine.writeRange(.{ .segment = 0x1000, .offset = 0 }, &[_]u8{ 0xE4, 0x61, 0xF4 });
    try std.testing.expectError(error.PortUnavailable, machine.execute(.{ .cs = 0x1000 }, .{}));
}
