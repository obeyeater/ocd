# OCD: Obesssive Compulsive Directory
# See https://github.com/nycksw/ocd for detailed information.
#
# Functions and usage:
#   ocd-restore:        pull from git master and copy files to homedir
#   ocd-backup:         push all local changes to master
#   ocd-add:            track a new file in the repository
#   ocd-rm:             stop tracking a file in the repository
#   ocd-missing-debs:   compare system against ${HOME}/.favdebs and report missing
#   ocd-extra-debs:     compare system against ${HOME}/.favdebs and report extras
#   ocd-status:         check if OK or Behind

OCD_IGNORE_RE="^\./(README|\.git/)"
OCD_REPO="git@github.com:nycksw/dotfiles.git"
OCD_DIR="${HOME}/.ocd"

# Disable interactive prompts.
GIT_SSH_COMMAND="ssh -oBatchMode=yes"

ocd::err()  { echo "$@" >&2; }

ocd::yesno() {
  echo -n "$@ (yes/no): "
  while true; do
    local answer
    read answer
    if [[ ${answer} == "yes" ]];then
      return 0
    elif [[ ${answer} == "no" ]];then
      return 1
    else
      echo -n "$@ (yes/no): "
    fi
  done
}

ocd-restore() {
  if [[ ! -d "${OCD_DIR}" ]]; then
    echo "${OCD_DIR}: doesn't exist!" && return
  fi
  pushd "${OCD_DIR}" >/dev/null
  echo "Running: git-pull:"
  git pull || {
    ocd::err  "error: couldn't git-pull; check status in ${OCD_DIR}"
    popd >/dev/null
    return 1
  }

  local files=$(find . -type f -o -type l | egrep -v  "${OCD_IGNORE_RE}")
  local dirs=$(find . -type d | egrep -v  "${OCD_IGNORE_RE}")

  for dir in ${dirs}; do
    mkdir -p "${HOME}/${dir}"
  done

  echo -n "Restoring"
  for file in ${files}; do
    echo -n .
    dst="${HOME}/${file}"
    if [[ -f "${dst}" ]]; then
      rm -f "${dst}"
    fi
    ln "${file}" "${dst}"
  done
  echo

  # Some changes require cleanup that OCD won't handle; e.g., if you rename
  # a file the old file will remain. Housekeeping commands that need to be
  # run may be put in ${OCD_DIR}/.ocd_cleanup; they run only once.
  if ! cmp ${HOME}/.ocd_cleanup{,_ran} &>/dev/null; then
    echo -e "Running: ${HOME}/.ocd_cleanup:"
    "${HOME}/.ocd_cleanup" && cp ${HOME}/.ocd_cleanup{,_ran}
  fi
  popd >/dev/null
}

ocd-backup() {
  pushd "${OCD_DIR}" >/dev/null
  echo -e "git status in $(pwd):\n"
  git status
  if ! git status | grep -q "working directory clean"; then
    git diff
    if ocd::yesno "Commit and push now?"; then
      git commit -a
      git push
    fi
  fi
  popd >/dev/null
}

ocd-status() {
  # If an arg is passed, assume it's a file and report on if it's tracked.
  if [[ -e "$1" ]]; then
    if [[ -d "$1" ]]; then
      ocd::err "Argument should be a file, not a directory."
      return 1
    fi
    local base=$(basename "$1")
    local abspath=$(cd "$(dirname $1)"; pwd)
    local relpath="${abspath/#${HOME}/}"
    if [[ -f "${OCD_DIR}${relpath}/${base}" ]]; then
      echo "tracked"
    else
      echo "untracked"
    fi
    return 0
  elif [[ -z "$1" ]]; then
    # Arg isn't passed; report on the repo status instead.
    pushd "${OCD_DIR}" >/dev/null
    git remote update &>/dev/null
    if git status -uno | grep -q behind; then
      echo "behind"
      popd >/dev/null && return 1
    else
      echo "ok"
      popd >/dev/null && return 0
    fi
    echo "Error"
    popd >/dev/null && return 1
  else
    ocd::err "No such file: $1"
    return 1
  fi
  return 0
}

ocd-missing-debs() {
  [[ -f "${HOME}/.favdebs" ]] || touch "${HOME}/.favdebs"
  dpkg --get-selections | grep '\sinstall$' | awk '{print $1}' | sort \
      | comm -13 - <(egrep -v '(^-|^ *#)' "${HOME}/.favdebs" \
      | sed 's/ *#.*$//' |sort)
}

ocd-extra-debs() {
  [[ -f "${HOME}/.favdebs" ]] || touch "${HOME}/.favdebs"
  dpkg --get-selections | grep '\sinstall$' | awk '{print $1}' | sort \
      | comm -12 - <(grep -v '^ *#' "${HOME}/.favdebs" | grep '^-' | cut -b2- \
      | sed 's/ *#.*$//' |sort)
}

ocd-add() {
  if [[ -z "$1" ]];then
    echo "Usage: ocd-add <filename>"
    return 1
  fi
  if [[ ! -f "$1" ]];then
    echo "$1 not found."
    return 1
  fi
  local base="$(basename $1)"
  local abspath=$(cd $(dirname "$1"); pwd)
  local relpath="${abspath/#${HOME}/}"
  if [[ "${HOME}${relpath}/${base}" != "${abspath}/${base}" ]]; then
    echo "$1 is not in ${HOME}"
    return 1
  fi
  mkdir -p "${OCD_DIR}/${relpath}"
  ln -f "${HOME}${relpath}/${base}" "${OCD_DIR}${relpath}/${base}"
  pushd "${OCD_DIR}" >/dev/null
  git add ".${relpath}/${base}" && echo "Tracking: $1"
  popd >/dev/null

  # If there are more arguments, call self.
  if [[ ! -z "$2" ]]; then
    ocd-add "${@:2}"
  fi
}

ocd-rm() {
  if [[ -z "$1" ]];then
    echo "Usage: ocd-rm <filename>"
    return 1
  fi
  if [[ ! -f "$1" ]];then
    echo "$1 not found."
    return 1
  fi
  local base="$(basename $1)"
  local abspath="$(cd "$(dirname $1)"; pwd)"
  local relpath="${abspath/#${HOME}/}"
  if [[ ! -f "${OCD_DIR}/${relpath}/${base}" ]]; then
    ocd::err "$1 is not in ${OCD_DIR}."
    return 1
  fi
  pushd "${OCD_DIR}/${relpath}" >/dev/null
  git rm -f "${base}" 1>/dev/null && echo "Untracking: $1" 
  popd >/dev/null

  # Clean directory if empty.
  rm -d "${OCD_DIR}/${relpath}" 2>/dev/null

  # If there are more arguments, call self.
  if [[ ! -z "$2" ]]; then
    ocd-rm "${@:2}"
  fi

  return 0
}

# Check if installed. If not, fix it.
if [[ ! -d "${OCD_DIR}/.git" ]]; then
  echo "OCD not installed! running install script..."

  # Check if we need SSH auth for getting the repo.
  if [[ "${OCD_REPO}" == *"@"* ]]; then

    # Check if an ssh-agent is active with identities in memory.
    get_idents() { ssh-add -l 2>/dev/null; }

    if [[ -z "$(get_idents)" ]]; then
      if ! ocd::yesno "No SSH identities are available for \"${OCD_REPO}\". Continue anyway?"
      then
        ocd::err "Quitting due to missing SSH identities."
        return 1
      fi
    fi
  fi

  # Fetch the repository.
  if ocd::yesno "Fetch from git repository \"${OCD_REPO}?\""; then
    if ! which git >/dev/null; then
      echo "Installing git..."
      sudo apt-get install -y git
    fi
    if git clone "${OCD_REPO}" "${OCD_DIR}" ; then
        ocd-restore && source .bashrc
    fi
    if [[ ! -z "$(ocd-missing-debs)" ]]; then
      if ocd::yesno "Install missing debs? (`ocd-missing-debs|xargs`)"; then
        sudo apt-get install -y `ocd-missing-debs`
      fi
    fi
  fi
fi
