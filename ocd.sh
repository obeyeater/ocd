#!/usr/bin/env bash
#shellcheck disable=SC1091,SC2086,SC2164
#
# OCD: Optimally Configured Dotfiles
# See https://github.com/nycksw/ocd for detailed information.

CHECK_PERMS() {
  if [[ ! -f ${1} ]]; then return; fi
  if (( ( 8#$(stat -L -c '%a' ${1}) & 8#002 ) != 0 )); then
    echo "File \"${1}\" may be modified by anyone; exiting." >&2 && exit 1
  fi
}; CHECK_PERMS "${BASH_SOURCE[0]}" 

# Globals beginning with "OCD_" may be set separately in "~/.ocd.conf";
# other globals have an underscore prepended, e.g.: "_OCD_FN_BASENAME".

OCD_CONF="${OCD_CONF:-${HOME}/.ocd.conf}" && CHECK_PERMS "${OCD_CONF}"
if [[ -f "${OCD_CONF}" ]]; then source <( grep '^OCD_' ${OCD_CONF} ); fi

# These defaults may be overridden via the environment.
OCD_REPO="${OCD_REPO:-git@github.com:username/your-dotfiles.git}"
OCD_USER_HOME="${OCD_USER_HOME:-$HOME}"
OCD_GIT_DIR="${OCD_GIT_DIR:-${HOME}/.ocd}"
OCD_FAV_PKGS="${OCD_FAV_PKGS:-$OCD_USER_HOME/.favpkgs}"
OCD_ASSUME_YES="${OCD_ASSUME_YES:-false}"  # Set to true for non-interactive/testing.

# Pattern for files to ignore when doing anything with OCD (find, tar, etc.)
_OCD_IGNORE_RE="./.git"

# For git commands that need OCD_GIT_DIR as the working directory.
_OCD_GIT="git -C ${OCD_GIT_DIR}"

# Pretty stdio/stderr helpers.
ocd_info() { echo  -e "\e[1;32m\u2713\e[0;0m ${*}"; }    # '✓ ...' (green)
ocd_err() { echo -e "\e[1;31m\u2717\e[0;0m ${*}" >&2; }  # '✗ ...' (red)

# Optional SSH identity for the git repository.
if [[ -n "${OCD_IDENT-}" ]]; then
  if [[ ! -f "${OCD_IDENT}" ]]; then
    ocd_err "Couldn't find SSH identity from ${OCD_CONF}: ${OCD_IDENT}"
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
  ocd export FILE:    create a tar.gz archive with everything in ${OCD_GIT_DIR}
  ocd missing-pkgs:   compare system against ${OCD_FAV_PKGS} and report missing
EOF
)

##########
# We do a lot of manipulating files based on paths relative to the user's home
# directory, so this function does some sanity checking to ensure we're only
# dealing with regular files, and then splits the path and filename into useful
# chunks, storing them in these "_FILE_*" globals, documented below, inline.
ocd_filename_split() {
  if [[ ! -f "${1}" ]]; then
    ocd_err "${1} doesn't exist or is not a regular file."
    exit 1
  fi

  if [[ ! "$(realpath ${1})" == "${OCD_USER_HOME}"* ]]; then
    ocd_err "OCD only works on files within the user's home directory."
    exit 1
  fi

  # Just the filename with no directory, e.g.:
  #   ~/.vim/colors/solarized.vim -> solarized.vim
  _OCD_FN_BASENAME=$(basename "${1}")
  # The directory relative to the user's homedir, e.g.:
  #   ~/.vim/colors/solarized.vim -> .vim/colors
  _OCD_FN_RELDIR=$(dirname "$(realpath -ms --relative-to="${OCD_USER_HOME}" "${1}")")
  # The full path of the filename in the user's homedir, e.g.:
  #   ~/.vim/colors/solarized.vim -> /home/luser/.vim/colors/solarized.vim
  _OCD_FN_IN_HOME=$(realpath --no-symlinks "${OCD_USER_HOME}/${_OCD_FN_RELDIR}/${_OCD_FN_BASENAME}")
  # The full path of the filename in the Git directory, e.g.:
  #   ~/.vim/colors/solarized.vim -> /home/luser/.ocd/.vim/colors/solarized.vim
  _OCD_FN_IN_GIT=$(realpath "${OCD_GIT_DIR}/${_OCD_FN_RELDIR}/${_OCD_FN_BASENAME}")
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
# Pull changes from git, and push them to  the user's homedirectory.
ocd_restore() {
  if [[ ! -d "${OCD_GIT_DIR}" ]]; then
    ocd_err "${OCD_GIT_DIR}: doesn't exist!" && return
  fi

  ocd_info "Running: git-pull:"
  ${_OCD_GIT} pull || {
    ocd_err  "error: couldn't git-pull; check status in ${OCD_GIT_DIR}"
    exit 1
  }

  files=$(cd ${OCD_GIT_DIR}; find . -type f -o -type l | grep -Ev  "${_OCD_IGNORE_RE}")
  dirs=$(cd ${OCD_GIT_DIR}; find . -type d | grep -Ev  "${_OCD_IGNORE_RE}")

  for dir in ${dirs}; do
    mkdir -p "${OCD_USER_HOME}/${dir}"
  done

  ocd_info  "Restoring..."
  pushd "${OCD_GIT_DIR}" 1>/dev/null

  for existing_file in ${files}; do
    new_file="$(realpath -s ${OCD_USER_HOME}/${existing_file})"
    # Only restore file if it doesn't already exist, or if it has changed.
    if [[ ! -f "${new_file}" ]] || ! cmp --silent "${existing_file}" "${new_file}"; then
      ocd_info "  ${existing_file} -> ${new_file}"
      if [[ -f "${new_file}" ]]; then
        rm -f "${new_file}"
      fi
      # Link files from home directory to files in ~/.ocd repo.
      ln -sr "${OCD_GIT_DIR}/${existing_file}" "${new_file}"
    fi
  done
  popd 1>/dev/null

  # Some changes require cleanup that OCD won't handle; e.g., if you rename a
  # file the old file will remain. Housekeeping commands that need to be run
  # may be put in ${OCD_GIT_DIR}/.ocd_cleanup; they run only once.
  if [[ -f "${OCD_USER_HOME}/.ocd_cleanup" ]] && \
      ! cmp "${OCD_USER_HOME}"/.ocd_cleanup{,_ran} &>/dev/null; then
    ocd_info "Running: ${OCD_USER_HOME}/.ocd_cleanup:"
    "${OCD_USER_HOME}/.ocd_cleanup" && cp "${OCD_USER_HOME}"/.ocd_cleanup{,_ran}
  fi
}

##########
# Show status of local git repo, and optionally commit/push changes upstream.
ocd_backup() {
  ocd_info "git status in ${OCD_GIT_DIR}:\\n"
  ${_OCD_GIT} status
  if ! ${_OCD_GIT} status | grep -q "nothing to commit"; then
    ${_OCD_GIT} diff
    if ocd_ask "Commit everything and push to '${OCD_REPO}'?"; then
      if [[ "${OCD_ASSUME_YES}" == "true" ]]; then
        ${_OCD_GIT} commit -a -m "Non-interactive commit."
      else
        ${_OCD_GIT} commit -a
      fi
      ${_OCD_GIT} push
    fi
  fi
}

##########
# Show tracking/modified status for a file, or the whole repo.
ocd_status() {
  # If an arg is passed, assume it's a file and report on whether it's tracked.
  if [[ -n "${1-}" ]]; then
    ocd_filename_split ${1}  # Populate "_FILE_*" globals.

    if [[ -f "${_OCD_FN_IN_GIT}" ]]; then
      ocd_info "is tracked"
    else
      ocd_info "not tracked"
    fi
    return 0
  fi

  # If no args were passed, print env vars and  run `git status` instead.
  ocd_info "OCD configuration:"
  # OCD_* vars can exist as environmental variables as well as shell variables, see we'll
  # grep through both and sort the output.
  sort -u <( env | grep OCD_) <(declare -p | grep 'declare -- OCD_' | sed 's/^.*OCD_/OCD_/')
  printf '\n'

  ocd_info "git status:"
  ${_OCD_GIT} status
}

##########
# Display which of the user's favorite packages are not installed. (Debian-only)
ocd_missing_pkgs() {
  [[ -f "$OCD_FAV_PKGS" ]] || touch "$OCD_FAV_PKGS"

  if command -v dpkg 1>/dev/null; then
    missing_pkgs=$(dpkg --get-selections | grep '\sinstall$' | awk '{print $1}' | sort \
        | comm -13 - <(grep -Ev '(^-|^ *#)' "$OCD_FAV_PKGS" \
        | sed 's/ *#.*$//' |sort))

    if [[ -n "${missing_pkgs}" ]]; then
      ocd_info "Missing packages:"
      echo ${missing_pkgs}
    fi
  else
    ocd_err "This system lacks \`dpkg\`. Not a Debian-based system?"
    return
  fi
}

##########
# Start tracking a file in the user's home directory. This will add it to the git repo.
ocd_add() {
  if [[ -z "${1-}" ]]; then
    ocd_err "Usage: ocd_add <filename>"
    exit 1
  fi

  ocd_filename_split ${1}  # Populate "_FILE_*" globals.

  mkdir -p "${OCD_GIT_DIR}/${_OCD_FN_RELDIR}"

  if [[ -f "${_OCD_FN_IN_GIT}" ]]; then
    ocd_err "Already tracked: ${_OCD_FN_IN_GIT}"
    return
  fi

  # Add file to local Git repository and symlink to it.
  mv "${_OCD_FN_IN_HOME}" "${_OCD_FN_IN_GIT}"
  ln -sr "${_OCD_FN_IN_GIT}" "${_OCD_FN_IN_HOME}"

  ${_OCD_GIT} add "${_OCD_FN_RELDIR}/${_OCD_FN_BASENAME}"

  ocd_info "Added: ${_OCD_FN_IN_HOME}"

  # If there are more arguments, call self.
  if [[ -n "${2:-}" ]]; then
    ocd_add "${@:2}"
  fi
}

##########
# Stop tracking a file in the user's home directory. This will remove it from the git repo.
ocd_rm() {
  if [[ -z "$1" ]];then
    ocd_info "Usage: ocd_rm <filename>"
    exit 1
  fi

  ocd_filename_split ${1}  # Populate "_FILE_*" globals.

  if [[ ! -f "${_OCD_FN_IN_GIT}" ]]; then
    ocd_err "Not tracked: ${_OCD_FN_IN_HOME}"
    exit 1
  fi

  rm -f "${_OCD_FN_IN_HOME}"  # Remove symlink.
  cp -f "${_OCD_FN_IN_GIT}" "${_OCD_FN_IN_HOME}"  # Replace original.
  ${_OCD_GIT} rm -f "${_OCD_FN_RELDIR}/${_OCD_FN_BASENAME}"

  ocd_info "Removed: ${_OCD_FN_IN_HOME}"

  # If there are more arguments, call self.
  if [[ -n "${2:-}" ]]; then
    ocd_rm "${@:2}"
  fi
}

##########
# Create a tar.gz archive with everything in ~/.ocd. This is useful for
# exporting your dotfiles to another host where you don't want to run OCD.
ocd_export() {
  if [[ -n "$1" ]]; then
    OCD_TMP=$(mktemp -d)
    rsync -av ${OCD_GIT_DIR}/ ${OCD_TMP}/
    ocd_info "$(date +%Y-%m-%d)" > ${OCD_TMP}/.ocd_exported
    tar -C ${OCD_TMP} --exclude ${_OCD_IGNORE_RE} -czvpf $1 .
    rm -rf ${OCD_TMP}
  else
    ocd_err "Must supply a filename for the new tar.gz archive."
  fi
}

##########
# If OCD isn't already installed, guide the user through installation.
ocd_install() {
  if [[ ! -d "${OCD_GIT_DIR}/.git" ]]; then
    ocd_info "OCD not installed! Running install script..."

    ocd_info "Using repository: ${OCD_REPO}"
    if ! ocd_ask "Continue with this repo?"; then
      if ocd_ask "Continue without a repo?"; then
        mkdir -p "${OCD_GIT_DIR}/.git"
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
          ocd_err "Quitting due to missing SSH identities."
          exit 1
        fi
      fi
    fi

    # Fetch the repository.
    if ! command -v git >/dev/null; then
      ocd_err "OCD requires \`git\`."; exit
    fi

    if git clone "${OCD_REPO}" "${OCD_GIT_DIR}"; then
      if [[ -z "$(${_OCD_GIT} branch -a)" ]]; then
        # You can't push to a bare repo with no commits, because the main
        # branch won't exist yet.  # So, we have to check for that and do
        # an initial commit or else subsequent git commands # will not work.
        ocd_info "Notice: ${OCD_REPO} looks like a bare repo with no commits;"
        ocd_info "  commiting and pushing README.md to create a main branch."
        printf "https://github.com/nycksw/ocd\n" > "${OCD_GIT_DIR}"/README.md
        ${_OCD_GIT} add .
        ${_OCD_GIT} commit -m "Initial commit."
        ${_OCD_GIT} branch -M main
        ${_OCD_GIT} push -u origin main
      fi
      ocd_restore
    else
      ocd_err "Couldn't clone repository: ${OCD_REPO}"
      exit 1
    fi

    # Setup bash completion for OCD.
    if [[ ! "${OCD_ASSUME_YES}" == "true" ]] && \
      ocd_ask "Install the bash completion config for OCD? (requires sudo)"; then
      if [[ -d /etc/bash_completion.d ]]; then
        echo -e "${_OCD_BASH_COMPLETION_CONFIG}" | sudo tee /etc/bash_completion.d/ocd > /dev/null
        sudo chmod 644 /etc/bash_completion.d/ocd
        ocd_info "Installed: /etc/bash_completion.d/ocd"
      else
        ocd_err "Couldn't install /etc/bash_completion.d/ocd; directory doesn't exist."
      fi
    fi

    # Display missing Debian packages.
    ocd_missing_pkgs
  else
    ocd_info "Already installed."
  fi
}

_OCD_BASH_COMPLETION_CONFIG=$(cat <<'END'
_ocd() {
  local cur prev opts
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  opts="install add rm restore backup status export missing-pkgs"

  case "${prev}" in
    add|rm|status)
      COMPREPLY=( $(compgen -f -- "${cur}") )
      ;;
    *)
      if [[ "${COMP_WORDS[@]:0:${COMP_CWORD}}" =~ (add|rm|status) ]]; then
        COMPREPLY=( $(compgen -f -- "${cur}") )
      else
        COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
      fi
      ;;
  esac
}
complete -F _ocd ocd
complete -F _ocd ocd.sh
END
)

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

  set -o errexit   # Exit on error.
  set -o nounset   # Don't use undeclared variables.
  set -o pipefail  # Catch errs from piped cmds.

  main "$@"
fi
