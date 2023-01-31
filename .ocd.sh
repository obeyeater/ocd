#!/usr/bin/env bash
#shellcheck disable=SC1091,SC2086,SC2164

# OCD: Obesssive Compulsive Directory
# See https://github.com/nycksw/ocd for detailed information.
#
# To install, just source this file from bash.
#
# Functions and usage:
#   ocd-restore:        pull from git master and copy files to homedir
#   ocd-backup:         push all local changes to master
#   ocd-add:            track a new file in the repository
#   ocd-rm:             stop tracking a file in the repository
#   ocd-missing-pkgs:   compare system against ${OCD_HOME}/.favpkgs, report missing
#   ocd-status:         check if OK or Behind

OCD_IGNORE_RE="^\./(README|\.git/)"
OCD_REPO="git@github.com:nycksw/dotfiles.git"
OCD_DIR="${OCD_HOME}/.ocd"
OCD_HOME="${HOME}"
OCD_FAV_PKGS="${OCD_HOME}/.favpkgs"

# OCD only works on Debian and NixOS.
if uname -v | grep -q 'Debian'; then
  OCD_DIST="debian"
elif uname -v | grep -q 'NixOS'; then
  OCD_DIST="nixos"
else
  OCD_ERR "Couldn't detect which distribution we're using."
  return 1
fi

OCD_ERR()  { echo "$*" >&2; }

OCD_FILE_SPLIT() {
  # We do a lot of manipulating files based on paths relative to different
  # directories, so this helper function does some sanity checking to ensure
  # we're only dealing with regular files, and the splits the path and filename
  # into useful chunks relative to the user's homedir.

  if [[ ! -f "$1" ]]; then
    OCD_ERR "$1 is not a regular file."
    return 1
  fi

  OCD_FILE_BASE=$(basename "$1")
  OCD_FILE_REL=$(dirname "$(realpath --relative-to="${OCD_HOME}" "$1")")
}

OCD_ASK() {
  echo -n "$* (y/n): "
  while true; do
    local answer
    read -r answer
    if [[ ${answer} == "y"* ]];then
      return 0
    elif [[ ${answer} == "n"* ]];then
      return 1
    else
      echo -n "$* (y/n): "
    fi
  done
}

OCD_INSTALL() {
  if [[ -z "$1" ]]; then
    return 1
  fi

  echo "Installing ${1}..."

  if [[ "${OCD_DIST}" == "debian" ]]; then
    sudo apt-get install -y "$1"
  elif [[ "${OCD_DIST}" == "nixos" ]]; then
    nix-env -i "$1"
  else
    OCD_ERR "Couldn't detect which distribution we're using."
    return 1
  fi

  # If there are more arguments, call self recursively.
  if [[ -n "$2" ]]; then
    OCD_INSTALL "${@:2}"
  fi
}

# The remaining functions are named in lowercase and with dashes, as they
# are used as CLI functions.

ocd-restore() {
  if [[ ! -d "${OCD_DIR}" ]]; then
    echo "${OCD_DIR}: doesn't exist!" && return
  fi
  pushd "${OCD_DIR}" >/dev/null
  echo "Running: git-pull:"
  git pull || {
    OCD_ERR  "error: couldn't git-pull; check status in ${OCD_DIR}"
    popd >/dev/null
    return 1
  }

  local files
  local dirs

  files=$(find . -type f -o -type l | grep -Ev  "${OCD_IGNORE_RE}")
  dirs=$(find . -type d | grep -Ev  "${OCD_IGNORE_RE}")

  for dir in ${dirs}; do
    mkdir -p "${OCD_HOME}/${dir}"
  done

  echo -n "Restoring"
  for file in ${files}; do
    echo -n .
    dst="${OCD_HOME}/${file}"
    if [[ -f "${dst}" ]]; then
      rm -f "${dst}"
    fi
    ln "${file}" "${dst}"
  done
  echo

  # Some changes require cleanup that OCD won't handle; e.g., if you rename
  # a file the old file will remain. Housekeeping commands that need to be
  # run may be put in ${OCD_DIR}/.ocd_cleanup; they run only once.
  if ! cmp "${OCD_HOME}"/.ocd_cleanup{,_ran} &>/dev/null; then
    echo -e "Running: ${OCD_HOME}/.ocd_cleanup:"
    "${OCD_HOME}/.ocd_cleanup" && cp "${OCD_HOME}"/.ocd_cleanup{,_ran}
  fi
  popd >/dev/null
}

ocd-backup() {
  pushd "${OCD_DIR}" >/dev/null
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
  # If given an argument, check whether it's a file being tracked in the repo.
  if [[ -n "$1" ]]; then
    OCD_FILE_SPLIT ${1}

    if [[ -f "${OCD_DIR}/${OCD_FILE_REL}/${OCD_FILE_BASE}" ]]; then
      echo "tracked"
    else
      echo "untracked"
    fi
    return 0
  fi

  # If no args were passed, just run `git status` instead.
  pushd "${OCD_DIR}" >/dev/null
  git status
  popd >/dev/null && return
}

ocd-missing-pkgs() {
  [[ -f "$OCD_FAV_PKGS" ]] || touch "$OCD_FAV_PKGS"

  # Debian
  if [[ "${OCD_DIST}" == "debian" ]]; then
    dpkg --get-selections | grep '\sinstall$' | awk '{print $1}' | sort \
        | comm -13 - <(grep -Ev '(^-|^ *#)' "$OCD_FAV_PKGS" \
        | sed 's/ *#.*$//' |sort)

  # NixOS
  elif [[ "${OCD_DIST}" == "nixos" ]]; then
    # TODO:implement missing pkg check for NixOS
    OCD_ERR "Notice: Checking .favpkgs not yet implemented on NixOS."
    return 1

  else
    OCD_ERR "Couldn't detect which distribution we're using."
    return 1
  fi
}

ocd-add() {
  if [[ -z "$1" ]];then
    OCD_ERR "Usage: ocd-add <filename>"
    return 1
  fi

  OCD_FILE_SPLIT ${1}

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
    OCD_INSTALL git
  fi

  if git clone "${OCD_REPO}" "${OCD_DIR}" ; then
      ocd-restore && source .bashrc
  fi

  if [[ -n "$(ocd-missing-pkgs)" ]]; then
    if OCD_ASK "Install missing pkgs? ($(ocd-missing-pkgs|xargs))"; then
      OCD_INSTALL "$(ocd-missing-pkgs)"
    fi
  fi

  echo "Make sure you source ~/.ocd.sh from bashrc or similar."
fi

alias ocd="pushd \${OCD_HOME}/.ocd"
