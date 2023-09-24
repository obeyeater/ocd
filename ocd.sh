#!/usr/bin/env bash
#shellcheck disable=SC1091,SC2086,SC2164
#
# OCD: Optimally Configured Dotfiles <https://github.com/nycksw/ocd>

# Env vars may be set separately in "~/.ocd.conf".
OCD_CONF="${OCD_CONF:-${HOME}/.ocd.conf}"
if [[ -f "${OCD_CONF}" ]]; then source "${OCD_CONF}"; fi

# These defaults may be overridden via the environment; see unit tests for examples.
OCD_REPO="${OCD_REPO:-git@github.com:username/your-dotfiles.git}"
OCD_HOME="${OCD_HOME:-$HOME}"
OCD_DIR="${OCD_DIR:-${HOME}/.ocd}"
OCD_FAV_PKGS="${OCD_FAV_PKGS:-$OCD_HOME/.favpkgs}"
OCD_FORCE="${OCD_FORCE:-false}"
OCD_ASSUME_YES="${OCD_ASSUME_YES:-false}"  # Set to true for non-interactive/testing.

# Pattern for files to ignore when doing anything with OCD (find, tar, etc.)
OCD_IGNORE_RE="./.git"

# For git commands that need OCD_DIR as the working directory.
OCD_GIT="git -C ${OCD_DIR}"

# Pretty stdio/stderr helpers.
_err() { echo -e "\e[1;31m\u2717\e[0;0m ${*}"; }
_info() { echo  -e "\e[1;32m\u2713\e[0;0m ${*}"; }

# Optional SSH identity for the git repository.
if [[ -n "${OCD_IDENT-}" ]]; then
  if [[ ! -f "${OCD_IDENT}" ]]; then
    _err "Couldn't find SSH identity from ${OCD_CONF}: ${OCD_IDENT}"
    exit 1
  fi
  GIT_SSH_COMMAND="ssh -i ${OCD_IDENT}"
  export GIT_SSH_COMMAND
fi

USAGE=$(cat << EOF
Usage:
  ocd install:        install files from ${OCD_REPO}
  ocd add FILE:       track a new file in the repository
  ocd rm FILE:        stop tracking a file in the repository
  ocd restore:        pull from git master and copy files to homedir
  ocd backup:         push all local changes to master
  ocd status [FILE]:  check if a file is tracked, or if there are uncommited changes
  ocd export FILE:    create a tar.gz archive with everything in ${OCD_DIR}
  ocd missing-pkgs:   compare system against ${OCD_FAV_PKGS} and report missing
EOF
)

##########
# We do a lot of manipulating files based on paths relative to the user's home directory, so this
# helper function does some sanity checking to ensure we're only dealing with regular files, and
# then splits the path and filename into useful chunks, storing them in these ugly globals.
ocd_file_split() {
  if [[ ! -f "${1-}" ]]; then
    _err "${1-} doesn't exist or is not a regular file."
    return 1
  fi
  OCD_FILE_BASE=$(basename "${1-}")
  OCD_FILE_REL=$(dirname "$(realpath -s --relative-to="${OCD_HOME}" "${1-}")")
}

ocd_ask() {
  if [[ "${OCD_ASSUME_YES}" == "true" ]]; then
    return
  fi
  prompt="${*} [NO/yes]: "
  echo -ne "${prompt}"
  while true; do
    local answer
    read -r answer
    if [[ -z "${answer}" ]]; then
        return 1  # Empty response defaults to "no".
    elif [[ "${answer,,}" == "yes" || "${answer,,}" == "y" ]];then
      return 0
    elif [[ "${answer,,}" == "no" || "${answer,,}" == "n" ]];then
      return 1
    else
      echo -ne "${prompt}"
    fi
  done
}

##########
# Install a package via sudo/dpkg. (Debian-only)
ocd_install_pkg() {
  if [[ -z "${1-}" ]]; then
    return 1
  fi

  _info "Installing ${1}..."

  if command -v dpkg >/dev/null; then
    sudo apt-get install -y "${1}"
  else
    _err "No \`dpkg\` available."
    return 1
  fi

  # If there are more arguments, call self recursively.
  if [[ -n "$2" ]]; then
    ocd_install_pkg "${@:2}"
  fi
}

##########
# Pull changes from git, and push them to  the user's homedirectory.
ocd_restore() {
  if [[ ! -d "${OCD_DIR}" ]]; then
    _err "${OCD_DIR}: doesn't exist!" && return
  fi

  _info "Running: git-pull:"
  ${OCD_GIT} pull || {
    _err  "error: couldn't git-pull; check status in ${OCD_DIR}"
    return 1
  }

  files=$(cd ${OCD_DIR}; find . -type f -o -type l | grep -Ev  "${OCD_IGNORE_RE}")
  dirs=$(cd ${OCD_DIR}; find . -type d | grep -Ev  "${OCD_IGNORE_RE}")

  for dir in ${dirs}; do
    mkdir -p "${OCD_HOME}/${dir}"
  done

  _info  "Restoring..."
  pushd "${OCD_DIR}" 1>/dev/null

  for existing_file in ${files}; do
    new_file="$(realpath -s ${OCD_HOME}/${existing_file})"
    # Only restore file if it doesn't already exist, or if it has changed.
    if [[ ! -f "${new_file}" ]] || [[ "${OCD_FORCE}" == "true" ]] \
        || ! cmp --silent "${existing_file}" "${new_file}"; then
      _info "  ${existing_file} -> ${new_file}"
      if [[ -f "${new_file}" ]]; then
        rm -f "${new_file}"
      fi
      # Link files from home directory to files in ~/.ocd repo.
      ln -sr "${OCD_DIR}/${existing_file}" "${new_file}"
    fi
  done
  popd 1>/dev/null

  # Some changes require cleanup that OCD won't handle; e.g., if you rename a file the old file
  # will remain. Housekeeping commands that need to be run may be put in ${OCD_DIR}/.ocd_cleanup;
  # they run only once.
  if [[ -f "${OCD_HOME}/.ocd_cleanup" ]] && \
      ! cmp "${OCD_HOME}"/.ocd_cleanup{,_ran} &>/dev/null; then
    _info "Running: ${OCD_HOME}/.ocd_cleanup:"
    "${OCD_HOME}/.ocd_cleanup" && cp "${OCD_HOME}"/.ocd_cleanup{,_ran}
  fi
}

##########
# Show status of local git repo, and optionally commit/push changes upstream.
ocd_backup() {
  _info "git status in ${OCD_DIR}:\\n"
  ${OCD_GIT} status
  if ! ${OCD_GIT} status | grep -q "nothing to commit"; then
    ${OCD_GIT} diff
    if ocd_ask "Commit everything and push to '${OCD_REPO}'?"; then
      if [[ "${OCD_ASSUME_YES}" == "true" ]]; then
        ${OCD_GIT} commit -a -m "Non-interactive commit."
      else
        ${OCD_GIT} commit -a
      fi
      ${OCD_GIT} push
    fi
  fi
}

##########
# Show tracking/modified status for a file, or the whole repo.
ocd_status() {
  # If an arg is passed, assume it's a file and report on whether it's tracked.
  if [[ -n "${1-}" ]]; then
    ocd_file_split ${1}

    if [[ -f "${OCD_DIR}/${OCD_FILE_REL}/${OCD_FILE_BASE}" ]]; then
      _info "is tracked"
    else
      _info "not tracked"
    fi
    return 0
  fi

  # If no args were passed, print env vars and  run `git status` instead.
  _info "OCD environment:"
  declare -p | grep 'declare -- OCD_' | sed 's/^.*OCD_/OCD_/' | sort
  printf '\n'

  _info "git status:"
  ${OCD_GIT} status
}

##########
# Display which of the user's favorite packages are not installed. (Debian-only)
ocd_missing_pkgs() {
  [[ -f "$OCD_FAV_PKGS" ]] || touch "$OCD_FAV_PKGS"

  if command -v dpkg 1>/dev/null; then
    dpkg --get-selections | grep '\sinstall$' | awk '{print $1}' | sort \
        | comm -13 - <(grep -Ev '(^-|^ *#)' "$OCD_FAV_PKGS" \
        | sed 's/ *#.*$//' |sort)
  else
    _err "Couldn't detect which distribution we're using."
    return 1
  fi
}

##########
# Start tracking a file in the user's home directory. This will add it to the git repo.
ocd_add() {
  if [[ -z "${1-}" ]]; then
    _err "Usage: ocd_add <filename>"
    return 1
  fi

  ocd_file_split ${1} || return 1

  mkdir -p "${OCD_DIR}/${OCD_FILE_REL}"

  home_file="${OCD_HOME}/${OCD_FILE_REL}/${OCD_FILE_BASE}"
  ocd_file="${OCD_DIR}/${OCD_FILE_REL}/${OCD_FILE_BASE}"

  # Link from home directory to file in ~/.ocd repo.
  mv "${home_file}" "${ocd_file}"
  ln -sr "${ocd_file}" "${home_file}"

  ${OCD_GIT} add "${OCD_FILE_REL}/${OCD_FILE_BASE}"

  # If there are more arguments, call self.
  if [[ -n "${2:-}" ]]; then
    ocd_add "${@:2}"
  fi
}

##########
# Stop tracking a file in the user's home directory. This will remove it from the git repo.
ocd_rm() {
  if [[ -z "$1" ]];then
    _info "Usage: ocd_rm <filename>"
    return 1
  fi

  ocd_file_split ${1}

  if [[ ! -f "${OCD_HOME}/${OCD_FILE_REL}/${OCD_FILE_BASE}" ]]; then
    _err "$1 is not in ${OCD_DIR}."
    return 1
  fi

  rm -f "${OCD_HOME}/${OCD_FILE_REL}/${OCD_FILE_BASE}"
  cp -f "${OCD_DIR}/${OCD_FILE_REL}/${OCD_FILE_BASE}" "${OCD_HOME}/${OCD_FILE_REL}/${OCD_FILE_BASE}"
  ${OCD_GIT} rm -f "${OCD_FILE_REL}/${OCD_FILE_BASE}"

  # If there are more arguments, call self.
  if [[ -n "${2:-}" ]]; then
    ocd_rm "${@:2}"
  fi
}

##########
# Create a tar.gz archive with everything in ~/.ocd. This is useful for exporting your dotfiles to
# another host where you don't want to run OCD.
ocd_export() {
  if [[ -n "$1" ]]; then
    OCD_TMP=$(mktemp -d)
    rsync -av ${OCD_DIR}/ ${OCD_TMP}/
    _info "$(date +%Y-%m-%d)" > ${OCD_TMP}/.ocd_exported
    tar -C ${OCD_TMP} --exclude ${OCD_IGNORE_RE} -czvpf $1 .
    rm -rf ${OCD_TMP}
  else
    _err "Must supply a filename for the new tar archive."
  fi
}

##########
# If OCD isn't already installed, guide the user through installation.
ocd_install() {
  if [[ ! -d "${OCD_DIR}/.git" ]]; then
    _info "OCD not installed! Running install script..."

    _info "Using repository: ${OCD_REPO}"
    if ! ocd_ask "Continue with this repo?"; then
      if ocd_ask "Continue without a repo?"; then
        mkdir -p "${OCD_DIR}/.git"
      fi
      return
    fi

    # Check if we need SSH auth for getting the repo.
    if [[ "${OCD_REPO}" == *"@"* ]]; then

      # Check if an ssh-agent is active with identities in memory.
      get_idents() { ssh-add -l 2>/dev/null; }

      if [[ -z "$(get_idents)" && -z "${OCD_IDENT}" ]]; then
        if ! ocd_ask "No SSH identities are available for \"${OCD_REPO}\".\nContinue anyway?"
        then
          _err "Quitting due to missing SSH identities."
          return 1
        fi
      fi
    fi

    # Fetch the repository.
    if ! command -v git >/dev/null; then
      ocd_install_pkg git
    fi

    if git clone "${OCD_REPO}" "${OCD_DIR}"; then
      if [[ -z "$(${OCD_GIT} branch -a)" ]]; then
        # You can't push to a bare repo with no commits, because the main branch won't exist yet.
        # So, we have to check for that and do an initial commit or else subsequent git commands will
        # not work.
        _info "Notice: ${OCD_REPO} looks like a bare repo with no commits;"
        _info "  commiting and pushing README.md to create a main branch."
        _info "https://github.com/nycksw/ocd" > "${OCD_DIR}"/README.md
        ${OCD_GIT} add .
        ${OCD_GIT} commit -m "Initial commit."
        ${OCD_GIT} branch -M main
        ${OCD_GIT} push -u origin main
      fi
      ocd_restore
      if [[ -f .bashrc ]]; then
        source .bashrc
      fi
    else
      _err "Couldn't clone repository: ${OCD_REPO}"
      return 1
    fi

    if [[ -n "$(ocd_missing_pkgs)" ]]; then
      if ocd_ask "Install missing pkgs? ($(ocd_missing_pkgs|xargs))"; then
        ocd_install_pkg "$(ocd_missing_pkgs)"
      fi
    fi

  else
    _info "Already installed."
  fi
}


main() {
  case "${1-}" in
    install)
      ocd_install
      ;;
    add)
      shift 1 && ocd_add "$@"
      ;;
    rm)
      shift 1 && ocd_rm "$@"
      ;;
    restore)
      ocd_restore
      ;;
    backup)
      ocd_backup
      ;;
    status)
      shift 1 && ocd_status "$@"
      ;;
    export)
      shift 1 && ocd_export "$@"
      ;;
    missing-pkgs)
      ocd_missing_pkgs
      ;;
    *)
      echo "${USAGE}"
      ;;
  esac
}

# Execute main function if script wasn't sourced.
if [[ "$0" = "${BASH_SOURCE[0]}" ]]; then

  # Vars for current file & dir.
  _dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  _file="${_dir}/$(basename "${BASH_SOURCE[0]}")"
  _base="$(basename ${_file})"
  _root="$(cd "$(dirname "${_dir}")" && pwd)"

  set -o errexit   # Exit on error.
  set -o nounset   # Don't use undeclared variables.
  set -o pipefail  # Catch errs from piped cmds.

  main "$@"
fi
