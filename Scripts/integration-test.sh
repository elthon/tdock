#!/usr/bin/env bash
# 启动一个临时、非 root 的 sshd，并带集成测试环境变量运行 TDockCore 的 swift test。
# 所有密钥都在临时目录中现场生成，结束后删除；仓库中不保存任何密钥。
#
# 可覆盖的环境变量：
#   SSHD            sshd 路径（默认 /usr/sbin/sshd）
#   SSHD_SESSION    OpenSSH ≥ 9.8 的 sshd-session 路径（可选）
#   SSHD_AUTH       OpenSSH ≥ 10 的 sshd-auth 路径（可选）
#   SFTP_SERVER     sftp-server 路径（默认 /usr/lib/openssh/sftp-server）
#   SERVER_PATH     服务器端会话的 PATH（需包含 tmux、mosh-server 以测试相应功能）
#   SERVER_LD_LIBRARY_PATH  服务器端会话的 LD_LIBRARY_PATH（可选）
#   SWIFT_TEST_ARGS 透传给 swift test 的参数，例如 "--filter Integration"
#   IT_SHELL=1      不运行测试，改为打开一个已设置好 TDOCK_IT_* 变量的 shell（调试用）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SSHD="${SSHD:-/usr/sbin/sshd}"
SFTP_SERVER="${SFTP_SERVER:-/usr/lib/openssh/sftp-server}"
SERVER_PATH="${SERVER_PATH:-/usr/local/bin:/usr/bin:/bin}"
PORT="${PORT:-$((20000 + RANDOM % 20000))}"

WORK="$(mktemp -d)"
cleanup() {
  [ -f "$WORK/sshd.pid" ] && kill "$(cat "$WORK/sshd.pid")" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

ssh-keygen -q -t ed25519 -N "" -C tdock-it-host -f "$WORK/host_key"
ssh-keygen -q -t ed25519 -N "" -C tdock-it-client -f "$WORK/client_key"
cp "$WORK/client_key.pub" "$WORK/authorized_keys"

{
  echo "Port $PORT"
  echo "ListenAddress 127.0.0.1"
  echo "HostKey $WORK/host_key"
  echo "AuthorizedKeysFile $WORK/authorized_keys"
  echo "PidFile $WORK/sshd.pid"
  echo "PasswordAuthentication no"
  echo "KbdInteractiveAuthentication no"
  echo "UsePAM no"
  echo "StrictModes no"
  echo "AllowTcpForwarding yes"
  echo "Subsystem sftp $SFTP_SERVER"
  echo "SetEnv PATH=$SERVER_PATH${SERVER_LD_LIBRARY_PATH:+ LD_LIBRARY_PATH=$SERVER_LD_LIBRARY_PATH}"
  [ -n "${SSHD_SESSION:-}" ] && echo "SshdSessionPath $SSHD_SESSION"
  [ -n "${SSHD_AUTH:-}" ] && echo "SshdAuthPath $SSHD_AUTH"
} > "$WORK/sshd_config"

"$SSHD" -f "$WORK/sshd_config" -E "$WORK/sshd.log"
for _ in $(seq 50); do [ -f "$WORK/sshd.pid" ] && break; sleep 0.1; done

export TDOCK_IT_HOST=127.0.0.1
export TDOCK_IT_PORT="$PORT"
export TDOCK_IT_USER="$(id -un)"
export TDOCK_IT_KEY="$WORK/client_key"
# 允许测试把自己现场生成的公钥追加进来（验证 App 内生成的密钥可登录）。
export TDOCK_IT_AUTHORIZED_KEYS="$WORK/authorized_keys"
export TDOCK_IT_HOST_FINGERPRINT="$(ssh-keygen -lf "$WORK/host_key.pub" | awk '{print $2}')"

cd "$ROOT/Packages/TDockCore"
# shellcheck disable=SC2086
if [ -n "${IT_SHELL:-}" ]; then
  echo "sshd 已在 127.0.0.1:$PORT 启动；退出此 shell 即清理。"
  bash
else
  swift test ${SWIFT_TEST_ARGS:-}
fi
