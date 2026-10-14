#!/usr/bin/env bash
# Синтаксис Bash + ShellCheck для всех скриптов проекта.

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

SCRIPTS=(
  scripts/common.sh
  scripts/00-preflight.sh
  scripts/10-prepare-system.sh
  scripts/20-install-cloudpanel.sh
  scripts/30-verify-installation.sh
  scripts/40-postinstall-checks.sh
  scripts/install-interactive.sh
  tests/shellcheck.sh
  tests/test-config.sh
)

echo "== bash -n =="
fail=0
for f in "${SCRIPTS[@]}"; do
  if ! bash -n "${f}"; then
    echo "SYNTAX FAIL: ${f}"
    fail=1
  else
    echo "OK syntax: ${f}"
  fi
done

echo ""
echo "== shellcheck =="
if command -v shellcheck >/dev/null 2>&1; then
  # SC1091 source; SC2034 vars for consumers; SC2153 SCRIPTS_DIR vs SCRIPT_DIR intentional
  if ! shellcheck -x \
      -e SC1091 \
      -e SC2034 \
      -e SC2153 \
      "${SCRIPTS[@]}"; then
    echo "SHELLCHECK FAIL"
    fail=1
  else
    echo "OK shellcheck"
  fi
else
  echo "WARN: shellcheck не установлен — выполнена только проверка bash -n"
  echo "Установка: apt-get install -y shellcheck  ИЛИ  brew install shellcheck"
fi

if [[ "${fail}" -ne 0 ]]; then
  exit 1
fi
echo "Все проверки синтаксиса пройдены."
