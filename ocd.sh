#!/usr/bin/env bash
#shellcheck disable=SC1091,SC2086,SC2164

# OCD: Obesssive Compulsive Directory
# See https://github.com/nycksw/ocd for detailed information.
#
# To install, just source this file from bash.
#
# Functions and usage:
#   ocd-add:            track a new file in the repository
#   ocd-rm:             stop tracking a file in the repository
#   ocd-restore:        pull from git master and copy files to homedir
#   ocd-backup:         push all local changes to master
#   ocd-status:         check if a file is tracked, or if there are uncommited changes
#   ocd-missing-pkgs:   compare system against ${OCD_HOME}/.favpkgs, report missing

OCD_IGNORE_RE="/\.git/"

# These defaults may be overridden via the environment; see unit tests for examples.
OCD_REPO="${OCD_REPO:-git@github.com:nycksw/dotfiles.git}"
OCD_HOME="${OCD_HOME:-$HOME}"
OCD_DIR="${OCD_DIR:-${HOME}/.ocd}"
OCD_FAV_PKGS="${OCD_FAV_PKGS:-$OCD_HOME/.favpkgs}"

OCD_ASSUME_YES="${OCD_ASSUME_YES:-false}"  # Set to true for non-interactive/testing.

OCD_ERR()  { echo "$*" >&2; }

# OCD needs git, or at least a package manager (apt or nix) to install it. We can also
# use this to install packages via ocd-missing-pkgs based on user preferences.
if command -v dpkg >/dev/null; then
  OCD_PKG_MGR="dpkg"
elif command -v nix-env >/dev/null; then
  OCD_PKG_MGR="nix"
else
  if ! command -v git >/dev/null; then
    OCD_ERR "Couldn't find git or install it."
    return 1
  fi
fi

OCD_FILE_SPLIT() {
  # We do a lot of manipulating files based on paths relative to different
  # directories, so this helper function does some sanity checking to ensure
  # we're only dealing with regular files, and the splits the path and filename
  # into useful chunks.

  if [[ ! -f "$1" ]]; then
    OCD_ERR "$1 is not a regular file."
    return 1
  fi

  OCD_FILE_BASE=$(basename "$1")
  OCD_FILE_REL=$(dirname "$(realpath --relative-to="${OCD_HOME}" "$1")")
}

OCD_ASK() {
  if [[ "${OCD_ASSUME_YES}" == "true" ]]; then
    return
  fi
  echo -n "$* (yes/no): "
  while true; do
    local answer
    read -r answer
    if [[ ${answer} == "yes" ]];then
      return
    elif [[ ${answer} == "no" ]];then
      return 1
    else
      echo -n "$* (yes/no): "
    fi
  done
}

OCD_INSTALL_PKG() {
  if [[ -z "$1" ]]; then
    return 1
  fi

  echo "Installing ${1}..."

  if [[ "${OCD_PKG_MGR}" == "dpkg" ]]; then
    sudo apt-get install -y "$1"
  elif [[ "${OCD_PKG_MGR}" == "nix" ]]; then
    nix-env -i "$1"
  else
    OCD_ERR "Couldn't detect a suitable package manager."
    return 1
  fi

  # If there are more arguments, call self recursively.
  if [[ -n "$2" ]]; then
    OCD_INSTALL_PKG "${@:2}"
  fi
}

# The remaining functions are named in lowercase and with dashes, as they
# are intended as CLI utilities.

ocd-restore() {
  if [[ ! -d "${OCD_DIR}" ]]; then
    echo "${OCD_DIR}: doesn't exist!" && return
  fi

  echo "Running: git-pull:"
  git -C "${OCD_DIR}" pull || {
    OCD_ERR  "error: couldn't git-pull; check status in ${OCD_DIR}"
    return 1
  }

  local files
  local dirs

  files=$(cd ${OCD_DIR}; find . -type f -o -type l | grep -Ev  "${OCD_IGNORE_RE}")
  dirs=$(cd ${OCD_DIR}; find -type d | grep -Ev  "${OCD_IGNORE_RE}")

  for dir in ${dirs}; do
    mkdir -p "${OCD_HOME}/${dir}"
  done

  # If we're making changes to ~/.ocd.sh outside of the repo, it's easy to accidentally
  # lose them when restoring from the repo. Check for this condition and keep the mods.
  if [[ -f "${OCD_DIR}/.ocd.sh" ]] && \
      ! cmp "${OCD_DIR}/.ocd.sh" "${BASH_SOURCE[0]}" >/dev/null; then
    echo "Note: the local version of ocd.sh differs from the one in your repo."
    echo "Keeping the local version, and adding it to '${OCD_DIR}'."
    cp "${BASH_SOURCE[0]}" ${OCD_DIR}/.ocd.sh
  fi

  echo  "Restoring..."

  for file in ${files}; do
    dst="$(realpath -s ${OCD_HOME}/${file})"
    echo "  ${file} -> ${dst}"
    if [[ -f "${dst}" ]]; then
      rm -f "${dst}"
    fi
    ln "${OCD_DIR}/${file}" "${dst}"
  done

  # Some changes require cleanup that OCD won't handle; e.g., if you rename
  # a file the old file will remain. Housekeeping commands that need to be
  # run may be put in ${OCD_DIR}/.ocd_cleanup; they run only once.
  if [[ -f "${OCD_HOME}/.ocd_cleanup" ]] && \
      ! cmp "${OCD_HOME}"/.ocd_cleanup{,_ran} &>/dev/null; then
    echo -e "Running: ${OCD_HOME}/.ocd_cleanup:"
    "${OCD_HOME}/.ocd_cleanup" && cp "${OCD_HOME}"/.ocd_cleanup{,_ran}
  fi
}

ocd-backup() {
  pushd "${OCD_DIR}" >/dev/null
  echo -e "git status in $(pwd):\n"
  git status
  if ! git status | grep -q "nothing to commit"; then
    git diff
    if OCD_ASK "Commit everything and push to '${OCD_REPO}'?"; then
      git commit -a
      git push
    fi
  fi
  popd >/dev/null
}

ocd-status() {
  # If an arg is passed, assume it's a file and report on whether it's tracked.
  if [[ -n "$1" ]]; then
    OCD_FILE_SPLIT ${1}

    if [[ -f "${OCD_DIR}/${OCD_FILE_REL}/${OCD_FILE_BASE}" ]]; then
      echo "tracked"
    else
      echo "untracked"
    fi
    return 0
  fi

  # If no args were passed, run `git status` instead.

  pushd "${OCD_DIR}" >/dev/null
  git status
  popd >/dev/null
}

ocd-missing-pkgs() {
  [[ -f "$OCD_FAV_PKGS" ]] || touch "$OCD_FAV_PKGS"

  if [[ "${OCD_PKG_MGR}" == "dpkg" ]]; then
    dpkg --get-selections | grep '\sinstall$' | awk '{print $1}' | sort \
        | comm -13 - <(grep -Ev '(^-|^ *#)' "$OCD_FAV_PKGS" \
        | sed 's/ *#.*$//' |sort)
  elif [[ "${OCD_PKG_MGR}" == "nix" ]]; then
    # TODO:implement missing pkg check for NixOS
    OCD_ERR "Notice: Checking .favpkgs not yet implemented on NixOS."

  else
    OCD_ERR "Couldn't detect which distribution we're using."
    return 1
  fi
}

ocd-add() {
  if [[ -z "$1" ]];then
    ocd:err "Usage: ocd-add <filename>"
    return 1
  fi

  OCD_FILE_SPLIT ${1} || return 1

  mkdir -p "${OCD_DIR}/${OCD_FILE_REL}"
  ln -f "${OCD_HOME}/${OCD_FILE_REL}/${OCD_FILE_BASE}" "${OCD_DIR}/${OCD_FILE_REL}/${OCD_FILE_BASE}"

  pushd "${OCD_DIR}" >/dev/null
  git add "./${OCD_FILE_REL}/${OCD_FILE_BASE}" && echo "Tracking: $1"
  popd >/dev/null

  # If there are more arguments, call self.
  if [[ -n "$2" ]]; then
    ocd-add "${@:2}"
  fi
}

ocd-rm() {
  if [[ -z "$1" ]];then
    echo "Usage: ocd-rm <filename>"
    return 1
  fi

  OCD_FILE_SPLIT ${1}

  if [[ ! -f "${OCD_DIR}/${OCD_FILE_REL}/${OCD_FILE_BASE}" ]]; then
    OCD_ERR "$1 is not in ${OCD_DIR}."
    return 1
  fi
  pushd "${OCD_DIR}/${OCD_FILE_REL}" >/dev/null
  git rm -f "${OCD_FILE_BASE}" 1>/dev/null && echo "Untracking: $1" 
  popd >/dev/null

  # Clean directory if empty.
  rm -d "${OCD_DIR}/${OCD_FILE_REL}" 2>/dev/null

  # If there are more arguments, call self.
  if [[ -n "$2" ]]; then
    ocd-rm "${@:2}"
  fi

  return 0
}

# If OCD isn't already installed, guide the user through installation.

if [[ ! -d "${OCD_DIR}/.git" ]]; then
  echo "OCD not installed! Running install script..."

  echo "Using repository: ${OCD_REPO}"
  if ! OCD_ASK "Continue with this repo?"; then
    return
  fi

  # Check if we need SSH auth for getting the repo.
  if [[ "${OCD_REPO}" == *"@"* ]]; then

    # Check if an ssh-agent is active with identities in memory.
    get_idents() { ssh-add -l 2>/dev/null; }

    if [[ -z "$(get_idents)" ]]; then
      if ! OCD_ASK "No SSH identities are available for \"${OCD_REPO}\". Continue anyway?"
      then
        OCD_ERR "Quitting due to missing SSH identities."
        return 1
      fi
    fi
  fi

  # Fetch the repository.

  if ! which git >/dev/null; then
    OCD_INSTALL_PKG git
  fi

  if git clone "${OCD_REPO}" "${OCD_DIR}" ; then
    ocd-restore
    if [[ -f .bashrc ]]; then
      source .bashrc
    fi
  else
    OCD_ERR "Couldn't clone repository: ${OCD_REPO}"
    return 1
  fi

  if [[ -n "$(ocd-missing-pkgs)" ]]; then
    if OCD_ASK "Install missing pkgs? ($(ocd-missing-pkgs|xargs))"; then
      OCD_INSTALL_PKG "$(ocd-missing-pkgs)"
    fi
  fi

  # Add this script to the repo if it's not already there.
  if [[ ! -f "${OCD_DIR}/.ocd.sh" ]]; then
    echo "Adding this script to ${OCD_HOME}/.ocd.sh and tracking in repo."
    cp "${BASH_SOURCE[0]}" "${OCD_HOME}/.ocd.sh"
    ocd-add "${OCD_HOME}/.ocd.sh"
  fi

  echo "DON'T FORGET to source ${OCD_HOME}/.ocd.sh via .bash_profile or something similar."
  echo "...something like: test -f ~/.ocd.sh && source ~/.ocd.sh"
fi

alias ocd="pushd \${OCD_HOME}/.ocd"
