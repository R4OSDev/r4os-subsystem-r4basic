const std = @import("std");

pub const contract_version = "2.0.0";
pub const maximum_source_bytes: usize = 256 * 1024;
pub const maximum_identifier_bytes: usize = 40;
pub const maximum_expression_depth: usize = 128;
pub const recommended_token_capacity: usize = 24 * 1024;
pub const recommended_diagnostic_capacity: usize = 128;

pub const Span = struct {
    start: u32,
    end: u32,
    line: u32,
    column: u32,

    pub fn bytes(self: Span, source: []const u8) []const u8 {
        const first: usize = @min(source.len, @as(usize, self.start));
        const last: usize = @min(source.len, @as(usize, self.end));
        return source[first..@max(first, last)];
    }
};

pub const DiagnosticCode = enum {
    source_too_large,
    token_capacity_exceeded,
    diagnostic_capacity_exceeded,
    invalid_byte,
    invalid_identifier,
    invalid_number,
    unterminated_string,
    unsupported_metacommand,
    expected_statement,
    expected_identifier,
    expected_expression,
    expected_separator,
    expected_token,
    wrong_argument_count,
    unsupported_statement,
    unexpected_token,
    unmatched_block,
    unclosed_block,
    nesting_too_deep,
    expression_too_deep,
};

pub const Diagnostic = struct {
    code: DiagnosticCode,
    span: Span,
    file_name: []const u8 = "",

    pub fn message(self: Diagnostic) []const u8 {
        return switch (self.code) {
            .source_too_large => "source exceeds the R4BASIC v2 lexical limit",
            .token_capacity_exceeded => "token buffer is too small",
            .diagnostic_capacity_exceeded => "diagnostic buffer is too small",
            .invalid_byte => "invalid byte in BASIC source",
            .invalid_identifier => "BASIC identifier exceeds the current lexical length limit",
            .invalid_number => "malformed numeric literal",
            .unterminated_string => "unterminated string literal",
            .unsupported_metacommand => "unsupported BASIC metacommand",
            .expected_statement => "expected BASIC statement",
            .expected_identifier => "expected BASIC identifier",
            .expected_expression => "expected BASIC expression",
            .expected_separator => "expected statement separator",
            .expected_token => "required token is missing",
            .wrong_argument_count => "function has the wrong number of arguments",
            .unsupported_statement => "statement is outside the active R4BASIC contract",
            .unexpected_token => "unexpected token",
            .unmatched_block => "block terminator does not match the active block",
            .unclosed_block => "block is not closed before end of source",
            .nesting_too_deep => "BASIC block nesting is too deep",
            .expression_too_deep => "BASIC expression nesting is too deep",
        };
    }
};

pub const Keyword = enum(u8) {
    none,
    abs,
    and_,
    any,
    append,
    as,
    atn,
    beep,
    byref,
    byval,
    call,
    case,
    chr_string,
    cint,
    circle,
    close,
    cls,
    color,
    const_,
    cos,
    data,
    declare,
    def,
    defint,
    dim,
    do_,
    double,
    dynamic,
    else_,
    elseif,
    end,
    eof,
    error_,
    exit,
    fn_,
    for_,
    function,
    get,
    gosub,
    goto_,
    if_,
    inkey_string,
    input,
    instr,
    int,
    integer,
    left_string,
    len,
    let,
    line,
    locate,
    long,
    loop,
    ltrim_string,
    mid_string,
    mod,
    next,
    not,
    on,
    open,
    or_,
    output,
    paint,
    palette,
    peek,
    play,
    point,
    poke,
    print,
    pset,
    put,
    randomize,
    read,
    redim,
    rem,
    restore,
    resume_,
    return_,
    rnd,
    screen,
    seg,
    select,
    shared,
    sin,
    single,
    sleep,
    space_string,
    static,
    step,
    str_string,
    string,
    sub,
    tab,
    then,
    timer,
    to,
    type,
    ucase_string,
    until,
    val,
    view,
    wend,
    while_,
    width,
    xor,
    unsupported,
};

pub const TokenKind = enum(u8) {
    eof,
    newline,
    colon,
    comma,
    semicolon,
    left_paren,
    right_paren,
    dot,
    hash,
    plus,
    minus,
    multiply,
    divide,
    integer_divide,
    power,
    equal,
    less,
    greater,
    less_equal,
    greater_equal,
    not_equal,
    number,
    string,
    identifier,
    keyword,
    metacommand,
};

pub const Token = struct {
    kind: TokenKind,
    keyword: Keyword = .none,
    span: Span,

    pub fn text(self: Token, source: []const u8) []const u8 {
        return self.span.bytes(source);
    }
};

pub const ProgramSummary = struct {
    statements: u32 = 0,
    expressions: u32 = 0,
    labels: u32 = 0,
    procedures: u32 = 0,
    functions: u32 = 0,
    user_types: u32 = 0,
    metacommands: u32 = 0,
    maximum_block_depth: u16 = 0,
    maximum_expression_depth: u16 = 0,
};

pub const Result = struct {
    token_count: usize,
    diagnostic_count: usize,
    diagnostics_truncated: bool,
    summary: ProgramSummary,

    pub fn ok(self: Result) bool {
        return self.diagnostic_count == 0 and !self.diagnostics_truncated;
    }
};

pub const LexResult = struct {
    token_count: usize,
    diagnostic_count: usize,
    diagnostics_truncated: bool,
    cancelled: bool = false,
    keyword_lookups: u64 = 0,
    keyword_probes: u64 = 0,
    keyword_max_probe: u16 = 0,
    progress_updates: u32 = 0,

    pub fn ok(self: LexResult) bool {
        return self.diagnostic_count == 0 and !self.diagnostics_truncated;
    }
};

pub const TokenizeObserver = struct {
    context: *anyopaque,
    update_fn: *const fn (context: *anyopaque, completed: usize, total: usize) bool,

    fn update(self: TokenizeObserver, completed: usize, total: usize) bool {
        return self.update_fn(self.context, completed, total);
    }
};

const DiagnosticSink = struct {
    storage: []Diagnostic,
    file_name: []const u8,
    count: usize = 0,
    truncated: bool = false,

    fn add(self: *DiagnosticSink, code: DiagnosticCode, span: Span) void {
        if (self.count >= self.storage.len) {
            self.truncated = true;
            return;
        }
        self.storage[self.count] = .{ .code = code, .span = span, .file_name = self.file_name };
        self.count += 1;
    }
};

pub fn tokenize(source: []const u8, tokens: []Token, diagnostics: []Diagnostic) LexResult {
    return tokenizeNamed("", source, tokens, diagnostics);
}

pub fn tokenizeNamed(file_name: []const u8, source: []const u8, tokens: []Token, diagnostics: []Diagnostic) LexResult {
    return tokenizeNamedObserved(file_name, source, tokens, diagnostics, null);
}

pub fn tokenizeNamedObserved(
    file_name: []const u8,
    source: []const u8,
    tokens: []Token,
    diagnostics: []Diagnostic,
    observer: ?TokenizeObserver,
) LexResult {
    var sink = DiagnosticSink{ .storage = diagnostics, .file_name = file_name };
    if (source.len > maximum_source_bytes) {
        sink.add(.source_too_large, .{ .start = 0, .end = 0, .line = 1, .column = 1 });
        return .{
            .token_count = 0,
            .diagnostic_count = sink.count,
            .diagnostics_truncated = sink.truncated,
        };
    }

    var lexer = Lexer{
        .source = source,
        .tokens = tokens,
        .diagnostics = &sink,
        .observer = observer,
    };
    lexer.run();
    return .{
        .token_count = lexer.count,
        .diagnostic_count = sink.count,
        .diagnostics_truncated = sink.truncated,
        .cancelled = lexer.cancelled,
        .keyword_lookups = lexer.keyword_stats.lookups,
        .keyword_probes = lexer.keyword_stats.probes,
        .keyword_max_probe = lexer.keyword_stats.maximum_probe,
        .progress_updates = lexer.progress_updates,
    };
}

pub fn countTokens(source: []const u8) usize {
    if (source.len > maximum_source_bytes) return 1;
    var no_diagnostics: [0]Diagnostic = .{};
    var sink = DiagnosticSink{ .storage = no_diagnostics[0..], .file_name = "" };
    var lexer = Lexer{
        .source = source,
        .tokens = &.{},
        .diagnostics = &sink,
        .count_only = true,
    };
    lexer.run();
    return @max(@as(usize, 1), lexer.count);
}

const KeywordLookupStats = struct {
    lookups: u64 = 0,
    probes: u64 = 0,
    maximum_probe: u16 = 0,

    fn record(self: *KeywordLookupStats, probe: usize) void {
        self.probes +%= 1;
        self.maximum_probe = @max(self.maximum_probe, @as(u16, @intCast(probe)));
    }
};

const Lexer = struct {
    source: []const u8,
    tokens: []Token,
    diagnostics: *DiagnosticSink,
    index: usize = 0,
    line: u32 = 1,
    column: u32 = 1,
    count: usize = 0,
    statement_start: bool = true,
    capacity_reported: bool = false,
    observer: ?TokenizeObserver = null,
    next_progress: usize = 0,
    progress_updates: u32 = 0,
    cancelled: bool = false,
    count_only: bool = false,
    keyword_stats: KeywordLookupStats = .{},

    fn run(self: *Lexer) void {
        if (!self.count_only and self.tokens.len == 0) {
            self.diagnostics.add(.token_capacity_exceeded, self.pointSpan());
            return;
        }

        if (!self.reportProgress()) return;
        while (self.index < self.source.len) {
            if (self.index >= self.next_progress and !self.reportProgress()) return;
            const byte = self.source[self.index];
            switch (byte) {
                ' ', '\t', 0x0B, 0x0C => self.advanceByte(),
                '\r', '\n' => self.lexNewline(),
                '\'' => self.lexApostropheComment(),
                ':' => self.single(.colon, true),
                ',' => self.single(.comma, false),
                ';' => self.single(.semicolon, false),
                '(' => self.single(.left_paren, false),
                ')' => self.single(.right_paren, false),
                '.' => if (self.peekDigit(1)) self.lexNumber() else self.single(.dot, false),
                '#' => self.single(.hash, false),
                '+' => self.single(.plus, false),
                '-' => self.single(.minus, false),
                '*' => self.single(.multiply, false),
                '/' => self.single(.divide, false),
                '\\' => self.single(.integer_divide, false),
                '^' => self.single(.power, false),
                '=' => self.single(.equal, false),
                '<', '>' => self.lexComparison(),
                '"' => self.lexString(),
                '0'...'9' => self.lexNumber(),
                'A'...'Z', 'a'...'z' => self.lexWord(),
                else => {
                    const span = self.pointSpan();
                    self.diagnostics.add(.invalid_byte, span);
                    self.advanceByte();
                    self.statement_start = false;
                },
            }
        }
        self.emit(.eof, .none, .{
            .start = @intCast(self.index),
            .end = @intCast(self.index),
            .line = self.line,
            .column = self.column,
        });
        if (!self.count_only and self.count == self.tokens.len and self.tokens[self.count - 1].kind != .eof) {
            self.tokens[self.count - 1] = .{ .kind = .eof, .span = self.pointSpan() };
        }
        _ = self.reportProgress();
    }

    fn reportProgress(self: *Lexer) bool {
        const observer = self.observer orelse return true;
        self.next_progress = @min(self.source.len, self.index + 2048);
        self.progress_updates +%= 1;
        if (observer.update(self.index, self.source.len)) return true;
        self.cancelled = true;
        return false;
    }

    fn lexNewline(self: *Lexer) void {
        const start = self.index;
        const line = self.line;
        const column = self.column;
        if (self.source[self.index] == '\r' and self.index + 1 < self.source.len and self.source[self.index + 1] == '\n') {
            self.index += 2;
        } else {
            self.index += 1;
        }
        self.line += 1;
        self.column = 1;
        self.statement_start = true;
        self.emit(.newline, .none, self.makeSpan(start, self.index, line, column));
    }

    fn lexApostropheComment(self: *Lexer) void {
        const start = self.index;
        const line = self.line;
        const column = self.column;
        self.advanceByte();
        if (self.index < self.source.len and self.source[self.index] == '$') {
            self.advanceByte();
            const name_start = self.index;
            while (self.index < self.source.len and std.ascii.isAlphabetic(self.source[self.index])) self.advanceByte();
            const keyword = metacommandKeyword(self.source[name_start..self.index]);
            const span = self.makeSpan(start, self.index, line, column);
            if (keyword == .none) self.diagnostics.add(.unsupported_metacommand, span);
            self.emit(.metacommand, keyword, span);
        }
        self.skipToLineEnd();
    }

    fn lexWord(self: *Lexer) void {
        const start = self.index;
        const line = self.line;
        const column = self.column;
        while (self.index < self.source.len and isIdentifierBody(self.source[self.index])) self.advanceByte();
        if (self.index < self.source.len and isTypeSuffix(self.source[self.index])) self.advanceByte();
        const text = self.source[start..self.index];
        if (text.len > maximum_identifier_bytes) {
            self.diagnostics.add(.invalid_identifier, self.makeSpan(start, self.index, line, column));
        }

        if (self.statement_start and std.ascii.eqlIgnoreCase(text, "REM")) {
            var probe = self.index;
            while (probe < self.source.len and (self.source[probe] == ' ' or self.source[probe] == '\t')) probe += 1;
            if (probe < self.source.len and self.source[probe] == '$') {
                self.index = probe + 1;
                self.column += @intCast(self.index - probe);
                const name_start = self.index;
                while (self.index < self.source.len and std.ascii.isAlphabetic(self.source[self.index])) self.advanceByte();
                const keyword = metacommandKeyword(self.source[name_start..self.index]);
                const span = self.makeSpan(start, self.index, line, column);
                if (keyword == .none) self.diagnostics.add(.unsupported_metacommand, span);
                self.emit(.metacommand, keyword, span);
            }
            self.skipToLineEnd();
            return;
        }

        const keyword = if (self.count_only) Keyword.none else keywordFor(text, &self.keyword_stats);
        self.emit(if (keyword == .none) .identifier else .keyword, keyword, self.makeSpan(start, self.index, line, column));
        self.statement_start = false;
    }

    fn lexNumber(self: *Lexer) void {
        const start = self.index;
        const line = self.line;
        const column = self.column;
        var saw_dot = false;
        if (self.source[self.index] == '.') {
            saw_dot = true;
            self.advanceByte();
        }
        while (self.index < self.source.len and std.ascii.isDigit(self.source[self.index])) self.advanceByte();
        if (!saw_dot and self.index < self.source.len and self.source[self.index] == '.') {
            saw_dot = true;
            self.advanceByte();
            while (self.index < self.source.len and std.ascii.isDigit(self.source[self.index])) self.advanceByte();
        }
        if (self.index < self.source.len and (self.source[self.index] == 'E' or self.source[self.index] == 'e' or self.source[self.index] == 'D' or self.source[self.index] == 'd')) {
            self.advanceByte();
            if (self.index < self.source.len and (self.source[self.index] == '+' or self.source[self.index] == '-')) self.advanceByte();
            const exponent_start = self.index;
            while (self.index < self.source.len and std.ascii.isDigit(self.source[self.index])) self.advanceByte();
            if (self.index == exponent_start) self.diagnostics.add(.invalid_number, self.makeSpan(start, self.index, line, column));
        }
        if (self.index < self.source.len and isNumericTypeSuffix(self.source[self.index])) self.advanceByte();
        self.emit(.number, .none, self.makeSpan(start, self.index, line, column));
        self.statement_start = false;
    }

    fn lexString(self: *Lexer) void {
        const start = self.index;
        const line = self.line;
        const column = self.column;
        self.advanceByte();
        var terminated = false;
        while (self.index < self.source.len) {
            const byte = self.source[self.index];
            if (byte == '\r' or byte == '\n') break;
            if (byte == '"') {
                self.advanceByte();
                terminated = true;
                break;
            }
            if (byte == 0) self.diagnostics.add(.invalid_byte, self.pointSpan());
            self.advanceByte();
        }
        const span = self.makeSpan(start, self.index, line, column);
        if (!terminated) self.diagnostics.add(.unterminated_string, span);
        self.emit(.string, .none, span);
        self.statement_start = false;
    }

    fn lexComparison(self: *Lexer) void {
        const start = self.index;
        const line = self.line;
        const column = self.column;
        const first = self.source[self.index];
        self.advanceByte();
        var kind: TokenKind = if (first == '<') .less else .greater;
        if (self.index < self.source.len) {
            const second = self.source[self.index];
            if (first == '<' and second == '=') {
                kind = .less_equal;
                self.advanceByte();
            } else if (first == '>' and second == '=') {
                kind = .greater_equal;
                self.advanceByte();
            } else if ((first == '<' and second == '>') or (first == '>' and second == '<')) {
                kind = .not_equal;
                self.advanceByte();
            }
        }
        self.emit(kind, .none, self.makeSpan(start, self.index, line, column));
        self.statement_start = false;
    }

    fn single(self: *Lexer, kind: TokenKind, starts_statement: bool) void {
        const start = self.index;
        const line = self.line;
        const column = self.column;
        self.advanceByte();
        self.emit(kind, .none, self.makeSpan(start, self.index, line, column));
        self.statement_start = starts_statement;
    }

    fn emit(self: *Lexer, kind: TokenKind, keyword: Keyword, span: Span) void {
        if (self.count_only) {
            self.count += 1;
            return;
        }
        if (self.count >= self.tokens.len) {
            if (!self.capacity_reported) {
                self.diagnostics.add(.token_capacity_exceeded, span);
                self.capacity_reported = true;
            }
            return;
        }
        self.tokens[self.count] = .{ .kind = kind, .keyword = keyword, .span = span };
        self.count += 1;
    }

    fn skipToLineEnd(self: *Lexer) void {
        while (self.index < self.source.len and self.source[self.index] != '\r' and self.source[self.index] != '\n') self.advanceByte();
    }

    fn advanceByte(self: *Lexer) void {
        if (self.index >= self.source.len) return;
        self.index += 1;
        self.column += 1;
    }

    fn peekDigit(self: *const Lexer, distance: usize) bool {
        return self.index + distance < self.source.len and std.ascii.isDigit(self.source[self.index + distance]);
    }

    fn pointSpan(self: *const Lexer) Span {
        return .{
            .start = @intCast(self.index),
            .end = @intCast(@min(self.source.len, self.index + 1)),
            .line = self.line,
            .column = self.column,
        };
    }

    fn makeSpan(_: *const Lexer, start: usize, end: usize, line: u32, column: u32) Span {
        return .{ .start = @intCast(start), .end = @intCast(end), .line = line, .column = column };
    }
};

fn isIdentifierBody(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte);
}

fn isTypeSuffix(byte: u8) bool {
    return byte == '$' or byte == '%' or byte == '&' or byte == '!' or byte == '#';
}

fn isNumericTypeSuffix(byte: u8) bool {
    return byte == '%' or byte == '&' or byte == '!' or byte == '#';
}

fn metacommandKeyword(text: []const u8) Keyword {
    if (std.ascii.eqlIgnoreCase(text, "DYNAMIC")) return .dynamic;
    if (std.ascii.eqlIgnoreCase(text, "STATIC")) return .static;
    return .none;
}

pub const KeywordEntry = struct { text: []const u8, keyword: Keyword };

pub const supported_keyword_entries = [_]KeywordEntry{
    .{ .text = "ABS", .keyword = .abs },
    .{ .text = "AND", .keyword = .and_ },
    .{ .text = "ANY", .keyword = .any },
    .{ .text = "APPEND", .keyword = .append },
    .{ .text = "AS", .keyword = .as },
    .{ .text = "ATN", .keyword = .atn },
    .{ .text = "BEEP", .keyword = .beep },
    .{ .text = "BYREF", .keyword = .byref },
    .{ .text = "BYVAL", .keyword = .byval },
    .{ .text = "CALL", .keyword = .call },
    .{ .text = "CASE", .keyword = .case },
    .{ .text = "CHR$", .keyword = .chr_string },
    .{ .text = "CINT", .keyword = .cint },
    .{ .text = "CIRCLE", .keyword = .circle },
    .{ .text = "CLOSE", .keyword = .close },
    .{ .text = "CLS", .keyword = .cls },
    .{ .text = "COLOR", .keyword = .color },
    .{ .text = "CONST", .keyword = .const_ },
    .{ .text = "COS", .keyword = .cos },
    .{ .text = "DATA", .keyword = .data },
    .{ .text = "DECLARE", .keyword = .declare },
    .{ .text = "DEF", .keyword = .def },
    .{ .text = "DEFINT", .keyword = .defint },
    .{ .text = "DIM", .keyword = .dim },
    .{ .text = "DO", .keyword = .do_ },
    .{ .text = "DOUBLE", .keyword = .double },
    .{ .text = "ELSE", .keyword = .else_ },
    .{ .text = "ELSEIF", .keyword = .elseif },
    .{ .text = "END", .keyword = .end },
    .{ .text = "EOF", .keyword = .eof },
    .{ .text = "ERROR", .keyword = .error_ },
    .{ .text = "EXIT", .keyword = .exit },
    .{ .text = "FN", .keyword = .fn_ },
    .{ .text = "FOR", .keyword = .for_ },
    .{ .text = "FUNCTION", .keyword = .function },
    .{ .text = "GET", .keyword = .get },
    .{ .text = "GOSUB", .keyword = .gosub },
    .{ .text = "GOTO", .keyword = .goto_ },
    .{ .text = "IF", .keyword = .if_ },
    .{ .text = "INKEY$", .keyword = .inkey_string },
    .{ .text = "INPUT", .keyword = .input },
    .{ .text = "INSTR", .keyword = .instr },
    .{ .text = "INT", .keyword = .int },
    .{ .text = "INTEGER", .keyword = .integer },
    .{ .text = "LEFT$", .keyword = .left_string },
    .{ .text = "LEN", .keyword = .len },
    .{ .text = "LET", .keyword = .let },
    .{ .text = "LINE", .keyword = .line },
    .{ .text = "LOCATE", .keyword = .locate },
    .{ .text = "LONG", .keyword = .long },
    .{ .text = "LOOP", .keyword = .loop },
    .{ .text = "LTRIM$", .keyword = .ltrim_string },
    .{ .text = "MID$", .keyword = .mid_string },
    .{ .text = "MOD", .keyword = .mod },
    .{ .text = "NEXT", .keyword = .next },
    .{ .text = "NOT", .keyword = .not },
    .{ .text = "ON", .keyword = .on },
    .{ .text = "OPEN", .keyword = .open },
    .{ .text = "OR", .keyword = .or_ },
    .{ .text = "OUTPUT", .keyword = .output },
    .{ .text = "PAINT", .keyword = .paint },
    .{ .text = "PALETTE", .keyword = .palette },
    .{ .text = "PEEK", .keyword = .peek },
    .{ .text = "PLAY", .keyword = .play },
    .{ .text = "POINT", .keyword = .point },
    .{ .text = "POKE", .keyword = .poke },
    .{ .text = "PRINT", .keyword = .print },
    .{ .text = "PSET", .keyword = .pset },
    .{ .text = "PUT", .keyword = .put },
    .{ .text = "RANDOMIZE", .keyword = .randomize },
    .{ .text = "READ", .keyword = .read },
    .{ .text = "REDIM", .keyword = .redim },
    .{ .text = "REM", .keyword = .rem },
    .{ .text = "RESTORE", .keyword = .restore },
    .{ .text = "RESUME", .keyword = .resume_ },
    .{ .text = "RETURN", .keyword = .return_ },
    .{ .text = "RND", .keyword = .rnd },
    .{ .text = "SCREEN", .keyword = .screen },
    .{ .text = "SEG", .keyword = .seg },
    .{ .text = "SELECT", .keyword = .select },
    .{ .text = "SHARED", .keyword = .shared },
    .{ .text = "SIN", .keyword = .sin },
    .{ .text = "SINGLE", .keyword = .single },
    .{ .text = "SLEEP", .keyword = .sleep },
    .{ .text = "SPACE$", .keyword = .space_string },
    .{ .text = "STATIC", .keyword = .static },
    .{ .text = "STEP", .keyword = .step },
    .{ .text = "STR$", .keyword = .str_string },
    .{ .text = "STRING", .keyword = .string },
    .{ .text = "SUB", .keyword = .sub },
    .{ .text = "TAB", .keyword = .tab },
    .{ .text = "THEN", .keyword = .then },
    .{ .text = "TIMER", .keyword = .timer },
    .{ .text = "TO", .keyword = .to },
    .{ .text = "TYPE", .keyword = .type },
    .{ .text = "UCASE$", .keyword = .ucase_string },
    .{ .text = "UNTIL", .keyword = .until },
    .{ .text = "VAL", .keyword = .val },
    .{ .text = "VIEW", .keyword = .view },
    .{ .text = "WEND", .keyword = .wend },
    .{ .text = "WHILE", .keyword = .while_ },
    .{ .text = "WIDTH", .keyword = .width },
    .{ .text = "XOR", .keyword = .xor },
};

pub const unsupported_keyword_words = [_][]const u8{
    "ASC",     "BASE",   "BLOAD",    "BSAVE",  "CDBL",    "CHAIN",    "CHDIR",
    "CHDRIVE", "CLNG",   "COMMAND$", "COMMON", "CSNG",    "CVD",      "CVI",
    "CVL",     "CVS",    "DATE$",    "DRAW",   "ENVIRON", "ENVIRON$", "EQV",
    "ERASE",   "ERL",    "ERR",      "EXP",    "FIELD",   "FILES",    "FIX",
    "FRE",     "HEX$",   "IMP",      "INP",    "INPUT$",  "IOCTL",    "IOCTL$",
    "IS",      "KEY",    "KILL",     "LBOUND", "LCASE$",  "LOAD",     "LOC",
    "LOCK",    "LOF",    "LOG",      "LPOS",   "LPRINT",  "MKD$",     "MKDIR",
    "MKI$",    "MKL$",   "MKS$",     "NAME",   "OCT$",    "OPTION",   "OUT",
    "PCOPY",   "POS",    "PRESERVE", "PRESET", "RANDOM",  "RIGHT$",   "RMDIR",
    "RUN",     "SADD",   "SAVE",     "SGN",    "SHELL",   "SOUND",    "SPC",
    "SQR",     "STICK",  "STRIG",    "SWAP",   "SYSTEM",  "TAN",      "TIME$",
    "UBOUND",  "UNLOCK", "USING",    "VARPTR", "VARSEG",  "WAIT",     "WRITE",
};

const KeywordSlot = struct {
    text: []const u8 = "",
    keyword: Keyword = .none,
};

pub const keyword_table_capacity: usize = 512;
const keyword_table = buildKeywordTable();
pub const keyword_lookup_probe_bound: usize = keywordProbeBound(keyword_table);

fn keywordHash(text: []const u8) u64 {
    var hash: u64 = 14_695_981_039_346_656_037;
    for (text) |byte| {
        hash ^= std.ascii.toUpper(byte);
        hash *%= 1_099_511_628_211;
    }
    return hash;
}

fn buildKeywordTable() [keyword_table_capacity]KeywordSlot {
    @setEvalBranchQuota(20_000);
    var table = [_]KeywordSlot{.{}} ** keyword_table_capacity;
    for (supported_keyword_entries) |entry| insertKeyword(&table, entry.text, entry.keyword);
    for (unsupported_keyword_words) |word| insertKeyword(&table, word, .unsupported);
    return table;
}

fn insertKeyword(table: *[keyword_table_capacity]KeywordSlot, text: []const u8, keyword: Keyword) void {
    var index: usize = @intCast(keywordHash(text) & (keyword_table_capacity - 1));
    while (table[index].text.len != 0) index = (index + 1) & (keyword_table_capacity - 1);
    table[index] = .{ .text = text, .keyword = keyword };
}

fn keywordProbeBound(table: [keyword_table_capacity]KeywordSlot) usize {
    @setEvalBranchQuota(20_000);
    var maximum: usize = 1;
    for (0..keyword_table_capacity) |start| {
        var probe: usize = 1;
        var index = start;
        while (table[index].text.len != 0 and probe < keyword_table_capacity) : (probe += 1) {
            index = (index + 1) & (keyword_table_capacity - 1);
        }
        maximum = @max(maximum, probe);
    }
    return maximum;
}

fn keywordFor(text: []const u8, stats: *KeywordLookupStats) Keyword {
    stats.lookups +%= 1;
    var index: usize = @intCast(keywordHash(text) & (keyword_table_capacity - 1));
    var probe: usize = 1;
    while (probe <= keyword_lookup_probe_bound) : (probe += 1) {
        stats.record(probe);
        const slot = keyword_table[index];
        if (slot.text.len == 0) return .none;
        if (std.ascii.eqlIgnoreCase(text, slot.text)) return slot.keyword;
        index = (index + 1) & (keyword_table_capacity - 1);
    }
    return .none;
}
