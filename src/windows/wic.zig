//! Pictures Windows decodes, with the Windows Imaging Component: JPEG, GIF
//! (its first frame), BMP, TIFF, ICO, WebP and HEIC where their codecs are
//! installed, and PNG. Out: premultiplied BGRA, as myzig's PNG decoder.
const std = @import("std");
const com = @import("com.zig");

extern "ole32" fn CoCreateInstance(clsid: *const com.GUID, outer: ?*anyopaque, ctx: u32, iid: *const com.GUID, out: *?com.Object) callconv(.winapi) com.HRESULT;

const CLSID_WICImagingFactory = com.GUID.parse("cacaf262-9370-4615-a13b-9f5539da4c0a");
const IID_IWICImagingFactory = com.GUID.parse("ec5ec8a9-c395-4314-9c77-54d7a935ff70");
const GUID_WICPixelFormat32bppPBGRA = com.GUID.parse("6fddc324-4e03-4bfe-b185-3d77768dc910");

pub const Decoded = struct { width: u32, height: u32, bgra: []u8 };

/// Methods by their index in the vtables.
const factory_create_decoder_from_stream = 4;
const factory_create_format_converter = 10;
const factory_create_stream = 14;
const stream_initialize_from_memory = 16;
const decoder_get_frame = 13;
const source_get_size = 3;
const source_copy_pixels = 7;
const converter_initialize = 8;

pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) !Decoded {
    if (bytes.len == 0 or bytes.len > std.math.maxInt(u32)) return error.NotAPicture;
    _ = com.CoInitializeEx(null, 0x2);
    var factory: ?com.Object = null;
    if (com.failed(CoCreateInstance(&CLSID_WICImagingFactory, null, 1, &IID_IWICImagingFactory, &factory))) return error.Wic;
    defer com.release(factory);
    var stream: ?com.Object = null;
    if (com.failed(com.call(factory.?, factory_create_stream, .{&stream}))) return error.Wic;
    defer com.release(stream);
    if (com.failed(com.call(stream.?, stream_initialize_from_memory, .{ bytes.ptr, @as(u32, @intCast(bytes.len)) }))) return error.Wic;
    var decoder: ?com.Object = null;
    // WICDecodeMetadataCacheOnDemand.
    if (com.failed(com.call(factory.?, factory_create_decoder_from_stream, .{ stream.?, @as(?*const com.GUID, null), @as(u32, 0), &decoder }))) return error.NotAPicture;
    defer com.release(decoder);
    var frame: ?com.Object = null;
    if (com.failed(com.call(decoder.?, decoder_get_frame, .{ @as(u32, 0), &frame }))) return error.NotAPicture;
    defer com.release(frame);
    var conv: ?com.Object = null;
    if (com.failed(com.call(factory.?, factory_create_format_converter, .{&conv}))) return error.Wic;
    defer com.release(conv);
    // No dither, no palette, alpha threshold 0, custom palette type.
    if (com.failed(com.call(conv.?, converter_initialize, .{ frame.?, &GUID_WICPixelFormat32bppPBGRA, @as(u32, 0), @as(?*anyopaque, null), @as(f64, 0), @as(u32, 0) }))) return error.Wic;
    var w: u32 = 0;
    var h: u32 = 0;
    if (com.failed(com.call(conv.?, source_get_size, .{ &w, &h }))) return error.Wic;
    if (w == 0 or h == 0 or @as(u64, w) * h > 64 << 20) return error.NotAPicture;
    const stride = w * 4;
    const out = try gpa.alloc(u8, @as(usize, stride) * h);
    errdefer gpa.free(out);
    if (com.failed(com.call(conv.?, source_copy_pixels, .{ @as(?*const anyopaque, null), stride, @as(u32, @intCast(out.len)), out.ptr }))) return error.Wic;
    return .{ .width = w, .height = h, .bgra = out };
}
