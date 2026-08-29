#!/bin/sh
# EPM Automate installer — one command on Windows, Linux, and macOS:
#   curl -fsSL https://raw.githubusercontent.com/<owner>/epmautomate-install/main/install.sh | sh
#
# Detects the OS, downloads the matching client from a Cloud EPM environment,
# then either launches the Windows GUI installer or fully installs on Unix.

set -eu

VERSION=1.0.0
USER_AGENT="epmautomate-install/${VERSION}"
MIN_BYTES=102400
MARKER_BEGIN="# >>> epmautomate-install >>>"
MARKER_END="# <<< epmautomate-install <<<"

EPM_URL=${EPM_URL-}
EPM_USER=${EPM_USER-}
EPM_PASSWORD=${EPM_PASSWORD-}
EPM_DOMAIN=${EPM_DOMAIN-}
EPM_TOKEN=${EPM_TOKEN-}
EPM_INSTALL_DIR=${EPM_INSTALL_DIR-}
EPM_INSTALLER=${EPM_INSTALLER-}
EPM_SKIP_JAVA=${EPM_SKIP_JAVA-}
EPM_SKIP_UPGRADE=${EPM_SKIP_UPGRADE-}

usage() {
  cat <<'EOF'
Install Oracle EPM Automate from a Cloud EPM environment.

Usage:
  curl -fsSL <raw-url>/install.sh | sh
  curl -fsSL <raw-url>/install.sh | sh -s -- [options]
  sh install.sh [options]

The script detects the OS:
  Windows (Git Bash / MSYS / Cygwin)
      Download EPM Automate.exe and launch the GUI installer.
  Linux and macOS
      Download EPMAutomate.tar, extract it, set JAVA_HOME/PATH, and
      optionally run "epmautomate upgrade".

Options:
  --url URL            Cloud EPM URL (or set EPM_URL)
  --user NAME          Identity-domain user (or set EPM_USER)
  --password PASS      Password (or set EPM_PASSWORD; prefer a prompt)
  --domain DOMAIN      Classic identity domain (or set EPM_DOMAIN)
  --token TOKEN        Bearer token instead of basic auth (or EPM_TOKEN)
  --prefix DIR         Unix install directory (or EPM_INSTALL_DIR)
  --from-file PATH     Use a local installer instead of downloading
                       (or set EPM_INSTALLER)
  --skip-java          Do not install a JRE (or EPM_SKIP_JAVA=1)
  --skip-upgrade       Skip "epmautomate upgrade" on Unix
  -h, --help           Show this help

Required for download (unless --from-file): EPM_URL.
Credentials are optional if the installer is reachable anonymously;
otherwise they are prompted for when /dev/tty is available.

MFA users cannot use basic auth. Use a service account without MFA,
or --from-file after downloading from Settings and Actions > Downloads.
EOF
}

info() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

trim_cr() {
  printf '%s' "$1" | tr -d '\r'
}

can_prompt() {
  { : >/dev/tty </dev/tty; } 2>/dev/null
}

prompt_text() {
  _p=$1
  printf '%s' "$_p" >/dev/tty
  IFS= read -r _v </dev/tty || die "failed to read input"
  printf '%s' "$(trim_cr "$_v")"
}

prompt_secret() {
  _p=$1
  printf '%s' "$_p" >/dev/tty
  stty -echo </dev/tty
  IFS= read -r _v </dev/tty || {
    stty echo </dev/tty
    die "failed to read password"
  }
  stty echo </dev/tty
  printf '\n' >/dev/tty
  printf '%s' "$(trim_cr "$_v")"
}

# --- args ---

parse_args() {
  while [ $# -gt 0 ]; do
    case $1 in
      -h|--help)
        usage
        exit 0
        ;;
      --url)
        [ $# -ge 2 ] || die "$1 requires a value"
        EPM_URL=$2
        shift 2
        ;;
      --url=*)
        EPM_URL=${1#--url=}
        shift
        ;;
      --user)
        [ $# -ge 2 ] || die "$1 requires a value"
        EPM_USER=$2
        shift 2
        ;;
      --user=*)
        EPM_USER=${1#--user=}
        shift
        ;;
      --password)
        [ $# -ge 2 ] || die "$1 requires a value"
        EPM_PASSWORD=$2
        shift 2
        ;;
      --password=*)
        EPM_PASSWORD=${1#--password=}
        shift
        ;;
      --domain)
        [ $# -ge 2 ] || die "$1 requires a value"
        EPM_DOMAIN=$2
        shift 2
        ;;
      --domain=*)
        EPM_DOMAIN=${1#--domain=}
        shift
        ;;
      --token)
        [ $# -ge 2 ] || die "$1 requires a value"
        EPM_TOKEN=$2
        shift 2
        ;;
      --token=*)
        EPM_TOKEN=${1#--token=}
        shift
        ;;
      --prefix)
        [ $# -ge 2 ] || die "$1 requires a value"
        EPM_INSTALL_DIR=$2
        shift 2
        ;;
      --prefix=*)
        EPM_INSTALL_DIR=${1#--prefix=}
        shift
        ;;
      --from-file)
        [ $# -ge 2 ] || die "$1 requires a value"
        EPM_INSTALLER=$2
        shift 2
        ;;
      --from-file=*)
        EPM_INSTALLER=${1#--from-file=}
        shift
        ;;
      --skip-java)
        EPM_SKIP_JAVA=1
        shift
        ;;
      --skip-upgrade)
        EPM_SKIP_UPGRADE=1
        shift
        ;;
      --)
        shift
        break
        ;;
      -*)
        die "unknown option: $1 (try --help)"
        ;;
      *)
        die "unexpected argument: $1 (try --help)"
        ;;
    esac
  done
}

# --- OS ---

detect_os() {
  _s=$(uname -s 2>/dev/null || printf '%s' unknown)
  case $_s in
    Linux*)
      TARGET_OS=unix
      TARGET_KIND=linux
      OS_LABEL=Linux
      ;;
    Darwin*)
      TARGET_OS=unix
      TARGET_KIND=linux
      OS_LABEL=macOS
      ;;
    MINGW*|MSYS*|CYGWIN*)
      TARGET_OS=windows
      TARGET_KIND=windows
      OS_LABEL=Windows
      ;;
    *)
      if [ -n "${WINDIR-}" ] || [ -n "${SYSTEMROOT-}" ]; then
        TARGET_OS=windows
        TARGET_KIND=windows
        OS_LABEL=Windows
      else
        die "unsupported OS: $_s (need Windows, Linux, or macOS)"
      fi
      ;;
  esac
}

# --- URL / download ---

strip_slash() {
  _u=$1
  while [ "$_u" != "${_u%/}" ]; do
    _u=${_u%/}
  done
  printf '%s' "$_u"
}

normalize_base() {
  _u=$(trim_cr "$1")
  _u=$(strip_slash "$_u")
  case $_u in
    */epmcloud) _u=${_u%/epmcloud} ;;
  esac
  case $_u in
    */HyperionPlanning) _u=${_u%/HyperionPlanning} ;;
  esac
  case $_u in
    */workspace) _u=${_u%/workspace} ;;
  esac
  strip_slash "$_u"
}

hex2() {
  dd if="$1" bs=1 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n'
}

is_mz() {
  [ "$(hex2 "$1")" = "4d5a" ]
}

is_gzip() {
  [ "$(hex2 "$1")" = "1f8b" ]
}

is_ustar() {
  _m=$(dd if="$1" bs=1 skip=257 count=5 2>/dev/null || true)
  [ "$_m" = "ustar" ]
}

is_html_or_json() {
  _h=$(dd if="$1" bs=1 count=96 2>/dev/null || true)
  _l=$(printf '%s' "$_h" | tr '[:upper:]' '[:lower:]')
  case $_l in
    *'<html'*|*'<!doctype'*|*'<?xml'*) return 0 ;;
  esac
  case $_h in
    '{'*|'['*) return 0 ;;
  esac
  return 1
}

file_size() {
  _n=$(wc -c <"$1" | tr -d ' ')
  printf '%s' "$_n"
}

validate_installer() {
  _f=$1
  _kind=$2
  [ -f "$_f" ] || return 1
  _sz=$(file_size "$_f")
  [ -n "$_sz" ] && [ "$_sz" -ge "$MIN_BYTES" ] 2>/dev/null || return 1
  if is_html_or_json "$_f"; then
    return 1
  fi
  case $_kind in
    windows)
      is_mz "$_f"
      ;;
    linux)
      is_gzip "$_f" || is_ustar "$_f"
      ;;
    *)
      return 1
      ;;
  esac
}

list_candidates() {
  _kind=$1
  _base=$2
  for _root in "$_base" "$_base/epmcloud" "$_base/HyperionPlanning"; do
    if [ "$_kind" = windows ]; then
      printf '%s\n' \
        "$_root/interop/rest/11.1.2.3.600/epmautomate?os=windows" \
        "$_root/interop/rest/11.1.2.3.600/epmautomate?os=win" \
        "$_root/interop/rest/11.1.2.3.600/epmautomate?platform=windows" \
        "$_root/interop/rest/v1/epmautomate?os=windows" \
        "$_root/interop/rest/v1/epmautomate?platform=windows" \
        "$_root/interop/rest/v2/epmautomate?os=windows" \
        "$_root/download/epmautomate/windows" \
        "$_root/download?product=epmautomate&platform=windows" \
        "$_root/HyperionPlanning/download/epmautomate/windows" \
        "$_root/epmautomate/windows/EPM%20Automate.exe" \
        "$_root/epmautomate/windows/EPMAutomate.exe" \
        "$_root/epmautomate/EPM%20Automate.exe" \
        "$_root/epmautomate/EPMAutomate.exe" \
        "$_root/epmstatic/epmautomate/EPM%20Automate.exe" \
        "$_root/epmstatic/epmautomate/EPMAutomate.exe"
    else
      printf '%s\n' \
        "$_root/interop/rest/11.1.2.3.600/epmautomate?os=linux" \
        "$_root/interop/rest/11.1.2.3.600/epmautomate?platform=linux" \
        "$_root/interop/rest/v1/epmautomate?os=linux" \
        "$_root/interop/rest/v1/epmautomate?platform=linux" \
        "$_root/interop/rest/v2/epmautomate?os=linux" \
        "$_root/download/epmautomate/linux" \
        "$_root/download?product=epmautomate&platform=linux" \
        "$_root/HyperionPlanning/download/epmautomate/linux" \
        "$_root/epmautomate/linux/EPMAutomate.tar" \
        "$_root/epmautomate/EPMAutomate.tar" \
        "$_root/epmstatic/epmautomate/EPMAutomate.tar" \
        "$_root/epmstatic/common/epmautomate/EPMAutomate.tar" \
        "$_root/workspace/download/epmautomate"
    fi
  done
}

curl_download() {
  _url=$1
  _dest=$2
  _auth=$3
  set -- -sS -L --connect-timeout 30 --retry 2 \
    -A "$USER_AGENT" \
    -H "Accept: application/octet-stream,*/*" \
    -o "$_dest" \
    -w "%{http_code}"
  if [ "$_auth" = yes ]; then
    if [ -n "$EPM_TOKEN" ]; then
      set -- "$@" -H "Authorization: Bearer ${EPM_TOKEN}"
    else
      set -- "$@" -u "${EPM_USER}:${EPM_PASSWORD}"
    fi
  fi
  # curl non-zero (network) must not abort the candidate loop
  _code=$(curl "$@" "$_url") || _code=000
  printf '%s' "$_code"
}

has_creds() {
  [ -n "$EPM_TOKEN" ] || { [ -n "$EPM_USER" ] && [ -n "$EPM_PASSWORD" ]; }
}

try_candidate_urls() {
  _dest=$1
  _kind=$2
  _cand_file=$3
  _use_auth=$4
  _n=$(wc -l <"$_cand_file" | tr -d ' ')
  _try=0
  while IFS= read -r _url; do
    [ -n "$_url" ] || continue
    _try=$((_try + 1))
    printf '    [%s/%s] %s\n' "$_try" "$_n" "$_url"
    _code=$(curl_download "$_url" "$_dest" "$_use_auth")
    LAST_HTTP=$_code
    if [ "$_code" = 200 ] && validate_installer "$_dest" "$_kind"; then
      info "using $_url"
      return 0
    fi
    rm -f "$_dest"
  done <"$_cand_file"
  return 1
}

download_from_epm() {
  _dest=$1
  _kind=$2
  _base=$3
  LAST_HTTP=000

  _cand_file="${TMPDIR:-/tmp}/epm-urls.$$"
  list_candidates "$_kind" "$_base" | sort -u | sed '/^$/d' >"$_cand_file"

  info "downloading EPM Automate ($_kind)"

  if has_creds; then
    if try_candidate_urls "$_dest" "$_kind" "$_cand_file" yes; then
      rm -f "$_cand_file"
      return 0
    fi
    rm -f "$_cand_file"
    return 1
  fi

  if try_candidate_urls "$_dest" "$_kind" "$_cand_file" no; then
    rm -f "$_cand_file"
    return 0
  fi

  if can_prompt; then
    info "anonymous download did not return an installer; Cloud EPM credentials are required"
    [ -n "$EPM_USER" ] || EPM_USER=$(prompt_text "EPM user: ")
    [ -n "$EPM_PASSWORD" ] || EPM_PASSWORD=$(prompt_secret "EPM password: ")
  fi

  if has_creds; then
    info "retrying download with credentials"
    if try_candidate_urls "$_dest" "$_kind" "$_cand_file" yes; then
      rm -f "$_cand_file"
      return 0
    fi
  fi

  rm -f "$_cand_file"
  return 1
}

ensure_url() {
  if [ -n "$EPM_INSTALLER" ]; then
    return 0
  fi
  [ -n "$EPM_URL" ] || {
    if can_prompt; then
      EPM_URL=$(prompt_text "Cloud EPM URL: ")
    fi
  }
  [ -n "$EPM_URL" ] || die "EPM_URL is required (example: https://epm-xxx.epm.region.ocs.oraclecloud.com/epmcloud)"
}

# --- Windows ---

windows_temp() {
  if [ -n "${TEMP-}" ]; then
    printf '%s' "$TEMP"
  elif [ -n "${TMPDIR-}" ]; then
    printf '%s' "$TMPDIR"
  else
    printf '%s' /tmp
  fi
}

to_win_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1"
  else
    printf '%s' "$1"
  fi
}

launch_windows_exe() {
  _exe=$1
  _win=$(to_win_path "$_exe")
  info "launching Windows installer (accept UAC, then walk through the GUI)"
  if command -v powershell.exe >/dev/null 2>&1; then
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command \
      "try { Start-Process -LiteralPath '$_win' -Verb RunAs } catch { Start-Process -LiteralPath '$_win' }"
  elif command -v cmd.exe >/dev/null 2>&1; then
    cmd.exe /c start "" "$_win"
  else
    die "downloaded $_exe but could not launch it (no powershell.exe / cmd.exe)"
  fi
  cat <<'EOF'

The EPM Automate GUI installer is running.
Default location: Program Files\Oracle\EPM Automate
After it finishes, open an elevated Command Prompt and run:

    epmautomate upgrade

so the client matches the latest Cloud EPM release.
EOF
}

# --- Unix Java / extract / PATH ---

java_major() {
  _bin=$1
  _out=$("$_bin" -version 2>&1) || return 1
  _ver=$(printf '%s\n' "$_out" | sed -n 's/.*version "\([^"]*\)".*/\1/p' | head -n 1)
  [ -n "$_ver" ] || return 1
  case $_ver in
    1.*)
      printf '%s\n' "$_ver" | sed -n 's/^1\.\([0-9][0-9]*\).*/\1/p'
      ;;
    *)
      printf '%s\n' "$_ver" | sed -n 's/^\([0-9][0-9]*\).*/\1/p'
      ;;
  esac
}

java_ok() {
  _m=$(java_major "$1") || return 1
  [ -n "$_m" ] && [ "$_m" -ge 17 ] 2>/dev/null
}

resolve_symlink() {
  _p=$1
  _n=0
  while [ -L "$_p" ] && [ "$_n" -lt 20 ]; do
    _t=$(ls -ld "$_p" | sed 's/.* -> //')
    case $_t in
      /*) _p=$_t ;;
      *) _p=$(dirname "$_p")/$_t ;;
    esac
    _n=$((_n + 1))
  done
  printf '%s' "$_p"
}

java_home_from_bin() {
  _bin=$(resolve_symlink "$1")
  _dir=$(dirname "$_bin")
  _home=$(dirname "$_dir")
  if [ -x "$_home/bin/java" ]; then
    printf '%s' "$_home"
    return 0
  fi
  return 1
}

find_java_home() {
  if [ -n "${JAVA_HOME-}" ] && [ -x "$JAVA_HOME/bin/java" ] && java_ok "$JAVA_HOME/bin/java"; then
    printf '%s' "$JAVA_HOME"
    return 0
  fi
  if command -v java >/dev/null 2>&1; then
    _j=$(command -v java)
    if java_ok "$_j"; then
      if _h=$(java_home_from_bin "$_j"); then
        printf '%s' "$_h"
        return 0
      fi
    fi
  fi
  for _d in \
    /usr/lib/jvm/java-21-openjdk* \
    /usr/lib/jvm/java-17-openjdk* \
    /usr/lib/jvm/jre-17* \
    /usr/lib/jvm/java-21* \
    /usr/lib/jvm/java-17* \
    /opt/jdk-21* \
    /opt/jdk-17* \
    /opt/jdk_17* \
    /Library/Java/JavaVirtualMachines/*/Contents/Home
  do
    [ -x "$_d/bin/java" ] || continue
    if java_ok "$_d/bin/java"; then
      printf '%s' "$_d"
      return 0
    fi
  done
  if [ "$(uname -s 2>/dev/null)" = Darwin ] && command -v /usr/libexec/java_home >/dev/null 2>&1; then
    _h=$(/usr/libexec/java_home 2>/dev/null) || true
    if [ -n "$_h" ] && [ -x "$_h/bin/java" ] && java_ok "$_h/bin/java"; then
      printf '%s' "$_h"
      return 0
    fi
  fi
  return 1
}

have_sudo() {
  if [ "$(id -u)" = 0 ]; then
    return 0
  fi
  command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null
}

pkg_sudo() {
  if [ "$(id -u)" = 0 ]; then
    printf '%s' ""
  else
    printf '%s' "sudo"
  fi
}

install_java17() {
  if [ -n "$EPM_SKIP_JAVA" ] && [ "$EPM_SKIP_JAVA" != 0 ]; then
    die "Java 17+ is required. Install a JRE and set JAVA_HOME, or omit --skip-java"
  fi
  info "Java 17+ not found; installing OpenJDK 17"
  if ! have_sudo && [ "$(id -u)" != 0 ]; then
    die "need root or passwordless sudo to install Java 17 (or install it yourself and re-run)"
  fi
  _sudo=$(pkg_sudo)
  if command -v apt-get >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    $_sudo apt-get update -y
    # shellcheck disable=SC2086
    DEBIAN_FRONTEND=noninteractive $_sudo apt-get install -y openjdk-17-jre-headless
  elif command -v dnf >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    $_sudo dnf install -y java-17-openjdk
  elif command -v yum >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    $_sudo yum install -y java-17-openjdk
  elif command -v zypper >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    $_sudo zypper --non-interactive install java-17-openjdk
  elif command -v pacman >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    $_sudo pacman -Sy --noconfirm jre17-openjdk
  elif command -v apk >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    $_sudo apk add --no-cache openjdk17-jre
  else
    die "no supported package manager found; install Java 17 and set JAVA_HOME"
  fi
}

ensure_java() {
  if FOUND_JAVA=$(find_java_home); then
    JAVA_HOME=$FOUND_JAVA
    export JAVA_HOME
    info "using JAVA_HOME=$JAVA_HOME"
    return 0
  fi
  install_java17
  if FOUND_JAVA=$(find_java_home); then
    JAVA_HOME=$FOUND_JAVA
    export JAVA_HOME
    info "using JAVA_HOME=$JAVA_HOME"
    return 0
  fi
  die "Java 17+ is required but was not found after installation"
}

default_prefix() {
  if [ -n "$EPM_INSTALL_DIR" ]; then
    printf '%s' "$EPM_INSTALL_DIR"
    return
  fi
  if [ "$(id -u)" = 0 ]; then
    printf '%s' /opt/oracle/epmautomate
  else
    printf '%s' "${HOME}/.local/oracle/epmautomate"
  fi
}

extract_tar() {
  _archive=$1
  _tmpdir=$2
  mkdir -p "$_tmpdir"
  if is_gzip "$_archive"; then
    if tar xf "$_archive" -C "$_tmpdir" 2>/dev/null; then
      return 0
    fi
    need_cmd gzip
    gzip -dc "$_archive" | tar xf - -C "$_tmpdir"
  else
    tar xf "$_archive" -C "$_tmpdir"
  fi
}

find_epmautomate_sh() {
  _root=$1
  find "$_root" -name epmautomate.sh \( -type f -o -type l \) 2>/dev/null | head -n 1
}

copy_tree() {
  _src=$1
  _dst=$2
  mkdir -p "$_dst"
  tar cf - -C "$_src" . | tar xf - -C "$_dst"
}

write_env_sh() {
  _dir=$1
  cat >"$_dir/env.sh" <<EOF
# Generated by epmautomate-install ${VERSION}
export JAVA_HOME='${JAVA_HOME}'
PATH='${_dir}/bin':"\$PATH"
export PATH
EOF
}

write_wrapper() {
  _dir=$1
  _wrap=$2
  mkdir -p "$(dirname "$_wrap")"
  cat >"$_wrap" <<EOF
#!/bin/sh
export JAVA_HOME='${JAVA_HOME}'
exec '${_dir}/bin/epmautomate.sh' "\$@"
EOF
  chmod +x "$_wrap"
}

upsert_rc() {
  _file=$1
  _dir=$2
  [ -n "$_file" ] || return 0
  if [ ! -e "$_file" ]; then
    if ! : >"$_file" 2>/dev/null; then
      warn "could not create $_file"
      return 0
    fi
  fi
  _tmp="${_file}.epmnew"
  if grep -q "$MARKER_BEGIN" "$_file" 2>/dev/null; then
    awk -v b="$MARKER_BEGIN" -v e="$MARKER_END" '
      $0 == b { skip = 1; next }
      $0 == e { skip = 0; next }
      !skip { print }
    ' "$_file" >"$_tmp" || {
      rm -f "$_tmp"
      warn "could not update $_file"
      return 0
    }
  else
    cp "$_file" "$_tmp"
  fi
  cat >>"$_tmp" <<EOF
${MARKER_BEGIN}
[ -f '${_dir}/env.sh' ] && . '${_dir}/env.sh'
${MARKER_END}
EOF
  mv "$_tmp" "$_file"
}

install_unix() {
  _archive=$1
  need_cmd tar
  need_cmd find
  ensure_java

  PREFIX=$(default_prefix)
  case $PREFIX in
    /|/usr|/usr/local|/usr/bin|/bin|/etc|/opt|"$HOME"|"$HOME/")
      die "refusing to install into $PREFIX (choose a dedicated directory)"
      ;;
  esac
  info "installing to $PREFIX"

  _stage="${TMPDIR:-/tmp}/epm-extract.$$"
  rm -rf "$_stage"
  mkdir -p "$_stage"
  extract_tar "$_archive" "$_stage"

  _script=$(find_epmautomate_sh "$_stage")
  [ -n "$_script" ] && [ -f "$_script" ] || die "EPMAutomate.tar did not contain epmautomate.sh"
  _pkg=$(dirname "$(dirname "$_script")")

  rm -rf "$PREFIX"
  copy_tree "$_pkg" "$PREFIX"
  rm -rf "$_stage"

  chmod +x "$PREFIX/bin/epmautomate.sh"
  write_env_sh "$PREFIX"

  if [ "$(id -u)" = 0 ]; then
    _wrap=/usr/local/bin/epmautomate
  else
    mkdir -p "${HOME}/.local/bin"
    _wrap="${HOME}/.local/bin/epmautomate"
  fi
  write_wrapper "$PREFIX" "$_wrap"
  info "wrapper $_wrap"

  upsert_rc "${HOME}/.profile" "$PREFIX"
  case ${SHELL-} in
    */zsh) upsert_rc "${HOME}/.zshrc" "$PREFIX" ;;
    */bash) upsert_rc "${HOME}/.bashrc" "$PREFIX" ;;
    *)
      [ -f "${HOME}/.bashrc" ] && upsert_rc "${HOME}/.bashrc" "$PREFIX"
      [ -f "${HOME}/.zshrc" ] && upsert_rc "${HOME}/.zshrc" "$PREFIX"
      ;;
  esac

  info "checking epmautomate.sh"
  set +e
  _out=$("$PREFIX/bin/epmautomate.sh" 2>&1)
  _st=$?
  set -e
  printf '%s\n' "$_out"
  if [ "$_st" -ne 0 ]; then
    warn "epmautomate.sh exited $_st (often normal when run with no command)"
  fi

  if [ -z "$EPM_SKIP_UPGRADE" ] || [ "$EPM_SKIP_UPGRADE" = 0 ]; then
    if [ -n "$EPM_USER" ] && [ -n "$EPM_PASSWORD" ] && [ -n "$EPM_URL_RAW" ]; then
      info "logging in and running upgrade (Downloads copy can lag the latest client)"
      (
        # shellcheck disable=SC1091
        . "$PREFIX/env.sh"
        if [ -n "$EPM_DOMAIN" ]; then
          "$PREFIX/bin/epmautomate.sh" login "$EPM_USER" "$EPM_PASSWORD" "$EPM_URL_RAW" "$EPM_DOMAIN"
        else
          "$PREFIX/bin/epmautomate.sh" login "$EPM_USER" "$EPM_PASSWORD" "$EPM_URL_RAW"
        fi
        "$PREFIX/bin/epmautomate.sh" upgrade
        "$PREFIX/bin/epmautomate.sh" logout || true
      ) || warn "upgrade skipped (login or upgrade failed); run it later with: epmautomate upgrade"
    else
      info "skipping upgrade (set EPM_USER and EPM_PASSWORD to enable)"
    fi
  fi

  cat <<EOF

EPM Automate is installed.
  prefix:  $PREFIX
  command: $_wrap

Open a new terminal, or run:
  . ${HOME}/.profile

Then:
  epmautomate
EOF
}

# --- main ---

main() {
  parse_args "$@"
  detect_os
  info "detected $OS_LABEL"

  need_cmd curl
  need_cmd dd
  need_cmd od
  need_cmd tr
  need_cmd wc
  need_cmd sed
  need_cmd sort

  if [ -n "$EPM_INSTALLER" ]; then
    [ -f "$EPM_INSTALLER" ] || die "installer not found: $EPM_INSTALLER"
    if ! validate_installer "$EPM_INSTALLER" "$TARGET_KIND"; then
      die "$EPM_INSTALLER is not a valid $TARGET_KIND EPM Automate installer"
    fi
    _file=$EPM_INSTALLER
    info "using local file $_file"
    if [ -n "$EPM_URL" ]; then
      EPM_URL_RAW=$(trim_cr "$EPM_URL")
    else
      EPM_URL_RAW=
    fi
  else
    ensure_url
    EPM_URL_RAW=$(trim_cr "$EPM_URL")
    EPM_BASE=$(normalize_base "$EPM_URL_RAW")
    info "Cloud EPM: $EPM_BASE"

    _dest=
    case $TARGET_OS in
      windows)
        _td=$(windows_temp)
        mkdir -p "$_td"
        _dest="${_td}/EPM Automate.exe"
        ;;
      unix)
        _dest="${TMPDIR:-/tmp}/EPMAutomate.tar.$$"
        ;;
    esac
    rm -f "$_dest"

    if ! download_from_epm "$_dest" "$TARGET_KIND" "$EPM_BASE"; then
      cat >&2 <<EOF
error: could not download a valid EPM Automate installer from Cloud EPM.
Last HTTP status: ${LAST_HTTP}

Oracle only publishes the client on each environment's Downloads page
(Settings and Actions > Downloads). There is no public CDN.

Download it in a browser, then re-run:
  sh install.sh --from-file /path/to/installer

Basic auth cannot be used with MFA accounts.
EOF
      exit 1
    fi
    _file=$_dest
  fi

  case $TARGET_OS in
    windows)
      launch_windows_exe "$_file"
      ;;
    unix)
      install_unix "$_file"
      if [ -z "$EPM_INSTALLER" ]; then
        rm -f "$_file"
      fi
      ;;
  esac
}

main "$@"
