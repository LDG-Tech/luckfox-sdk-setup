#!/usr/bin/env bash
set -euo pipefail

# ===================================================
#  Configuration
# ===================================================
USERNAME="luckfox"
PASSWORD="luckfox"
USER_HOME="/home/${USERNAME}"
PKGS_BASE=( git ssh make gcc gcc-multilib g++-multilib module-assistant expect g++ gawk texinfo libssl-dev bison flex fakeroot cmake unzip gperf autoconf device-tree-compiler libncurses5-dev pkg-config bc python-is-python3 passwd openssl openssh-server openssh-client vim file cpio rsync htop )
PKGS_RK=( libudev-dev libusb-1.0-0-dev dh-autoreconf )
REPO_PICO="https://github.com/LDG-Tech/luckfox-pico-14.git"
REPO_RKDEV="https://github.com/rockchip-linux/rkdeveloptool.git"
STATE_DIR="/var/tmp/luckfox-setup"
DISTRO_NAME="Ubuntu-22.04"

mkdir -p "$STATE_DIR"

# ===================================================
#  Helpers
# ===================================================
log()   { printf "%-70s" "  $*"; }
ok()    { echo "[OK]"; }
skip()  { echo "[SKIP]"; }
fail()  { echo "[FAIL]"; }
waitm() { printf "%s\n" "  [WAIT] $*"; }
done_flag() { [ -f "${STATE_DIR}/$1.done" ]; }
mark_done() { touch "${STATE_DIR}/$1.done"; }

trap 'echo; fail "Erreur ligne $LINENO."; exit 1' ERR

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Ce script doit être exécuté en root."; exit 1
  fi
}

# ===================================================
#  Step 1 : Fetching the Windows user
# ===================================================
detect_win_user() {
  local step="detectwin"
  if done_flag "$step"; then
    WIN_USER=$(cat "${STATE_DIR}/WIN_USER" 2>/dev/null || true)
    if [ -z "${WIN_USER:-}" ]; then
      echo "Erreur : WIN_USER introuvable. Supprime ${STATE_DIR} pour tout réinitialiser."; exit 1
    fi
    WIN_HOME="/mnt/c/Users/${WIN_USER}"
    log "Utilisateur Windows déjà détecté"; skip; return
  fi

  RAW=$(/mnt/c/Windows/System32/cmd.exe /C "echo %USERNAME%" 2>/dev/null || true)
  WIN_USER=$(printf "%s" "$RAW" | tr -d '\r' | sed '/\\/d;/[Cc][Mm][Dd]/d;/^$/d' | tail -n1 | awk '{$1=$1;print}')
  if [ -z "${WIN_USER:-}" ]; then
    echo "Impossible de détecter l'utilisateur Windows."; exit 1
  fi
  echo "${WIN_USER}" > "${STATE_DIR}/WIN_USER"
  WIN_HOME="/mnt/c/Users/${WIN_USER}"
  echo "Utilisateur Windows détecté : ${WIN_USER}"
  mark_done "$step"
}

# ===================================================
#  Step 2 : Configuration wsl.conf (Removing Windows directories from PATH)
# ===================================================
configure_wsl_conf() {
  local step="wslconf"
  if done_flag "$step"; then log "wsl.conf déjà configuré"; skip; return; fi
  waitm "Configuration de /etc/wsl.conf (PATH et metadata)"
  cat >/etc/wsl.conf <<'EOF'
[interop]
appendWindowsPath = false

[automount]
enabled = true
options = "metadata,uid=1000,gid=1000,umask=22,fmask=11"
EOF
  ok
  echo "⚙️  Ces changements prendront effet après redémarrage WSL :"
  echo "   → wsl --shutdown && wsl"
  mark_done "$step"
}

# ===================================================
#  Step 3 : Create user
# ===================================================
ensure_user() {
  local step="user"
  if done_flag "$step"; then log "Utilisateur ${USERNAME} déjà prêt"; skip; return; fi
  if id "$USERNAME" &>/dev/null; then
    log "Utilisateur ${USERNAME} existe déjà"; ok
  else
    log "Création utilisateur ${USERNAME}"
    useradd -m -s /bin/bash "$USERNAME"
    echo "${USERNAME}:${PASSWORD}" | chpasswd
    ok
  fi
  chown -R "${USERNAME}:${USERNAME}" "$USER_HOME" || true
  mark_done "$step"
}

# ===================================================
#  Step 4 : Add user to sudoers
# ===================================================
setup_sudoers() {
  local step="sudoers"
  if done_flag "$step"; then log "Sudoers déjà configuré"; skip; return; fi
  echo "${USERNAME} ALL=(ALL:ALL) NOPASSWD:ALL" >/etc/sudoers.d/90-${USERNAME}-nopasswd
  chmod 0440 /etc/sudoers.d/90-${USERNAME}-nopasswd
  usermod -aG sudo "${USERNAME}" || true
  ok
  mark_done "$step"
}

# ===================================================
#  Step 5 : Install dependencies
# ===================================================
install_packages() {
  local step="packages"
  if done_flag "$step"; then log "Paquets déjà installés"; skip; return; fi
  waitm "Installation des paquets requis"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y --no-install-recommends "${PKGS_BASE[@]}" >/dev/null
  ok
  mark_done "$step"
}

# ===================================================
#  Step 6 : Getting SDK from github
# ===================================================
clone_luckfox_pico() {
  local step="luckfoxpico"
  if done_flag "$step"; then log "luckfox-pico déjà présent"; skip; return; fi
  waitm "Préparation du dépôt luckfox-pico"
  sudo -u "$USERNAME" -H bash -lc '
    set -e
    if [ -d "$HOME/luckfox-pico/.git" ]; then
      cd "$HOME/luckfox-pico"
      git pull --ff-only || true
    else
      git clone --depth=1 "'"${REPO_PICO}"'" "$HOME/luckfox-pico"
    fi
  '
  ok
  mark_done "$step"
}

# ===================================================
#  Step 7 : Toolchain install
# ===================================================
install_toolchain_env() {
  local step="toolchain"
  if done_flag "$step"; then log "Toolchain déjà configuré"; skip; return; fi
  waitm "Configuration du toolchain cross-compile (Luckfox Pico)"

  sudo -u "$USERNAME" -H bash <<'EOSU'
set -euo pipefail
TOOLCHAIN_DIR="$HOME/luckfox-pico/tools/linux/toolchain/arm-rockchip830-linux-uclibcgnueabihf"

if [ -f "$TOOLCHAIN_DIR/env_install_toolchain.sh" ]; then
  cd "$TOOLCHAIN_DIR"
  [ -f "$HOME/.bash_profile" ] || touch "$HOME/.bash_profile"
  bash -lc "source '$TOOLCHAIN_DIR/env_install_toolchain.sh' || true"
  if ! grep -q "env_install_toolchain.sh" "$HOME/.bashrc"; then
    echo "source \$HOME/luckfox-pico/tools/linux/toolchain/arm-rockchip830-linux-uclibcgnueabihf/env_install_toolchain.sh" >> "$HOME/.bashrc"
  fi
else
  echo "⚠️  env_install_toolchain.sh introuvable : $TOOLCHAIN_DIR"
fi
EOSU

  ok
  mark_done "$step"
}

# ===================================================
#  Step 8 : Build rkdeveloptool
# ===================================================
build_rkdeveloptool() {
  local step="rkdev"
  if done_flag "$step"; then log "rkdeveloptool déjà construit"; skip; return; fi
  waitm "Construction rkdeveloptool"
  apt-get install -y --no-install-recommends "${PKGS_RK[@]}" >/dev/null

  sudo -u "$USERNAME" -H bash <<'EOSU'
set -euo pipefail
sudo hwclock --hctosys 2>/dev/null || true
sudo date -u "+%Y-%m-%d %H:%M:%S"

rm -rf /tmp/rkdev
mkdir -p /tmp/rkdev && cd /tmp/rkdev
git clone https://github.com/rockchip-linux/rkdeveloptool.git .
find . -type f -exec touch {} + >/dev/null 2>&1
if [ -x ./autogen.sh ]; then ./autogen.sh; else autoreconf -i; fi
./configure
make -j"$(nproc)"
EOSU

  install -m 0755 -o root -g root "/tmp/rkdev/rkdeveloptool" /usr/local/bin/rkdeveloptool
  rm -rf /tmp/rkdev
  ok
  mark_done "$step"
}

# ===================================================
#  Final step
# ===================================================
final_shell_as_user() {
  local win_path="\\\\wsl.localhost\\${DISTRO_NAME}\\home\\${USERNAME}\\luckfox-pico"

  echo
  echo "===================================================="
  echo " Tout est prêt."
  echo " - Utilisateur : ${USERNAME} (sudo NOPASSWD configuré)"
  echo " - Home : ${USER_HOME} (ext4 natif)"
  echo " - luckfox-pico : ~/luckfox-pico"
  echo " - Toolchain : sourcé + persistant (~/.bashrc)"
  echo " - rkdeveloptool : /usr/local/bin/rkdeveloptool"
  echo "===================================================="
  echo
  echo " 💾 Accès depuis Windows :"
  echo "    ${win_path}"
  echo
  echo " • Redémarre WSL maintenant : wsl --shutdown"
  echo " • Pour builder : cd ~/luckfox-pico && ./build"
  echo " • Sortie de build : /output/"
  echo " • Pour flasher : utilise SocToolKit sous Windows."
  echo " • Nom du loader : download.bin"
  echo " • Image complète pour update : update.img"
  echo
  exec sudo -u "${USERNAME}" -H bash -lc 'cd ~/luckfox-pico; exec "$SHELL" -l'
}

# ===================================================
#  Main
# ===================================================
main() {
  require_root
  detect_win_user
  configure_wsl_conf
  ensure_user
  setup_sudoers
  install_packages
  clone_luckfox_pico
  install_toolchain_env
  build_rkdeveloptool
  final_shell_as_user
}

main
