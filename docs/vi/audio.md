<a id="audio"></a>

# Âm thanh

`myzig.audio` phát âm thanh từ Zig: các hiệu ứng được giải mã một lần vào bộ nhớ và phát thường xuyên như âm thanh của chúng, nhạc phát trực tuyến từ một tệp khi nó phát và âm thanh do ứng dụng tự tạo ra, của bộ tổng hợp hoặc của trò chơi. myzig trộn các trình phát và gửi chúng đến đầu ra của hệ thống, đầu ra này sẽ tải khi nội dung nào đó phát lần đầu: một ứng dụng không phát không liên kết gì với nó và một ứng dụng đã ngừng phát sẽ đóng thiết bị sau đó vài giây.

```zig
const std = @import("std");
const myzig = @import("myzig");
const audio = myzig.audio;

pub fn main(init: std.process.Init) !void {
    const engine = try audio.Engine.create(init.gpa, init.io, .{});
    defer engine.destroy();

    const hoe = try engine.decodeSound(@embedFile("hoe.wav")); // decoded once
    defer hoe.release();
    engine.play(hoe); // as often as it sounds, over itself

    const music = try engine.openStream("spring.wav"); // decoded as it plays
    music.setLoop(true).setVolume(0.6).play();
    // ...
}
```

Ví dụ `piano` phát các nốt mà nó tổng hợp và ví dụ `farm` (`examples/farm`) có các hiệu ứng và giai điệu được tạo ra khi nó phát.

<a id="the-engine"></a>

## Động cơ

`audio.Engine.create(gpa, io, options)` chế tạo động cơ; `destroy` dừng mọi thứ và đóng đầu ra. `gpa` phải an toàn trước một số luồng: người chơi được phân bổ trên các luồng của ứng dụng và được giải phóng sau khi luồng của đầu ra để họ rời đi. Mọi phương pháp của công cụ và người chơi của nó đều an toàn trước mọi luồng.

`audio.Options` có:

- `device`: `.system` phát trên đầu ra mặc định của hệ thống. `.manual` không mở: ứng dụng hoặc kiểm thử sẽ tự kéo các frame hỗn hợp bằng `engine.render(out)`, khung này sẽ lấp đầy các frame âm thanh nổi xen kẽ tại `audio.rate` và trả về xem có phát bất kỳ thứ gì hay không. Ví dụ `piano` sử dụng nó khi nó chạy headless (`--myzig-hidden`, `--myzig-snapshot`), vì vậy các kiểm thử của nó không phát ra âm thanh.
- `idle_close_ms`: thời gian đầu ra vẫn mở khi không phát (5000).

`engine.setVolume(v)` đặt âm lượng của mọi thứ, 1 là được giải mã.

<a id="sounds-and-streams"></a>

## Âm thanh và luồng

`Sound` chứa các mẫu đã được giải mã trong bộ nhớ mà bất kỳ số lượng người chơi nào cũng đọc cùng một lúc. Nó được tính tham chiếu: `release` khi ứng dụng hoàn tất và nó sẽ được giải phóng sau khi người chơi cuối cùng của nó cũng biến mất.

- `engine.decodeSound(bytes)` giải mã tệp WAV, Ogg Vorbis hoặc MP3 (được biểu thị bằng byte đầu tiên) trong bộ nhớ (byte của `@embedFile` hoặc tệp được đọc) thành âm thanh, sao chép những gì nó cần.
- `engine.newSound(sample_rate, channels, samples)` tạo ra âm thanh của các mẫu mà ứng dụng tính toán, các phao xen kẽ được phân bổ với `gpa` của động cơ mà âm thanh sẽ sử dụng.

Luồng giải mã khi phát, đối với nhạc quá lâu không được lưu trong bộ nhớ hoặc đối với âm thanh mà ứng dụng tạo ra khi phát:

- `engine.openStream(path)` trả về trình phát bị tạm dừng của tệp WAV, Ogg Vorbis hoặc MP3 (được biểu thị bằng byte đầu tiên của nó).
- `engine.newStreamPlayer(decoder)` trả về trình phát bị tạm dừng của bất kỳ `audio.Decoder` nào, trình phát này sẽ đóng cùng với trình phát.

`Decoder` là giao diện của ứng dụng: `ptr`, `vtable` của `read`, `seek` và `deinit`, `rate`, `channels` và `frames` (null cho luồng vô tận). `read` lấp đầy bộ đệm với toàn bộ số khung float xen kẽ và trả về số lượng nó đọc được, chỉ 0 ở cuối:

```zig
const Tone = struct {
    gpa: std.mem.Allocator,
    pos: u64 = 0,

    fn decoder(gpa: std.mem.Allocator) !audio.Decoder {
        const t = try gpa.create(Tone);
        t.* = .{ .gpa = gpa };
        return .{ .ptr = t, .vtable = &vtable, .rate = 48000, .channels = 1, .frames = null };
    }

    const vtable: audio.Decoder.VTable = .{ .read = read, .seek = seek, .deinit = deinit };

    fn read(p: *anyopaque, dst: []f32) anyerror!usize {
        const t: *Tone = @ptrCast(@alignCast(p));
        for (dst) |*s| {
            s.* = 0.2 * @sin(2 * std.math.pi * 440 * @as(f32, @floatFromInt(t.pos)) / 48000);
            t.pos += 1;
        }
        return dst.len; // mono: one sample a frame
    }
    fn seek(p: *anyopaque, frame: u64) anyerror!void {
        const t: *Tone = @ptrCast(@alignCast(p));
        t.pos = frame;
    }
    fn deinit(p: *anyopaque) void {
        const t: *Tone = @ptrCast(@alignCast(p));
        t.gpa.destroy(t);
    }
};

const tone = try engine.newStreamPlayer(try Tone.decoder(gpa));
tone.play();
```

`read` chạy trên luồng đầu ra, dưới khóa của bộ trộn: nó phải nhanh và không được đợi trên luồng chính.

<a id="players"></a>

## Người chơi

`engine.play(sound)` phát âm thanh một lần, trong trình phát riêng của nó, được giải phóng khi kết thúc: muốn có hiệu ứng gì. Để kiểm soát nhiều hơn, `engine.newPlayer(sound)` trả về `Player` bị tạm dừng để thiết lập trước. Một người chơi:

- `play()` phát từ vị trí cũ và sau khi kết thúc lại bắt đầu lại; `pause()` tạm dừng, mờ dần trong 5 mili giây; `stop()` tạm dừng và quay lại từ đầu.
- `playing()` cho biết trò chơi có phát hay không: false ở cuối, vì vậy trò chơi có thể chờ âm thanh.
- `seek(seconds)` di chuyển; `position()` là vị trí của nó và `duration()` thời lượng phát (null khi vô tận hoặc không xác định), tính bằng giây.
- `setVolume(x)` (1 là đã giải mã, 0 im lặng), `setPan(x)` (-1 trái đến 1 phải), `setSpeed(x)` (tốc độ và cao độ cùng nhau, như một bản ghi: 2 là cao hơn một quãng tám), `setLoop(on)` (bắt đầu lại ở cuối, không có khoảng trống) và `setLoopRange(start, end)` (vòng lặp từ `end`, null ở cuối, quay lại `start`: phần giới thiệu của một giai điệu phát một lần rồi lặp lại). Họ trả lại người chơi để xâu chuỗi họ.
- `release()` để nó đi: nó phát đến hết hoặc tạm dừng, sau đó nó được giải phóng. Người chơi không thể được sử dụng sau đó.

```zig
const step = try engine.newPlayer(footstep);
step.setPan(-0.4).setSpeed(1.1).play();
step.release();
```

Bắt đầu, tạm dừng và tìm kiếm ở giữa âm thanh nhỏ dần và nhỏ dần trong hơn 5 mili giây nên không tạo ra tiếng click.

<a id="formats"></a>

## Định dạng

`audio.wav` đọc các tệp WAV có PCM số nguyên từ 8 đến 32 bit và số float 32 hoặc 64 bit, ở bất kỳ tốc độ nào và với bất kỳ số lượng kênh nào, từ bộ nhớ hoặc từ một tệp khi chúng phát. `audio.wav.write(writer, samples, rate, channels, .pcm16)` (hoặc `.float32`) ghi các mẫu float dưới dạng tệp WAV, kiểm thử ghi lại công cụ `manual` sẽ tiết kiệm được bao nhiêu.

`audio.vorbis` giải mã Ogg Vorbis (tầng 0 và 1, tồn tại 0–2, mọi kênh) và `audio.mp3` giải mã MPEG-1/2/2.5 lớp III (không có khoảng cách với thẻ LAME, ID3v2 bị bỏ qua). Cả hai đều giải mã khi chúng phát, từ bộ nhớ hoặc tệp và cả hai đều tìm kiếm. Các định dạng khác: `Decoder` của ứng dụng.

<a id="the-output"></a>

## Đầu ra

Động cơ trộn ở tần số 48 kHz ở dạng âm thanh nổi (`audio.rate`, `audio.channels`), tiến về phía trước khoảng 40 mili giây, trên một luồng riêng, ở chế độ ngủ trong khi không có gì phát. Người chơi ở các mức giá khác được lấy mẫu lại khi họ chơi, trên đường trục Catmull-Rom; âm thanh đơn âm phát ở cả hai loa và chuyển đổi giữa chúng.

| | đầu ra | đã nạp |
|---|---|---|
| macOS | Hàng đợi âm thanh trên đầu ra mặc định, theo sau nó | Hộp công cụ âm thanh, với `dlopen` |
| Linux | API đơn giản của PulseAudio (mà PipeWire cũng phục vụ), thiết bị mặc định khác của ALSA | với `dlopen` |
| Windows | WASAPI ở chế độ chia sẻ trên đầu ra mặc định, được mở lại khi mặc định thay đổi hoặc thiết bị gặp sự cố | COM |
| trình duyệt | chưa có | |

Khi không có đầu ra nào mở ra (không có máy chủ âm thanh, không có thiết bị, trình duyệt), người chơi vẫn chơi đúng giờ, không nghe thấy, vì vậy họ kết thúc khi đáng lẽ phải chơi và `engine.outputError()` cho biết lý do. Động cơ sẽ thử lại thiết bị thực sau một thời gian.
