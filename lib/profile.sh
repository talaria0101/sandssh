# sandhome profile fragment. Installed by bootstrap.sh as profile.sh and read
# from the login files with one guarded line. POSIX sh only: bash, dash, ash,
# ksh and FreeBSD sh all read it. No arrays, no `local`, no `[[`, no `$'...'`.
#
# ⛔ IT FETCHES NOTHING, EVER. A profile that updates itself puts a fetch in front
# of every shell start and makes its own content untrackable.
# ⛔ NO ALIASES AND NO PROMPT. An alias for a tool that was not installed is an
# error on every shell start, and a prompt is taste rather than a tool.
# ⭐ ONE SWITCH TURNS ALL OF IT OFF: SANDHOME_NO_PROFILE=1.
#
# Everything is inside one function so `return` is legal however this file was
# read, and so the early exits read as one list rather than nested ifs.

sandhome_profile_main() {
  # Sourced twice, the second time does nothing. A plain variable, not exported:
  # a nested login shell decides for itself.
  if [ -n "${SANDHOME_PROFILE:-}" ]; then
    return 0
  fi
  SANDHOME_PROFILE=1

  if [ -n "${SANDHOME_NO_PROFILE:-}" ]; then
    return 0
  fi

  # ⛔ INTERACTIVE, NOT LOGIN. A tool that sends commands to a LOGIN shell would
  # otherwise have its environment changed silently and after the caller's own
  # setup. `$-` carries `i` only for a shell a person is typing at.
  case "$-" in
    *i*) ;;
    *)   return 0 ;;
  esac

  # -- the environment, if a shell has not read it already ---------------------
  # ⭐ LOADING env.sh IS WHY THIS FILE IS INSTALLED. It puts the exec view on
  # PATH and every toolchain fragment into the environment, in one place. The
  # guard is that the file exists; a login shell that already sourced it has
  # SANDHOME_HOME set.
  if [ -z "${SANDHOME_HOME:-}" ] && [ -n "${HOME:-}" ]; then
    for _shp_env in "$HOME/.local/share/sandhome/env.sh" \
                    "$HOME/.sandhome/env.sh" \
                    "${XDG_DATA_HOME:-$HOME/.local/share}/sandhome/env.sh"; do
      if [ -r "$_shp_env" ]; then
        . "$_shp_env"
        break
      fi
    done
  fi

  # -- PATH, de-duplicated and nothing else ------------------------------------
  # ⭐ A login shell inside a login shell runs /etc/profile again, and /etc/profile
  # appends, so /usr/local/bin appears twice and the list a person reads to work
  # out which binary wins grows every time. The first occurrence keeps its place.
  #
  # ⛔ AN EMPTY ELEMENT MEANS THE CURRENT DIRECTORY and it is dropped. PATH=/bin:
  # searches `.` for every command typed, which is the oldest way to run someone
  # else's program by accident.
  if [ -n "${PATH:-}" ]; then
    _shp_new=''
    _shp_rest=$PATH
    while [ -n "$_shp_rest" ]; do
      case "$_shp_rest" in
        *:*) _shp_one=${_shp_rest%%:*}; _shp_rest=${_shp_rest#*:} ;;
        *)   _shp_one=$_shp_rest; _shp_rest='' ;;
      esac
      if [ -z "$_shp_one" ]; then
        continue
      fi
      case ":$_shp_new:" in
        *":$_shp_one:"*) continue ;;
      esac
      if [ -z "$_shp_new" ]; then
        _shp_new=$_shp_one
      else
        _shp_new=$_shp_new:$_shp_one
      fi
    done
    if [ -n "$_shp_new" ] && [ "$_shp_new" != "$PATH" ]; then
      PATH=$_shp_new
      export PATH
    fi
  fi

  # -- history that survives the session ---------------------------------------
  # ⭐ ERANDSH'S IDEA, AND IT BELONGS IN A LONG-LIVED BASE: a session without a
  # pty loses its history, and an attached-to-again sandbox should not. Every
  # value is set only when nothing set it, so the account's own choice wins,
  # including a choice to send history nowhere.
  if [ -n "${HOME:-}" ] && [ -d "$HOME" ]; then
    if [ -z "${HISTFILE:-}" ]; then
      HISTFILE=$HOME/.sh_history
      export HISTFILE
    fi
    if [ -z "${HISTSIZE:-}" ]; then
      HISTSIZE=10000
      export HISTSIZE
    fi
    if [ -z "${HISTFILESIZE:-}" ]; then
      HISTFILESIZE=20000
      export HISTFILESIZE
    fi
    if [ -z "${HISTCONTROL:-}" ]; then
      HISTCONTROL=ignoreboth
      export HISTCONTROL
    fi
  fi

  # -- the Windows drive an interactive shell should not be sitting on ---------
  # Outside WSL there is no drive to leave, and this costs one variable read.
  if [ -z "${WSL_DISTRO_NAME:-}" ]; then
    _shp_release=''
    if [ -r /proc/sys/kernel/osrelease ]; then
      read -r _shp_release < /proc/sys/kernel/osrelease || _shp_release=''
    fi
    case "$_shp_release" in
      *[Mm]icrosoft*) ;;
      *)              return 0 ;;
    esac
  fi
  if [ -n "${SANDHOME_HERE:-}" ]; then
    return 0
  fi
  _shp_pwd=${PWD:-}
  [ -z "$_shp_pwd" ] && _shp_pwd=$(pwd 2>/dev/null) || true
  [ -z "$_shp_pwd" ] && return 0
  for _shp_root in /mnt; do
    case "$_shp_pwd" in
      "$_shp_root"/?|"$_shp_root"/?/*) ;;
      *) return 0 ;;
    esac
    if [ -n "${HOME:-}" ] && [ -d "$HOME" ] && [ "$_shp_pwd" != "$HOME" ]; then
      cd "$HOME" || true
      printf 'sandhome: moved out of %s, a Windows drive this guest mounted, to %s. A shell started with SANDHOME_HERE=1 stays.\n' "$_shp_pwd" "$HOME" >&2
    fi
  done
  return 0
}

sandhome_profile_main
unset _shp_env _shp_new _shp_rest _shp_one _shp_release _shp_pwd _shp_root
unset -f sandhome_profile_main
:
