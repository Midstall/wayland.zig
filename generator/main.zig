//! Wayland protocol XML generator.
//! Reads a Wayland protocol XML file (path as first argument) and emits
//! Zig source code to a file (second argument). The generated code contains
//! one namespace struct per interface, with: version constant, request opcode
//! enum, event opcode enum, per-enum Zig enums, and request/event types.

const std = @import("std");
const xml = @import("xml");

const ArgType = enum {
    int,
    uint,
    fixed,
    string,
    object,
    new_id,
    array,
    fd,
};

const Arg = struct {
    name: []const u8,
    arg_type: ArgType,
    interface: ?[]const u8,
    enum_ref: ?[]const u8,
    summary: ?[]const u8,
    allow_null: bool,
};

const Message = struct {
    name: []const u8,
    description: ?[]const u8,
    args: std.ArrayList(Arg),
    since: ?u32,

    pub fn deinit(self: *Message, gpa: std.mem.Allocator) void {
        for (self.args.items) |*a| {
            gpa.free(a.name);
            if (a.interface) |iface| gpa.free(iface);
            if (a.enum_ref) |er| gpa.free(er);
            if (a.summary) |s| gpa.free(s);
        }
        self.args.deinit(gpa);
        gpa.free(self.name);
        if (self.description) |d| gpa.free(d);
    }
};

const EnumEntry = struct {
    name: []const u8,
    value: []const u8,
    summary: ?[]const u8,
};

const WlEnum = struct {
    name: []const u8,
    description: ?[]const u8,
    entries: std.ArrayList(EnumEntry),
    bitfield: bool,

    pub fn deinit(self: *WlEnum, gpa: std.mem.Allocator) void {
        for (self.entries.items) |*e| {
            gpa.free(e.name);
            gpa.free(e.value);
            if (e.summary) |s| gpa.free(s);
        }
        self.entries.deinit(gpa);
        gpa.free(self.name);
        if (self.description) |d| gpa.free(d);
    }
};

const Interface = struct {
    name: []const u8,
    version: u32,
    description: ?[]const u8,
    requests: std.ArrayList(Message),
    events: std.ArrayList(Message),
    enums: std.ArrayList(WlEnum),

    pub fn deinit(self: *Interface, gpa: std.mem.Allocator) void {
        for (self.requests.items) |*r| r.deinit(gpa);
        self.requests.deinit(gpa);
        for (self.events.items) |*e| e.deinit(gpa);
        self.events.deinit(gpa);
        for (self.enums.items) |*e| e.deinit(gpa);
        self.enums.deinit(gpa);
        gpa.free(self.name);
        if (self.description) |d| gpa.free(d);
    }
};

const Protocol = struct {
    name: []const u8,
    interfaces: std.ArrayList(Interface),

    pub fn deinit(self: *Protocol, gpa: std.mem.Allocator) void {
        for (self.interfaces.items) |*i| i.deinit(gpa);
        self.interfaces.deinit(gpa);
        gpa.free(self.name);
    }
};

fn parseArgType(s: []const u8) ArgType {
    if (std.mem.eql(u8, s, "int")) return .int;
    if (std.mem.eql(u8, s, "uint")) return .uint;
    if (std.mem.eql(u8, s, "fixed")) return .fixed;
    if (std.mem.eql(u8, s, "string")) return .string;
    if (std.mem.eql(u8, s, "object")) return .object;
    if (std.mem.eql(u8, s, "new_id")) return .new_id;
    if (std.mem.eql(u8, s, "array")) return .array;
    if (std.mem.eql(u8, s, "fd")) return .fd;
    return .uint;
}

fn zigArgType(arg: Arg) []const u8 {
    if (arg.allow_null) {
        return switch (arg.arg_type) {
            .int => "i32",
            .uint => "u32",
            .fixed => "core.Fixed",
            .string => "?[]const u8",
            .object => "?u32",
            .new_id => "u32",
            .array => "[]const u8",
            .fd => "i32",
        };
    }
    return switch (arg.arg_type) {
        .int => "i32",
        .uint => "u32",
        .fixed => "core.Fixed",
        .string => "[]const u8",
        .object => "u32",
        .new_id => "u32",
        .array => "[]const u8",
        .fd => "i32",
    };
}

fn zigArgWriteCall(arg: Arg) []const u8 {
    return switch (arg.arg_type) {
        .int => "writeInt",
        .uint => "writeUint",
        .fixed => "writeFixed",
        .string => "writeString",
        .object => "writeObject",
        .new_id => "writeNewId",
        .array => "writeArray",
        .fd => "writeUint", // fd sent out-of-band; placeholder
    };
}

// Convert snake_case to camelCase.
fn toCamelCase(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    var next_upper = false;
    for (name) |c| {
        if (c == '_') {
            next_upper = true;
        } else if (next_upper) {
            try result.append(gpa, std.ascii.toUpper(c));
            next_upper = false;
        } else {
            try result.append(gpa, c);
        }
    }
    return result.toOwnedSlice(gpa);
}

// Convert snake_case to PascalCase.
fn toPascalCase(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    var next_upper = true;
    for (name) |c| {
        if (c == '_') {
            next_upper = true;
        } else if (next_upper) {
            try result.append(gpa, std.ascii.toUpper(c));
            next_upper = false;
        } else {
            try result.append(gpa, c);
        }
    }
    return result.toOwnedSlice(gpa);
}

// Escape names that clash with Zig keywords or start with a digit.
fn escapeName(gpa: std.mem.Allocator, name: []const u8) ![]const u8 {
    // Names starting with a digit need quoting
    if (name.len > 0 and std.ascii.isDigit(name[0])) {
        return std.fmt.allocPrint(gpa, "@\"{s}\"", .{name});
    }
    const keywords = [_][]const u8{
        "error",       "type",   "align",       "and",         "break",          "const",     "continue",
        "defer",       "else",   "enum",        "export",      "extern",         "fn",        "for",
        "if",          "inline", "linksection", "noalias",     "noinline",       "nosuspend", "or",
        "orelse",      "pub",    "return",      "struct",      "suspend",        "switch",    "test",
        "threadlocal", "try",    "union",       "unreachable", "usingnamespace", "var",       "volatile",
        "while",
    };
    for (keywords) |kw| {
        if (std.mem.eql(u8, name, kw)) {
            return std.fmt.allocPrint(gpa, "@\"{s}\"", .{name});
        }
    }
    return gpa.dupe(u8, name);
}

const Parser = struct {
    gpa: std.mem.Allocator,
    reader: *xml.Reader,
    protocol: Protocol,

    current_interface: ?*Interface = null,
    current_message: ?*Message = null,
    current_enum: ?*WlEnum = null,
    collecting_description: bool = false,
    description_buf: std.ArrayList(u8),

    pub fn init(gpa: std.mem.Allocator, reader: *xml.Reader) Parser {
        return .{
            .gpa = gpa,
            .reader = reader,
            .protocol = .{
                .name = &.{},
                .interfaces = .empty,
            },
            .description_buf = .empty,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.description_buf.deinit(self.gpa);
    }

    fn getAttr(self: *Parser, name: []const u8) ?[]const u8 {
        const count = self.reader.attributeCount();
        var i: usize = 0;
        while (i < count) : (i += 1) {
            if (std.mem.eql(u8, self.reader.attributeName(i), name)) {
                return self.reader.attributeValueRaw(i);
            }
        }
        return null;
    }

    fn getAttrDupe(self: *Parser, name: []const u8) !?[]const u8 {
        if (self.getAttr(name)) |v| {
            return try self.gpa.dupe(u8, v);
        }
        return null;
    }

    pub fn parse(self: *Parser) !void {
        while (true) {
            const node = try self.reader.read();
            switch (node) {
                .eof => break,
                .element_start => try self.onElementStart(),
                .element_end => try self.onElementEnd(),
                .text => {
                    if (self.collecting_description) {
                        const t = self.reader.textRaw();
                        try self.description_buf.appendSlice(self.gpa, t);
                    }
                },
                .xml_declaration, .comment, .pi, .cdata, .character_reference, .entity_reference => {},
            }
        }
    }

    fn onElementStart(self: *Parser) !void {
        const name = self.reader.elementName();

        if (std.mem.eql(u8, name, "protocol")) {
            const pname = self.getAttr("name") orelse "wayland";
            self.protocol.name = try self.gpa.dupe(u8, pname);
        } else if (std.mem.eql(u8, name, "interface")) {
            const iname = self.getAttr("name") orelse "";
            const ver_str = self.getAttr("version") orelse "1";
            const ver = std.fmt.parseInt(u32, ver_str, 10) catch 1;
            try self.protocol.interfaces.append(self.gpa, .{
                .name = try self.gpa.dupe(u8, iname),
                .version = ver,
                .description = null,
                .requests = .empty,
                .events = .empty,
                .enums = .empty,
            });
            const idx = self.protocol.interfaces.items.len - 1;
            self.current_interface = &self.protocol.interfaces.items[idx];
        } else if (std.mem.eql(u8, name, "request")) {
            const mname = self.getAttr("name") orelse "";
            const since_str = self.getAttr("since");
            const since: ?u32 = if (since_str) |s| std.fmt.parseInt(u32, s, 10) catch null else null;
            if (self.current_interface) |iface| {
                try iface.requests.append(self.gpa, .{
                    .name = try self.gpa.dupe(u8, mname),
                    .description = null,
                    .args = .empty,
                    .since = since,
                });
                const idx = iface.requests.items.len - 1;
                self.current_message = &iface.requests.items[idx];
            }
        } else if (std.mem.eql(u8, name, "event")) {
            const mname = self.getAttr("name") orelse "";
            const since_str = self.getAttr("since");
            const since: ?u32 = if (since_str) |s| std.fmt.parseInt(u32, s, 10) catch null else null;
            if (self.current_interface) |iface| {
                try iface.events.append(self.gpa, .{
                    .name = try self.gpa.dupe(u8, mname),
                    .description = null,
                    .args = .empty,
                    .since = since,
                });
                const idx = iface.events.items.len - 1;
                self.current_message = &iface.events.items[idx];
            }
        } else if (std.mem.eql(u8, name, "arg")) {
            if (self.current_message) |msg| {
                const aname = self.getAttr("name") orelse "";
                const atype_str = self.getAttr("type") orelse "uint";
                const aiface = try self.getAttrDupe("interface");
                const aenum = try self.getAttrDupe("enum");
                const asumm = try self.getAttrDupe("summary");
                const allow_null_str = self.getAttr("allow-null");
                const allow_null = if (allow_null_str) |s| std.mem.eql(u8, s, "true") else false;
                try msg.args.append(self.gpa, .{
                    .name = try self.gpa.dupe(u8, aname),
                    .arg_type = parseArgType(atype_str),
                    .interface = aiface,
                    .enum_ref = aenum,
                    .summary = asumm,
                    .allow_null = allow_null,
                });
            }
        } else if (std.mem.eql(u8, name, "enum")) {
            const ename = self.getAttr("name") orelse "";
            const bitfield_str = self.getAttr("bitfield");
            const bitfield = if (bitfield_str) |s| std.mem.eql(u8, s, "true") else false;
            if (self.current_interface) |iface| {
                try iface.enums.append(self.gpa, .{
                    .name = try self.gpa.dupe(u8, ename),
                    .description = null,
                    .entries = .empty,
                    .bitfield = bitfield,
                });
                const idx = iface.enums.items.len - 1;
                self.current_enum = &iface.enums.items[idx];
            }
        } else if (std.mem.eql(u8, name, "entry")) {
            if (self.current_enum) |enm| {
                const ename = self.getAttr("name") orelse "";
                const evalue = self.getAttr("value") orelse "0";
                const esumm = try self.getAttrDupe("summary");
                try enm.entries.append(self.gpa, .{
                    .name = try self.gpa.dupe(u8, ename),
                    .value = try self.gpa.dupe(u8, evalue),
                    .summary = esumm,
                });
            }
        } else if (std.mem.eql(u8, name, "description")) {
            self.collecting_description = true;
            self.description_buf.clearRetainingCapacity();
        }
    }

    fn onElementEnd(self: *Parser) !void {
        const name = self.reader.elementName();

        if (std.mem.eql(u8, name, "interface")) {
            self.current_interface = null;
            self.current_message = null;
            self.current_enum = null;
        } else if (std.mem.eql(u8, name, "request") or std.mem.eql(u8, name, "event")) {
            self.current_message = null;
        } else if (std.mem.eql(u8, name, "enum")) {
            self.current_enum = null;
        } else if (std.mem.eql(u8, name, "description")) {
            self.collecting_description = false;
            const desc = std.mem.trim(u8, self.description_buf.items, " \t\n\r");
            if (desc.len > 0) {
                const duped = try self.gpa.dupe(u8, desc);
                if (self.current_message) |msg| {
                    if (msg.description == null) {
                        msg.description = duped;
                    } else {
                        self.gpa.free(duped);
                    }
                } else if (self.current_enum) |enm| {
                    if (enm.description == null) {
                        enm.description = duped;
                    } else {
                        self.gpa.free(duped);
                    }
                } else if (self.current_interface) |iface| {
                    if (iface.description == null) {
                        iface.description = duped;
                    } else {
                        self.gpa.free(duped);
                    }
                } else {
                    self.gpa.free(duped);
                }
            }
        }
    }
};

fn emitDocComment(w: *std.Io.Writer, text: []const u8, indent: []const u8) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) {
            try w.print("{s}///\n", .{indent});
        } else {
            try w.print("{s}/// {s}\n", .{ indent, trimmed });
        }
    }
}

/// Emit a single-line doc comment, collapsing any embedded newlines/whitespace runs to spaces.
fn emitSummaryComment(gpa: std.mem.Allocator, w: *std.Io.Writer, summary: []const u8, indent: []const u8) !void {
    // Replace runs of whitespace (including newlines) with a single space.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var in_ws = false;
    for (summary) |c| {
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            if (!in_ws) {
                try buf.append(gpa, ' ');
                in_ws = true;
            }
        } else {
            try buf.append(gpa, c);
            in_ws = false;
        }
    }
    const normalized = std.mem.trim(u8, buf.items, " ");
    if (normalized.len > 0) {
        try w.print("{s}/// {s}\n", .{ indent, normalized });
    }
}

fn emitEnum(gpa: std.mem.Allocator, w: *std.Io.Writer, enm: WlEnum) !void {
    if (enm.description) |d| {
        try emitDocComment(w, d, "    ");
    }
    const pascal = try toPascalCase(gpa, enm.name);
    defer gpa.free(pascal);
    if (enm.bitfield) {
        // Bitfields: emit as struct of u32 constants
        try w.print("    pub const {s} = struct {{\n", .{pascal});
        for (enm.entries.items) |entry| {
            if (entry.summary) |s| {
                try emitSummaryComment(gpa, w, s, "        ");
            }
            const ename = try escapeName(gpa, entry.name);
            defer gpa.free(ename);
            try w.print("        pub const {s}: u32 = {s};\n", .{ ename, entry.value });
        }
        try w.print("    }};\n\n", .{});
    } else {
        try w.print("    pub const {s} = enum(u32) {{\n", .{pascal});
        for (enm.entries.items) |entry| {
            if (entry.summary) |s| {
                try emitSummaryComment(gpa, w, s, "        ");
            }
            const ename = try escapeName(gpa, entry.name);
            defer gpa.free(ename);
            try w.print("        {s} = {s},\n", .{ ename, entry.value });
        }
        try w.print("        _,\n", .{});
        try w.print("    }};\n\n", .{});
    }
}

fn emitOpcodesEnum(gpa: std.mem.Allocator, w: *std.Io.Writer, enum_name: []const u8, messages: []const Message) !void {
    if (messages.len == 0) return;
    try w.print("    pub const {s} = enum(u16) {{\n", .{enum_name});
    for (messages, 0..) |msg, i| {
        const ename = try escapeName(gpa, msg.name);
        defer gpa.free(ename);
        try w.print("        {s} = {d},\n", .{ ename, i });
    }
    try w.print("    }};\n\n", .{});
}

fn emitEventUnion(gpa: std.mem.Allocator, w: *std.Io.Writer, events: []const Message) !void {
    if (events.len == 0) return;
    try w.print("    pub const Event = union(EventOpcode) {{\n", .{});
    for (events) |event| {
        const ename = try escapeName(gpa, event.name);
        defer gpa.free(ename);
        if (event.args.items.len == 0) {
            try w.print("        {s}: void,\n", .{ename});
        } else {
            try w.print("        {s}: struct {{\n", .{ename});
            for (event.args.items) |arg| {
                const aname = try escapeName(gpa, arg.name);
                defer gpa.free(aname);
                const atype = zigArgType(arg);
                try w.print("            {s}: {s},\n", .{ aname, atype });
            }
            try w.print("        }},\n", .{});
        }
    }
    try w.print("    }};\n\n", .{});
}

fn emitRequestMethod(gpa: std.mem.Allocator, w: *std.Io.Writer, msg: Message, opcode: usize) !void {
    if (msg.description) |d| {
        try emitDocComment(w, d, "    ");
    }
    const fname = try toCamelCase(gpa, msg.name);
    defer gpa.free(fname);

    try w.print("    pub fn {s}(ww: *core.Writer, alloc: std.mem.Allocator, self_id: u32", .{fname});
    for (msg.args.items) |arg| {
        const aname = try escapeName(gpa, arg.name);
        defer gpa.free(aname);
        const atype = zigArgType(arg);
        try w.print(", {s}: {s}", .{ aname, atype });
    }
    try w.print(") !void {{\n", .{});
    try w.print("        try ww.begin(alloc, self_id, {d});\n", .{opcode});
    for (msg.args.items) |arg| {
        const aname = try escapeName(gpa, arg.name);
        defer gpa.free(aname);
        if (arg.arg_type == .fd) {
            try w.print("        _ = {s}; // fd sent via SCM_RIGHTS ancillary data\n", .{aname});
            try w.print("        try ww.writeUint(alloc, 0);\n", .{});
        } else if (arg.arg_type == .object and arg.allow_null) {
            // A nullable object is typed `?u32`; the wire null object is id 0.
            try w.print("        try ww.writeObject(alloc, {s} orelse 0);\n", .{aname});
        } else {
            const call = zigArgWriteCall(arg);
            try w.print("        try ww.{s}(alloc, {s});\n", .{ call, aname });
        }
    }
    try w.print("    }}\n\n", .{});
}

/// The single signature char for an arg type.
fn sigChar(t: ArgType) u8 {
    return switch (t) {
        .int => 'i',
        .uint => 'u',
        .fixed => 'f',
        .string => 's',
        .object => 'o',
        .new_id => 'n',
        .array => 'a',
        .fd => 'h',
    };
}

/// Build the libwayland wl_message.signature string for one message: optional
/// leading since-version digits (when since>1), then per-arg '?' (allow-null)
/// followed by the type char. Matches src/scanner.c get_signature.
fn buildSignature(gpa: std.mem.Allocator, msg: Message) ![]u8 {
    var s: std.ArrayList(u8) = .empty;
    errdefer s.deinit(gpa);
    if (msg.since) |since| {
        if (since > 1) {
            var dbuf: [12]u8 = undefined;
            const ds = std.fmt.bufPrint(&dbuf, "{d}", .{since}) catch unreachable;
            try s.appendSlice(gpa, ds);
        }
    }
    for (msg.args.items) |arg| {
        if (arg.allow_null) try s.append(gpa, '?');
        try s.append(gpa, sigChar(arg.arg_type));
    }
    return s.toOwnedSlice(gpa);
}

/// True if `name` is an interface defined in this same protocol file. Only those
/// can be referenced by `&<Pascal>.interface`; cross-protocol references (e.g.
/// xdg-shell referring to wl_surface) are emitted as null, since the runtime's
/// codec keys off the signature, not the types array, and the array only needs
/// to keep the right length. Matches libwayland treating the type as opaque when
/// the referenced interface lives in another file.
fn isLocalInterface(protocol: *const Protocol, name: []const u8) bool {
    for (protocol.interfaces.items) |i| {
        if (std.mem.eql(u8, i.name, name)) return true;
    }
    return false;
}

/// Emit one Message literal: `.{ .name = "..", .signature = "..", .types = &.{ .. } }`.
/// Object/new_id args with a locally-defined interface reference
/// `&<Pascal>.interface`; everything else (dynamic new_id, cross-protocol refs)
/// is null.
fn emitMessageLiteral(gpa: std.mem.Allocator, w: *std.Io.Writer, protocol: *const Protocol, msg: Message) !void {
    const sig = try buildSignature(gpa, msg);
    defer gpa.free(sig);
    try w.print("        .{{ .name = \"{s}\", .signature = \"{s}\", .types = &.{{", .{ msg.name, sig });
    var first = true;
    for (msg.args.items) |arg| {
        if (!(arg.arg_type == .object or arg.arg_type == .new_id)) continue;
        if (!first) try w.print(",", .{});
        first = false;
        if (arg.interface != null and isLocalInterface(protocol, arg.interface.?)) {
            const pascal = try toPascalCase(gpa, arg.interface.?);
            defer gpa.free(pascal);
            try w.print(" &{s}.interface", .{pascal});
        } else {
            try w.print(" null", .{});
        }
    }
    if (!first) try w.print(" ", .{});
    try w.print("}} }},\n", .{});
}

/// Emit the wl.Interface description table (wl_interface) for this interface.
fn emitInterfaceTable(gpa: std.mem.Allocator, w: *std.Io.Writer, protocol: *const Protocol, iface: Interface) !void {
    try w.print("    pub const interface: wl.Interface = .{{\n", .{});
    try w.print("        .name = \"{s}\",\n", .{iface.name});
    try w.print("        .version = {d},\n", .{iface.version});
    if (iface.requests.items.len == 0) {
        try w.print("        .requests = &.{{}},\n", .{});
    } else {
        try w.print("        .requests = &.{{\n", .{});
        for (iface.requests.items) |req| {
            try w.print("    ", .{});
            try emitMessageLiteral(gpa, w, protocol, req);
        }
        try w.print("        }},\n", .{});
    }
    if (iface.events.items.len == 0) {
        try w.print("        .events = &.{{}},\n", .{});
    } else {
        try w.print("        .events = &.{{\n", .{});
        for (iface.events.items) |ev| {
            try w.print("    ", .{});
            try emitMessageLiteral(gpa, w, protocol, ev);
        }
        try w.print("        }},\n", .{});
    }
    try w.print("    }};\n\n", .{});
}

/// A server-side parameter name: the XML arg name with a trailing '_' so it can
/// never shadow a generated decl (interface, dispatch, Implementation, version).
fn serverArgName(gpa: std.mem.Allocator, name: []const u8) ![]const u8 {
    const suffixed = try std.fmt.allocPrint(gpa, "{s}_", .{name});
    defer gpa.free(suffixed);
    return escapeName(gpa, suffixed);
}

/// The Zig parameter type for a server-side event sender / request handler arg.
/// object args become typed resource pointers; new_id is passed as a u32 id.
fn zigServerArgType(arg: Arg) []const u8 {
    return switch (arg.arg_type) {
        .int => if (arg.allow_null) "i32" else "i32",
        .uint => "u32",
        .fixed => "wl.Fixed",
        .string => if (arg.allow_null) "?[]const u8" else "[]const u8",
        .object => if (arg.allow_null) "?*wl.Object" else "*wl.Object",
        .new_id => "u32",
        .array => if (arg.allow_null) "?[]const u8" else "[]const u8",
        .fd => "i32",
    };
}

/// Emit one event sender: `pub fn send<Event>(resource_: *wl.Object, args...) void`
/// which builds the Argument array and calls resource_.postEvent(opcode, ...).
fn emitEventSender(gpa: std.mem.Allocator, w: *std.Io.Writer, ev: Message, opcode: usize) !void {
    const pascal = try toPascalCase(gpa, ev.name);
    defer gpa.free(pascal);
    try w.print("    pub fn send{s}(resource_: *wl.Object", .{pascal});
    for (ev.args.items) |arg| {
        const aname = try serverArgName(gpa, arg.name);
        defer gpa.free(aname);
        try w.print(", {s}: {s}", .{ aname, zigServerArgType(arg) });
    }
    try w.print(") void {{\n", .{});
    if (ev.args.items.len == 0) {
        try w.print("        resource_.postEvent({d}, &.{{}}) catch {{}};\n", .{opcode});
    } else {
        try w.print("        resource_.postEvent({d}, &.{{\n", .{opcode});
        for (ev.args.items) |arg| {
            const aname = try serverArgName(gpa, arg.name);
            defer gpa.free(aname);
            switch (arg.arg_type) {
                .int => try w.print("            .{{ .int = {s} }},\n", .{aname}),
                .uint => try w.print("            .{{ .uint = {s} }},\n", .{aname}),
                .fixed => try w.print("            .{{ .fixed = {s} }},\n", .{aname}),
                .string => try w.print("            .{{ .string = {s} }},\n", .{aname}),
                .object => {
                    if (arg.allow_null) {
                        try w.print("            .{{ .object = if ({s}) |o_| o_.id else 0 }},\n", .{aname});
                    } else {
                        try w.print("            .{{ .object = {s}.id }},\n", .{aname});
                    }
                },
                .new_id => try w.print("            .{{ .new_id = {s} }},\n", .{aname}),
                .array => try w.print("            .{{ .array = {s} }},\n", .{aname}),
                .fd => try w.print("            .{{ .fd = {s} }},\n", .{aname}),
            }
        }
        try w.print("        }}) catch {{}};\n", .{});
    }
    try w.print("    }}\n\n", .{});
}

/// Emit the typed request Implementation struct: one optional fn ptr per request.
fn emitImplementation(gpa: std.mem.Allocator, w: *std.Io.Writer, iface: Interface) !void {
    try w.print("    pub const Implementation = struct {{\n", .{});
    for (iface.requests.items) |req| {
        const fname = try escapeName(gpa, req.name);
        defer gpa.free(fname);
        try w.print("        {s}: ?*const fn (client_data: ?*anyopaque, resource: *wl.Object", .{fname});
        for (req.args.items) |arg| {
            const aname = try serverArgName(gpa, arg.name);
            defer gpa.free(aname);
            try w.print(", {s}: {s}", .{ aname, zigServerArgType(arg) });
        }
        try w.print(") void = null,\n", .{});
    }
    try w.print("    }};\n\n", .{});
}

/// Emit the per-interface dispatcher: demarshal each request body per its
/// signature, pull typed values, and call the matching Implementation fn.
fn emitDispatch(gpa: std.mem.Allocator, w: *std.Io.Writer, iface: Interface) !void {
    try w.print("    pub fn dispatch(resource_: *wl.Object, opcode_: u16, reader_: *wl.wire.Reader) c_int {{\n", .{});
    if (iface.requests.items.len == 0) {
        try w.print("        _ = resource_;\n", .{});
        try w.print("        _ = opcode_;\n", .{});
        try w.print("        _ = reader_;\n", .{});
        try w.print("        return 0;\n", .{});
        try w.print("    }}\n\n", .{});
        return;
    }
    // reader_ is only consumed by requests that carry args; discard it when
    // every request is argument-less so the parameter is not flagged unused.
    var any_args = false;
    for (iface.requests.items) |req| {
        if (req.args.items.len > 0) any_args = true;
    }
    if (!any_args) try w.print("        _ = reader_;\n", .{});
    try w.print("        const impl_ = @as(?*const Implementation, @ptrCast(@alignCast(resource_.implementation))) orelse return 0;\n", .{});
    try w.print("        switch (opcode_) {{\n", .{});
    for (iface.requests.items, 0..) |req, op| {
        const fname = try escapeName(gpa, req.name);
        defer gpa.free(fname);
        const nargs = req.args.items.len;
        try w.print("            {d} => {{\n", .{op});
        if (nargs == 0) {
            try w.print("                if (impl_.{s}) |f_| f_(resource_.user_data, resource_);\n", .{fname});
        } else {
            try w.print("                var args_: [{d}]wl.Argument = undefined;\n", .{nargs});
            try w.print("                wl.argument.demarshal(reader_, &resource_.client.conn.recv, interface.requests[{d}].signature, &args_) catch return -1;\n", .{op});
            try w.print("                if (impl_.{s}) |f_| f_(resource_.user_data, resource_", .{fname});
            for (req.args.items, 0..) |arg, ai| {
                switch (arg.arg_type) {
                    .int => try w.print(", args_[{d}].int", .{ai}),
                    .uint => try w.print(", args_[{d}].uint", .{ai}),
                    .fixed => try w.print(", args_[{d}].fixed", .{ai}),
                    .string => {
                        if (arg.allow_null) {
                            try w.print(", args_[{d}].string", .{ai});
                        } else {
                            try w.print(", args_[{d}].string orelse \"\"", .{ai});
                        }
                    },
                    .object => {
                        if (arg.allow_null) {
                            try w.print(", if (args_[{d}].object) |id_| resource_.client.getObject(id_) else null", .{ai});
                        } else {
                            try w.print(", resource_.client.getObject(args_[{d}].object orelse 0) orelse return -1", .{ai});
                        }
                    },
                    .new_id => try w.print(", args_[{d}].new_id", .{ai}),
                    .array => {
                        if (arg.allow_null) {
                            try w.print(", args_[{d}].array", .{ai});
                        } else {
                            try w.print(", args_[{d}].array orelse \"\"", .{ai});
                        }
                    },
                    .fd => try w.print(", args_[{d}].fd", .{ai}),
                }
            }
            try w.print(");\n", .{});
        }
        try w.print("                return 0;\n", .{});
        try w.print("            }},\n", .{});
    }
    try w.print("            else => return -1,\n", .{});
    try w.print("        }}\n", .{});
    try w.print("    }}\n\n", .{});
}

/// Emit setImplementation: attach the typed impl + install the dispatcher.
fn emitSetImplementation(w: *std.Io.Writer) !void {
    try w.print("    pub fn setImplementation(resource_: *wl.Object, impl_: *const Implementation, data_: ?*anyopaque, destroy_: ?wl.server_client.ResourceDestroyFn) void {{\n", .{});
    try w.print("        resource_.setImplementation(impl_, data_, destroy_);\n", .{});
    try w.print("        resource_.dispatcher = dispatch;\n", .{});
    try w.print("    }}\n\n", .{});
}

fn emitInterface(gpa: std.mem.Allocator, w: *std.Io.Writer, protocol: *const Protocol, iface: Interface) !void {
    const struct_name = try toPascalCase(gpa, iface.name);
    defer gpa.free(struct_name);

    if (iface.description) |d| {
        try emitDocComment(w, d, "");
    }
    try w.print("pub const {s} = struct {{\n", .{struct_name});
    try w.print("    pub const interface_name: []const u8 = \"{s}\";\n", .{iface.name});
    try w.print("    pub const version: u32 = {d};\n\n", .{iface.version});

    for (iface.enums.items) |enm| {
        try emitEnum(gpa, w, enm);
    }

    try emitOpcodesEnum(gpa, w, "RequestOpcode", iface.requests.items);
    try emitOpcodesEnum(gpa, w, "EventOpcode", iface.events.items);
    try emitEventUnion(gpa, w, iface.events.items);

    for (iface.requests.items, 0..) |req, i| {
        try emitRequestMethod(gpa, w, req, i);
    }

    // ---- Server side (libwayland-server parity) ----
    try w.print("    // --- server side (wl_interface table, event senders, request dispatch) ---\n\n", .{});
    try emitInterfaceTable(gpa, w, protocol, iface);
    for (iface.events.items, 0..) |ev, i| {
        try emitEventSender(gpa, w, ev, i);
    }
    try emitImplementation(gpa, w, iface);
    try emitDispatch(gpa, w, iface);
    try emitSetImplementation(w);

    try w.print("}};\n\n", .{});
}

fn generate(gpa: std.mem.Allocator, protocol: Protocol, w: *std.Io.Writer) !void {
    try w.print("// This file is generated by the Wayland protocol generator.\n", .{});
    try w.print("// Do not edit manually.\n\n", .{});
    try w.print("const std = @import(\"std\");\n", .{});
    // The abstract wayland runtime module. `core` is kept as a back-compat alias
    // for the client-side request senders; the server-side output names it `wl`.
    try w.print("const wl = @import(\"wayland\");\n", .{});
    try w.print("const core = wl;\n\n", .{});
    try w.print("/// Protocol: {s}\n", .{protocol.name});
    try w.print("pub const protocol_name: []const u8 = \"{s}\";\n\n", .{protocol.name});

    for (protocol.interfaces.items) |iface| {
        try emitInterface(gpa, w, &protocol, iface);
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 3) {
        var stderr_buf: [256]u8 = undefined;
        var stderr_fw = std.Io.File.stderr().writer(io, &stderr_buf);
        const stderr = &stderr_fw.interface;
        try stderr.writeAll("usage: wayland-gen <protocol.xml> <output.zig>\n");
        try stderr.flush();
        std.process.exit(1);
    }

    const xml_path = args[1];
    const out_path = args[2];

    // Read the input XML file
    const xml_data = try std.Io.Dir.cwd().readFileAlloc(io, xml_path, gpa, std.Io.Limit.unlimited);
    defer gpa.free(xml_data);

    // Set up zig-xml reader over the in-memory data
    var static_reader: xml.Reader.Static = .init(gpa, xml_data, .{
        .namespace_aware = false,
    });
    defer static_reader.deinit();

    var parser: Parser = Parser.init(gpa, &static_reader.interface);
    defer parser.deinit();

    try parser.parse();

    var protocol = parser.protocol;
    defer protocol.deinit(gpa);

    // Generate into an Allocating buffer
    var out_buf: std.Io.Writer.Allocating = .init(gpa);
    defer out_buf.deinit();

    try generate(gpa, protocol, &out_buf.writer);

    const generated = try out_buf.toOwnedSlice();
    defer gpa.free(generated);

    // Write to the output file using Dir.writeFile
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = out_path,
        .data = generated,
    });
}
