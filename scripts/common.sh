#!/usr/bin/env bash
# Общий модуль: логирование, конфигурация, проверки и обработка ошибок.
# shellcheck disable=SC2034

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Определение путей проекта
# ---------------------------------------------------------------------------
COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${COMMON_DIR}/.." && pwd)"
CONFIG_DIR="${PROJECT_ROOT}/config"
SCRIPTS_DIR="${PROJECT_ROOT}/scripts"
DOCS_DIR="${PROJECT_ROOT}/docs"
DEFAULT_LOG_DIR="${PROJECT_ROOT}/logs"
DEFAULT_STATE_DIR="${PROJECT_ROOT}/state"
DEFAULT_ARTIFACT_DIR="${PROJECT_ROOT}/artifacts"

# ---------------------------------------------------------------------------
# Сохранить переменные из окружения процесса ДО значений по умолчанию,
# чтобы CLI (CONFIRM_INSTALL=YES bash ...) не перезаписывался deploy.env.
# ---------------------------------------------------------------------------
_ENV_CONFIRM_INSTALL="${CONFIRM_INSTALL-}"
_ENV_DB_ENGINE="${DB_ENGINE-}"
_ENV_APPLY_SECURITY_UPDATES="${APPLY_SECURITY_UPDATES-}"
_ENV_CONFIRM_REBOOT="${CONFIRM_REBOOT-}"
_ENV_INSTALLER_SHA256="${INSTALLER_SHA256-}"
_ENV_HTTPS_TEST_URL="${HTTPS_TEST_URL-}"
_ENV_MIN_RAM_MB="${MIN_RAM_MB-}"
_ENV_MIN_DISK_GB="${MIN_DISK_GB-}"
_ENV_ADMIN_SOURCE_IP="${ADMIN_SOURCE_IP-}"
_ENV_SITE_DOMAIN="${SITE_DOMAIN-}"

# ---------------------------------------------------------------------------
# Значения по умолчанию (перекрываются deploy.env, но CLI имеет приоритет)
# ---------------------------------------------------------------------------
PROJECT_NAME="${PROJECT_NAME:-cloudpanel-deploy}"
DEPLOY_MODE="${DEPLOY_MODE:-diagnose}"
SUPPORTED_DEBIAN_VERSIONS="${SUPPORTED_DEBIAN_VERSIONS:-12 13}"
MIN_RAM_MB="${MIN_RAM_MB:-2048}"
MIN_DISK_GB="${MIN_DISK_GB:-10}"
# Рекомендуемый запас свободного места после swap/кэшей (урок с 10GB VPS)
MIN_FREE_DISK_AFTER_SWAP_GB="${MIN_FREE_DISK_AFTER_SWAP_GB:-5}"
MIN_CPU_CORES="${MIN_CPU_CORES:-1}"
SUPPORTED_ARCHITECTURES="${SUPPORTED_ARCHITECTURES:-x86_64 amd64 aarch64 arm64}"
SITE_DOMAIN="${SITE_DOMAIN:-}"
EXPECTED_PUBLIC_IPV4="${EXPECTED_PUBLIC_IPV4:-}"
EXPECTED_HOSTNAME="${EXPECTED_HOSTNAME:-}"
DB_ENGINE="${DB_ENGINE:-MARIADB_11.8}"
INSTALLER_URL="${INSTALLER_URL:-https://installer.cloudpanel.io/ce/v2/install.sh}"
INSTALLER_SHA256="${INSTALLER_SHA256:-8146dbe0a488e7088b04071b0c34d59aa0ab1fe9dcec382d395fd155c9e6c476}"
LOG_DIR="${LOG_DIR:-}"
STATE_DIR="${STATE_DIR:-}"
ARTIFACT_DIR="${ARTIFACT_DIR:-}"
DNS_TEST_HOST="${DNS_TEST_HOST:-deb.debian.org}"
# Корень installer.cloudpanel.io/ часто отдаёт 403; проверяем сам install.sh
HTTPS_TEST_URL="${HTTPS_TEST_URL:-https://installer.cloudpanel.io/ce/v2/install.sh}"
APT_MIRROR_CHECK="${APT_MIRROR_CHECK:-1}"
CHECK_IPV6="${CHECK_IPV6:-1}"
SSH_PORT="${SSH_PORT:-22}"
HTTP_PORT="${HTTP_PORT:-80}"
HTTPS_PORT="${HTTPS_PORT:-443}"
CLOUDPANEL_PORT="${CLOUDPANEL_PORT:-8443}"
ADMIN_SOURCE_IP="${ADMIN_SOURCE_IP:-}"
CONFIRM_INSTALL="${CONFIRM_INSTALL:-NO}"
APPLY_SECURITY_UPDATES="${APPLY_SECURITY_UPDATES:-NO}"
CONFIRM_REBOOT="${CONFIRM_REBOOT:-NO}"
CONFIRM_HOSTNAME_CHANGE="${CONFIRM_HOSTNAME_CHANGE:-NO}"
NEW_HOSTNAME="${NEW_HOSTNAME:-}"
CONFLICT_POLICY="${CONFLICT_POLICY:-block}"
NETWORK_TIMEOUT="${NETWORK_TIMEOUT:-10}"
CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-8}"
# Автосоздание swap при RAM < официального минимума (prepare)
ENSURE_SWAP="${ENSURE_SWAP:-YES}"
SWAP_SIZE_MB="${SWAP_SIZE_MB:-2048}"

# Официальные источники
OFFICIAL_DOCS_INSTALL="https://www.cloudpanel.io/docs/v2/getting-started/other/"
OFFICIAL_DOCS_REQUIREMENTS="https://www.cloudpanel.io/docs/v2/requirements/"
OFFICIAL_DOCS_SECURITY="https://www.cloudpanel.io/docs/v2/guides/best-practices/security/"
OFFICIAL_DOCS_TLS="https://www.cloudpanel.io/docs/v2/frontend-area/tls/"
OFFICIAL_DOCS_WORDPRESS="https://www.cloudpanel.io/docs/v2/php/applications/wordpress/"

# Состояние выполнения
SCRIPT_NAME="${SCRIPT_NAME:-unknown}"
LOG_FILE=""
ERROR_LOG_FILE=""
RUN_ID=""
STARTED_AT=""
CURRENT_STAGE="init"
PREFLIGHT_STATUS="UNKNOWN"
declare -a WARNINGS=()
declare -a ERRORS=()
declare -a CONFLICTS=()
declare -a INFO_NOTES=()

# ---------------------------------------------------------------------------
# Утилиты
# ---------------------------------------------------------------------------
is_true() {
  local value
  value="$(printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]')"
  case "${value}" in
    YES|Y|TRUE|1|ON) return 0 ;;
    *) return 1 ;;
  esac
}

trim() {
  local s="${1:-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

human_time() {
  date +"%Y-%m-%d %H:%M:%S %Z"
}

ensure_dir() {
  local dir="$1"
  local mode="${2:-750}"
  mkdir -p "${dir}"
  chmod "${mode}" "${dir}"
}

# Удаляет потенциально чувствительные фрагменты из текста перед журналированием.
sanitize_for_log() {
  local text="${1:-}"
  # Пароли / токены в типичных формах аргументов
  text="$(printf '%s' "${text}" | sed -E \
    -e 's/(password|passwd|pwd|token|secret|api[_-]?key|authorization)[=:][^[:space:]]+/\1=***REDACTED***/Ig' \
    -e 's/(--password[= ])[^[:space:]]+/\1***REDACTED***/Ig' \
    -e 's/(Bearer[[:space:]]+)[A-Za-z0-9._~+/=-]+/\1***REDACTED***/Ig')"
  printf '%s' "${text}"
}

color_enabled() {
  [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]
}

# ---------------------------------------------------------------------------
# Логирование
# ---------------------------------------------------------------------------
_log_write() {
  local level="$1"
  shift
  local message
  message="$(sanitize_for_log "$*")"
  local line
  line="[$(timestamp)] [${level}] [${SCRIPT_NAME}] [${CURRENT_STAGE}] ${message}"
  if [[ -n "${LOG_FILE}" ]]; then
    printf '%s\n' "${line}" >>"${LOG_FILE}"
  fi
  # Все уровни — в stderr, чтобы захват stdout ($(...)) не ломался логами.
  case "${level}" in
    ERROR)
      if color_enabled; then
        printf '\033[31m%s\033[0m\n' "${line}" >&2
      else
        printf '%s\n' "${line}" >&2
      fi
      ;;
    WARN)
      if color_enabled; then
        printf '\033[33m%s\033[0m\n' "${line}" >&2
      else
        printf '%s\n' "${line}" >&2
      fi
      ;;
    SUCCESS)
      if color_enabled; then
        printf '\033[32m%s\033[0m\n' "${line}" >&2
      else
        printf '%s\n' "${line}" >&2
      fi
      ;;
    *)
      printf '%s\n' "${line}" >&2
      ;;
  esac
}

log_info() { _log_write "INFO" "$@"; }
log_warn() {
  WARNINGS+=("$*")
  _log_write "WARN" "$@"
}
log_error() {
  ERRORS+=("$*")
  _log_write "ERROR" "$@"
}
log_success() { _log_write "SUCCESS" "$@"; }

set_stage() {
  CURRENT_STAGE="$1"
  log_info "Этап: ${CURRENT_STAGE}"
}

add_conflict() {
  CONFLICTS+=("$*")
  log_warn "Конфликт: $*"
}

add_note() {
  INFO_NOTES+=("$*")
  log_info "$*"
}

# ---------------------------------------------------------------------------
# Обработка ошибок и сигналов
# ---------------------------------------------------------------------------
on_error() {
  local exit_code=$?
  local line_no="${1:-unknown}"
  log_error "Сбой на этапе '${CURRENT_STAGE}' (строка ${line_no}, код ${exit_code})."
  log_error "Рекомендация: изучите журнал ${LOG_FILE:-"(не задан)"} и docs/TROUBLESHOOTING.md."
  if [[ -n "${ERROR_LOG_FILE:-}" ]]; then
    {
      echo "---- failure snapshot $(timestamp) ----"
      echo "stage=${CURRENT_STAGE}"
      echo "line=${line_no}"
      echo "exit=${exit_code}"
      echo "script=${SCRIPT_NAME}"
    } >>"${ERROR_LOG_FILE}"
  fi
  exit "${exit_code}"
}

on_signal() {
  local sig="$1"
  log_error "Получен сигнал ${sig}. Выполнение прервано на этапе '${CURRENT_STAGE}'."
  log_error "Частичное выполнение возможно. Не повторяйте установку без диагностики."
  exit 130
}

setup_traps() {
  trap 'on_error ${LINENO}' ERR
  trap 'on_signal INT' INT
  trap 'on_signal TERM' TERM
  trap 'on_signal HUP' HUP
}

# ---------------------------------------------------------------------------
# Конфигурация
# ---------------------------------------------------------------------------
restore_cli_overrides() {
  # Переменные, заданные в окружении при запуске скрипта, важнее deploy.env.
  # Всегда return 0: иначе последний ложный [[ ]] ломает set -e у вызывающего.
  [[ -n "${_ENV_CONFIRM_INSTALL}" ]] && CONFIRM_INSTALL="${_ENV_CONFIRM_INSTALL}"
  [[ -n "${_ENV_DB_ENGINE}" ]] && DB_ENGINE="${_ENV_DB_ENGINE}"
  [[ -n "${_ENV_APPLY_SECURITY_UPDATES}" ]] && APPLY_SECURITY_UPDATES="${_ENV_APPLY_SECURITY_UPDATES}"
  [[ -n "${_ENV_CONFIRM_REBOOT}" ]] && CONFIRM_REBOOT="${_ENV_CONFIRM_REBOOT}"
  [[ -n "${_ENV_INSTALLER_SHA256}" ]] && INSTALLER_SHA256="${_ENV_INSTALLER_SHA256}"
  [[ -n "${_ENV_HTTPS_TEST_URL}" ]] && HTTPS_TEST_URL="${_ENV_HTTPS_TEST_URL}"
  [[ -n "${_ENV_MIN_RAM_MB}" ]] && MIN_RAM_MB="${_ENV_MIN_RAM_MB}"
  [[ -n "${_ENV_MIN_DISK_GB}" ]] && MIN_DISK_GB="${_ENV_MIN_DISK_GB}"
  [[ -n "${_ENV_ADMIN_SOURCE_IP}" ]] && ADMIN_SOURCE_IP="${_ENV_ADMIN_SOURCE_IP}"
  [[ -n "${_ENV_SITE_DOMAIN}" ]] && SITE_DOMAIN="${_ENV_SITE_DOMAIN}"
  return 0
}

load_config() {
  local env_file="${1:-${CONFIG_DIR}/deploy.env}"
  local example_file="${CONFIG_DIR}/deploy.env.example"

  if [[ -f "${env_file}" ]]; then
    # shellcheck disable=SC1090
    set -a
    # shellcheck source=/dev/null
    source "${env_file}"
    set +a
    restore_cli_overrides
    log_info "Загружена конфигурация: ${env_file}"
  elif [[ -f "${example_file}" ]]; then
    log_warn "Файл ${env_file} не найден. Используются значения по умолчанию из example/common.sh."
  else
    log_warn "Конфигурация не найдена. Используются встроенные значения по умолчанию."
  fi

  LOG_DIR="${LOG_DIR:-${DEFAULT_LOG_DIR}}"
  STATE_DIR="${STATE_DIR:-${DEFAULT_STATE_DIR}}"
  ARTIFACT_DIR="${ARTIFACT_DIR:-${DEFAULT_ARTIFACT_DIR}}"
}

init_runtime() {
  SCRIPT_NAME="${1:-unknown}"
  RUN_ID="$(date +%Y%m%dT%H%M%S)_$$"
  STARTED_AT="$(human_time)"

  ensure_dir "${LOG_DIR}" 750
  ensure_dir "${STATE_DIR}" 750
  ensure_dir "${ARTIFACT_DIR}" 750

  LOG_FILE="${LOG_DIR}/${SCRIPT_NAME}_${RUN_ID}.log"
  ERROR_LOG_FILE="${LOG_DIR}/${SCRIPT_NAME}_${RUN_ID}.error.log"
  touch "${LOG_FILE}" "${ERROR_LOG_FILE}"
  chmod 640 "${LOG_FILE}" "${ERROR_LOG_FILE}" || true

  setup_traps
  log_info "Старт: ${STARTED_AT}"
  log_info "PROJECT_ROOT=${PROJECT_ROOT}"
  log_info "RUN_ID=${RUN_ID}"
}

finish_runtime() {
  local status="${1:-SUCCESS}"
  local ended
  ended="$(human_time)"
  if [[ "${status}" == "SUCCESS" ]]; then
    log_success "Завершено успешно: ${ended}"
  else
    log_warn "Завершено со статусом ${status}: ${ended}"
  fi
}

require_var() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    log_error "Обязательная переменная не задана: ${name}"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Права и окружение
# ---------------------------------------------------------------------------
have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

is_root() {
  [[ "$(id -u)" -eq 0 ]]
}

can_sudo() {
  if is_root; then
    return 0
  fi
  if have_cmd sudo && sudo -n true >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

require_root_or_sudo() {
  if is_root; then
    log_info "Выполнение от root."
    return 0
  fi
  if can_sudo; then
    log_info "Доступен passwordless sudo."
    return 0
  fi
  log_error "Недостаточно прав. Запустите от root или с работающим sudo:"
  log_error "  sudo bash ${SCRIPTS_DIR}/${SCRIPT_NAME}.sh"
  return 1
}

run_priv() {
  if is_root; then
    "$@"
  else
    sudo "$@"
  fi
}

# ---------------------------------------------------------------------------
# ОС и ресурсы
# ---------------------------------------------------------------------------
read_os_release() {
  if [[ ! -f /etc/os-release ]]; then
    return 1
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-}"
  OS_VERSION_ID="${VERSION_ID:-}"
  OS_VERSION_CODENAME="${VERSION_CODENAME:-}"
  OS_PRETTY_NAME="${PRETTY_NAME:-}"
}

get_arch() {
  uname -m
}

arch_supported() {
  local arch
  arch="$(get_arch)"
  local item
  for item in ${SUPPORTED_ARCHITECTURES}; do
    if [[ "${arch}" == "${item}" ]]; then
      return 0
    fi
  done
  return 1
}

debian_version_supported() {
  local version="${1:-}"
  local item
  for item in ${SUPPORTED_DEBIAN_VERSIONS}; do
    if [[ "${version}" == "${item}" ]]; then
      return 0
    fi
  done
  return 1
}

db_engine_supported_for_debian() {
  local version="$1"
  local engine="$2"
  case "${version}" in
    12)
      case "${engine}" in
        MYSQL_8.4|MYSQL_8.0|MARIADB_10.11|MARIADB_11.4|MARIADB_11.8|MARIADB_12.3) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    13)
      case "${engine}" in
        MYSQL_8.4|MYSQL_8.0|MARIADB_11.8|MARIADB_12.3) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    *)
      return 1
      ;;
  esac
}

mem_total_mb() {
  if [[ -r /proc/meminfo ]]; then
    awk '/MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo
  elif have_cmd sysctl; then
    # macOS / BSD fallback для локальных тестов
    local bytes
    bytes="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
    awk -v b="${bytes}" 'BEGIN {printf "%d", b/1024/1024}'
  else
    echo 0
  fi
}

cpu_cores() {
  if [[ -r /proc/cpuinfo ]]; then
    grep -c ^processor /proc/cpuinfo
  elif have_cmd sysctl; then
    sysctl -n hw.ncpu 2>/dev/null || echo 1
  else
    echo 1
  fi
}

disk_free_gb() {
  local path="${1:-/}"
  df -Pk "${path}" 2>/dev/null | awk 'NR==2 {printf "%.0f", $4/1024/1024}'
}

apt_busy() {
  if [[ -f /var/lib/dpkg/lock-frontend ]] || [[ -f /var/lib/apt/lists/lock ]] || [[ -f /var/lib/dpkg/lock ]]; then
    if have_cmd fuser; then
      if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
        || fuser /var/lib/apt/lists/lock >/dev/null 2>&1 \
        || fuser /var/lib/dpkg/lock >/dev/null 2>&1; then
        return 0
      fi
    fi
  fi
  if [[ -d /var/lib/dpkg/updates ]] && compgen -G "/var/lib/dpkg/updates/[0-9]*" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Сеть
# ---------------------------------------------------------------------------
have_default_route() {
  if have_cmd ip; then
    ip route show default 2>/dev/null | grep -q .
  else
    netstat -rn 2>/dev/null | awk 'NR>1 && ($1=="default" || $1=="0.0.0.0") {found=1} END{exit !found}'
  fi
}

dns_resolves() {
  local host="$1"
  if have_cmd getent; then
    getent ahosts "${host}" >/dev/null 2>&1 && return 0
  fi
  if have_cmd dig; then
    dig +short +time="${NETWORK_TIMEOUT}" "${host}" >/dev/null 2>&1 && return 0
  fi
  if have_cmd nslookup; then
    nslookup "${host}" >/dev/null 2>&1 && return 0
  fi
  return 1
}

https_reachable() {
  local url="$1"
  if ! have_cmd curl; then
    return 1
  fi
  curl -fsS --connect-timeout "${CURL_CONNECT_TIMEOUT}" --max-time "${NETWORK_TIMEOUT}" \
    -o /dev/null -w '' "${url}" >/dev/null 2>&1
}

detect_public_ipv4() {
  local ip=""
  if have_cmd curl; then
    ip="$(curl -4 -fsS --connect-timeout "${CURL_CONNECT_TIMEOUT}" --max-time "${NETWORK_TIMEOUT}" \
      https://api.ipify.org 2>/dev/null || true)"
  fi
  printf '%s' "$(trim "${ip}")"
}

list_local_ipv4() {
  if have_cmd ip; then
    ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1
  elif have_cmd ifconfig; then
    ifconfig 2>/dev/null | awk '/inet / && $2 !~ /^127\./ {print $2}'
  fi
}

listening_ports_summary() {
  if have_cmd ss; then
    ss -tuln 2>/dev/null | awk 'NR>1 {print}' | head -n 50
  elif have_cmd netstat; then
    netstat -tuln 2>/dev/null | awk 'NR>2 {print}' | head -n 50
  else
    echo "ss/netstat недоступны"
  fi
}

# ---------------------------------------------------------------------------
# Состояние / идемпотентность
# ---------------------------------------------------------------------------
write_state_file() {
  local name="$1"
  local content="$2"
  local path="${STATE_DIR}/${name}"
  printf '%s\n' "${content}" >"${path}"
  chmod 640 "${path}" || true
}

read_state_file() {
  local name="$1"
  local path="${STATE_DIR}/${name}"
  if [[ -f "${path}" ]]; then
    cat "${path}"
  fi
}

mark_install_started() {
  write_state_file "install.status" "STARTED $(timestamp)"
}

mark_install_finished() {
  write_state_file "install.status" "FINISHED $(timestamp)"
}

install_status() {
  read_state_file "install.status"
}

cloudpanel_apparently_installed() {
  [[ -d /home/clp ]] || [[ -x /usr/bin/clpctl ]] || [[ -d /etc/cloudpanel ]] || systemctl list-unit-files 2>/dev/null | grep -qi cloudpanel
}

save_system_snapshot() {
  local outfile="${1:-${ARTIFACT_DIR}/system-snapshot_${RUN_ID}.txt}"
  {
    echo "timestamp=$(timestamp)"
    echo "hostname=$(hostname 2>/dev/null || true)"
    echo "uname=$(uname -a 2>/dev/null || true)"
    if [[ -f /etc/os-release ]]; then
      cat /etc/os-release
    fi
    echo "---- memory ----"
    free -m 2>/dev/null || true
    echo "---- disk ----"
    df -h 2>/dev/null || true
    echo "---- listening ----"
    listening_ports_summary
    echo "---- packages of interest ----"
    dpkg -l 2>/dev/null | awk '/nginx|apache2|mariadb|mysql|php-fpm|docker|ufw/ {print}' || true
  } >"${outfile}"
  chmod 640 "${outfile}" || true
  printf '%s' "${outfile}"
}

# ---------------------------------------------------------------------------
# Отчёты
# ---------------------------------------------------------------------------
compute_preflight_status() {
  if [[ ${#ERRORS[@]} -gt 0 ]] || [[ ${#CONFLICTS[@]} -gt 0 && "${CONFLICT_POLICY}" == "block" ]]; then
    PREFLIGHT_STATUS="BLOCKED"
  elif [[ ${#WARNINGS[@]} -gt 0 ]] || [[ ${#CONFLICTS[@]} -gt 0 ]]; then
    PREFLIGHT_STATUS="READY_WITH_WARNINGS"
  else
    PREFLIGHT_STATUS="READY"
  fi
  printf '%s' "${PREFLIGHT_STATUS}"
}

print_report_section() {
  local title="$1"
  shift
  echo ""
  echo "=== ${title} ==="
  if [[ "$#" -eq 0 ]]; then
    echo "(нет)"
    return
  fi
  local item
  for item in "$@"; do
    echo "- ${item}"
  done
}

write_preflight_report() {
  local status="$1"
  local report_file="${2:-${LOG_DIR}/preflight-report_${RUN_ID}.txt}"
  {
    echo "CloudPanel Deploy — отчёт предварительной диагностики"
    echo "Время: $(human_time)"
    echo "Статус: ${status}"
    echo "ОС: ${OS_PRETTY_NAME:-unknown} (${OS_ID:-unknown} ${OS_VERSION_ID:-unknown})"
    echo "Архитектура: $(get_arch)"
    echo "Hostname: $(hostname 2>/dev/null || echo unknown)"
    print_report_section "Заметки" "${INFO_NOTES[@]:-}"
    print_report_section "Предупреждения" "${WARNINGS[@]:-}"
    print_report_section "Конфликты" "${CONFLICTS[@]:-}"
    print_report_section "Ошибки" "${ERRORS[@]:-}"
  } | tee "${report_file}"
  chmod 640 "${report_file}" || true
  write_state_file "preflight.status" "${status}"
  write_state_file "preflight.report" "${report_file}"
  write_state_file "preflight.fingerprint" "$(build_system_fingerprint)"
}

build_system_fingerprint() {
  {
    echo "os=${OS_ID:-}:${OS_VERSION_ID:-}"
    echo "arch=$(get_arch)"
    echo "hostname=$(hostname 2>/dev/null || true)"
    list_local_ipv4 | sort | tr '\n' ','
    echo
    dpkg -l 2>/dev/null | awk '/^(ii|hi).* (nginx|apache2|mariadb-server|mysql-server|php[0-9.]*-fpm|docker-ce|docker.io) / {print $2"="$3}' | sort
  } | sha256sum 2>/dev/null | awk '{print $1}'
}

verify_fingerprint_unchanged() {
  local previous
  previous="$(read_state_file "preflight.fingerprint")"
  if [[ -z "${previous}" ]]; then
    log_warn "Отпечаток предыдущей диагностики отсутствует."
    return 1
  fi
  local current
  current="$(build_system_fingerprint)"
  if [[ "${previous}" != "${current}" ]]; then
    log_error "Система изменилась с момента preflight. Повторите 00-preflight.sh."
    return 1
  fi
  log_info "Отпечаток системы совпадает с preflight."
  return 0
}

download_official_installer() {
  local dest_dir="${ARTIFACT_DIR}/installer"
  local dest_file="${dest_dir}/install.sh"
  ensure_dir "${dest_dir}" 700

  if [[ -z "${INSTALLER_SHA256}" ]]; then
    log_error "INSTALLER_SHA256 не задан. Укажите контрольную сумму из официальной документации."
    log_error "Источник: ${OFFICIAL_DOCS_INSTALL}"
    return 1
  fi

  if ! have_cmd curl; then
    log_error "Требуется curl для загрузки официального установщика."
    return 1
  fi

  log_info "Загрузка установщика: ${INSTALLER_URL}"
  curl -fsS --connect-timeout "${CURL_CONNECT_TIMEOUT}" --max-time 120 \
    "${INSTALLER_URL}" -o "${dest_file}"
  chmod 700 "${dest_file}"

  local actual
  actual="$(sha256sum "${dest_file}" | awk '{print $1}')"
  if [[ "${actual}" != "${INSTALLER_SHA256}" ]]; then
    log_error "Контрольная сумма установщика не совпала."
    log_error "Ожидалось: ${INSTALLER_SHA256}"
    log_error "Получено:  ${actual}"
    log_error "Сверьте INSTALLER_SHA256 с актуальной документацией: ${OFFICIAL_DOCS_INSTALL}"
    rm -f "${dest_file}"
    return 1
  fi

  log_success "Установщик проверен (SHA-256 совпадает)."
  printf '%s' "${dest_file}"
}

print_next_steps_after_install() {
  local ip
  ip="$(detect_public_ipv4)"
  if [[ -z "${ip}" ]]; then
    ip="<PUBLIC_IP>"
  fi
  cat <<EOF

Следующие шаги:
1. Как можно быстрее откройте https://${ip}:${CLOUDPANEL_PORT} и создайте администратора.
   Официально предупреждается окно, в котором боты могут создать пользователя первыми.
2. Ограничьте порт ${CLOUDPANEL_PORT} вашим IP на firewall провайдера.
3. Запустите: sudo bash ${SCRIPTS_DIR}/30-verify-installation.sh
4. Затем: sudo bash ${SCRIPTS_DIR}/40-postinstall-checks.sh
5. Документация: ${DOCS_DIR}/INSTALLATION.md

EOF
}

# Swap помогает на VPS с RAM < 2GB, но съедает место на диске.
ensure_swap_if_needed() {
  local mem
  mem="$(mem_total_mb)"
  if ! is_true "${ENSURE_SWAP}"; then
    log_info "ENSURE_SWAP=NO — swap не создаётся."
    return 0
  fi
  if [[ "${mem}" -ge "${MIN_RAM_MB}" ]]; then
    log_info "RAM ${mem} MB >= ${MIN_RAM_MB} MB — дополнительный swap не обязателен."
    return 0
  fi
  if swapon --show 2>/dev/null | grep -q .; then
    log_info "Swap уже активен: $(swapon --show --noheadings 2>/dev/null | tr '\n' '; ')"
    return 0
  fi

  local free_gb needed_gb
  free_gb="$(disk_free_gb /)"
  needed_gb=$(( (SWAP_SIZE_MB / 1024) + MIN_FREE_DISK_AFTER_SWAP_GB ))
  if [[ "${free_gb}" -lt "${needed_gb}" ]]; then
    log_error "Для swap ${SWAP_SIZE_MB}MB нужно ≥${needed_gb}GB свободно на / (сейчас ${free_gb}GB)."
    log_error "Увеличьте диск VPS (рекомендуется ≥20GB) или уменьшите SWAP_SIZE_MB."
    return 1
  fi

  local swapfile="/swapfile-cloudpanel-deploy"
  log_warn "RAM ${mem} MB < официального минимума ${MIN_RAM_MB} MB — создаём swap ${SWAP_SIZE_MB}MB."
  if [[ ! -f "${swapfile}" ]]; then
    if have_cmd fallocate; then
      run_priv fallocate -l "${SWAP_SIZE_MB}M" "${swapfile}" || \
        run_priv dd if=/dev/zero of="${swapfile}" bs=1M count="${SWAP_SIZE_MB}" status=none
    else
      run_priv dd if=/dev/zero of="${swapfile}" bs=1M count="${SWAP_SIZE_MB}" status=none
    fi
    run_priv chmod 600 "${swapfile}"
    run_priv mkswap "${swapfile}"
  fi
  run_priv swapon "${swapfile}"
  if ! grep -q "${swapfile}" /etc/fstab 2>/dev/null; then
    echo "${swapfile} none swap sw 0 0" | run_priv tee -a /etc/fstab >/dev/null
  fi
  log_success "Swap активирован (${swapfile}). Свободно на /: $(disk_free_gb /) GB"
}

# После частичной установки postinst может не вызвать import шаблонов (ошибка WordPress vhost).
ensure_vhost_templates() {
  if ! have_cmd clpctl; then
    log_warn "clpctl недоступен — импорт vhost-шаблонов пропущен."
    return 1
  fi
  log_info "Импорт vhost-шаблонов CloudPanel (clpctl vhost-templates:import)..."
  if run_priv clpctl vhost-templates:import; then
    log_success "Vhost-шаблоны импортированы (включая WordPress)."
    return 0
  fi
  log_error "Не удалось импортировать vhost-шаблоны."
  return 1
}

installer_log_looks_broken() {
  local install_log="$1"
  [[ -f "${install_log}" ]] || return 1
  if grep -Eqi 'No space left on device|dpkg returned an error code|Errors were encountered while processing' "${install_log}"; then
    return 0
  fi
  return 1
}

cloudpanel_package_ok() {
  dpkg -l cloudpanel 2>/dev/null | awk '/^ii/ {ok=1} END{exit !ok}'
}
