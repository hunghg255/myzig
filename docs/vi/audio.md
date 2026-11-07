<a id="audio"></a>

# Âm thanh

`myzig.audio` phát âm thanh từ Zig: hiệu ứng âm thanh, nhạc, và âm thanh do app tự tạo ra.

```zig
const std = @import("std");
const myzig = @import("myzig");
const audio = myzig.audio;

pub fn main(init: std.process.Init) !void {
    const engine = try audio.Engine.create(init.gpa, init.io, .{});
    defer engine.destroy();

    const hoe = try engine.decodeSound(@embedFile("hoe.wav")); // giải mã một lần
    defer hoe.release();
    engine.play(hoe); // phát bao nhiêu lần cũng được, chồng lên nhau

    const music = try engine.openStream("spring.wav"); // giải mã trong lúc phát
    music.setLoop(true).setVolume(0.6).play();
    // ...
}
```

- Hiệu ứng được giải mã một lần vào bộ nhớ và phát bao nhiêu lần tùy ý.
- Nhạc được stream từ file trong lúc phát.
- Âm thanh app tự tạo, của một bộ tổng hợp âm hay của game, cũng phát được.
- myzig trộn các player lại và gửi tới đầu ra âm thanh của hệ thống.
- Đầu ra chỉ được nạp khi có thứ gì đó phát lần đầu. App không phát gì thì không link gì của nó.
- App ngừng phát thì đóng thiết bị sau vài giây.

Ví dụ `piano` phát các nốt do nó tự tổng hợp. Ví dụ `farm` (`examples/farm`) có hiệu ứng và một giai điệu tạo ra trong lúc phát.

<a id="the-engine"></a>

## Engine

`audio.Engine.create(gpa, io, options)` tạo engine. `destroy` dừng mọi thứ và đóng đầu ra.

- `gpa` phải an toàn khi dùng từ nhiều thread. Player được cấp phát trên các thread của app và được giải phóng sau khi thread của đầu ra đã buông chúng.
- Mọi method của engine và player đều an toàn khi gọi từ bất kỳ thread nào.
- `engine.setVolume(v)` đặt âm lượng chung, 1 là giữ nguyên như khi giải mã.

`audio.Options`:

| Trường | Mặc định | |
|---|---|---|
| `device` | `.system` | `.system` phát trên đầu ra mặc định của hệ thống; `.manual` không mở đầu ra nào |
| `idle_close_ms` | 5000 | đầu ra còn mở bao lâu khi không có gì phát |

Với `.manual`, app hoặc test tự lấy các frame đã trộn bằng `engine.render(out)`. Hàm này điền các frame stereo xen kẽ ở `audio.rate` và trả về có gì đã phát hay không. Ví dụ `piano` dùng chế độ này khi chạy headless (`--myzig-hidden`, `--myzig-snapshot`), nên test của nó không phát ra tiếng.

<a id="sounds-and-streams"></a>

## Sound và stream

Một `Sound` giữ các mẫu đã giải mã trong bộ nhớ, bao nhiêu player cũng đọc cùng lúc được. Nó được đếm tham chiếu: `release` khi app dùng xong, và nó được giải phóng khi player cuối cùng của nó cũng đã xong.

- `engine.decodeSound(bytes)` giải mã một file WAV, Ogg Vorbis hoặc MP3 trong bộ nhớ thành sound, sound tự sao chép những gì nó cần. Định dạng được nhận ra qua các byte đầu. Các byte lấy từ `@embedFile` hoặc từ một file đã đọc.
- `engine.newSound(sample_rate, channels, samples)` tạo sound từ các mẫu app tự tính. Đó là các số float xen kẽ, cấp phát bằng `gpa` của engine, và sound nhận quyền sở hữu chúng.

Stream giải mã trong lúc phát: cho nhạc quá dài để giữ trong bộ nhớ, hoặc cho âm thanh app tạo ra trong lúc phát.

- `engine.openStream(path)` trả về một player đang dừng, phát file WAV, Ogg Vorbis hoặc MP3 (nhận ra qua các byte đầu).
- `engine.newStreamPlayer(decoder)` trả về một player đang dừng, phát bất kỳ `audio.Decoder` nào, và đóng decoder cùng với player.

`Decoder` là một interface do app cung cấp:

- một `ptr` và một `vtable` gồm `read`, `seek` và `deinit`;
- `rate`, `channels`, và `frames` của nó (null với stream vô tận).

`read` điền vào buffer một số nguyên frame float xen kẽ. Nó trả về số frame đã đọc, chỉ trả 0 khi hết:

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
        return dst.len; // mono: mỗi frame một mẫu
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

`read` chạy trên thread của đầu ra, trong khi giữ lock của bộ trộn. Nó phải chạy nhanh và không được chờ main thread.

<a id="players"></a>

## Player

`engine.play(sound)` phát một sound một lần, trong một player riêng, tự giải phóng khi phát xong: đúng thứ hiệu ứng cần. Muốn điều khiển nhiều hơn thì `engine.newPlayer(sound)` trả về một `Player` đang dừng để thiết lập trước.

```zig
const step = try engine.newPlayer(footstep);
step.setPan(-0.4).setSpeed(1.1).play();
step.release();
```

| Method | |
|---|---|
| `play()` | phát từ vị trí hiện tại; khi đã hết thì phát lại từ đầu |
| `pause()` | tạm dừng, nhỏ dần trong 5 ms |
| `stop()` | tạm dừng và quay về đầu |
| `playing()` | có đang phát không: false khi đã hết, để game chờ một sound phát xong |
| `seek(seconds)` | nhảy tới vị trí |
| `position()`, `duration()` | vị trí hiện tại và độ dài, tính bằng giây; `duration` là null khi vô tận hoặc không rõ |
| `setVolume(x)` | 1 là như khi giải mã, 0 là im lặng |
| `setPan(x)` | -1 bên trái tới 1 bên phải |
| `setSpeed(x)` | tốc độ và cao độ cùng đổi, như đĩa than: 2 là cao hơn một quãng tám |
| `setLoop(on)` | hết thì phát lại từ đầu, không có khoảng hở |
| `setLoopRange(start, end)` | lặp từ `end` (null là tới cuối) về `start`: đoạn mở đầu của bản nhạc phát một lần, rồi tới đoạn lặp |
| `release()` | buông player: nó phát tiếp tới hết, hoặc vẫn dừng, rồi được giải phóng; sau đó không dùng được nữa |

- Các setter trả về chính player, để gọi nối tiếp.
- Bắt đầu, tạm dừng và seek giữa chừng một sound đều to dần hoặc nhỏ dần trong 5 ms, nên không gây tiếng lách cách.

<a id="formats"></a>

## Định dạng

| Module | Đọc được |
|---|---|
| `audio.wav` | PCM số nguyên 8 tới 32 bit, và float 32 hoặc 64 bit, ở mọi tần số và với số kênh bất kỳ |
| `audio.vorbis` | Ogg Vorbis: floor 0 và 1, residue 0–2, số kênh bất kỳ |
| `audio.mp3` | MPEG-1/2/2.5 layer III: không khoảng hở nhờ tag của LAME, bỏ qua ID3v2 |

- Cả ba đều giải mã trong lúc phát, từ bộ nhớ hoặc từ file. Vorbis và MP3 seek được.
- `audio.wav.write(writer, samples, rate, channels, .pcm16)` (hoặc `.float32`) ghi các mẫu float thành file WAV. Test ghi lại một engine `manual` lưu kết quả theo cách này.
- Định dạng khác: dùng một `Decoder` do app cung cấp.

<a id="the-output"></a>

## Đầu ra

- Engine trộn ở 48 kHz stereo (`audio.rate`, `audio.channels`), đi trước khoảng 40 ms.
- Nó trộn trên một thread riêng, thread này ngủ khi không có gì phát.
- Player ở tần số khác được resample trong lúc phát, theo spline Catmull-Rom.
- Sound mono phát ở cả hai loa, và pan được giữa hai loa.

| | Đầu ra | Nạp bằng |
|---|---|---|
| macOS | một Audio Queue trên đầu ra mặc định, đi theo đầu ra mặc định khi nó đổi | AudioToolbox, bằng `dlopen` |
| Linux | API đơn giản của PulseAudio (PipeWire cũng phục vụ API này), nếu không có thì thiết bị mặc định của ALSA | bằng `dlopen` |
| Windows | WASAPI ở chế độ shared trên đầu ra mặc định, mở lại khi đầu ra mặc định đổi hoặc thiết bị bị rút | COM |
| trình duyệt | chưa có | |

Ở nơi không mở được đầu ra nào (không có sound server, không có thiết bị, trong trình duyệt), player vẫn phát đúng giờ nhưng không ai nghe. Chúng kết thúc đúng lúc lẽ ra phải kết thúc, và `engine.outputError()` cho biết lý do. Một lúc sau engine thử lại thiết bị thật.
