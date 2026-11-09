//! Assemble kitty OSC 99 chunks into a desktop notification.
//!
//! The upstream parser (kitty_desktop_notification.zig) returns one raw
//! chunk per sequence and leaves delivery to the consumer. term-mesh shows
//! these as desktop notifications, so the stream joins title and body chunks
//! that share an `i` identifier until a chunk arrives with `d=1`.

const std = @import("std");

const Parser = @import("../../osc.zig").Parser;
const encoding = @import("../encoding.zig");
const kitty_desktop_notification = @import("kitty_desktop_notification.zig");

const log = std.log.scoped(.osc_kitty_notification);

pub const Notification = struct {
    title: [:0]const u8,
    body: [:0]const u8,
};

const Target = enum { title, body };

/// Feed one parsed OSC 99 chunk. Returns the notification once the final
/// chunk arrives; the returned slices stay valid until the next call.
pub fn assemble(
    pending: *Parser.KittyNotificationPending,
    osc: kitty_desktop_notification.OSC,
) ?Notification {
    const target: Target = switch (osc.readOption(.p)) {
        .title => .title,
        .body => .body,
        else => return null,
    };

    var decoded: [Parser.MAX_BUF]u8 = undefined;
    const payload: []const u8 = if (osc.readOption(.e)) payload: {
        const decoder = std.base64.standard.Decoder;
        const len = decoder.calcSizeForSlice(osc.payload) catch return null;
        if (len > decoded.len) return null;
        decoder.decode(decoded[0..len], osc.payload) catch return null;
        break :payload decoded[0..len];
    } else osc.payload;

    if (!encoding.isSafeUtf8(payload)) return null;

    if (osc.readOption(.i)) |id| {
        if (!pending.active or !std.mem.eql(u8, pending.idSlice(), id)) {
            pending.reset();
            pending.active = true;
            pending.id_len = @min(id.len, pending.id.len);
            @memcpy(pending.id[0..pending.id_len], id[0..pending.id_len]);
        }
    } else {
        pending.reset();
        pending.active = true;
    }

    const ok = switch (target) {
        .title => appendBuffer(&pending.title, &pending.title_len, payload),
        .body => appendBuffer(&pending.body, &pending.body_len, payload),
    };
    if (!ok) {
        pending.reset();
        return null;
    }

    if (!osc.readOption(.d)) return null;

    if (pending.title_len == 0 and pending.body_len == 0) {
        pending.reset();
        return null;
    }

    pending.title[pending.title_len] = 0;
    pending.body[pending.body_len] = 0;

    var result: Notification = .{
        .title = pending.title[0..pending.title_len :0],
        .body = pending.body[0..pending.body_len :0],
    };
    if (pending.title_len == 0) {
        result = .{ .title = result.body, .body = "" };
    }

    // Lengths reset for the next notification; the buffers keep the bytes
    // the returned slices point at.
    pending.reset();
    return result;
}

fn appendBuffer(buffer: *[Parser.MAX_BUF]u8, len: *usize, payload: []const u8) bool {
    if (payload.len == 0) return true;
    if (len.* + payload.len >= buffer.len) {
        log.warn("kitty notification payload too large (len={d})", .{payload.len});
        return false;
    }
    @memcpy(buffer[len.* .. len.* + payload.len], payload);
    len.* += payload.len;
    return true;
}

fn feed(p: *Parser, pending: *Parser.KittyNotificationPending, input: []const u8) ?Notification {
    p.reset();
    for (input) |ch| p.next(ch);
    const cmd = p.end('\x1b') orelse return null;
    return assemble(pending, cmd.kitty_desktop_notification);
}

test "OSC 99: kitty notification with title only" {
    const testing = std.testing;
    var p: Parser = .init(testing.allocator);
    defer p.deinit();
    var pending: Parser.KittyNotificationPending = .{};

    const n = feed(&p, &pending, "99;;Hello Kitty").?;
    try testing.expectEqualStrings("Hello Kitty", n.title);
    try testing.expectEqualStrings("", n.body);
}

test "OSC 99: kitty notification with title and body chunks" {
    const testing = std.testing;
    var p: Parser = .init(testing.allocator);
    defer p.deinit();
    var pending: Parser.KittyNotificationPending = .{};

    try testing.expect(feed(&p, &pending, "99;i=abc:d=0:p=title;Kitty Title") == null);
    const n = feed(&p, &pending, "99;i=abc:p=body;Kitty Body").?;
    try testing.expectEqualStrings("Kitty Title", n.title);
    try testing.expectEqualStrings("Kitty Body", n.body);
}

test "OSC 99: kitty notification decodes base64 and promotes a lone body" {
    const testing = std.testing;
    var p: Parser = .init(testing.allocator);
    defer p.deinit();
    var pending: Parser.KittyNotificationPending = .{};

    // "7ZWc6riA" is base64 for "한글".
    const n = feed(&p, &pending, "99;e=1:p=body;7ZWc6riA").?;
    try testing.expectEqualStrings("한글", n.title);
    try testing.expectEqualStrings("", n.body);
}

test "OSC 99: kitty notification ignores close and query payloads" {
    const testing = std.testing;
    var p: Parser = .init(testing.allocator);
    defer p.deinit();
    var pending: Parser.KittyNotificationPending = .{};

    try testing.expect(feed(&p, &pending, "99;p=close;") == null);
    try testing.expect(feed(&p, &pending, "99;p=?;") == null);
}
