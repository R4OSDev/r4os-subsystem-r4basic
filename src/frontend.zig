const std = @import("std");

pub const contract_version = "1.0.0";
pub const maximum_source_bytes: usize = 256 * 1024;
pub const maximum_identifier_bytes: usize = 40;
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
};

pub const Diagnostic = struct {
    code: DiagnosticCode,
    span: Span,
    file_name: []const u8 = "",

    pub fn message(self: Diagnostic) []const u8 {
        return switch (self.code) {
            .source_too_large => "source exceeds the R4BASIC v1 frontend limit",
            .token_capacity_exceeded => "token buffer is too small",
            .diagnostic_capacity_exceeded => "diagnostic buffer is too small",
            .invalid_byte => "invalid byte in BASIC source",
            .invalid_identifier => "BASIC identifier exceeds the v1 length limit",
            .invalid_number => "malformed numeric literal",
            .unterminated_string => "unterminated string literal",
            .unsupported_metacommand => "unsupported BASIC metacommand",
            .expected_statement => "expected BASIC statement",
            .expected_identifier => "expected BASIC identifier",
            .expected_expression => "expected BASIC expression",
            .expected_separator => "expected statement separator",
            .expected_token => "required token is missing",
            .wrong_argument_count => "function has the wrong number of arguments",
            .unsupported_statement => "statement is outside the R4BASIC v1 contract",
            .unexpected_token => "unexpected token",
            .unmatched_block => "block terminator does not match the active block",
            .unclosed_block => "block is not closed before end of source",
            .nesting_too_deep => "BASIC block nesting is too deep",
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

    pub fn ok(self: LexResult) bool {
        return self.diagnostic_count == 0 and !self.diagnostics_truncated;
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

pub fn analyze(source: []const u8, tokens: []Token, diagnostics: []Diagnostic) Result {
    return analyzeNamed("", source, tokens, diagnostics);
}

pub fn analyzeNamed(file_name: []const u8, source: []const u8, tokens: []Token, diagnostics: []Diagnostic) Result {
    const lexed = tokenizeNamed(file_name, source, tokens, diagnostics);
    var sink = DiagnosticSink{
        .storage = diagnostics,
        .file_name = file_name,
        .count = lexed.diagnostic_count,
        .truncated = lexed.diagnostics_truncated,
    };
    var summary: ProgramSummary = .{};
    if (lexed.token_count != 0) {
        var parser = Parser{
            .source = source,
            .tokens = tokens[0..lexed.token_count],
            .diagnostics = &sink,
        };
        parser.run();
        summary = parser.summary;
    }
    return .{
        .token_count = lexed.token_count,
        .diagnostic_count = sink.count,
        .diagnostics_truncated = sink.truncated,
        .summary = summary,
    };
}

pub fn tokenize(source: []const u8, tokens: []Token, diagnostics: []Diagnostic) LexResult {
    return tokenizeNamed("", source, tokens, diagnostics);
}

pub fn tokenizeNamed(file_name: []const u8, source: []const u8, tokens: []Token, diagnostics: []Diagnostic) LexResult {
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
    };
    lexer.run();
    return .{
        .token_count = lexer.count,
        .diagnostic_count = sink.count,
        .diagnostics_truncated = sink.truncated,
    };
}

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

    fn run(self: *Lexer) void {
        if (self.tokens.len == 0) {
            self.diagnostics.add(.token_capacity_exceeded, self.pointSpan());
            return;
        }

        while (self.index < self.source.len) {
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
        if (self.count == self.tokens.len and self.tokens[self.count - 1].kind != .eof) {
            self.tokens[self.count - 1] = .{ .kind = .eof, .span = self.pointSpan() };
        }
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
            self.emit(.metacommand, keyword, self.makeSpan(start, self.index, line, column));
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
                self.emit(.metacommand, keyword, self.makeSpan(start, self.index, line, column));
            }
            self.skipToLineEnd();
            return;
        }

        const keyword = keywordFor(text);
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

fn keywordFor(text: []const u8) Keyword {
    const Entry = struct { text: []const u8, keyword: Keyword };
    const entries = [_]Entry{
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
    for (entries) |entry| if (std.ascii.eqlIgnoreCase(text, entry.text)) return entry.keyword;

    const unsupported = [_][]const u8{
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
    for (unsupported) |word| if (std.ascii.eqlIgnoreCase(text, word)) return .unsupported;
    return .none;
}

const BlockKind = enum(u8) {
    if_block,
    select_block,
    for_block,
    while_block,
    do_block,
    type_block,
    sub_block,
    function_block,
};

const Block = struct {
    kind: BlockKind,
    span: Span,
};

const Parser = struct {
    source: []const u8,
    tokens: []const Token,
    diagnostics: *DiagnosticSink,
    index: usize = 0,
    summary: ProgramSummary = .{},
    blocks: [128]Block = undefined,
    block_count: usize = 0,

    fn run(self: *Parser) void {
        while (!self.at(.eof)) {
            if (self.consume(.newline) or self.consume(.colon)) continue;
            if (self.at(.metacommand)) {
                self.parseMetacommand();
                self.requireBoundary();
                continue;
            }
            if (self.at(.identifier) and self.peek(1).kind == .colon) {
                self.summary.labels += 1;
                self.advance();
                self.advance();
                continue;
            }

            const before = self.index;
            if (self.parseStatement(false)) {
                self.summary.statements += 1;
                self.requireBoundary();
            } else {
                if (self.index == before) self.advance();
                self.synchronize();
            }
        }

        while (self.block_count != 0) {
            self.block_count -= 1;
            self.diagnostics.add(.unclosed_block, self.blocks[self.block_count].span);
        }
    }

    fn parseMetacommand(self: *Parser) void {
        const token = self.current();
        self.advance();
        self.summary.metacommands += 1;
        if (token.keyword != .dynamic and token.keyword != .static) {
            self.diagnostics.add(.unsupported_metacommand, token.span);
        }
    }

    fn parseStatement(self: *Parser, inline_statement: bool) bool {
        if (self.at(.identifier)) {
            if (self.topIs(.type_block)) return self.parseTypeField();
            return self.parseAssignmentOrCall();
        }
        if (!self.at(.keyword)) return self.fail(.expected_statement);

        return switch (self.current().keyword) {
            .declare => self.parseDeclare(),
            .defint => self.parseDefInt(),
            .def => self.parseDef(),
            .type => self.parseTypeBlock(),
            .const_ => self.parseConst(),
            .dim, .redim => self.parseDim(),
            .data => self.parseData(),
            .read => self.parseLvalueListStatement(),
            .restore => self.parseRestore(),
            .sub => self.parseProcedure(.sub_block),
            .function => self.parseProcedure(.function_block),
            .end => self.parseEnd(),
            .if_ => self.parseIf(inline_statement),
            .elseif => self.parseElseIf(),
            .else_ => self.parseElse(),
            .select => self.parseSelect(),
            .case => self.parseCase(),
            .for_ => self.parseFor(),
            .next => self.parseNext(),
            .while_ => self.parseWhile(),
            .wend => self.parseWend(),
            .do_ => self.parseDo(),
            .loop => self.parseLoop(),
            .goto_, .gosub => self.parseBranch(),
            .return_ => self.parseReturn(),
            .on => self.parseOnError(),
            .resume_ => self.parseResume(),
            .call => self.parseCall(),
            .exit => self.parseExit(),
            .let => self.parseLet(),
            .screen => self.parseRequiredExpressionStatement(),
            .width => self.parseExpressionListStatement(1, 2, false),
            .color => self.parseExpressionListStatement(0, 2, true),
            .cls => self.parseExpressionListStatement(0, 1, false),
            .locate => self.parseExpressionListStatement(1, 5, true),
            .view => self.parseViewPrint(),
            .print => self.parsePrint(),
            .input => self.parseInput(false),
            .line => self.parseLineStatement(),
            .randomize => self.parseExpressionListStatement(0, 1, false),
            .sleep => self.parseExpressionListStatement(0, 1, false),
            .beep => self.parseNoArgumentStatement(),
            .play => self.parseRequiredExpressionStatement(),
            .palette => self.parseExpressionListStatement(2, 2, false),
            .pset => self.parsePset(),
            .circle => self.parseCircle(),
            .paint => self.parsePaint(),
            .get => self.parseGraphicsGet(),
            .put => self.parseGraphicsPut(),
            .poke => self.parseExpressionListStatement(2, 2, false),
            .open => self.parseOpen(),
            .close => self.parseClose(),
            .unsupported => self.fail(.unsupported_statement),
            else => self.fail(.expected_statement),
        };
    }

    fn parseDeclare(self: *Parser) bool {
        self.advance();
        const kind = self.current().keyword;
        if (kind != .sub and kind != .function) return self.fail(.expected_token);
        self.advance();
        if (!self.expectIdentifier()) return false;
        if (!self.parseParameterList()) return false;
        if (kind == .function and self.consumeKeyword(.as) and !self.parseTypeName()) return false;
        return true;
    }

    fn parseDefInt(self: *Parser) bool {
        self.advance();
        var count: usize = 0;
        while (true) {
            if (!self.expectIdentifier()) return false;
            count += 1;
            if (self.consume(.minus) and !self.expectIdentifier()) return false;
            if (!self.consume(.comma)) break;
        }
        return count != 0;
    }

    fn parseDef(self: *Parser) bool {
        self.advance();
        if (self.consumeKeyword(.seg)) {
            if (self.consume(.equal)) return self.parseExpression();
            return true;
        }
        _ = self.consumeKeyword(.fn_);
        if (!self.expectIdentifier()) return false;
        if (!self.parseParameterList()) return false;
        if (!self.expect(.equal)) return false;
        return self.parseExpression();
    }

    fn parseTypeBlock(self: *Parser) bool {
        const span = self.current().span;
        self.advance();
        if (!self.expectIdentifier()) return false;
        self.summary.user_types += 1;
        return self.pushBlock(.type_block, span);
    }

    fn parseTypeField(self: *Parser) bool {
        if (!self.expectIdentifier()) return false;
        if (!self.expectKeyword(.as)) return false;
        return self.parseTypeName();
    }

    fn parseConst(self: *Parser) bool {
        self.advance();
        while (true) {
            if (!self.expectIdentifier() or !self.expect(.equal) or !self.parseExpression()) return false;
            if (!self.consume(.comma)) break;
        }
        return true;
    }

    fn parseDim(self: *Parser) bool {
        self.advance();
        _ = self.consumeKeyword(.shared);
        while (true) {
            if (!self.expectIdentifier()) return false;
            if (self.consume(.left_paren)) {
                if (!self.consume(.right_paren)) {
                    while (true) {
                        if (!self.parseExpression()) return false;
                        if (self.consumeKeyword(.to) and !self.parseExpression()) return false;
                        if (!self.consume(.comma)) break;
                    }
                    if (!self.expect(.right_paren)) return false;
                }
            }
            if (self.consumeKeyword(.as) and !self.parseTypeName()) return false;
            if (!self.consume(.comma)) break;
        }
        return true;
    }

    fn parseData(self: *Parser) bool {
        self.advance();
        if (self.atBoundary() or self.atKeyword(.else_)) return self.fail(.expected_expression);
        while (true) {
            if (!self.parseExpression()) return false;
            if (!self.consume(.comma)) break;
            if (self.atBoundary()) return self.fail(.expected_expression);
        }
        return true;
    }

    fn parseLvalueListStatement(self: *Parser) bool {
        self.advance();
        while (true) {
            if (!self.parseLvalue()) return false;
            if (!self.consume(.comma)) break;
        }
        return true;
    }

    fn parseRestore(self: *Parser) bool {
        self.advance();
        if (self.atBoundary() or self.atKeyword(.else_)) return true;
        if (self.at(.identifier) or self.at(.number)) {
            self.advance();
            return true;
        }
        return self.fail(.expected_identifier);
    }

    fn parseProcedure(self: *Parser, kind: BlockKind) bool {
        const span = self.current().span;
        self.advance();
        if (!self.expectIdentifier()) return false;
        if (self.at(.left_paren) and !self.parseParameterList()) return false;
        if (kind == .function_block and self.consumeKeyword(.as) and !self.parseTypeName()) return false;
        _ = self.consumeKeyword(.static);
        if (kind == .sub_block) {
            self.summary.procedures += 1;
        } else {
            self.summary.functions += 1;
        }
        return self.pushBlock(kind, span);
    }

    fn parseEnd(self: *Parser) bool {
        self.advance();
        if (self.consumeKeyword(.if_)) return self.popBlock(.if_block);
        if (self.consumeKeyword(.select)) return self.popBlock(.select_block);
        if (self.consumeKeyword(.type)) return self.popBlock(.type_block);
        if (self.consumeKeyword(.sub)) return self.popBlock(.sub_block);
        if (self.consumeKeyword(.function)) return self.popBlock(.function_block);
        return true;
    }

    fn parseIf(self: *Parser, _: bool) bool {
        const span = self.current().span;
        self.advance();
        if (!self.parseExpression() or !self.expectKeyword(.then)) return false;
        if (self.atBoundary()) return self.pushBlock(.if_block, span);
        if (!self.parseStatement(true)) return false;
        if (self.consumeKeyword(.else_)) {
            if (!self.parseStatement(true)) return false;
        }
        return true;
    }

    fn parseElseIf(self: *Parser) bool {
        if (!self.requireTop(.if_block)) return false;
        self.advance();
        return self.parseExpression() and self.expectKeyword(.then);
    }

    fn parseElse(self: *Parser) bool {
        if (!self.requireTop(.if_block)) return false;
        self.advance();
        return true;
    }

    fn parseSelect(self: *Parser) bool {
        const span = self.current().span;
        self.advance();
        if (!self.expectKeyword(.case) or !self.parseExpression()) return false;
        return self.pushBlock(.select_block, span);
    }

    fn parseCase(self: *Parser) bool {
        if (!self.requireTop(.select_block)) return false;
        self.advance();
        if (self.consumeKeyword(.else_)) return true;
        while (true) {
            if (!self.parseExpression()) return false;
            if (self.consumeKeyword(.to) and !self.parseExpression()) return false;
            if (!self.consume(.comma)) break;
        }
        return true;
    }

    fn parseFor(self: *Parser) bool {
        const span = self.current().span;
        self.advance();
        if (!self.parseLvalue() or !self.expect(.equal) or !self.parseExpression()) return false;
        if (!self.expectKeyword(.to) or !self.parseExpression()) return false;
        if (self.consumeKeyword(.step) and !self.parseExpression()) return false;
        return self.pushBlock(.for_block, span);
    }

    fn parseNext(self: *Parser) bool {
        self.advance();
        var closes: usize = 1;
        if (self.at(.identifier)) {
            self.advance();
            while (self.consume(.comma)) {
                if (!self.expectIdentifier()) return false;
                closes += 1;
            }
        }
        while (closes != 0) : (closes -= 1) if (!self.popBlock(.for_block)) return false;
        return true;
    }

    fn parseWhile(self: *Parser) bool {
        const span = self.current().span;
        self.advance();
        if (!self.parseExpression()) return false;
        return self.pushBlock(.while_block, span);
    }

    fn parseWend(self: *Parser) bool {
        self.advance();
        return self.popBlock(.while_block);
    }

    fn parseDo(self: *Parser) bool {
        const span = self.current().span;
        self.advance();
        if (self.consumeKeyword(.while_) or self.consumeKeyword(.until)) {
            if (!self.parseExpression()) return false;
        }
        return self.pushBlock(.do_block, span);
    }

    fn parseLoop(self: *Parser) bool {
        self.advance();
        if (self.consumeKeyword(.while_) or self.consumeKeyword(.until)) {
            if (!self.parseExpression()) return false;
        }
        return self.popBlock(.do_block);
    }

    fn parseBranch(self: *Parser) bool {
        self.advance();
        if (self.at(.identifier) or self.at(.number)) {
            self.advance();
            return true;
        }
        return self.fail(.expected_identifier);
    }

    fn parseReturn(self: *Parser) bool {
        self.advance();
        if (self.at(.identifier) or self.at(.number)) self.advance();
        return true;
    }

    fn parseOnError(self: *Parser) bool {
        self.advance();
        if (!self.expectKeyword(.error_) or !self.expectKeyword(.goto_)) return false;
        if (self.at(.identifier) or self.at(.number)) {
            self.advance();
            return true;
        }
        return self.fail(.expected_identifier);
    }

    fn parseResume(self: *Parser) bool {
        self.advance();
        if (self.consumeKeyword(.next)) return true;
        if (self.at(.identifier) or self.at(.number)) self.advance();
        return true;
    }

    fn parseCall(self: *Parser) bool {
        self.advance();
        if (!self.expectIdentifier()) return false;
        if (self.consume(.left_paren)) return self.parseCallArgumentsAfterOpen();
        return true;
    }

    fn parseExit(self: *Parser) bool {
        self.advance();
        if (self.atKeyword(.sub) or self.atKeyword(.function) or self.atKeyword(.do_) or self.atKeyword(.for_)) {
            self.advance();
            return true;
        }
        return self.fail(.expected_token);
    }

    fn parseLet(self: *Parser) bool {
        self.advance();
        if (!self.parseLvalue() or !self.expect(.equal)) return false;
        return self.parseExpression();
    }

    fn parseRequiredExpressionStatement(self: *Parser) bool {
        self.advance();
        return self.parseExpression();
    }

    fn parseNoArgumentStatement(self: *Parser) bool {
        self.advance();
        return true;
    }

    fn parseExpressionListStatement(self: *Parser, minimum: usize, maximum: usize, allow_missing: bool) bool {
        self.advance();
        var count: usize = 0;
        if (self.atBoundary() or self.atKeyword(.else_)) return minimum == 0 or self.fail(.expected_expression);
        while (count < maximum) {
            if (self.at(.comma)) {
                if (!allow_missing) return self.fail(.expected_expression);
            } else if (!self.parseExpression()) {
                return false;
            }
            count += 1;
            if (!self.consume(.comma)) break;
            if (count == maximum) return self.fail(.unexpected_token);
            if ((self.atBoundary() or self.atKeyword(.else_)) and !allow_missing) return self.fail(.expected_expression);
        }
        if (count < minimum) return self.fail(.expected_expression);
        return true;
    }

    fn parseViewPrint(self: *Parser) bool {
        self.advance();
        if (!self.expectKeyword(.print)) return false;
        if (self.atBoundary() or self.atKeyword(.else_)) return true;
        if (!self.parseExpression()) return false;
        if (self.consumeKeyword(.to) and !self.parseExpression()) return false;
        return true;
    }

    fn parsePrint(self: *Parser) bool {
        self.advance();
        if (self.consume(.hash)) {
            if (!self.parseExpression() or !self.expect(.comma)) return false;
        }
        while (!self.atBoundary() and !self.atKeyword(.else_)) {
            if (self.consume(.semicolon) or self.consume(.comma)) continue;
            if (!self.parseExpression()) return false;
        }
        return true;
    }

    fn parseInput(self: *Parser, line_input: bool) bool {
        if (!line_input) self.advance();
        _ = self.consume(.semicolon);
        if (self.consume(.hash)) {
            if (!self.parseExpression() or !self.expect(.comma)) return false;
            return self.parseLvalueList();
        }
        if (self.at(.string)) {
            if (!self.parseExpression()) return false;
            if (!self.consume(.semicolon) and !self.consume(.comma)) return self.fail(.expected_separator);
        }
        return self.parseLvalueList();
    }

    fn parseLineStatement(self: *Parser) bool {
        self.advance();
        if (self.consumeKeyword(.input)) return self.parseInput(true);
        if (!self.parsePoint() or !self.expect(.minus) or !self.parsePoint()) return false;
        if (!self.expect(.comma) or !self.parseExpression()) return false;
        if (self.consume(.comma)) {
            if (self.at(.identifier)) {
                const mode = self.current().text(self.source);
                if (!std.ascii.eqlIgnoreCase(mode, "B") and !std.ascii.eqlIgnoreCase(mode, "BF")) return self.fail(.unexpected_token);
                self.advance();
            } else {
                return self.fail(.expected_identifier);
            }
        }
        return true;
    }

    fn parsePset(self: *Parser) bool {
        self.advance();
        if (!self.parsePoint()) return false;
        if (self.consume(.comma)) return self.parseExpression();
        return true;
    }

    fn parseCircle(self: *Parser) bool {
        self.advance();
        if (!self.parsePoint() or !self.expect(.comma) or !self.parseExpression()) return false;
        return self.parseOptionalExpressionTail(5);
    }

    fn parsePaint(self: *Parser) bool {
        self.advance();
        if (!self.parsePoint()) return false;
        return self.parseOptionalExpressionTail(2);
    }

    fn parseGraphicsGet(self: *Parser) bool {
        self.advance();
        if (!self.parsePoint() or !self.expect(.minus) or !self.parsePoint() or !self.expect(.comma)) return false;
        return self.parseLvalue();
    }

    fn parseGraphicsPut(self: *Parser) bool {
        self.advance();
        if (!self.parsePoint() or !self.expect(.comma) or !self.parseLvalue() or !self.expect(.comma)) return false;
        if (self.consumeKeyword(.pset) or self.consumeKeyword(.xor)) return true;
        return self.fail(.expected_token);
    }

    fn parseOpen(self: *Parser) bool {
        self.advance();
        if (!self.parseExpression() or !self.expectKeyword(.for_)) return false;
        if (!self.consumeKeyword(.input) and !self.consumeKeyword(.output) and !self.consumeKeyword(.append)) return self.fail(.unsupported_statement);
        if (!self.expectKeyword(.as) or !self.expect(.hash)) return false;
        return self.parseExpression();
    }

    fn parseClose(self: *Parser) bool {
        self.advance();
        if (self.atBoundary() or self.atKeyword(.else_)) return true;
        while (true) {
            if (!self.expect(.hash) or !self.parseExpression()) return false;
            if (!self.consume(.comma)) break;
        }
        return true;
    }

    fn parseOptionalExpressionTail(self: *Parser, maximum: usize) bool {
        var count: usize = 0;
        while (count < maximum and self.consume(.comma)) : (count += 1) {
            if (self.at(.comma) or self.atBoundary() or self.atKeyword(.else_)) continue;
            if (!self.parseExpression()) return false;
        }
        return true;
    }

    fn parsePoint(self: *Parser) bool {
        if (!self.expect(.left_paren) or !self.parseExpression() or !self.expect(.comma)) return false;
        return self.parseExpression() and self.expect(.right_paren);
    }

    fn parseAssignmentOrCall(self: *Parser) bool {
        const start = self.index;
        if (!self.parseLvalue()) return false;
        if (self.consume(.equal)) return self.parseExpression();
        self.index = start;
        self.advance();
        if (self.consume(.left_paren)) return self.parseCallArgumentsAfterOpen();
        if (self.atBoundary() or self.atKeyword(.else_)) return true;
        while (true) {
            if (!self.parseExpression()) return false;
            if (!self.consume(.comma)) break;
        }
        return true;
    }

    fn parseLvalueList(self: *Parser) bool {
        if (!self.parseLvalue()) return false;
        while (self.consume(.comma)) if (!self.parseLvalue()) return false;
        return true;
    }

    fn parseLvalue(self: *Parser) bool {
        if (!self.expectIdentifier()) return false;
        while (true) {
            if (self.consume(.left_paren)) {
                if (!self.consume(.right_paren)) {
                    if (!self.parseExpression()) return false;
                    while (self.consume(.comma)) if (!self.parseExpression()) return false;
                    if (!self.expect(.right_paren)) return false;
                }
            } else if (self.consume(.dot)) {
                if (!self.expectIdentifier()) return false;
            } else break;
        }
        return true;
    }

    fn parseParameterList(self: *Parser) bool {
        if (!self.expect(.left_paren)) return false;
        if (self.consume(.right_paren)) return true;
        while (true) {
            _ = self.consumeKeyword(.byval) or self.consumeKeyword(.byref);
            if (!self.expectIdentifier()) return false;
            if (self.consume(.left_paren) and !self.expect(.right_paren)) return false;
            if (self.consumeKeyword(.as) and !self.parseTypeName()) return false;
            if (!self.consume(.comma)) break;
        }
        return self.expect(.right_paren);
    }

    fn parseTypeName(self: *Parser) bool {
        if (self.at(.identifier)) {
            self.advance();
            return true;
        }
        if (self.at(.keyword)) switch (self.current().keyword) {
            .any, .integer, .long, .single, .double, .string => {
                self.advance();
                return true;
            },
            else => {},
        };
        return self.fail(.expected_identifier);
    }

    fn parseCallArgumentsAfterOpen(self: *Parser) bool {
        if (self.consume(.right_paren)) return true;
        while (true) {
            if (!self.parseExpression()) return false;
            if (!self.consume(.comma)) break;
        }
        return self.expect(.right_paren);
    }

    fn parseExpression(self: *Parser) bool {
        if (!self.parseBinary(1)) return false;
        self.summary.expressions += 1;
        return true;
    }

    fn parseBinary(self: *Parser, minimum_precedence: u8) bool {
        if (!self.parseUnary()) return false;
        while (binaryPrecedence(self.current()) >= minimum_precedence) {
            const precedence = binaryPrecedence(self.current());
            const right_associative = self.current().kind == .power;
            self.advance();
            if (!self.parseBinary(if (right_associative) precedence else precedence + 1)) return false;
        }
        return true;
    }

    fn parseUnary(self: *Parser) bool {
        if (self.at(.plus) or self.at(.minus) or self.atKeyword(.not)) {
            self.advance();
            return self.parseUnary();
        }
        return self.parsePrimary();
    }

    fn parsePrimary(self: *Parser) bool {
        if (self.at(.number) or self.at(.string)) {
            self.advance();
            return true;
        }
        if (self.at(.identifier)) {
            self.advance();
            return self.parsePostfix();
        }
        if (self.at(.keyword) and isBuiltinFunction(self.current().keyword)) {
            return self.parseBuiltinFunction();
        }
        if (self.consume(.left_paren)) {
            if (!self.parseExpression() or !self.expect(.right_paren)) return false;
            return self.parsePostfix();
        }
        return self.fail(.expected_expression);
    }

    fn parseBuiltinFunction(self: *Parser) bool {
        const token = self.current();
        const signature = builtinSignature(token.keyword) orelse return self.fail(.expected_expression);
        self.advance();

        if (!self.consume(.left_paren)) {
            if (signature.allow_bare) return true;
            return self.failAt(.expected_token, token.span);
        }
        if (!signature.allow_parentheses) return self.failAt(.wrong_argument_count, token.span);

        var argument_count: usize = 0;
        if (!self.consume(.right_paren)) {
            while (true) {
                if (!self.parseExpression()) return false;
                argument_count += 1;
                if (!self.consume(.comma)) break;
            }
            if (!self.expect(.right_paren)) return false;
        }

        if (argument_count < signature.minimum or argument_count > signature.maximum) {
            return self.failAt(.wrong_argument_count, token.span);
        }
        return true;
    }

    fn parsePostfix(self: *Parser) bool {
        while (true) {
            if (self.consume(.left_paren)) {
                if (!self.parseCallArgumentsAfterOpen()) return false;
            } else if (self.consume(.dot)) {
                if (!self.expectIdentifier()) return false;
            } else break;
        }
        return true;
    }

    fn requireBoundary(self: *Parser) void {
        if (self.atBoundary()) return;
        self.diagnostics.add(.expected_separator, self.current().span);
        self.synchronize();
    }

    fn synchronize(self: *Parser) void {
        while (!self.atBoundary()) self.advance();
    }

    fn atBoundary(self: *const Parser) bool {
        return self.at(.newline) or self.at(.colon) or self.at(.eof);
    }

    fn pushBlock(self: *Parser, kind: BlockKind, span: Span) bool {
        if (self.block_count >= self.blocks.len) return self.failAt(.nesting_too_deep, span);
        self.blocks[self.block_count] = .{ .kind = kind, .span = span };
        self.block_count += 1;
        self.summary.maximum_block_depth = @max(self.summary.maximum_block_depth, @as(u16, @intCast(self.block_count)));
        return true;
    }

    fn popBlock(self: *Parser, expected: BlockKind) bool {
        if (!self.requireTop(expected)) return false;
        self.block_count -= 1;
        return true;
    }

    fn requireTop(self: *Parser, expected: BlockKind) bool {
        if (self.block_count == 0 or self.blocks[self.block_count - 1].kind != expected) return self.fail(.unmatched_block);
        return true;
    }

    fn topIs(self: *const Parser, expected: BlockKind) bool {
        return self.block_count != 0 and self.blocks[self.block_count - 1].kind == expected;
    }

    fn expectIdentifier(self: *Parser) bool {
        if (!self.at(.identifier)) return self.fail(.expected_identifier);
        self.advance();
        return true;
    }

    fn expect(self: *Parser, kind: TokenKind) bool {
        if (!self.at(kind)) return self.fail(.expected_token);
        self.advance();
        return true;
    }

    fn expectKeyword(self: *Parser, keyword: Keyword) bool {
        if (!self.atKeyword(keyword)) return self.fail(.expected_token);
        self.advance();
        return true;
    }

    fn consume(self: *Parser, kind: TokenKind) bool {
        if (!self.at(kind)) return false;
        self.advance();
        return true;
    }

    fn consumeKeyword(self: *Parser, keyword: Keyword) bool {
        if (!self.atKeyword(keyword)) return false;
        self.advance();
        return true;
    }

    fn at(self: *const Parser, kind: TokenKind) bool {
        return self.current().kind == kind;
    }

    fn atKeyword(self: *const Parser, keyword: Keyword) bool {
        return self.current().kind == .keyword and self.current().keyword == keyword;
    }

    fn current(self: *const Parser) Token {
        return self.tokens[@min(self.index, self.tokens.len - 1)];
    }

    fn peek(self: *const Parser, distance: usize) Token {
        return self.tokens[@min(self.index + distance, self.tokens.len - 1)];
    }

    fn advance(self: *Parser) void {
        if (self.index + 1 < self.tokens.len) self.index += 1;
    }

    fn fail(self: *Parser, code: DiagnosticCode) bool {
        self.diagnostics.add(code, self.current().span);
        return false;
    }

    fn failAt(self: *Parser, code: DiagnosticCode, span: Span) bool {
        self.diagnostics.add(code, span);
        return false;
    }
};

fn binaryPrecedence(token: Token) u8 {
    if (token.kind == .keyword) return switch (token.keyword) {
        .or_ => 1,
        .xor => 2,
        .and_ => 3,
        .mod => 6,
        else => 0,
    };
    return switch (token.kind) {
        .equal, .less, .greater, .less_equal, .greater_equal, .not_equal => 4,
        .plus, .minus => 5,
        .multiply, .divide, .integer_divide => 6,
        .power => 7,
        else => 0,
    };
}

const BuiltinSignature = struct {
    minimum: usize,
    maximum: usize,
    allow_bare: bool = false,
    allow_parentheses: bool = true,
};

fn builtinSignature(keyword: Keyword) ?BuiltinSignature {
    return switch (keyword) {
        .abs,
        .atn,
        .chr_string,
        .cint,
        .cos,
        .eof,
        .int,
        .len,
        .ltrim_string,
        .peek,
        .sin,
        .space_string,
        .str_string,
        .tab,
        .ucase_string,
        .val,
        => .{ .minimum = 1, .maximum = 1 },
        .left_string, .point => .{ .minimum = 2, .maximum = 2 },
        .instr, .mid_string => .{ .minimum = 2, .maximum = 3 },
        .rnd => .{ .minimum = 0, .maximum = 1, .allow_bare = true },
        .inkey_string, .timer => .{
            .minimum = 0,
            .maximum = 0,
            .allow_bare = true,
            .allow_parentheses = false,
        },
        else => null,
    };
}

fn isBuiltinFunction(keyword: Keyword) bool {
    return builtinSignature(keyword) != null;
}
