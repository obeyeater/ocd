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

# Instal me system-wide like this:
#   sudo cp ./ocd_completion.sh /etc/bash_completion.d/ocd
#   sudo chmod 644 /etc/bash_completion.d/ocd
