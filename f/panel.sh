#!/bin/bash

set -e
set -o pipefail

######################################################################################
#                                                                                    #
# Project 'pterodactyl-installer'                                                    #
#                                                                                    #
# Copyright (C) 2018 - 2026, Vilhelm Prytz, <vilhelm@prytznet.se>                    #
#                                                                                    #
#   This program is free software: you can redistribute it and/or modify             #
#   it under the terms of the GNU General Public License as published by             #
#   the Free Software Foundation, either version 3 of the License, or                #
#   (at your option) any later version.                                              #
#                                                                                    #
#   This program is distributed in the hope that it will be useful,                  #
#   but WITHOUT ANY WARRANTY; without even the implied warranty of                   #
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the                    #
#   GNU General Public License for more details.                                     #
#                                                                                    #
#   You should have received a copy of the GNU General Public License                #
#   along with this program.  If not, see <https://www.gnu.org/licenses/>.           #
#                                                                                    #
# https://github.com/pterodactyl-installer/pterodactyl-installer/blob/master/LICENSE #
#                                                                                    #
# This script is not associated with the official Pterodactyl Project.               #
# https://github.com/pterodactyl-installer/pterodactyl-installer                     #
#                                                                                    #
######################################################################################

export GITHUB_SOURCE="v1.3.0"
export SCRIPT_RELEASE="v1.3.0"
export GITHUB_BASE_URL="https://raw.githubusercontent.com/pterodactyl-installer/pterodactyl-installer"

LOG_PATH="/var/log/pterodactyl-installer.log"
PANEL_PATH="${PANEL_PATH:-/var/www/pterodactyl}"
PANEL_BACKUP_ROOT="${PANEL_BACKUP_ROOT:-/var/backups/pterodactyl}"
NOOKTHEME_URL="${NOOKTHEME_URL:-https://github.com/Nookure/NookTheme/releases/latest/download/panel.tar.gz}"

# check for curl
if ! [ -x "$(command -v curl)" ]; then
  echo "* curl is required in order for this script to work."
  echo "* install using apt (Debian and derivatives) or yum/dnf (CentOS)"
  exit 1
fi

# Always remove lib.sh, before downloading it
[ -f /tmp/lib.sh ] && rm -rf /tmp/lib.sh
curl -sSL -o /tmp/lib.sh "$GITHUB_BASE_URL"/master/lib/lib.sh
# shellcheck source=lib/lib.sh
source /tmp/lib.sh

install_nooktheme() (
  set -Eeuo pipefail

  local panel_path="${PANEL_PATH%/}"
  local panel_parent="${panel_path%/*}"
  local panel_name="${panel_path##*/}"
  local timestamp
  local backup_dir
  local archive=""
  local db_option_file=""
  local maintenance_enabled=0
  local panel_owner

  cleanup_nooktheme() {
    local status=$?
    trap - EXIT

    [ -n "$db_option_file" ] && rm -f "$db_option_file"
    [ -n "$archive" ] && rm -f "$archive"

    if [ "$maintenance_enabled" -eq 1 ] && [ "$status" -ne 0 ]; then
      echo "* NookTheme installation failed; attempting to bring the panel back online."
      (cd "$panel_path" && php artisan up) || true
      echo "* The pre-installation backup is available at: $backup_dir"
    fi

    exit "$status"
  }

  read_panel_env() {
    php -r '
      $key = $argv[1];
      $file = $argv[2];
      foreach (file($file, FILE_IGNORE_NEW_LINES) as $line) {
          $trimmed = ltrim($line);
          if ($trimmed === "" || str_starts_with($trimmed, "#")) {
              continue;
          }
          if (!str_starts_with($line, $key . "=")) {
              continue;
          }
          $value = trim(substr($line, strlen($key) + 1));
          if (strlen($value) >= 2) {
              $first = $value[0];
              $last = $value[strlen($value) - 1];
              if (($first === "\"" && $last === "\"") || ($first === "\047" && $last === "\047")) {
                  $value = substr($value, 1, -1);
              }
          }
          echo $value;
          exit(0);
      }
    ' "$1" "$panel_path/.env"
  }

  mysql_option_escape() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '%s' "$value"
  }

  trap cleanup_nooktheme EXIT

  if [ "${EUID}" -ne 0 ]; then
    echo "* NookTheme installation must be run as root."
    exit 1
  fi

  for required_command in php composer curl tar stat mktemp mysqldump; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
      echo "* Cannot install NookTheme: required command '$required_command' is missing."
      exit 1
    fi
  done

  if [ ! -f "$panel_path/artisan" ] || [ ! -f "$panel_path/.env" ]; then
    echo "* Cannot install NookTheme: no completed Pterodactyl installation was found at $panel_path."
    exit 1
  fi

  panel_owner="$(stat -c '%U:%G' "$panel_path/artisan")"
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup_dir="${PANEL_BACKUP_ROOT%/}/nooktheme-${timestamp}"
  archive="$(mktemp /tmp/nooktheme-panel.XXXXXX.tar.gz)"

  echo "* Downloading the latest NookTheme release."
  curl --fail --location --silent --show-error --retry 3 --retry-delay 2 \
    "$NOOKTHEME_URL" --output "$archive"
  tar -tzf "$archive" >/dev/null

  mkdir -p "$backup_dir"
  chmod 700 "$backup_dir"

  cd "$panel_path"
  php artisan down
  maintenance_enabled=1

  echo "* Backing up the current panel files to $backup_dir."
  tar -czf "$backup_dir/panel-files.tar.gz" -C "$panel_parent" "$panel_name"

  local db_connection
  local db_host
  local db_port
  local db_socket
  local db_database
  local db_username
  local db_password
  local escaped_db_value

  db_connection="$(read_panel_env DB_CONNECTION)"
  db_host="$(read_panel_env DB_HOST)"
  db_port="$(read_panel_env DB_PORT)"
  db_socket="$(read_panel_env DB_SOCKET)"
  db_database="$(read_panel_env DB_DATABASE)"
  db_username="$(read_panel_env DB_USERNAME)"
  db_password="$(read_panel_env DB_PASSWORD)"

  if [ -n "$db_connection" ] && [ "$db_connection" != "mysql" ]; then
    echo "* Cannot create a database backup for unsupported connection: $db_connection"
    exit 1
  fi
  if [ -z "$db_database" ] || [ -z "$db_username" ]; then
    echo "* Cannot create a database backup: DB_DATABASE or DB_USERNAME is empty."
    exit 1
  fi

  db_host="${db_host:-127.0.0.1}"
  db_port="${db_port:-3306}"
  db_option_file="$(mktemp "$backup_dir/.mysql-client.XXXXXX")"
  chmod 600 "$db_option_file"
  {
    printf '[client]\n'
    escaped_db_value="$(mysql_option_escape "$db_username")"
    printf 'user="%s"\n' "$escaped_db_value"
    escaped_db_value="$(mysql_option_escape "$db_password")"
    printf 'password="%s"\n' "$escaped_db_value"
    if [ -n "$db_socket" ]; then
      escaped_db_value="$(mysql_option_escape "$db_socket")"
      printf 'socket="%s"\n' "$escaped_db_value"
    else
      escaped_db_value="$(mysql_option_escape "$db_host")"
      printf 'host="%s"\n' "$escaped_db_value"
      printf 'port=%s\n' "$db_port"
    fi
  } >"$db_option_file"

  echo "* Backing up the Pterodactyl database."
  mysqldump --defaults-extra-file="$db_option_file" \
    --single-transaction --quick --skip-lock-tables "$db_database" \
    >"$backup_dir/database.sql"
  rm -f "$db_option_file"
  db_option_file=""

  echo "* Installing NookTheme."
  tar -xzf "$archive" -C "$panel_path"
  chmod -R 755 "$panel_path/storage" "$panel_path/bootstrap/cache"
  COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction
  php artisan view:clear
  php artisan config:clear
  php artisan migrate --seed --force
  chown -R "$panel_owner" "$panel_path"
  php artisan queue:restart
  php artisan up
  maintenance_enabled=0

  echo "* NookTheme installation completed."
  echo "* Backup saved at: $backup_dir"
)

execute() {
  echo -e "\n\n* pterodactyl-installer $(date) \n\n" >>"$LOG_PATH"

  if [ "$1" == "nooktheme" ]; then
    install_nooktheme |& tee -a "$LOG_PATH"
    return 0
  fi

  [[ "$1" == *"canary"* ]] && export GITHUB_SOURCE="master" && export SCRIPT_RELEASE="canary"
  update_lib_source
  run_ui "${1//_canary/}" |& tee -a "$LOG_PATH"

  if [ "$1" == "panel" ]; then
    install_nooktheme |& tee -a "$LOG_PATH"
  fi

  if [[ -n $2 ]]; then
    echo -e -n "* Installation of $1 completed. Do you want to proceed to $2 installation? (y/N): "
    read -r CONFIRM
    if [[ "$CONFIRM" =~ [Yy] ]]; then
      execute "$2"
    else
      error "Installation of $2 aborted."
      exit 1
    fi
  fi
}

welcome ""

done=false
while [ "$done" == false ]; do
  options=(
    "Install the panel"
    "Install Wings"
    "Install both [0] and [1] on the same machine (wings script runs after panel)"
    "Install or update NookTheme only on an existing panel"
    # "Uninstall panel or wings\n"

    "Install panel with canary version of the script (the versions that lives in master, may be broken!)"
    "Install Wings with canary version of the script (the versions that lives in master, may be broken!)"
    "Install both [4] and [5] on the same machine (wings script runs after panel)"
    "Uninstall panel or wings with canary version of the script (the versions that lives in master, may be broken!)"
  )

  actions=(
    "panel"
    "wings"
    "panel;wings"
    "nooktheme"
    # "uninstall"

    "panel_canary"
    "wings_canary"
    "panel_canary;wings_canary"
    "uninstall_canary"
  )

  output "What would you like to do?"

  for i in "${!options[@]}"; do
    output "[$i] ${options[$i]}"
  done

  echo -n "* Input 0-$((${#actions[@]} - 1)): "
  read -r action

  [ -z "$action" ] && error "Input is required" && continue

  valid_input=("$(for ((i = 0; i <= ${#actions[@]} - 1; i += 1)); do echo "${i}"; done)")
  [[ ! " ${valid_input[*]} " =~ ${action} ]] && error "Invalid option"
  [[ " ${valid_input[*]} " =~ ${action} ]] && done=true && IFS=";" read -r i1 i2 <<<"${actions[$action]}" && execute "$i1" "$i2"
done

# Remove lib.sh, so next time the script is run the, newest version is downloaded.
rm -rf /tmp/lib.sh
