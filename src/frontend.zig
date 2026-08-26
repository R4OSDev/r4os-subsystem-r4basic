const std = @import("std");

pub const contract_version = "2.9.0";
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
    file_id: u16 = 0,

    pub fn bytes(self: Span, source: []const u8) []const u8 {
        const first: usize = @min(source.len, @as(usize, self.start));
        const last: usize = @min(source.len, @as(usize, self.end));
        return source[first..@max(first, last)];
    }
};

pub const LineOrigin = struct {
    file_id: u16,
    line: u32,
};

pub const DiagnosticCode = enum {
    source_too_large,
    token_capacity_exceeded,
    diagnostic_capacity_exceeded,
    invalid_byte,
    invalid_identifier,
    invalid_number,
    invalid_line_continuation,
    unterminated_string,
    unsupported_metacommand,
    invalid_include,
    include_missing,
    include_cycle,
    include_depth_exceeded,
    include_graph_too_large,
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
            .invalid_line_continuation => "invalid BASIC line continuation",
            .unterminated_string => "unterminated string literal",
            .unsupported_metacommand => "unsupported BASIC metacommand",
            .invalid_include => "invalid $INCLUDE metacommand",
            .include_missing => "$INCLUDE source file was not found",
            .include_cycle => "$INCLUDE graph contains a cycle",
            .include_depth_exceeded => "$INCLUDE graph is too deep",
            .include_graph_too_large => "$INCLUDE graph exceeds the source limit",
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
    access,
    alias,
    all,
    asc,
    and_,
    any,
    append,
    as,
    atn,
    base,
    beep,
    bload,
    binary,
    bsave,
    byref,
    byval,
    call,
    calls,
    case,
    chain,
    chdir,
    cdbl,
    cdecl,
    chr_string,
    cint,
    circle,
    close,
    clng,
    clear,
    cls,
    color,
    com,
    command_string,
    common,
    const_,
    cos,
    csrlin,
    csng,
    cvd,
    cvdmbf,
    cvi,
    cvl,
    cvs,
    cvsmbf,
    data,
    date_string,
    declare,
    def,
    defdbl,
    defint,
    deflng,
    defsng,
    defstr,
    delete,
    dim,
    do_,
    double,
    draw,
    dynamic,
    else_,
    elseif,
    end,
    eqv,
    eof,
    environ,
    environ_string,
    erase,
    err,
    erdev,
    erdev_string,
    erl,
    error_,
    exit,
    exp,
    field,
    fileattr,
    files,
    fn_,
    fix,
    for_,
    function,
    fre,
    freefile,
    get,
    gosub,
    goto_,
    hex_string,
    if_,
    imp,
    inp,
    include,
    inkey_string,
    input,
    input_string,
    instr,
    int,
    integer,
    ioctl,
    ioctl_string,
    is,
    key,
    kill,
    left_string,
    lcase_string,
    lbound,
    len,
    let,
    line,
    list,
    loc,
    locate,
    lock,
    log,
    lof,
    long,
    loop,
    lpos,
    lprint,
    lset,
    ltrim_string,
    mid_string,
    mkdir,
    mkd_string,
    mkdmbf_string,
    mki_string,
    mkl_string,
    mks_string,
    mksmbf_string,
    mod,
    name,
    next,
    not,
    oct_string,
    off,
    on,
    open,
    option,
    or_,
    out,
    output,
    paint,
    palette,
    pcopy,
    peek,
    pen,
    play,
    pmap,
    point,
    pos,
    poke,
    preset,
    preserve,
    print,
    pset,
    put,
    random,
    randomize,
    read,
    redim,
    rem,
    restore,
    reset,
    resume_,
    return_,
    right_string,
    rmdir,
    rnd,
    rset,
    rtrim_string,
    run,
    sadd,
    screen,
    seg,
    select,
    seek,
    setmem,
    shared,
    sgn,
    shell,
    sin,
    single,
    sleep,
    sound,
    space_string,
    spc,
    sqr,
    static,
    step,
    stick,
    stop,
    str_string,
    string,
    string_string,
    strig,
    sub,
    system,
    tab,
    tan,
    then,
    time_string,
    timer,
    to,
    troff,
    tron,
    type,
    ubound,
    ucase_string,
    uevent,
    unlock,
    until,
    using,
    val,
    varptr,
    varptr_string,
    varseg,
    view,
    wait,
    wend,
    while_,
    width,
    window,
    write,
    swap,
    xor,
    unsupported,
};

pub const TokenKind = enum(u8) {
    eof,
    newline,
    colon,
    comma,
    semicolon,
    question,
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
    return tokenizeGraphNamedObserved(file_name, source, &.{}, tokens, diagnostics, observer);
}

pub fn tokenizeGraphNamedObserved(
    file_name: []const u8,
    source: []const u8,
    line_origins: []const LineOrigin,
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
        .line_origins = line_origins,
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
    continuation_forbidden: bool = false,
    line_origins: []const LineOrigin = &.{},
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
                '?' => self.single(.question, false),
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
                '&' => self.lexBasedNumber(),
                '_' => self.lexContinuation(),
                'A'...'Z', 'a'...'z' => self.lexWord(),
                else => {
                    const span = self.pointSpan();
                    self.diagnostics.add(.invalid_byte, span);
                    self.advanceByte();
                    self.statement_start = false;
                },
            }
        }
        self.emit(.eof, .none, self.makeSpan(self.index, self.index, self.line, self.column));
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
        self.continuation_forbidden = false;
        self.emit(.newline, .none, self.makeSpan(start, self.index, line, column));
    }

    fn lexApostropheComment(self: *Lexer) void {
        const start = self.index;
        const line = self.line;
        const column = self.column;
        self.advanceByte();
        while (self.index < self.source.len and (self.source[self.index] == ' ' or self.source[self.index] == '\t')) self.advanceByte();
        if (self.index >= self.source.len or self.source[self.index] != '$') return self.skipToLineEnd();
        self.lexMetacommands(start, line, column);
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
                self.column += @intCast(probe - self.index);
                self.index = probe;
                self.lexMetacommands(start, line, column);
                return;
            }
            self.skipToLineEnd();
            return;
        }

        const keyword = if (self.count_only) Keyword.none else keywordFor(text, &self.keyword_stats);
        if (self.statement_start and std.ascii.eqlIgnoreCase(text, "DATA")) self.continuation_forbidden = true;
        self.emit(if (keyword == .none) .identifier else .keyword, keyword, self.makeSpan(start, self.index, line, column));
        self.statement_start = false;
    }

    fn lexBasedNumber(self: *Lexer) void {
        const start = self.index;
        const line = self.line;
        const column = self.column;
        self.advanceByte();
        var base: u8 = 8;
        if (self.index < self.source.len and (self.source[self.index] == 'H' or self.source[self.index] == 'h')) {
            base = 16;
            self.advanceByte();
        } else if (self.index < self.source.len and (self.source[self.index] == 'O' or self.source[self.index] == 'o')) {
            self.advanceByte();
        }
        var saw_digit = false;
        var invalid = false;
        while (self.index < self.source.len and std.ascii.isAlphanumeric(self.source[self.index])) {
            const byte = std.ascii.toUpper(self.source[self.index]);
            const valid = if (base == 16)
                std.ascii.isDigit(byte) or (byte >= 'A' and byte <= 'F')
            else
                byte >= '0' and byte <= '7';
            invalid = invalid or !valid;
            saw_digit = true;
            self.advanceByte();
        }
        if (self.index < self.source.len and self.source[self.index] == '&') self.advanceByte();
        const span = self.makeSpan(start, self.index, line, column);
        if (!saw_digit or invalid) self.diagnostics.add(.invalid_number, span);
        self.emit(.number, .none, span);
        self.statement_start = false;
    }

    fn lexContinuation(self: *Lexer) void {
        const start = self.index;
        const line = self.line;
        const column = self.column;
        self.advanceByte();
        while (self.index < self.source.len and (self.source[self.index] == ' ' or self.source[self.index] == '\t')) self.advanceByte();
        const span = self.makeSpan(start, self.index, line, column);
        if (self.index >= self.source.len or (self.source[self.index] != '\r' and self.source[self.index] != '\n')) {
            self.diagnostics.add(.invalid_line_continuation, span);
            self.statement_start = false;
            return;
        }
        if (self.continuation_forbidden) {
            self.diagnostics.add(.invalid_line_continuation, span);
            self.lexNewline();
            return;
        }
        if (self.source[self.index] == '\r' and self.index + 1 < self.source.len and self.source[self.index + 1] == '\n') {
            self.index += 2;
        } else {
            self.index += 1;
        }
        self.line += 1;
        self.column = 1;
    }

    fn lexMetacommands(self: *Lexer, comment_start: usize, line: u32, column: u32) void {
        while (self.index < self.source.len) {
            while (self.index < self.source.len and (self.source[self.index] == ' ' or self.source[self.index] == '\t')) self.advanceByte();
            if (self.index >= self.source.len or self.source[self.index] == '\r' or self.source[self.index] == '\n') break;
            if (self.source[self.index] != '$') break;
            const command_start = self.index;
            self.advanceByte();
            const name_start = self.index;
            while (self.index < self.source.len and std.ascii.isAlphabetic(self.source[self.index])) self.advanceByte();
            const keyword = metacommandKeyword(self.source[name_start..self.index]);
            var valid = name_start != self.index;
            if (keyword == .include) {
                while (self.index < self.source.len and (self.source[self.index] == ' ' or self.source[self.index] == '\t')) self.advanceByte();
                if (self.index >= self.source.len or self.source[self.index] != ':') {
                    valid = false;
                } else {
                    self.advanceByte();
                    while (self.index < self.source.len and (self.source[self.index] == ' ' or self.source[self.index] == '\t')) self.advanceByte();
                    if (self.index >= self.source.len or self.source[self.index] != '\'') {
                        valid = false;
                    } else {
                        self.advanceByte();
                        const argument_start = self.index;
                        while (self.index < self.source.len and self.source[self.index] != '\r' and self.source[self.index] != '\n' and self.source[self.index] != '\'') self.advanceByte();
                        valid = valid and self.index != argument_start and self.index < self.source.len and self.source[self.index] == '\'';
                        if (self.index < self.source.len and self.source[self.index] == '\'') self.advanceByte();
                    }
                }
            }
            const span = self.makeSpan(command_start, self.index, line, @intCast(column + command_start - comment_start));
            if (keyword == .none) self.diagnostics.add(.unsupported_metacommand, span);
            if (!valid) self.diagnostics.add(.invalid_include, span);
            self.emit(.metacommand, keyword, span);
        }
        self.skipToLineEnd();
    }

    fn lexNumber(self: *Lexer) void {
        const was_statement_start = self.statement_start;
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
        self.statement_start = was_statement_start;
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
        if (starts_statement) self.continuation_forbidden = false;
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
        return self.makeSpan(self.index, @min(self.source.len, self.index + 1), self.line, self.column);
    }

    fn makeSpan(self: *const Lexer, start: usize, end: usize, line: u32, column: u32) Span {
        const origin = if (line != 0 and line <= self.line_origins.len)
            self.line_origins[line - 1]
        else
            LineOrigin{ .file_id = 0, .line = line };
        return .{
            .start = @intCast(start),
            .end = @intCast(end),
            .line = origin.line,
            .column = column,
            .file_id = origin.file_id,
        };
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
    if (std.ascii.eqlIgnoreCase(text, "INCLUDE")) return .include;
    if (std.ascii.eqlIgnoreCase(text, "DYNAMIC")) return .dynamic;
    if (std.ascii.eqlIgnoreCase(text, "STATIC")) return .static;
    return .none;
}

pub const KeywordEntry = struct { text: []const u8, keyword: Keyword };

pub const supported_keyword_entries = [_]KeywordEntry{
    .{ .text = "ABS", .keyword = .abs },
    .{ .text = "ACCESS", .keyword = .access },
    .{ .text = "ALIAS", .keyword = .alias },
    .{ .text = "ALL", .keyword = .all },
    .{ .text = "ASC", .keyword = .asc },
    .{ .text = "AND", .keyword = .and_ },
    .{ .text = "ANY", .keyword = .any },
    .{ .text = "APPEND", .keyword = .append },
    .{ .text = "AS", .keyword = .as },
    .{ .text = "ATN", .keyword = .atn },
    .{ .text = "BASE", .keyword = .base },
    .{ .text = "BEEP", .keyword = .beep },
    .{ .text = "BLOAD", .keyword = .bload },
    .{ .text = "BINARY", .keyword = .binary },
    .{ .text = "BSAVE", .keyword = .bsave },
    .{ .text = "BYREF", .keyword = .byref },
    .{ .text = "BYVAL", .keyword = .byval },
    .{ .text = "CALL", .keyword = .call },
    .{ .text = "CALLS", .keyword = .calls },
    .{ .text = "CASE", .keyword = .case },
    .{ .text = "CHAIN", .keyword = .chain },
    .{ .text = "CHDIR", .keyword = .chdir },
    .{ .text = "CDBL", .keyword = .cdbl },
    .{ .text = "CDECL", .keyword = .cdecl },
    .{ .text = "CHR$", .keyword = .chr_string },
    .{ .text = "CINT", .keyword = .cint },
    .{ .text = "CIRCLE", .keyword = .circle },
    .{ .text = "CLOSE", .keyword = .close },
    .{ .text = "CLNG", .keyword = .clng },
    .{ .text = "CLEAR", .keyword = .clear },
    .{ .text = "CLS", .keyword = .cls },
    .{ .text = "COLOR", .keyword = .color },
    .{ .text = "COM", .keyword = .com },
    .{ .text = "COMMAND$", .keyword = .command_string },
    .{ .text = "COMMON", .keyword = .common },
    .{ .text = "CONST", .keyword = .const_ },
    .{ .text = "COS", .keyword = .cos },
    .{ .text = "CSRLIN", .keyword = .csrlin },
    .{ .text = "CSNG", .keyword = .csng },
    .{ .text = "CVD", .keyword = .cvd },
    .{ .text = "CVDMBF", .keyword = .cvdmbf },
    .{ .text = "CVI", .keyword = .cvi },
    .{ .text = "CVL", .keyword = .cvl },
    .{ .text = "CVS", .keyword = .cvs },
    .{ .text = "CVSMBF", .keyword = .cvsmbf },
    .{ .text = "DATA", .keyword = .data },
    .{ .text = "DATE$", .keyword = .date_string },
    .{ .text = "DECLARE", .keyword = .declare },
    .{ .text = "DEF", .keyword = .def },
    .{ .text = "DEFDBL", .keyword = .defdbl },
    .{ .text = "DEFINT", .keyword = .defint },
    .{ .text = "DEFLNG", .keyword = .deflng },
    .{ .text = "DEFSNG", .keyword = .defsng },
    .{ .text = "DEFSTR", .keyword = .defstr },
    .{ .text = "DELETE", .keyword = .delete },
    .{ .text = "DIM", .keyword = .dim },
    .{ .text = "DO", .keyword = .do_ },
    .{ .text = "DOUBLE", .keyword = .double },
    .{ .text = "DRAW", .keyword = .draw },
    .{ .text = "ELSE", .keyword = .else_ },
    .{ .text = "ELSEIF", .keyword = .elseif },
    .{ .text = "END", .keyword = .end },
    .{ .text = "EQV", .keyword = .eqv },
    .{ .text = "EOF", .keyword = .eof },
    .{ .text = "ENVIRON", .keyword = .environ },
    .{ .text = "ENVIRON$", .keyword = .environ_string },
    .{ .text = "ERASE", .keyword = .erase },
    .{ .text = "ERR", .keyword = .err },
    .{ .text = "ERDEV", .keyword = .erdev },
    .{ .text = "ERDEV$", .keyword = .erdev_string },
    .{ .text = "ERL", .keyword = .erl },
    .{ .text = "ERROR", .keyword = .error_ },
    .{ .text = "EXIT", .keyword = .exit },
    .{ .text = "EXP", .keyword = .exp },
    .{ .text = "FIELD", .keyword = .field },
    .{ .text = "FILEATTR", .keyword = .fileattr },
    .{ .text = "FILES", .keyword = .files },
    .{ .text = "FN", .keyword = .fn_ },
    .{ .text = "FIX", .keyword = .fix },
    .{ .text = "FOR", .keyword = .for_ },
    .{ .text = "FUNCTION", .keyword = .function },
    .{ .text = "FRE", .keyword = .fre },
    .{ .text = "FREEFILE", .keyword = .freefile },
    .{ .text = "GET", .keyword = .get },
    .{ .text = "GOSUB", .keyword = .gosub },
    .{ .text = "GOTO", .keyword = .goto_ },
    .{ .text = "HEX$", .keyword = .hex_string },
    .{ .text = "IF", .keyword = .if_ },
    .{ .text = "IMP", .keyword = .imp },
    .{ .text = "INP", .keyword = .inp },
    .{ .text = "INKEY$", .keyword = .inkey_string },
    .{ .text = "INPUT", .keyword = .input },
    .{ .text = "INPUT$", .keyword = .input_string },
    .{ .text = "INSTR", .keyword = .instr },
    .{ .text = "INT", .keyword = .int },
    .{ .text = "INTEGER", .keyword = .integer },
    .{ .text = "IOCTL", .keyword = .ioctl },
    .{ .text = "IOCTL$", .keyword = .ioctl_string },
    .{ .text = "IS", .keyword = .is },
    .{ .text = "KEY", .keyword = .key },
    .{ .text = "KILL", .keyword = .kill },
    .{ .text = "LEFT$", .keyword = .left_string },
    .{ .text = "LCASE$", .keyword = .lcase_string },
    .{ .text = "LBOUND", .keyword = .lbound },
    .{ .text = "LEN", .keyword = .len },
    .{ .text = "LET", .keyword = .let },
    .{ .text = "LINE", .keyword = .line },
    .{ .text = "LIST", .keyword = .list },
    .{ .text = "LOC", .keyword = .loc },
    .{ .text = "LOCATE", .keyword = .locate },
    .{ .text = "LOCK", .keyword = .lock },
    .{ .text = "LOG", .keyword = .log },
    .{ .text = "LOF", .keyword = .lof },
    .{ .text = "LONG", .keyword = .long },
    .{ .text = "LOOP", .keyword = .loop },
    .{ .text = "LPOS", .keyword = .lpos },
    .{ .text = "LPRINT", .keyword = .lprint },
    .{ .text = "LSET", .keyword = .lset },
    .{ .text = "LTRIM$", .keyword = .ltrim_string },
    .{ .text = "MID$", .keyword = .mid_string },
    .{ .text = "MKDIR", .keyword = .mkdir },
    .{ .text = "MKD$", .keyword = .mkd_string },
    .{ .text = "MKDMBF$", .keyword = .mkdmbf_string },
    .{ .text = "MKI$", .keyword = .mki_string },
    .{ .text = "MKL$", .keyword = .mkl_string },
    .{ .text = "MKS$", .keyword = .mks_string },
    .{ .text = "MKSMBF$", .keyword = .mksmbf_string },
    .{ .text = "MOD", .keyword = .mod },
    .{ .text = "NAME", .keyword = .name },
    .{ .text = "NEXT", .keyword = .next },
    .{ .text = "NOT", .keyword = .not },
    .{ .text = "OCT$", .keyword = .oct_string },
    .{ .text = "OFF", .keyword = .off },
    .{ .text = "ON", .keyword = .on },
    .{ .text = "OPEN", .keyword = .open },
    .{ .text = "OPTION", .keyword = .option },
    .{ .text = "OR", .keyword = .or_ },
    .{ .text = "OUT", .keyword = .out },
    .{ .text = "OUTPUT", .keyword = .output },
    .{ .text = "PAINT", .keyword = .paint },
    .{ .text = "PALETTE", .keyword = .palette },
    .{ .text = "PCOPY", .keyword = .pcopy },
    .{ .text = "PEEK", .keyword = .peek },
    .{ .text = "PEN", .keyword = .pen },
    .{ .text = "PLAY", .keyword = .play },
    .{ .text = "PMAP", .keyword = .pmap },
    .{ .text = "POINT", .keyword = .point },
    .{ .text = "POS", .keyword = .pos },
    .{ .text = "POKE", .keyword = .poke },
    .{ .text = "PRESET", .keyword = .preset },
    .{ .text = "PRESERVE", .keyword = .preserve },
    .{ .text = "PRINT", .keyword = .print },
    .{ .text = "PSET", .keyword = .pset },
    .{ .text = "PUT", .keyword = .put },
    .{ .text = "RANDOM", .keyword = .random },
    .{ .text = "RANDOMIZE", .keyword = .randomize },
    .{ .text = "READ", .keyword = .read },
    .{ .text = "REDIM", .keyword = .redim },
    .{ .text = "REM", .keyword = .rem },
    .{ .text = "RESTORE", .keyword = .restore },
    .{ .text = "RESET", .keyword = .reset },
    .{ .text = "RESUME", .keyword = .resume_ },
    .{ .text = "RETURN", .keyword = .return_ },
    .{ .text = "RIGHT$", .keyword = .right_string },
    .{ .text = "RMDIR", .keyword = .rmdir },
    .{ .text = "RND", .keyword = .rnd },
    .{ .text = "RSET", .keyword = .rset },
    .{ .text = "RTRIM$", .keyword = .rtrim_string },
    .{ .text = "RUN", .keyword = .run },
    .{ .text = "SADD", .keyword = .sadd },
    .{ .text = "SCREEN", .keyword = .screen },
    .{ .text = "SEG", .keyword = .seg },
    .{ .text = "SELECT", .keyword = .select },
    .{ .text = "SEEK", .keyword = .seek },
    .{ .text = "SETMEM", .keyword = .setmem },
    .{ .text = "SHARED", .keyword = .shared },
    .{ .text = "SGN", .keyword = .sgn },
    .{ .text = "SHELL", .keyword = .shell },
    .{ .text = "SIN", .keyword = .sin },
    .{ .text = "SINGLE", .keyword = .single },
    .{ .text = "SLEEP", .keyword = .sleep },
    .{ .text = "SOUND", .keyword = .sound },
    .{ .text = "SPACE$", .keyword = .space_string },
    .{ .text = "SPC", .keyword = .spc },
    .{ .text = "SQR", .keyword = .sqr },
    .{ .text = "STATIC", .keyword = .static },
    .{ .text = "STEP", .keyword = .step },
    .{ .text = "STICK", .keyword = .stick },
    .{ .text = "STOP", .keyword = .stop },
    .{ .text = "STR$", .keyword = .str_string },
    .{ .text = "STRING", .keyword = .string },
    .{ .text = "STRING$", .keyword = .string_string },
    .{ .text = "STRIG", .keyword = .strig },
    .{ .text = "SUB", .keyword = .sub },
    .{ .text = "SYSTEM", .keyword = .system },
    .{ .text = "TAB", .keyword = .tab },
    .{ .text = "TAN", .keyword = .tan },
    .{ .text = "THEN", .keyword = .then },
    .{ .text = "TIME$", .keyword = .time_string },
    .{ .text = "TIMER", .keyword = .timer },
    .{ .text = "TO", .keyword = .to },
    .{ .text = "TROFF", .keyword = .troff },
    .{ .text = "TRON", .keyword = .tron },
    .{ .text = "TYPE", .keyword = .type },
    .{ .text = "UBOUND", .keyword = .ubound },
    .{ .text = "UCASE$", .keyword = .ucase_string },
    .{ .text = "UEVENT", .keyword = .uevent },
    .{ .text = "UNLOCK", .keyword = .unlock },
    .{ .text = "UNTIL", .keyword = .until },
    .{ .text = "USING", .keyword = .using },
    .{ .text = "VAL", .keyword = .val },
    .{ .text = "VARPTR", .keyword = .varptr },
    .{ .text = "VARPTR$", .keyword = .varptr_string },
    .{ .text = "VARSEG", .keyword = .varseg },
    .{ .text = "VIEW", .keyword = .view },
    .{ .text = "WAIT", .keyword = .wait },
    .{ .text = "WEND", .keyword = .wend },
    .{ .text = "WHILE", .keyword = .while_ },
    .{ .text = "WIDTH", .keyword = .width },
    .{ .text = "WINDOW", .keyword = .window },
    .{ .text = "WRITE", .keyword = .write },
    .{ .text = "SWAP", .keyword = .swap },
    .{ .text = "XOR", .keyword = .xor },
};

pub const unsupported_keyword_words = [_][]const u8{
    "CHDRIVE", "ENDIF", "LOAD",
    "LOCAL",   "SAVE",  "SIGNAL",
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
