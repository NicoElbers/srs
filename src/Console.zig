stdin: *Reader,
stdout: *Writer,
config: Config,

const Console = @This();

pub fn init(stdin: *Reader, stdout: *Writer, config: Config) Console {
    // TODO: See if we want to find the width of the console

    return .{
        .stdin = stdin,
        .stdout = stdout,
        .config = config,
    };
}

pub fn deinit(self: *Console) Writer.Error!void {
    try self.flush();

    self.* = undefined;
}

pub fn flush(self: *Console) Writer.Error!void {
    try self.stdout.flush();
}

const ReadLineError = error{ ReadFailed, StreamTooLong };
pub fn readLine(self: *Console) ReadLineError!?[]const u8 {
    return self.stdin.takeDelimiter('\n');
}

test readLine {
    const stdin_text = "hello\nworld\nend";

    var stdin: Reader = .fixed(stdin_text);
    var stdout: Writer = .failing;

    var console: Console = .init(&stdin, &stdout, .no_color);

    try std.testing.expectEqualStrings("hello", (try console.readLine()).?);
    try std.testing.expectEqualStrings("world", (try console.readLine()).?);
    try std.testing.expectEqualStrings("end", (try console.readLine()).?);
    try std.testing.expectEqual(null, try console.readLine());

    try console.deinit();
}

pub fn write(self: *Console, bytes: []const u8) Writer.Error!void {
    return self.stdout.writeAll(bytes);
}

pub fn writeLn(self: *Console, bytes: []const u8) Writer.Error!void {
    return self.writeVecConst(&.{ bytes, "\n" });
}

pub fn writeVecConst(self: *Console, vec: []const []const u8) Writer.Error!void {
    var var_vec: [5][]const u8 = undefined;
    var rem_vec = vec;

    while (rem_vec.len > 0) {
        const end = @min(var_vec.len, rem_vec.len);

        @memcpy(var_vec[0..end], rem_vec[0..end]);
        rem_vec = rem_vec[end..];

        try self.stdout.writeVecAll(var_vec[0..end]);
    }
}

const AskError = error{ WriteFailed, ReadFailed, EndOfStream };
pub fn ask(self: *Console, question: []const []const u8) AskError![]const u8 {
    try self.writeVecConst(question);
    try self.stdout.flush();

    const answer = loop: while (true) {
        break :loop self.stdin.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => return error.ReadFailed,
            error.StreamTooLong => {
                _ = try self.stdin.discardDelimiterInclusive('\n');

                try self.write("Your answer was too long, please try again\n");
                continue;
            },
        };
    };

    return answer orelse return error.EndOfStream;
}

test ask {
    const prefix = "> ";
    const question = "question";
    const answer = "answer";

    var stdout_buf: [100]u8 = undefined;
    const stdin_text = answer;

    var stdout: Writer = .fixed(&stdout_buf);
    var stdin: Reader = .fixed(stdin_text);

    var console: Console = .init(&stdin, &stdout, .no_color);

    try std.testing.expectEqualStrings(answer, try console.ask(&.{ prefix, question }));
    try std.testing.expectEqualStrings(prefix ++ question, stdout.buffered());
    try std.testing.expectError(error.EndOfStream, console.ask(&.{ prefix, question }));

    try console.deinit();
}

pub fn print(self: *Console, comptime fmt: []const u8, args: anytype) Writer.Error!void {
    return self.stdout.print(fmt, args);
}

pub fn printLn(self: *Console, comptime fmt: []const u8, args: anytype) Writer.Error!void {
    return self.print(fmt ++ "\n", args);
}

const std = @import("std");

const Io = std.Io;
const Reader = Io.Reader;
const Writer = Io.Writer;
const Config = Io.tty.Config;
