# opsa.zsh: 1Password service account for the infrastructure repositories (toolbox only).
#
# In the toolbox, `op` is the real CLI and has no account: it works only with
# OP_SERVICE_ACCOUNT_TOKEN. The token is read from the personal account through the desktop
# app (`host-spawn op`, one approval), cached for OPSA_TTL seconds in non-exported parameters
# of this shell, and exported only to the commands run by `opsa` (and `just` in OPSA_DIRS).
# Design: Infrastructure/docs/1password-local-access.md
#
# Source it from .zshrc, after compinit.

# Only in the toolbox: on the host, `op` talks to the desktop app directly.
(( $+commands[host-spawn] )) || return 0

zmodload zsh/datetime

typeset -ga OPSA_DIRS=(~/git/personal/infrastructure)
typeset -g  OPSA_VAULT=personal
typeset -g  OPSA_ITEM='1Password Service Account - infrastructure'
typeset -g  OPSA_FIELD=credential
typeset -gi OPSA_TTL=3600
typeset -gi OPSA_MAX_AGE_DAYS=30
typeset -gi OPSA_WARN_DAYS=5
typeset -g  OPSA_ROTATE_URL='https://my.1password.com/developer-tools/active/service-accounts'

# Cache. -H: the value is never shown by `typeset` or `set` listings.
typeset -gH _opsa_token=''
typeset -gi _opsa_expires=0

# Fills the cache if it is empty or expired. Must run in the current shell, not in $(...),
# otherwise the cache is lost.
_opsa_load() {
  setopt localoptions noxtrace noverbose
  [[ -n $_opsa_token ]] && (( EPOCHSECONDS < _opsa_expires )) && return 0

  local json token updated
  local -i updated_at age left
  print -u2 "opsa: reading the service account token from $OPSA_VAULT/$OPSA_ITEM (1Password approval)"
  if ! json=$(host-spawn op item get "$OPSA_ITEM" --vault "$OPSA_VAULT" --format json); then
    print -u2 "opsa: cannot read $OPSA_VAULT/$OPSA_ITEM"
    return 1
  fi
  json=${json//$'\r'/}   # host-spawn may go through a pty
  if ! token=$(print -r -- "$json" | jq -er --arg f "$OPSA_FIELD" \
      'first(.fields[] | select(.id == $f or .label == $f) | .value)'); then
    print -u2 "opsa: no '$OPSA_FIELD' field in $OPSA_VAULT/$OPSA_ITEM"
    return 1
  fi
  if ! updated=$(print -r -- "$json" | jq -er '.updated_at') \
      || ! updated_at=$(date -d "$updated" +%s); then
    print -u2 "opsa: cannot read the last update date of $OPSA_VAULT/$OPSA_ITEM"
    return 1
  fi

  age=$(( (EPOCHSECONDS - updated_at) / 86400 ))
  left=$(( OPSA_MAX_AGE_DAYS - age ))
  if (( left <= 0 )); then
    print -u2 -l \
      "opsa: the token was last updated $age days ago (maximum $OPSA_MAX_AGE_DAYS), rotate it:" \
      "  1. open $OPSA_ROTATE_URL, select the service account, 'Rotate token'," \
      "     'Expire existing token: now'" \
      "  2. paste the new token in the '$OPSA_FIELD' field of the existing $OPSA_VAULT/$OPSA_ITEM" \
      "     item (not 'Save in 1Password', it creates a new item)" \
      "  3. run 'opsa-clear' in the other shells, then run the command again"
    return 1
  fi
  (( left <= OPSA_WARN_DAYS )) \
    && print -u2 "opsa: the token must be rotated within $left day(s): $OPSA_ROTATE_URL"

  _opsa_token=$token
  _opsa_expires=$(( EPOCHSECONDS + OPSA_TTL ))
}

# opsa <command> [args...]: runs the command with the service account token in its environment.
opsa() {
  setopt localoptions noxtrace noverbose
  if (( ! $# )); then
    print -u2 'usage: opsa <command> [args...]'
    return 2
  fi
  _opsa_load || return
  # OP_CACHE=false: no vault data cached by the `op` daemon. The daemon itself still starts and
  # outlives the command, but `op` is setgid, so it is non-dumpable: its environment (which
  # likely holds the token) cannot be read by other processes of the user.
  OP_SERVICE_ACCOUNT_TOKEN=$_opsa_token OP_CACHE=false "$@"
}

# Forgets the cached token (e.g. after a rotation).
opsa-clear() {
  _opsa_token=''
  _opsa_expires=0
}

opsa-status() {
  if [[ -n $_opsa_token ]] && (( EPOCHSECONDS < _opsa_expires )); then
    print "opsa: token cached, expires in $(( (_opsa_expires - EPOCHSECONDS) / 60 )) min"
  else
    print 'opsa: no token cached'
  fi
}

# In OPSA_DIRS, recipes get the token. `just`, `just <module>` (listings) and `just --...`
# (including the shell completion) do not need it and never ask for an approval.
just() {
  local dir
  if (( $# >= 2 )) && [[ $1 != -* ]]; then
    for dir in $OPSA_DIRS; do
      if [[ ${PWD:A} == ${dir:A} || ${PWD:A} == ${dir:A}/* ]]; then
        opsa command just "$@"
        return
      fi
    done
  fi
  command just "$@"
}

compdef _precommand opsa
