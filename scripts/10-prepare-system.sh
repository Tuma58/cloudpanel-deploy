#!/usr/bin/env bash
# Подготовка системы перед установкой CloudPanel.
# Не устанавливает Nginx/PHP/MariaDB вручную — это делает официальный установщик.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

load_config
init_runtime "10-prepare-system"

OS_ID=""
OS_VERSION_ID=""
OS_VERSION_CODENAME=""
OS_PRETTY_NAME=""

require_prior_preflight() {
  set_stage "preflight-gate"
  local status
  status="$(read_state_file "preflight.status")"
  if [[ -z "${status}" ]]; then
    log_error "Нет результата preflight. Сначала запустите: sudo bash ${SCRIPTS_DIR}/00-preflight.sh"
    return 1
  fi
  if [[ "${status}" == "BLOCKED" ]]; then
    log_error "Предыдущий preflight завершился BLOCKED. Устраните проблемы и повторите диагностику."
    return 1
  fi
  log_info "Предыдущий preflight: ${status}"
}

recheck_critical() {
  set_stage "critical-recheck"
  require_root_or_sudo

  if ! read_os_release; then
    log_error "/etc/os-release недоступен."
    return 1
  fi
  if [[ "${OS_ID}" != "debian" ]] || ! debian_version_supported "${OS_VERSION_ID}"; then
    log_error "Неподдерживаемая ОС: ${OS_ID} ${OS_VERSION_ID}"
    return 1
  fi
  if ! arch_supported; then
    log_error "Неподдерживаемая архитектура: $(get_arch)"
    return 1
  fi
  if apt_busy; then
    log_error "apt/dpkg заняты. Повторите позже."
    return 1
  fi
  if cloudpanel_apparently_installed; then
    log_error "CloudPanel уже обнаружен. Подготовка для новой установки остановлена."
    return 1
  fi

  local mem root_free
  mem="$(mem_total_mb)"
  root_free="$(disk_free_gb /)"
  if [[ "${mem}" -lt "${MIN_RAM_MB}" ]]; then
    log_error "Недостаточно RAM: ${mem} MB"
    return 1
  fi
  if [[ "${root_free}" -lt "${MIN_DISK_GB}" ]]; then
    log_error "Недостаточно места на /: ${root_free} GB"
    return 1
  fi

  if ! verify_fingerprint_unchanged; then
    log_error "Повторите 00-preflight.sh на актуальном состоянии сервера."
    return 1
  fi
}

prepare_logging() {
  set_stage "logging"
  ensure_dir "${LOG_DIR}" 750
  ensure_dir "${STATE_DIR}" 750
  ensure_dir "${ARTIFACT_DIR}" 750
  log_info "Каталоги журналов и состояния подготовлены."
}

check_time_sync() {
  set_stage "time-sync"
  log_info "Текущее время: $(human_time)"
  if have_cmd timedatectl; then
    local sync
    sync="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
    local ntp
    ntp="$(timedatectl show -p NTP --value 2>/dev/null || true)"
    log_info "NTP=${ntp:-unknown}, NTPSynchronized=${sync:-unknown}"
    if [[ "${sync}" == "no" ]]; then
      log_warn "Часы, похоже, не синхронизированы. Для TLS/Let's Encrypt это критично."
      log_warn "Проверьте: timedatectl status"
    fi
  elif have_cmd chronyc; then
    chronyc tracking 2>/dev/null | head -n 5 | while read -r line; do
      log_info "chrony: ${line}"
    done || log_warn "chronyc tracking недоступен."
  else
    log_warn "Не удалось проверить синхронизацию времени (нет timedatectl/chronyc)."
  fi
}

check_apt_state() {
  set_stage "apt-state"
  run_priv apt-get update
  log_info "apt-get update выполнен."

  if run_priv dpkg --audit 2>&1 | tee -a "${LOG_FILE}" | grep -q .; then
    log_warn "dpkg --audit сообщил о проблемах. Рассмотрите: dpkg --configure -a"
  else
    log_info "dpkg --audit: замечаний нет."
  fi
}

report_security_updates() {
  set_stage "security-updates"
  local upgradable
  upgradable="$(apt list --upgradable 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')"
  log_info "Доступно обновляемых пакетов: ${upgradable}"

  if have_cmd apt-get; then
    # Только отчёт, без установки, если не подтверждено
    if run_priv apt-get -s upgrade 2>/dev/null | grep -qE 'Inst .*security'; then
      log_warn "Обнаружены потенциальные обновления безопасности (симуляция apt-get upgrade)."
    fi
  fi

  if is_true "${APPLY_SECURITY_UPDATES}"; then
    log_warn "APPLY_SECURITY_UPDATES=YES — будет выполнен apt-get upgrade."
    log_warn "Перезагрузка без CONFIRM_REBOOT=YES не выполняется."
    run_priv env DEBIAN_FRONTEND=noninteractive apt-get -y upgrade
    log_success "apt-get upgrade завершён."
    if [[ -f /var/run/reboot-required ]]; then
      log_warn "Система требует перезагрузки (/var/run/reboot-required)."
      if is_true "${CONFIRM_REBOOT}"; then
        log_warn "CONFIRM_REBOOT=YES — перезагрузка через 5 секунд. Подключитесь через консоль провайдера при необходимости."
        sleep 5
        run_priv reboot
      else
        log_warn "Перезагрузка НЕ выполнена. После обслуживания выполните reboot вручную и повторите preflight."
      fi
    fi
  else
    log_info "Автообновление отключено (APPLY_SECURITY_UPDATES=NO)."
    log_info "Для применения: задайте APPLY_SECURITY_UPDATES=YES в config/deploy.env и перезапустите скрипт."
  fi
}

install_prerequisites_only() {
  set_stage "prerequisites"
  # Согласно официальной инструкции: curl wget sudo
  # https://www.cloudpanel.io/docs/v2/getting-started/other/
  log_info "Установка только официально требуемых пакетов: curl wget sudo"
  run_priv env DEBIAN_FRONTEND=noninteractive apt-get -y install curl wget sudo
  log_success "Предварительные пакеты установлены."
}

hostname_procedure_notice() {
  set_stage "hostname-policy"
  if is_true "${CONFIRM_HOSTNAME_CHANGE}"; then
    if [[ -z "${NEW_HOSTNAME}" ]]; then
      log_error "CONFIRM_HOSTNAME_CHANGE=YES, но NEW_HOSTNAME пуст."
      return 1
    fi
    log_error "Автоматическая смена hostname отключена в этом проекте по соображениям безопасности SSH/сертификатов."
    log_error "Выполните документированную процедуру вручную (docs/INSTALLATION.md), затем повторите preflight."
    return 1
  fi
  log_info "Hostname не изменяется (CONFIRM_HOSTNAME_CHANGE=NO)."
}

save_prepare_marker() {
  set_stage "state"
  write_state_file "prepare.status" "DONE $(timestamp)"
  write_state_file "prepare.fingerprint" "$(build_system_fingerprint)"
  local snap
  snap="$(save_system_snapshot "${ARTIFACT_DIR}/pre-install-snapshot_${RUN_ID}.txt")"
  log_info "Снимок системы: ${snap}"
}

warn_small_vps() {
  set_stage "capacity-advice"
  local mem root_free
  mem="$(mem_total_mb)"
  root_free="$(disk_free_gb /)"
  if [[ "${mem}" -lt 2048 ]]; then
    log_warn "Официальный минимум CloudPanel — 2 GB RAM (сейчас ${mem} MB). Установка возможна с swap, но нестабильна."
  fi
  if [[ "${root_free}" -lt 15 ]]; then
    log_warn "Рекомендуется ≥20 GB диска / ≥15 GB свободно (сейчас ${root_free} GB). Иначе риск 'No space left' и битого пакета cloudpanel."
  fi
}

main() {
  require_prior_preflight
  recheck_critical
  prepare_logging
  check_time_sync
  hostname_procedure_notice
  warn_small_vps
  ensure_swap_if_needed
  check_apt_state
  report_security_updates
  install_prerequisites_only
  save_prepare_marker
  log_success "Подготовка завершена. Далее: sudo CONFIRM_INSTALL=YES bash ${SCRIPTS_DIR}/20-install-cloudpanel.sh"
  finish_runtime "SUCCESS"
}

main "$@"
