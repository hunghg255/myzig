# A Linux desktop for myzig's tests: GTK 3, WebKitGTK, fonts, and a virtual display
# (Xvfb) so windows open without a screen. Binaries are built on the host
# (zig build -Dtarget=aarch64-linux-gnu) and mounted in.
FROM ubuntu:24.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    libgtk-3-0t64 libwebkit2gtk-4.1-0 libgl1-mesa-dri libegl1 libgles2 libgl1 libepoxy0 fonts-dejavu-core fonts-noto-core fonts-noto-cjk fonts-noto-color-emoji libharfbuzz0b libfreetype6 libfontconfig1 xvfb xauth x11-utils imagemagick xdotool zsh vim less python3 git curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /work
