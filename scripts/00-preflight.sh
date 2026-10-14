#!/usr/bin/env bash
# Предварительная диагностика сервера перед установкой CloudPanel.
# Ничего не устанавливает и не изменяет систему.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

load_config
init_runtime "00-preflight"

OS_ID=""
OS_VERSION_ID=""
OS_VERSION_CODENAME=""
OS_PRETTY_NAME=""

check_os() {
  set_stage "os"
  if ! read_os_release; then
    log_error "Файл /etc/os-release недоступен. Поддерживается только Debian."
    return 1
  fi

  add_note "ОС: ${OS_PRETTY_NAME} (ID=${OS_ID}, VERSION_ID=${OS_VERSION_ID}, CODENAME=${OS_VERSION_CODENAME})"

  if [[ "${OS_ID}" != "debian" ]]; then
    log_error "Обнаружена ОС '${OS_ID}'. Этот проект предназначен для чистого Debian VPS."
    log_error "Официальные Requirements: ${OFFICIAL_DOCS_REQUIREMENTS}"
    return 1
  fi

  if ! debian_version_supported "${OS_VERSION_ID}"; then
    if [[ "${OS_VERSION_ID}" == "11" ]]; then
      log_error "Debian 11 больше не указан в официальных Requirements CloudPanel."
      log_error "Поддерживаются Debian 12 и Debian 13. Источник: ${OFFICIAL_DOCS_REQUIREMENTS}"
    else
      log_error "Debian ${OS_VERSION_ID} не подтверждён официальными Requirements CloudPanel."
      log_error "Ожидаются версии: ${SUPPORTED_DEBIAN_VERSIONS}"
    fi
    return 1
  fi

  local arch
  arch="$(get_arch)"
  add_note "Архитектура: ${arch}"
  if ! arch_supported; then
    log_error "Архитектура ${arch} не поддерживается (ожидаются: ${SUPPORTED_ARCHITECTURES})."
    return 1
  fi

  local bash_major
  bash_major="${BASH_VERSINFO[0]}"
  add_note "Bash: ${BASH_VERSION}"
  if [[ "${bash_major}" -lt 4 ]]; then
    log_error "Требуется Bash >= 4."
    return 1
  fi

  if ! have_cmd apt-get || ! have_cmd dpkg; then
    log_error "apt/dpkg недоступны."
    return 1
  fi
  add_note "apt/dpkg доступны."
}

check_privileges() {
  set_stage "privileges"
  if is_root; then
    add_note "Права: root"
  elif can_sudo; then
    add_note "Права: пользователь с passwordless sudo"
  else
    log_error "Нет root и нет работающего sudo -n."
    log_error "Повторный запуск: sudo bash ${SCRIPTS_DIR}/00-preflight.sh"
    return 1
  fi

  local required_cmds=(bash awk sed grep find mkdir chmod date uname df)
  local optional_cmds=(curl wget ss ip dig getent systemctl lsof)
  local cmd
  for cmd in "${required_cmds[@]}"; do
    if ! have_cmd "${cmd}"; then
      log_error "Отсутствует обязательная утилита: ${cmd}"
    fi
  done
  for cmd in "${optional_cmds[@]}"; do
    if ! have_cmd "${cmd}"; then
      log_warn "Желательная утилита отсутствует: ${cmd}"
    fi
  done

  if ! touch "${LOG_DIR}/.write-test" 2>/dev/null; then
    log_error "Нет прав записи в каталог журналов: ${LOG_DIR}"
    return 1
  fi
  rm -f "${LOG_DIR}/.write-test"

  if [[ ! -d /tmp ]] || [[ ! -w /tmp ]]; then
    log_error "Каталог /tmp недоступен для записи."
    return 1
  fi
}

check_resources() {
  set_stage "resources"
  local mem cores root_free var_free tmp_free
  mem="$(mem_total_mb)"
  cores="$(cpu_cores)"
  root_free="$(disk_free_gb /)"
  var_free="$(disk_free_gb /var)"
  tmp_free="$(disk_free_gb /tmp)"

  add_note "RAM: ${mem} MB (минимум ${MIN_RAM_MB} MB)"
  add_note "CPU cores: ${cores} (минимум ${MIN_CPU_CORES})"
  add_note "Свободно /: ${root_free} GB; /var: ${var_free} GB; /tmp: ${tmp_free} GB (минимум ${MIN_DISK_GB} GB на /)"

  if [[ "${mem}" -lt "${MIN_RAM_MB}" ]]; then
    log_error "Недостаточно RAM: ${mem} MB < ${MIN_RAM_MB} MB (Requirements CloudPanel)."
  fi
  if [[ "${cores}" -lt "${MIN_CPU_CORES}" ]]; then
    log_error "Недостаточно CPU: ${cores} < ${MIN_CPU_CORES}."
  fi
  if [[ "${root_free}" -lt "${MIN_DISK_GB}" ]]; then
    log_error "Недостаточно места на /: ${root_free} GB < ${MIN_DISK_GB} GB."
  fi
  if [[ "${var_free}" -lt 2 ]]; then
    log_warn "Мало свободного места на /var: ${var_free} GB."
  fi
  if [[ "${tmp_free}" -lt 1 ]]; then
    log_warn "Мало свободного места на /tmp: ${tmp_free} GB."
  fi

  if apt_busy; then
    log_error "Обнаружены незавершённые операции apt/dpkg. Дождитесь завершения или выполните dpkg --configure -a."
  else
    add_note "apt/dpkg не заняты."
  fi
}

check_network() {
  set_stage "network"
  if have_default_route; then
    add_note "Маршрут по умолчанию присутствует."
  else
    log_error "Маршрут по умолчанию отсутствует."
  fi

  if dns_resolves "${DNS_TEST_HOST}"; then
    add_note "DNS резолвит ${DNS_TEST_HOST}."
  else
    log_error "DNS не резолвит ${DNS_TEST_HOST}."
  fi

  if have_cmd curl; then
    if https_reachable "${HTTPS_TEST_URL}"; then
      add_note "Исходящий HTTPS к ${HTTPS_TEST_URL} доступен."
    else
      log_error "Исходящий HTTPS к ${HTTPS_TEST_URL} недоступен."
    fi
  else
    log_warn "curl отсутствует — проверка HTTPS пропущена на этом этапе."
  fi

  local local_ipv4
  local_ipv4="$(list_local_ipv4 | tr '\n' ' ')"
  if [[ -z "$(trim "${local_ipv4}")" ]]; then
    log_error "Глобальный IPv4 на интерфейсах не обнаружен."
  else
    add_note "Локальные IPv4: ${local_ipv4}"
  fi

  local public_ip
  public_ip="$(detect_public_ipv4)"
  if [[ -n "${public_ip}" ]]; then
    add_note "Внешний IPv4 (ipify): ${public_ip}"
    if ! printf '%s\n' "${local_ipv4}" | tr ' ' '\n' | grep -qx "${public_ip}"; then
      log_warn "Внешний IPv4 (${public_ip}) не совпадает с адресами интерфейсов. Возможен NAT."
    fi
    if [[ -n "${EXPECTED_PUBLIC_IPV4}" && "${EXPECTED_PUBLIC_IPV4}" != "${public_ip}" ]]; then
      log_warn "EXPECTED_PUBLIC_IPV4=${EXPECTED_PUBLIC_IPV4} отличается от обнаруженного ${public_ip}."
    fi
  else
    log_warn "Не удалось определить публичный IPv4 извне. Не делайте вывод только по наличию интерфейса."
  fi

  if is_true "${CHECK_IPV6}"; then
    if have_cmd ip && ip -6 route show default 2>/dev/null | grep -q .; then
      add_note "IPv6: маршрут по умолчанию обнаружен."
    else
      log_warn "IPv6 маршрут по умолчанию не обнаружен (не обязательно блокирует установку)."
    fi
  fi

  add_note "Hostname: $(hostname 2>/dev/null || echo unknown); FQDN: $(hostname -f 2>/dev/null || echo unknown)"
  if [[ -n "${EXPECTED_HOSTNAME}" ]]; then
    local current_hn
    current_hn="$(hostname 2>/dev/null || true)"
    if [[ "${current_hn}" != "${EXPECTED_HOSTNAME}" ]]; then
      log_warn "Текущий hostname (${current_hn}) != EXPECTED_HOSTNAME (${EXPECTED_HOSTNAME}). Автосмена отключена."
    fi
  fi

  echo ""
  echo "--- Слушающие порты (фрагмент) ---"
  listening_ports_summary || true
  echo "----------------------------------"

  if [[ -f /etc/ssh/sshd_config ]]; then
    local ssh_port_cfg
    ssh_port_cfg="$(awk '/^Port / {print $2}' /etc/ssh/sshd_config | tail -n1)"
    add_note "SSH config Port: ${ssh_port_cfg:-22 (по умолчанию)}"
  else
    log_warn "Файл /etc/ssh/sshd_config не найден."
  fi

  if have_cmd ufw; then
    add_note "UFW присутствует. Статус: $(ufw status 2>/dev/null | head -n1 || echo unknown)"
  fi
  if have_cmd iptables; then
    add_note "iptables доступен (правила не изменяются)."
  fi
  if have_cmd nft; then
    add_note "nftables доступен (правила не изменяются)."
  fi
}

check_cleanliness() {
  set_stage "cleanliness"

  # Пакеты / службы, конфликтующие с чистой установкой CloudPanel
  if dpkg -l nginx 2>/dev/null | awk '/^ii/ {ok=1} END{exit !ok}'; then
    add_conflict "Установлен пакет nginx"
  fi
  if systemctl is-active --quiet nginx 2>/dev/null; then
    add_conflict "Служба nginx активна"
  fi
  if dpkg -l apache2 2>/dev/null | awk '/^ii/ {ok=1} END{exit !ok}'; then
    add_conflict "Установлен пакет apache2"
  fi
  if systemctl is-active --quiet apache2 2>/dev/null; then
    add_conflict "Служба apache2 активна"
  fi
  if dpkg -l 'mariadb-server' 2>/dev/null | awk '/^ii/ {ok=1} END{exit !ok}' \
    || dpkg -l 'mysql-server' 2>/dev/null | awk '/^ii/ {ok=1} END{exit !ok}'; then
    add_conflict "Установлен MariaDB/MySQL server"
  fi
  if systemctl is-active --quiet mysql 2>/dev/null || systemctl is-active --quiet mariadb 2>/dev/null; then
    add_conflict "Служба mysql/mariadb активна"
  fi
  if compgen -G "/etc/php/*/fpm" >/dev/null 2>&1; then
    add_conflict "Обнаружены каталоги PHP-FPM в /etc/php"
  fi
  if dpkg -l docker.io 2>/dev/null | awk '/^ii/ {ok=1} END{exit !ok}' \
    || dpkg -l docker-ce 2>/dev/null | awk '/^ii/ {ok=1} END{exit !ok}'; then
    add_conflict "Установлен Docker"
  fi
  if have_cmd docker && docker ps >/dev/null 2>&1; then
    add_conflict "Docker отвечает на docker ps"
  fi

  # Другие панели управления
  local panel
  for panel in /usr/local/cpanel /usr/local/psa /usr/local/directadmin /opt/plesk /usr/local/lsws; do
    if [[ -e "${panel}" ]]; then
      add_conflict "Обнаружена другая панель/стек: ${panel}"
    fi
  done

  if cloudpanel_apparently_installed; then
    add_conflict "CloudPanel уже присутствует (частично или полностью)"
  fi

  if [[ -d /etc/nginx/sites-enabled ]] && compgen -G "/etc/nginx/sites-enabled/*" >/dev/null 2>&1; then
    add_conflict "Найдены конфигурации nginx sites-enabled"
  fi
  if [[ -d /var/www ]] && compgen -G "/var/www/*" >/dev/null 2>&1; then
    local count
    count="$(find /var/www -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "${count}" -gt 0 ]]; then
      log_warn "Каталог /var/www не пуст (${count} элементов). Убедитесь, что сервер чистый."
    fi
  fi

  # Официальный установщик проверяет порты 80, 443, 3306
  local port
  for port in 80 443 3306; do
    if have_cmd ss && ss -tlnn 2>/dev/null | grep -qE ":${port}\\b"; then
      add_conflict "Порт ${port} уже слушается (официальный установщик это блокирует)"
    elif have_cmd lsof && lsof -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1; then
      add_conflict "Порт ${port} уже слушается (официальный установщик это блокирует)"
    fi
  done

  if pgrep -f 'apt-get|aptitude|dpkg|unattended-upgrade' >/dev/null 2>&1; then
    add_conflict "Обнаружен активный процесс установки/обновления пакетов"
  fi

  if [[ ${#CONFLICTS[@]} -eq 0 ]]; then
    add_note "Конфликтующие компоненты не обнаружены."
  else
    log_error "Автоустановка заблокирована из-за конфликтов. Компоненты НЕ удаляются автоматически."
  fi
}

check_db_engine_config() {
  set_stage "db-engine-config"
  if [[ -z "${OS_VERSION_ID}" ]]; then
    return 0
  fi
  if db_engine_supported_for_debian "${OS_VERSION_ID}" "${DB_ENGINE}"; then
    add_note "DB_ENGINE=${DB_ENGINE} совместим с Debian ${OS_VERSION_ID}."
  else
    log_error "DB_ENGINE=${DB_ENGINE} не поддерживается для Debian ${OS_VERSION_ID} официальным установщиком."
  fi
  if [[ -z "${INSTALLER_SHA256}" ]]; then
    log_error "INSTALLER_SHA256 пуст. Укажите контрольную сумму из ${OFFICIAL_DOCS_INSTALL}"
  else
    add_note "INSTALLER_SHA256 задан (${#INSTALLER_SHA256} символов). Перед установкой сверьте с документацией."
  fi
}

main() {
  log_info "Предварительная диагностика CloudPanel. Изменения системы не выполняются."
  check_os || true
  check_privileges || true
  check_resources || true
  check_network || true
  check_cleanliness || true
  check_db_engine_config || true

  local status
  status="$(compute_preflight_status)"
  write_preflight_report "${status}"

  case "${status}" in
    READY)
      log_success "Статус: READY — можно переходить к 10-prepare-system.sh"
      finish_runtime "SUCCESS"
      exit 0
      ;;
    READY_WITH_WARNINGS)
      log_warn "Статус: READY_WITH_WARNINGS — изучите предупреждения перед установкой."
      finish_runtime "WARN"
      exit 0
      ;;
    *)
      log_error "Статус: BLOCKED — устраните ошибки/конфликты и повторите диагностику."
      finish_runtime "BLOCKED"
      exit 1
      ;;
  esac
}

main "$@"
