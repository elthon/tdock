#!/usr/bin/env bash
# 在一台全新的 Linux（云端开发环境 / VPS / 容器）上准备 TDockCore 的开发与测试环境：
#   - Swift 工具链（默认 6.0.3，装到 $PREFIX/swift，不动系统）
#   - 集成测试的服务器端：sshd、sftp-server、tmux、mosh-server
# 然后生成 $PREFIX/env.sh，之后只需：
#   source ~/.tdock-dev/env.sh && Scripts/integration-test.sh
#
# 有 root 或免密 sudo 时用 apt-get 安装系统包；否则把 .deb 解包到 $PREFIX/sysroot（无需 root）。
# 脚本可重复运行，已就绪的部分会跳过。iOS App 本身仍需在 Mac 上用 Xcode 编译。
#
# 用法：
#   Scripts/setup-linux.sh           # 安装并生成 env.sh
#   Scripts/setup-linux.sh --test    # 安装后再跑一遍完整测试（含集成测试）
#
# 可覆盖的环境变量：
#   TDOCK_DEV_PREFIX   安装目录（默认 ~/.tdock-dev）
#   SWIFT_VERSION      Swift 版本（默认 6.0.3）
#   SWIFT_PLATFORM     swift.org 的平台名，如 ubuntu2404 / ubuntu2204 / debian12（默认自动识别）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${TDOCK_DEV_PREFIX:-$HOME/.tdock-dev}"
SWIFT_VERSION="${SWIFT_VERSION:-6.0.3}"
RUN_TESTS=0
[ "${1:-}" = "--test" ] && RUN_TESTS=1

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m错误：\033[0m%s\n' "$*" >&2; exit 1; }

mkdir -p "$PREFIX"
command -v apt-get >/dev/null || die "目前只支持 Debian / Ubuntu（需要 apt-get）"

if [ "$(id -u)" = 0 ]; then
  SUDO=""
elif sudo -n true 2>/dev/null; then
  SUDO="sudo"
else
  SUDO="-"   # 无 root：走用户态解包
fi

LIBDIR_REL="usr/lib/$(uname -m)-linux-gnu"
use_sysroot_libs() {
  export LD_LIBRARY_PATH="$SYSROOT/$LIBDIR_REL:$SYSROOT/lib/$(uname -m)-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
}
# 用户态补库：对给定的二进制跑 ldd，把 “not found” 的 libfoo.so.N 映射成包名 libfooN / libfooNt64 再解包。
fetch_missing_libs() {
  local debs="$PREFIX/debs" lib pkg base ver
  mkdir -p "$debs" "$SYSROOT"
  use_sysroot_libs
  for lib in $(ldd "$@" 2>/dev/null | awk '/not found/ {print $1}' | sort -u); do
    base="${lib%%.so*}"; ver="${lib##*.so.}"; ver="${ver%%.*}"
    for pkg in "$base$ver" "${base}$ver"t64 "$base-$ver" "$base"; do
      if apt-cache show "$pkg" >/dev/null 2>&1; then
        (cd "$debs" && apt-get download -qq "$pkg" 2>/dev/null) && break
      fi
    done
  done
  for d in "$debs"/*.deb; do [ -e "$d" ] && dpkg -x "$d" "$SYSROOT"; done
  return 0
}

# ---------- 1. 系统包 ----------
# Swift 工具链的运行依赖 + 集成测试服务器端。逐个检查是否存在，避免某个发行版缺包导致整体失败。
PKGS=(ca-certificates curl git tar gzip binutils build-essential pkg-config tzdata unzip
      libcurl4-openssl-dev libxml2-dev libsqlite3-dev libncurses-dev libedit-dev zlib1g-dev libz3-dev
      openssh-client openssh-server openssh-sftp-server tmux mosh locales)

if [ "$SUDO" != "-" ]; then
  log "用 apt-get 安装系统包"
  export DEBIAN_FRONTEND=noninteractive
  $SUDO apt-get update -qq
  available=()
  for p in "${PKGS[@]}"; do apt-cache show "$p" >/dev/null 2>&1 && available+=("$p"); done
  $SUDO apt-get install -y -qq --no-install-recommends "${available[@]}" >/dev/null
  # 以 root 身份启动 sshd 时需要权限分离目录。
  $SUDO mkdir -p /run/sshd
  # mosh-server 要求 UTF-8 locale。
  locale -a 2>/dev/null | grep -qi '^c\.utf-\?8$' || { $SUDO locale-gen C.UTF-8 >/dev/null 2>&1 || true; }
  SYSROOT=""
else
  SYSROOT="$PREFIX/sysroot"
  need=0
  for t in sshd tmux mosh-server; do command -v "$t" >/dev/null || [ -x "/usr/sbin/$t" ] || need=1; done
  [ -x /usr/lib/openssh/sftp-server ] || need=1
  if [ "$need" = 0 ]; then
    log "sshd / sftp-server / tmux / mosh-server 已在系统中，跳过"
    SYSROOT=""
  elif [ -x "$SYSROOT/usr/bin/tmux" ] && [ -x "$SYSROOT/usr/bin/mosh-server" ] && [ -e "$SYSROOT/usr/sbin/sshd" ]; then
    log "用户态服务器端已存在：$SYSROOT"
  else
    log "没有 root：把 openssh-server / sftp-server / tmux / mosh 解包到 $SYSROOT"
    debs="$PREFIX/debs"; mkdir -p "$debs" "$SYSROOT"
    base=(openssh-server openssh-sftp-server tmux mosh)
    # 一并取它们直接依赖的 lib*（如 libevent、libutempter、libprotobuf、libncurses），系统里已有的也无妨。
    deps=$(apt-cache depends --no-recommends --no-suggests "${base[@]}" 2>/dev/null \
           | awk '/Depends:/ {print $2}' | grep '^lib' | tr -d '<>' | sort -u)
    (cd "$debs" && for p in "${base[@]}" $deps; do apt-get download -qq "$p" 2>/dev/null || true; done)
    for d in "$debs"/*.deb; do dpkg -x "$d" "$SYSROOT"; done
    [ -e "$SYSROOT/usr/sbin/sshd" ] || die "解包后仍未找到 sshd（apt-get download 失败？检查网络）"
    fetch_missing_libs "$SYSROOT/usr/bin/tmux" "$SYSROOT/usr/bin/mosh-server" "$SYSROOT/usr/sbin/sshd" \
      "$SYSROOT"/usr/lib/openssh/*
  fi
  [ -n "$SYSROOT" ] && use_sysroot_libs
fi

# ---------- 2. Swift 工具链 ----------
if [ "$SUDO" = "-" ] && [ -d "$PREFIX/sysroot" ]; then SYSROOT="$PREFIX/sysroot"; use_sysroot_libs; fi
swift_ok() { "$1" --version 2>/dev/null | grep -q "Swift version $SWIFT_VERSION"; }
SWIFT_BIN=""
if command -v swift >/dev/null && swift_ok swift; then
  SWIFT_BIN="$(dirname "$(command -v swift)")"
  log "已有 Swift $SWIFT_VERSION：$SWIFT_BIN"
elif [ -x "$PREFIX/swift/usr/bin/swift" ] && swift_ok "$PREFIX/swift/usr/bin/swift"; then
  SWIFT_BIN="$PREFIX/swift/usr/bin"
  log "已有 Swift $SWIFT_VERSION：$SWIFT_BIN"
else
  if [ -z "${SWIFT_PLATFORM:-}" ]; then
    . /etc/os-release
    case "$ID:${VERSION_ID:-}" in
      ubuntu:20.04) SWIFT_PLATFORM=ubuntu2004 ;;
      ubuntu:22.04) SWIFT_PLATFORM=ubuntu2204 ;;
      ubuntu:2[4-9].*) SWIFT_PLATFORM=ubuntu2404 ;;
      debian:*) SWIFT_PLATFORM=debian12 ;;   # Debian 13 上用 debian12 的包可正常工作
      *) die "无法识别的系统 $ID $VERSION_ID，请设置 SWIFT_PLATFORM（如 ubuntu2404）" ;;
    esac
  fi
  arch_suffix=""
  [ "$(uname -m)" = aarch64 ] && arch_suffix="-aarch64"
  # 目录名不带点（ubuntu2404），文件名里的 Ubuntu 版本带点（ubuntu24.04）；debian12 两处相同。
  file_platform="$(printf '%s' "$SWIFT_PLATFORM" | sed -E 's/^ubuntu([0-9]{2})([0-9]{2})$/ubuntu\1.\2/')"
  name="swift-$SWIFT_VERSION-RELEASE-$file_platform$arch_suffix"
  url="https://download.swift.org/swift-$SWIFT_VERSION-release/$SWIFT_PLATFORM$arch_suffix/swift-$SWIFT_VERSION-RELEASE/$name.tar.gz"
  log "下载 Swift：$url"
  tmp="$PREFIX/$name.tar.gz"
  curl -fL --retry 3 -o "$tmp" "$url" || die "下载失败。云端环境需要允许访问 download.swift.org"
  rm -rf "$PREFIX/swift" "$PREFIX/$name"
  tar -xzf "$tmp" -C "$PREFIX"
  mv "$PREFIX/$name" "$PREFIX/swift"
  rm -f "$tmp"
  SWIFT_BIN="$PREFIX/swift/usr/bin"
fi
if ! swift_ok "$SWIFT_BIN/swift" && [ "$SUDO" = "-" ]; then
  # 无 root 且系统缺少 Swift 依赖的库（常见是 libncurses6）：按 ldd 报告缺什么就解包什么。
  log "补齐 Swift 依赖的系统库（用户态）"
  SYSROOT="${SYSROOT:-$PREFIX/sysroot}"
  fetch_missing_libs "$SWIFT_BIN/swift-frontend" "$SWIFT_BIN/swift-build" "$SWIFT_BIN/swift-driver" "$SWIFT_BIN/clang"
fi
swift_ok "$SWIFT_BIN/swift" || die "Swift 无法运行：$("$SWIFT_BIN/swift" --version 2>&1 | head -1)"

# ---------- 3. 生成 env.sh ----------
ENV="$PREFIX/env.sh"
{
  echo "# 由 Scripts/setup-linux.sh 生成。用法：source $ENV"
  echo "export PATH=\"$SWIFT_BIN:\$PATH\""
  echo "export LANG=\"\${LANG:-C.UTF-8}\""
  if [ -n "$SYSROOT" ]; then
    libdir="$SYSROOT/$LIBDIR_REL"
    echo "export LD_LIBRARY_PATH=\"$libdir:$SYSROOT/lib/$(uname -m)-linux-gnu\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}\""
  fi
  if [ -n "$SYSROOT" ] && [ -e "$SYSROOT/usr/sbin/sshd" ]; then
    echo "export SSHD=\"$SYSROOT/usr/sbin/sshd\""
    [ -e "$SYSROOT/usr/lib/openssh/sshd-session" ] && echo "export SSHD_SESSION=\"$SYSROOT/usr/lib/openssh/sshd-session\""
    [ -e "$SYSROOT/usr/lib/openssh/sshd-auth" ] && echo "export SSHD_AUTH=\"$SYSROOT/usr/lib/openssh/sshd-auth\""
    echo "export SFTP_SERVER=\"$SYSROOT/usr/lib/openssh/sftp-server\""
    echo "export SERVER_PATH=\"$SYSROOT/usr/bin:/usr/local/bin:/usr/bin:/bin\""
    echo "export SERVER_LD_LIBRARY_PATH=\"$libdir\""
  fi
} > "$ENV"
log "已生成 $ENV"

# ---------- 4. 预取依赖 / 可选：跑测试 ----------
# shellcheck disable=SC1090
. "$ENV"
log "拉取 Swift 包依赖"
(cd "$ROOT/Packages/TDockCore" && swift package resolve)

if [ "$RUN_TESTS" = 1 ]; then
  log "运行完整测试（含集成测试）"
  "$ROOT/Scripts/integration-test.sh"
fi

cat <<EOF

完成。以后每个新 shell：
  source $ENV
  Scripts/integration-test.sh                     # 全部测试（含 sshd/SFTP/tmux/mosh 集成测试）
  (cd Packages/TDockCore && swift test)           # 只跑单元测试，集成测试自动跳过
EOF
