// WASI (preview 1) for an app of myzig in a browser: what Zig's standard
// library asks of the system, answered in memory. Its file system is a
// tree of directories and files (the fonts the host fetched under
// /usr/share/fonts, and whatever the app writes, for the page's life),
// preopened as "/" at descriptor 3, which Zig takes for the working
// directory. Standard output and error go to the console.

const ok = 0, badf = 8, exist = 20, inval = 28, isdir = 31, noent = 44, nosys = 52, notdir = 54;
const dirType = 3, fileType = 4;

/// Thrown by `proc_exit`: the app ended.
export class Exit {
  constructor(code) { this.code = code; }
}

function node(dir) {
  return dir ? { dir: true, entries: new Map() } : { dir: false, data: new Uint8Array(0), size: 0 };
}

export class Wasi {
  constructor(args = ["app"], env = {}) {
    this.args = args;
    this.env = Object.entries(env).map(([k, v]) => `${k}=${v}`);
    this.root = node(true);
    // Open descriptors: 3 is the root; 0, 1, 2 the standard streams.
    this.fds = new Map([[3, { node: this.root, pos: 0, path: "/" }]]);
    this.next = 4;
    this.memory = null;
    this.lines = ["", "", ""];
    const enc = new TextEncoder();
    this.enc = (s) => enc.encode(s);
    const dec = new TextDecoder();
    this.dec = (b) => dec.decode(b);
  }

  /// Puts a file at an absolute path, making its directories.
  writeFile(path, bytes) {
    const parts = path.split("/").filter(Boolean);
    let dir = this.root;
    for (const p of parts.slice(0, -1)) {
      if (!dir.entries.has(p)) dir.entries.set(p, node(true));
      dir = dir.entries.get(p);
    }
    const f = node(false);
    f.data = bytes;
    f.size = bytes.length;
    dir.entries.set(parts[parts.length - 1], f);
  }

  view() { return new DataView(this.memory.buffer); }
  bytes(ptr, len) { return new Uint8Array(this.memory.buffer, ptr, len); }
  str(ptr, len) { return this.dec(this.bytes(ptr, len).slice()); }

  /// The node at `path` from the directory of descriptor `fd`.
  lookup(fd, path, create, dirWanted) {
    const base = this.fds.get(fd);
    if (!base || !base.node.dir) return { err: badf };
    const parts = path.split("/").filter((p) => p && p !== ".");
    let at = path.startsWith("/") ? this.root : base.node;
    const stack = [];
    for (let i = 0; i < parts.length; i++) {
      const p = parts[i];
      if (p === "..") { at = stack.pop() || this.root; continue; }
      if (!at.dir) return { err: notdir };
      let next = at.entries.get(p);
      if (!next) {
        if (!create || i < parts.length - 1) return { err: noent };
        next = node(dirWanted);
        at.entries.set(p, next);
      }
      stack.push(at);
      at = next;
    }
    return { node: at, parent: stack[stack.length - 1], name: parts[parts.length - 1] };
  }

  filestat(ptr, n) {
    const v = this.view();
    for (let i = 0; i < 64; i += 8) v.setBigUint64(ptr + i, 0n, true);
    v.setUint8(ptr + 16, n.dir ? dirType : fileType);
    v.setBigUint64(ptr + 24, 1n, true);
    v.setBigUint64(ptr + 32, BigInt(n.dir ? 0 : n.size), true);
  }

  grow(n, size) {
    if (size <= n.data.length) return;
    const d = new Uint8Array(Math.max(size, n.data.length * 2));
    d.set(n.data.subarray(0, n.size));
    n.data = d;
  }

  /// Copies between descriptor `f`'s file at `pos` and the iovecs; the bytes moved.
  io(f, iovs, count, pos, write) {
    const v = this.view();
    let done = 0;
    for (let i = 0; i < count; i++) {
      const ptr = v.getUint32(iovs + i * 8, true);
      const len = v.getUint32(iovs + i * 8 + 4, true);
      const n = f.node;
      if (write) {
        this.grow(n, pos + done + len);
        n.data.set(this.bytes(ptr, len), pos + done);
        n.size = Math.max(n.size, pos + done + len);
        done += len;
      } else {
        const m = Math.max(0, Math.min(len, n.size - pos - done));
        this.bytes(ptr, m).set(n.data.subarray(pos + done, pos + done + m));
        done += m;
        if (m < len) break;
      }
    }
    return done;
  }

  imports() {
    const self = this;
    const v = () => self.view();
    const strings = (list, ptrs, buf) => {
      let at = buf;
      list.forEach((s, i) => {
        const b = self.enc(s + "\0");
        v().setUint32(ptrs + i * 4, at, true);
        self.bytes(at, b.length).set(b);
        at += b.length;
      });
      return ok;
    };
    const sizes = (list, count, size) => {
      v().setUint32(count, list.length, true);
      v().setUint32(size, list.reduce((n, s) => n + self.enc(s).length + 1, 0), true);
      return ok;
    };
    return {
      args_get: (ptrs, buf) => strings(self.args, ptrs, buf),
      args_sizes_get: (count, size) => sizes(self.args, count, size),
      environ_get: (ptrs, buf) => strings(self.env, ptrs, buf),
      environ_sizes_get: (count, size) => sizes(self.env, count, size),
      clock_res_get: (_, out) => { v().setBigUint64(out, 1000n, true); return ok; },
      clock_time_get: (id, _, out) => {
        const ns = id === 0 ? BigInt(Date.now()) * 1000000n : BigInt(Math.round(performance.now() * 1e6));
        v().setBigUint64(out, ns, true);
        return ok;
      },
      random_get: (ptr, len) => {
        for (let i = 0; i < len; i += 65536) crypto.getRandomValues(self.bytes(ptr + i, Math.min(65536, len - i)));
        return ok;
      },
      proc_exit: (code) => { throw new Exit(code); },
      sched_yield: () => ok,
      poll_oneoff: () => nosys,
      fd_write: (fd, iovs, count, out) => {
        if (fd === 1 || fd === 2) {
          let n = 0;
          for (let i = 0; i < count; i++) {
            const ptr = v().getUint32(iovs + i * 8, true);
            const len = v().getUint32(iovs + i * 8 + 4, true);
            self.lines[fd] += self.str(ptr, len);
            n += len;
          }
          const lines = self.lines[fd].split("\n");
          self.lines[fd] = lines.pop();
          for (const l of lines) (fd === 2 ? console.warn : console.log)(l);
          v().setUint32(out, n, true);
          return ok;
        }
        const f = self.fds.get(fd);
        if (!f || f.node.dir) return badf;
        const n = self.io(f, iovs, count, f.append ? f.node.size : f.pos, true);
        f.pos += n;
        v().setUint32(out, n, true);
        return ok;
      },
      fd_pwrite: (fd, iovs, count, offset, out) => {
        const f = self.fds.get(fd);
        if (!f || f.node.dir) return badf;
        v().setUint32(out, self.io(f, iovs, count, Number(offset), true), true);
        return ok;
      },
      fd_read: (fd, iovs, count, out) => {
        const f = self.fds.get(fd);
        if (fd === 0) { v().setUint32(out, 0, true); return ok; }
        if (!f) return badf;
        if (f.node.dir) return isdir;
        const n = self.io(f, iovs, count, f.pos, false);
        f.pos += n;
        v().setUint32(out, n, true);
        return ok;
      },
      fd_pread: (fd, iovs, count, offset, out) => {
        const f = self.fds.get(fd);
        if (!f) return badf;
        if (f.node.dir) return isdir;
        v().setUint32(out, self.io(f, iovs, count, Number(offset), false), true);
        return ok;
      },
      fd_seek: (fd, offset, whence, out) => {
        const f = self.fds.get(fd);
        if (!f) return badf;
        const base = whence === 0 ? 0 : whence === 1 ? f.pos : f.node.size;
        const pos = base + Number(offset);
        if (pos < 0) return inval;
        f.pos = pos;
        v().setBigUint64(out, BigInt(pos), true);
        return ok;
      },
      fd_tell: (fd, out) => {
        const f = self.fds.get(fd);
        if (!f) return badf;
        v().setBigUint64(out, BigInt(f.pos), true);
        return ok;
      },
      fd_close: (fd) => (self.fds.delete(fd) ? ok : badf),
      fd_sync: () => ok,
      fd_datasync: () => ok,
      fd_advise: () => ok,
      fd_allocate: () => ok,
      fd_fdstat_get: (fd, out) => {
        const f = self.fds.get(fd);
        if (!f && fd > 2) return badf;
        const view = v();
        for (let i = 0; i < 24; i += 8) view.setBigUint64(out + i, 0n, true);
        view.setUint8(out, f ? (f.node.dir ? dirType : fileType) : 2);
        view.setBigUint64(out + 8, 0xffffffffn, true);
        view.setBigUint64(out + 16, 0xffffffffn, true);
        return ok;
      },
      fd_fdstat_set_flags: () => ok,
      fd_filestat_get: (fd, out) => {
        const f = self.fds.get(fd);
        if (!f) return badf;
        self.filestat(out, f.node);
        return ok;
      },
      fd_filestat_set_size: (fd, size) => {
        const f = self.fds.get(fd);
        if (!f || f.node.dir) return badf;
        self.grow(f.node, Number(size));
        f.node.size = Number(size);
        return ok;
      },
      fd_filestat_set_times: () => ok,
      fd_prestat_get: (fd, out) => {
        if (fd !== 3) return badf;
        v().setUint32(out, 0, true);
        v().setUint32(out + 4, 1, true);
        return ok;
      },
      fd_prestat_dir_name: (fd, ptr, len) => {
        if (fd !== 3) return badf;
        if (len > 0) self.bytes(ptr, 1)[0] = 47; // "/"
        return ok;
      },
      fd_readdir: (fd, buf, len, cookie, out) => {
        const f = self.fds.get(fd);
        if (!f) return badf;
        if (!f.node.dir) return notdir;
        const names = [...f.node.entries.keys()];
        let at = 0;
        for (let i = Number(cookie); i < names.length && at < len; i++) {
          const name = self.enc(names[i]);
          const head = new DataView(new ArrayBuffer(24));
          head.setBigUint64(0, BigInt(i + 1), true);
          head.setBigUint64(8, BigInt(i + 1), true);
          head.setUint32(16, name.length, true);
          head.setUint8(20, f.node.entries.get(names[i]).dir ? dirType : fileType);
          const entry = new Uint8Array(24 + name.length);
          entry.set(new Uint8Array(head.buffer));
          entry.set(name, 24);
          const n = Math.min(entry.length, len - at);
          self.bytes(buf + at, n).set(entry.subarray(0, n));
          at += n;
        }
        v().setUint32(out, at, true);
        return ok;
      },
      path_open: (fd, _flags, ptr, len, oflags, _rights, _inheriting, fdflags, out) => {
        const creat = (oflags & 1) !== 0, directory = (oflags & 2) !== 0, excl = (oflags & 4) !== 0, trunc = (oflags & 8) !== 0;
        const path = self.str(ptr, len);
        const before = self.lookup(fd, path, false);
        if (before.node && creat && excl) return exist;
        const r = before.node ? before : self.lookup(fd, path, creat, false);
        if (r.err) return r.err;
        if (directory && !r.node.dir) return notdir;
        if (trunc && !r.node.dir) r.node.size = 0;
        const n = self.next++;
        self.fds.set(n, { node: r.node, pos: 0, append: (fdflags & 1) !== 0 });
        v().setUint32(out, n, true);
        return ok;
      },
      path_filestat_get: (fd, _flags, ptr, len, out) => {
        const r = self.lookup(fd, self.str(ptr, len), false);
        if (r.err) return r.err;
        self.filestat(out, r.node);
        return ok;
      },
      path_filestat_set_times: () => ok,
      path_create_directory: (fd, ptr, len) => {
        const path = self.str(ptr, len);
        if (self.lookup(fd, path, false).node) return exist;
        const r = self.lookup(fd, path, true, true);
        return r.err || ok;
      },
      path_remove_directory: (fd, ptr, len) => {
        const r = self.lookup(fd, self.str(ptr, len), false);
        if (r.err) return r.err;
        if (!r.node.dir) return notdir;
        r.parent.entries.delete(r.name);
        return ok;
      },
      path_unlink_file: (fd, ptr, len) => {
        const r = self.lookup(fd, self.str(ptr, len), false);
        if (r.err) return r.err;
        if (r.node.dir) return isdir;
        r.parent.entries.delete(r.name);
        return ok;
      },
      path_rename: (fd, ptr, len, fd2, ptr2, len2) => {
        const r = self.lookup(fd, self.str(ptr, len), false);
        if (r.err) return r.err;
        const to = self.str(ptr2, len2);
        const parts = to.split("/").filter(Boolean);
        const dir = self.lookup(fd2, parts.slice(0, -1).join("/") || ".", false);
        if (dir.err) return dir.err;
        r.parent.entries.delete(r.name);
        dir.node.entries.set(parts[parts.length - 1], r.node);
        return ok;
      },
      path_link: () => nosys,
      path_symlink: () => nosys,
      path_readlink: () => inval,
      sock_accept: () => nosys,
      sock_recv: () => nosys,
      sock_send: () => nosys,
      sock_shutdown: () => nosys,
    };
  }
}
