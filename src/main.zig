var stdin_buf: [4096]u8 = undefined;
var stdout_buf: [4096]u8 = undefined;

pub fn main() !void {
    var dbg_inst: std.heap.DebugAllocator(.{}) = .init;
    defer assert(dbg_inst.deinit() == .ok);
    const gpa = dbg_inst.allocator();

    var stdin_reader: File.Reader = .initStreaming(.stdin(), &stdin_buf);
    var stdout_writer: File.Writer = .initStreaming(.stdout(), &stdout_buf);
    const tty: std.Io.tty.Config = .detect(.stdout());

    var console: Console = .init(
        &stdin_reader.interface,
        &stdout_writer.interface,
        tty,
    );

    var save: Save = .empty;
    defer save.deinit(gpa);

    var ctx: Context = .{
        .gpa = gpa,
        .console = &console,
        .save = &save,
    };

    juicyMain(&ctx) catch |err| {
        try console.deinit();
        save.deinit(gpa);

        assert(dbg_inst.deinit() == .ok); // make sure we didn't leak first
        switch (err) {
            error.WriteFailed => std.process.fatal("stdout error: {t}", .{stdout_writer.err.?}),
            error.ReadFailed => std.process.fatal("stdin error: {t}", .{stdin_reader.err.?}),
            error.EndOfStream => std.process.exit(1), // just exit, don't report
            error.OutOfMemory => std.process.fatal("Out Of memory", .{}),
        }
    };

    try console.deinit();
}

const Context = struct {
    gpa: Allocator,
    console: *Console,
    save: *Save,
};

const prefix = "> ";

const Error = Reader.Error || Writer.Error || Allocator.Error;
pub fn juicyMain(ctx: *Context) Error!void {
    const console = ctx.console;

    const eql = std.ascii.eqlIgnoreCase;
    while (true) {
        const command = try console.ask(&.{prefix});

        if (eql("list", command)) {
            try listQuestions(ctx);
        } else if (eql("add", command)) {
            try addItem(ctx);
        } else if (eql("ask", command)) {
            try askItems(ctx);
        } else if (eql("save", command)) {
            const file = std.fs.cwd().createFileZ("test.save", .{}) catch @panic("a");
            defer file.close();

            var buf: [1024]u8 = undefined;
            var file_writer: std.fs.File.Writer = .init(file, &buf);

            ctx.save.serialize(&file_writer.interface) catch @panic("a");

            file_writer.interface.flush() catch unreachable;
        } else if (eql("load", command)) {
            const file = std.fs.cwd().openFileZ("test.save", .{}) catch @panic("a");
            defer file.close();

            var buf: [1024]u8 = undefined;
            var file_reader: std.fs.File.Reader = .init(file, &buf);

            ctx.save.deinit(ctx.gpa);
            ctx.save.* = Save.deserialize(ctx.gpa, &file_reader.interface) catch @panic("a");
        } else if (eql("warp", command)) {
            const num_txt = try console.ask(&.{ "How much? (H)\n", prefix });
            const num = std.fmt.parseInt(u32, num_txt, 0) catch @panic("Fuck you");

            const srs_list: []Save.Srs = ctx.save.items.items(.srs);
            for (srs_list) |*srs| {
                srs.deadline_hour -= num;
            }
        } else {
            try help(ctx);
        }
    }
}

fn help(ctx: *Context) Error!void {
    try ctx.console.writeLn("Help:");

    try ctx.console.print("Not done yet\n", .{});
}

fn askItems(ctx: *Context) Error!void {
    const console = ctx.console;
    const save = ctx.save;
    const gpa = ctx.gpa;

    const st = &save.string_table;

    const IndexedItem = struct { idx: usize, item: Save.Item };

    var questions: ArrayList(IndexedItem) = .empty;
    defer questions.deinit(gpa);

    const srs_slice: []Save.Srs = save.items.items(.srs);

    for (srs_slice, 0..) |srs, idx| {
        if (srs.timeUntil() != 0) continue;

        try questions.append(gpa, .{ .idx = idx, .item = save.items.get(idx) });
    }

    var scratch: ArrayList(IndexedItem) = try .initCapacity(gpa, questions.items.len);
    defer scratch.deinit(gpa);

    try console.print("Found {d} questions to be asked\n", .{questions.items.len});

    var current: *ArrayList(IndexedItem) = &questions;
    var next: *ArrayList(IndexedItem) = &scratch;

    var round: u32 = 0;
    while (current.items.len > 0) : (round += 1) {
        defer {
            std.mem.swap(*ArrayList(IndexedItem), &current, &next);
            next.clearRetainingCapacity();
        }

        for (current.items) |indexed_item| {
            const idx = indexed_item.idx;
            const item = &indexed_item.item;

            const question = item.question();
            const answers = item.answers(save);

            const answer = try console.ask(&.{ question.bytes(st), "\n", prefix });
            std.log.info("said: '{s}'", .{answer});

            const eql = std.ascii.eqlIgnoreCase;
            const correct = loop: for (answers) |ans| {
                std.log.info("Checking: '{s}' ({d})", .{ ans.bytes(st), @intFromEnum(ans) });
                if (eql(answer, ans.bytes(st))) {
                    break :loop true;
                }
            } else false;

            std.log.info("Correct: {}", .{correct});

            if (correct) {
                srs_slice[idx] = srs_slice[idx].nextDeadline(round == 0);

                try console.writeLn("Correct!");
            } else {
                next.appendAssumeCapacity(indexed_item);

                try console.writeLn("Incorrect:");
                try console.printLn("\tYou said '{s}'", .{answer});
                try console.writeLn("\tAnswer could be one of:");
                for (answers) |ans| {
                    try console.printLn("\t\t{f}", .{ans.fmt(st)});
                }
            }

            try console.write("\n");
        }
    }
}

fn addItem(ctx: *Context) Error!void {
    const console = ctx.console;
    const save = ctx.save;
    const gpa = ctx.gpa;

    const st = &save.string_table;

    const question = try st.put(gpa, try console.ask(&.{ "Question\n", prefix }));
    const answer = try st.put(gpa, try console.ask(&.{ "Answer\n", prefix }));

    try save.putSimpleQuestion(gpa, question, answer);
}

fn listQuestions(ctx: *Context) Error!void {
    const console = ctx.console;
    const save = ctx.save;

    const st = &save.string_table;

    try ctx.console.writeLn("Listing all questions:\n");

    for (0..save.items.len) |idx| {
        const item = save.items.get(idx);

        try console.print("Srs deadline in {D}\n", .{item.srs.timeUntil()});

        switch (item.type) {
            // * Left is question `String`.
            // * Right is answer `String`.
            .question_simple => {
                const question = item.left.asString();
                const answer = item.right.asString();

                try console.print(
                    "simple question: {f} => {f}\n",
                    .{ question.fmt(st), answer.fmt(st) },
                );
            },

            // * Left is question `String`.
            // * Right is `StringSliceIndex` into extra.
            .question_multi => {
                const question = item.left.asString();
                const answers = item.right.asStringSliceIndex().get(save);

                try console.print("multi question: {f} =>\n", .{question.fmt(st)});
                for (answers) |answer| {
                    try console.print("\t{f}\n", .{answer.fmt(st)});
                }
            },
        }

        try ctx.console.write("\n");
    }
}

test {
    _ = &Save;
    _ = &Console;
}

const std = @import("std");

const assert = std.debug.assert;

const Save = @import("Save.zig");
const Console = @import("Console.zig");
const Io = std.Io;
const File = std.fs.File;
const Reader = Io.Reader;
const Writer = Io.Writer;
const Config = Io.tty.Config;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
