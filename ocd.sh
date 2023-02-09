#!/usr/bin/env bash
#shellcheck disable=SC1091,SC2086,SC2164

# OCD: Optimally Configured Dotfiles
# See https://github.com/nycksw/ocd for detailed information.
#
# To install, just source this file from bash.
#
# Functions and usage:
#   ocd-add FILE:       track a new file in the repository
#   ocd-rm FILE:        stop tracking a file in the repository
#   ocd-restore:        pull from git master and copy files to homedir
#   ocd-backup:         push all local changes to master
#   ocd-status [FILE]:  check if a file is tracked, or if there are uncommited changes
#   ocd-export FILE:    create a tar.gz archive with everything in '~/.ocd'.
#   ocd-missing-pkgs:   compare system against ${OCD_HOME}/.favpkgs, report missing

# Pattern for files to ignore when doing anything with OCD (find, tar, etc.)
OCD_IGNORE_RE="./.git"

# These defaults may be overridden via the environment; see unit tests for examples.
OCD_REPO="${OCD_REPO:-git@github.com:nycksw/dotfiles.git}"
OCD_HOME="${OCD_HOME:-$HOME}"
OCD_DIR="${OCD_DIR:-${HOME}/.ocd}"
OCD_FAV_PKGS="${OCD_FAV_PKGS:-$OCD_HOME/.favpkgs}"
OCD_ASSUME_YES="${OCD_ASSUME_YES:-false}"  # Set to true for non-interactive/testing.

# Options for linking to files in the repo.
#OCD_LN_OPTS=""    # Leave options empty to create hard links.
OCD_LN_OPTS="-sr"  # Create relative symbolic links.

# For git commands that need OCD_DIR as the working directory.
OCD_GIT="git -C ${OCD_DIR}"

##########
# Send a message to stderr.
OCD_ERR()  { echo "$*" >&2; }

# OCD needs git, or at least a package manager (apt or nix) to install it. We can also use this to
# install packages via ocd-missing-pkgs based on user preferences.
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

##########
# We do a lot of manipulating files based on paths relative to the user's home directory, so this
# helper function does some sanity checking to ensure we're only dealing with regular files, and
# then splits the path and filename into useful chunks, storing them in these ugly globals.
OCD_FILE_SPLIT() {
  if [[ ! -f "$1" ]]; then
    OCD_ERR "$1 is not a regular file."
    return 1
  fi
  OCD_FILE_BASE=$(basename "$1")
  OCD_FILE_REL=$(dirname "$(realpath -s --relative-to="${OCD_HOME}" "$1")")
}

##########
# Ask the user if they want to do something.
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

##########
# Install a package via sudo. (Debian-only)
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

##########
# The remaining functions are named in lowercase and with dashes, as they are intended as CLI
# utilities.

##########
# Pull changes from git, and push them to  the user's homedirectory.
ocd-restore() {
  if [[ ! -d "${OCD_DIR}" ]]; then
    OCD_ERR "${OCD_DIR}: doesn't exist!" && return
  fi

  echo "Running: git-pull:"
  ${OCD_GIT} pull || {
    OCD_ERR  "error: couldn't git-pull; check status in ${OCD_DIR}"
    return 1
  }

  files=$(cd ${OCD_DIR}; find . -type f -o -type l | grep -Ev  "${OCD_IGNORE_RE}")
  dirs=$(cd ${OCD_DIR}; find . -type d | grep -Ev  "${OCD_IGNORE_RE}")

  for dir in ${dirs}; do
    mkdir -p "${OCD_HOME}/${dir}"
  done

  # If we're making changes to ~/.ocd.sh outside of the repo, it's easy to accidentally
  # lose them when restoring from the repo. Check for this condition and keep the mods.
  if [[ -f "${OCD_DIR}/.ocd.sh" ]] && \
      ! cmp "${OCD_DIR}/.ocd.sh" "${BASH_SOURCE[0]}" >/dev/null; then
    echo "NOTE: the local version of ocd.sh differs from the one in the repo."
    echo "  Keeping the local version, and adding it to '${OCD_DIR}'."
    echo "  Use 'git checkout -f ${OCD_DIR}/.ocd.sh' to overwrite local changes."
    echo "  Use 'ocd-backup' to commit the local changes to the repo."
    cp "${BASH_SOURCE[0]}" ${OCD_DIR}/.ocd.sh
  fi

  echo  "Restoring..."

  for file in ${files}; do
    dst="$(realpath -s ${OCD_HOME}/${file})"
    # Only restore file if it doesn't already exist, or if it has changed.
    if [[ ! -f "${dst}" ]] || ! cmp --silent "${file}" "${dst}"; then
      echo "  ${file} -> ${dst}"
      # If ~/.ocd.sh changed, warn the user that they should source it again.
      if [[ "${dst}" == "${OCD_HOME}/ocd.sh" ]]; then
        echo "Notice: ocd.sh changed, source it to use new version: source ${OCD_HOME}/.ocd.sh"
      fi
      if [[ -f "${dst}" ]]; then
        rm -f "${dst}"
      fi
      ln ${OCD_LN_OPTS} "${OCD_DIR}/${file}" "${dst}"
    fi
  done

  # Some changes require cleanup that OCD won't handle; e.g., if you rename a file the old file
  # will remain. Housekeeping commands that need to be run may be put in ${OCD_DIR}/.ocd_cleanup;
  # they run only once.
  if [[ -f "${OCD_HOME}/.ocd_cleanup" ]] && \
      ! cmp "${OCD_HOME}"/.ocd_cleanup{,_ran} &>/dev/null; then
    echo -e "Running: ${OCD_HOME}/.ocd_cleanup:"
    "${OCD_HOME}/.ocd_cleanup" && cp "${OCD_HOME}"/.ocd_cleanup{,_ran}
  fi
}

##########
# Show status of local git repo, and optionally commit/push changes upstream.
ocd-backup() {
  echo -e "git status in ${OCD_DIR}:\n"
  ${OCD_GIT} status
  if ! ${OCD_GIT} status | grep -q "nothing to commit"; then
    ${OCD_GIT} diff
    if OCD_ASK "Commit everything and push to '${OCD_REPO}'?"; then
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
  ${OCD_GIT} status
}

##########
# Display which of the user's favorite packages are not installed. (Debian-only) 
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

##########
# Start tracking a file in the user's home directory. This will add it to the git repo.
ocd-add() {
  if [[ -z "$1" ]];then
    ocd:err "Usage: ocd-add <filename>"
    return 1
  fi

  OCD_FILE_SPLIT ${1} || return 1

  mkdir -p "${OCD_DIR}/${OCD_FILE_REL}"
  ln ${OCD_LN_OPTS} "${OCD_HOME}/${OCD_FILE_REL}/${OCD_FILE_BASE}" \
      "${OCD_DIR}/${OCD_FILE_REL}/${OCD_FILE_BASE}"

  ${OCD_GIT} add "${OCD_FILE_REL}/${OCD_FILE_BASE}" && echo "Tracking: $1"

  # If there are more arguments, call self.
  if [[ -n "$2" ]]; then
    ocd-add "${@:2}"
  fi
}

##########
# Stop tracking a file in the user's home directory. This will remove it from the git repo.
ocd-rm() {
  if [[ -z "$1" ]];then
    echo "Usage: ocd-rm <filename>"
    return 1
  fi

  OCD_FILE_SPLIT ${1}

  if [[ ! -f "${OCD_HOME}/${OCD_FILE_REL}/${OCD_FILE_BASE}" ]]; then
    OCD_ERR "$1 is not in ${OCD_DIR}."
    return 1
  fi

  ${OCD_GIT} rm -f "${OCD_FILE_REL}/${OCD_FILE_BASE}" && echo "Untracking: $1"

  # If there are more arguments, call self.
  if [[ -n "$2" ]]; then
    ocd-rm "${@:2}"
  fi
}

##########
# Create a tar.gz archive with everything in ~/.ocd. This is useful for exporting your dotfiles to
# another host where you don't want to run OCD.
ocd-export() {
  if [[ -n "$1" ]]; then
    tar -C ${OCD_DIR} --exclude ${OCD_IGNORE_RE} -czvpf $1 .
  else
    OCD_ERR "Must supply a filename for the new tar archive."
  fi
}

##########
# Everything below runs when this file is sourced.

##########
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

  if git clone "${OCD_REPO}" "${OCD_DIR}"; then
    if [[ -z "$(${OCD_GIT} branch -a)" ]]; then
      # You can't push to a bare repo with no commits, because the main branch won't exist yet.
      # So, we have to check for that and do an initial commit or else subsequent git commands will
      # not work.
      echo "Notice: ${OCD_REPO} looks like a bare repo with no commits;"
      echo "  commiting and pushing README.md to create a main branch."
      echo "https://github.com/nycksw/ocd" > "${OCD_DIR}"/README.md
      ${OCD_GIT} add . 
      ${OCD_GIT} commit -m "Initial commit."
      ${OCD_GIT} push -u origin main
    fi
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
