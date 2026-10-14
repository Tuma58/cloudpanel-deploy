#!/usr/bin/env bash
# Установка CloudPanel официальным способом с проверкой SHA-256.
# Источник: https://www.cloudpanel.io/docs/v2/getting-started/other/

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

load_config
init_runtime "20-install-cloudpanel"

OS_ID=""
OS_VERSION_ID=""
OS_VERSION_CODENAME=""
OS_PRETTY_NAME=""

assert_confirmation() {
  set_stage "confirmation"
  if ! is_true "${CONFIRM_INSTALL}"; then
    cat <<EOF

Установка CloudPanel НЕ запущена.
Официальный установщик изменяет системные сервисы, устанавливает веб-стек,
базу данных и настраивает firewall (UFW). Откат может быть невозможен.

Для продолжения задайте явное подтверждение:

  sudo CONFIRM_INSTALL=YES bash ${SCRIPTS_DIR}/20-install-cloudpanel.sh

Либо в config/deploy.env:
  CONFIRM_INSTALL=YES

Документация: ${OFFICIAL_DOCS_INSTALL}

EOF
    log_error "CONFIRM_INSTALL != YES"
    return 1
  fi
  log_warn "Получено подтверждение CONFIRM_INSTALL=YES"
}

assert_not_already_installed() {
  set_stage "idempotency"
  local status
  status="$(install_status)"
  if [[ "${status}" == FINISHED* ]]; then
    log_error "Установка уже помечена как FINISHED. Повторный запуск заблокирован."
    log_error "Если панель повреждена — см. docs/TROUBLESHOOTING.md и BACKUP-AND-RECOVERY.md."
    return 1
  fi
  if [[ "${status}" == STARTED* ]]; then
    log_error "Обнаружена незавершённая установка (${status})."
    log_error "Автоматический повтор небезопасен. Выполните диагностику вручную:"
    log_error "  sudo bash ${SCRIPTS_DIR}/30-verify-installation.sh"
    return 1
  fi
  if cloudpanel_apparently_installed; then
    log_error "Признаки CloudPanel уже присутствуют. Установка остановлена."
    return 1
  fi
}

pre_install_gates() {
  set_stage "pre-install-gates"
  require_root_or_sudo

  if ! read_os_release; then
    log_error "/etc/os-release недоступен"
    return 1
  fi
  if [[ "${OS_ID}" != "debian" ]] || ! debian_version_supported "${OS_VERSION_ID}"; then
    log_error "ОС не поддерживается: ${OS_ID} ${OS_VERSION_ID}"
    return 1
  fi
  if ! arch_supported; then
    log_error "Архитектура не поддерживается: $(get_arch)"
    return 1
  fi
  if ! db_engine_supported_for_debian "${OS_VERSION_ID}" "${DB_ENGINE}"; then
    log_error "DB_ENGINE=${DB_ENGINE} несовместим с Debian ${OS_VERSION_ID}"
    return 1
  fi

  local prepare_status
  prepare_status="$(read_state_file "prepare.status")"
  if [[ -z "${prepare_status}" ]]; then
    log_error "Сначала выполните 10-prepare-system.sh"
    return 1
  fi

  local preflight_status
  preflight_status="$(read_state_file "preflight.status")"
  if [[ "${preflight_status}" == "BLOCKED" || -z "${preflight_status}" ]]; then
    log_error "Требуется успешный preflight (READY или READY_WITH_WARNINGS)."
    return 1
  fi

  if ! verify_fingerprint_unchanged; then
    return 1
  fi

  local mem root_free
  mem="$(mem_total_mb)"
  root_free="$(disk_free_gb /)"
  if [[ "${mem}" -lt "${MIN_RAM_MB}" || "${root_free}" -lt "${MIN_DISK_GB}" ]]; then
    log_error "Недостаточно ресурсов (RAM=${mem}MB, disk=${root_free}GB)."
    return 1
  fi

  if ! https_reachable "${INSTALLER_URL}"; then
    # installer URL может не отдавать 200 на HEAD без GET — проверим хост
    if ! https_reachable "https://installer.cloudpanel.io/"; then
      log_error "Официальный ресурс установщика недоступен."
      return 1
    fi
  fi

  # Повторная проверка конфликтующих портов официального установщика
  local port
  for port in 80 443 3306; do
    if have_cmd ss && ss -tlnn 2>/dev/null | grep -qE ":${port}\\b"; then
      log_error "Порт ${port} занят — официальный установщик завершится ошибкой."
      return 1
    fi
  done

  log_warn "ВНИМАНИЕ: установщик изменит конфигурацию системных сервисов, установит"
  log_warn "Nginx/PHP/БД и может настроить UFW. Безопасный полный откат не гарантирован."
}

backup_sensitive_configs_if_any() {
  set_stage "pre-backup"
  local backup_dir="${ARTIFACT_DIR}/pre-install-backup_${RUN_ID}"
  ensure_dir "${backup_dir}" 700
  local copied=0
  local path
  for path in /etc/ssh/sshd_config /etc/hosts /etc/hostname /etc/fstab; do
    if [[ -f "${path}" ]]; then
      cp -a "${path}" "${backup_dir}/" || true
      copied=1
    fi
  done
  if [[ "${copied}" -eq 1 ]]; then
    log_info "Сохранены копии базовых конфигов в ${backup_dir}"
  else
    log_info "Базовые конфиги для резервного копирования не найдены (необычно)."
  fi
  save_system_snapshot "${ARTIFACT_DIR}/install-start-snapshot_${RUN_ID}.txt" >/dev/null
}

run_official_installer() {
  set_stage "download-verify"
  local installer_path
  installer_path="$(download_official_installer)"
  log_info "Путь к проверенному установщику: ${installer_path}"

  set_stage "install"
  mark_install_started
  write_state_file "install.db_engine" "${DB_ENGINE}"
  write_state_file "install.installer_sha256" "${INSTALLER_SHA256}"
  write_state_file "install.started_at" "$(timestamp)"

  local install_log="${LOG_DIR}/cloudpanel-installer_${RUN_ID}.log"
  log_info "Запуск официального установщика с DB_ENGINE=${DB_ENGINE}"
  log_info "Журнал установщика: ${install_log}"

  # Не включаем set -x в родительском процессе, чтобы не протекали секреты окружения.
  # Официальный скрипт сам использует bash -x; его вывод пишем в отдельный журнал.
  set +e
  # Редирект в журнал от текущего пользователя — намеренно (каталог logs проекта).
  # shellcheck disable=SC2024
  if is_root; then
    DB_ENGINE="${DB_ENGINE}" bash "${installer_path}" >"${install_log}" 2>&1
  else
    sudo DB_ENGINE="${DB_ENGINE}" bash "${installer_path}" >"${install_log}" 2>&1
  fi
  local rc=$?
  set -e
  # Показать хвост журнала без set -x
  if [[ -f "${install_log}" ]]; then
    tail -n 40 "${install_log}" | while read -r line; do
      log_info "installer: $(sanitize_for_log "${line}")"
    done || true
  fi

  write_state_file "install.exit_code" "${rc}"
  write_state_file "install.finished_at" "$(timestamp)"

  if [[ "${rc}" -ne 0 ]]; then
    log_error "Официальный установщик завершился с кодом ${rc}."
    log_error "Автоматический откат НЕ выполняется (может быть опасен)."
    log_error "Сохраните журналы: ${LOG_FILE}, ${install_log}"
    log_error "См. docs/TROUBLESHOOTING.md и docs/BACKUP-AND-RECOVERY.md"
    write_state_file "install.status" "FAILED $(timestamp) rc=${rc}"
    save_system_snapshot "${ARTIFACT_DIR}/install-failed-snapshot_${RUN_ID}.txt" >/dev/null
    return "${rc}"
  fi

  # Установщик иногда печатает «complete», но dpkg/cloudpanel ломается из‑за диска.
  if installer_log_looks_broken "${install_log}"; then
    log_error "В журнале установщика есть признаки сбоя (No space left / dpkg error)."
    log_error "Не считайте установку успешной. Освободите диск и см. docs/TROUBLESHOOTING.md"
    write_state_file "install.status" "FAILED_PARTIAL $(timestamp)"
    save_system_snapshot "${ARTIFACT_DIR}/install-failed-snapshot_${RUN_ID}.txt" >/dev/null
    return 1
  fi
  if ! cloudpanel_package_ok; then
    log_error "Пакет cloudpanel не в состоянии 'ii' (возможна незавершённая настройка)."
    log_error "Проверьте: dpkg -l cloudpanel; df -h /; sudo dpkg --configure -a"
    write_state_file "install.status" "FAILED_PARTIAL $(timestamp)"
    return 1
  fi

  # Импорт шаблонов (WordPress и др.) — postinst мог не дойти до этого шага
  ensure_vhost_templates || log_warn "Импорт шаблонов не удался — повторите в 40-postinstall-checks.sh"

  mark_install_finished
  log_success "Официальный установщик завершился успешно."
  print_next_steps_after_install
}

main() {
  assert_confirmation
  assert_not_already_installed
  pre_install_gates
  backup_sensitive_configs_if_any
  run_official_installer
  finish_runtime "SUCCESS"
}

main "$@"
