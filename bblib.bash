#!/bin/bash

# Scripts should fail on all logic errors, as we don't want to let them run amok
set -e
set -o pipefail

# The FINALCMDS array needs to be defined before setting up finally
FINALCMDS=()

pprint () {
  # Function to properly wrap and print text
  # Usage:
  #   command | pprint [columns]
  #   pprint <<< "text"
  local COLUMNS="${1:-${COLUMNS:-$(tput cols)}}"
  fold -sw "${COLUMNS:-80}"
}

inarray () {
  # Function to see if a string is in an array
  # It works by taking all passed variables and seeing if the last one matches any before it.
  # It will return 0 and print the array index that matches on success,
  # and return 1 with nothing printed on failure.
  # Usage:
  #   inarray "${ARRAY[@]}" "SEARCHSTRING"
  #####
  local INDICIES=$#
  local SEARCH=${!INDICIES}
  for ((INDEX=1 ; INDEX < $# ; INDEX++)) {
    if [ "${!INDEX}" == "${SEARCH}" ]; then
      echo "$((INDEX - 1))"
      return 0
    fi
  }
  return 1
}

lc () {
  # Convert stdin/arguments to lowercase
  # Usage:
  #   lc [string]
  #   command | lc
  tr "[:upper:]" "[:lower:]" <<< "${@:-$(cat /dev/stdin)}"
}

uc () {
  # Convert stdin/arguments to uppercase
  # Usage:
  #   uc [string]
  #   command | uc
  tr "[:lower:]" "[:upper:]" <<< "${@:-$(cat /dev/stdin)}"
}

hr () {
  # Print horizontal rule
  # Usage:
  #   hr [character]
  local CHARACTER="${1:0:1}"
  local COLUMNS=${COLUMNS:-$(tput cols)}
  printf '%*s\n' "${COLUMNS:-80}" '' | tr ' ' "${CHARACTER:--}"
}

log () {
  # Function to send log output to file, syslog, and stderr
  # Usage:
  #     command |& log $SEVERITY
  #     log $SEVERITY $MESSAGE
  # Variables:
  #     LOGLEVEL: The cutoff for message severity to log (Default is INFO).
  local SEVERITY="$(uc "${1:-NOTICE}")"
  local LOGMSG="${2:-$(cat /dev/stdin)}"
  local LOGLEVELS=(EMERGENCY ALERT CRITICAL ERROR WARN NOTICE INFO DEBUG)
  local LOGLEVEL="$(uc "${LOGLEVEL:-INFO}")"
  local LOGTAG="[${SCRIPT_NAME:-$0}] [${CURRENT_FUNC:-SCRIPT_ROOT}] [${SEVERITY}]"
  local NUMERIC_LOGLEVEL="$(inarray "${LOGLEVELS[@]}" "${LOGLEVEL}")"
  local NUMERIC_SEVERITY="$(inarray "${LOGLEVELS[@]}" "${SEVERITY}")"

  if [ ${NUMERIC_SEVERITY:-5} -le ${NUMERIC_LOGLEVEL:-6} ] ; then
    while read -r LINE ; do
      logger -is -p user.${NUMERIC_SEVERITY:-5} -t "${LOGTAG} " -- "${LINE}"
    done <<< "${LOGMSG}" |& \
    if [ -n "${LOGFILE}" ] ; then
      tee -a "${LOGFILE}"
    else
      cat /dev/stdin
    fi
  fi 1>&2
}

# Shorthand log functions
log_debug () { log "DEBUG" "$*" ; }
log_info () { log "INFO" "$*" ; }
log_note () { log "NOTICE" "$*" ; }
log_warn () { log "WARN" "$*" ; }
log_err () { log "ERROR" "$*" ; }
log_crit () { log "CRITICAL" "$*" ; }
log_alert () { log "ALERT" "$*" ; }
log_emer () { log "EMERGENCY" "$*" ; }

quit () {
  # Function to log a message and exit
  # Usage:
  #    quit $SEVERITY $MESSAGE $EXITCODE
  log "${1:-WARN}" "${2:-Exiting without reason}"
  exit "${3:-3}"
}

bash4check () {
  # Call this function to enable features that depend on bash 4.0+.
  # Usage: bash4check
  if [ ${BASH_VERSINFO[0]} -lt 4 ] ; then
    log "ERROR" "Sorry, you need at least bash version 4 to run this function: $CURRENT_FUNC"
    return 1
  else
    log "DEBUG" "This script is safe to enable BASH version 4 features"
  fi
}

finally () {
  # Function to perform final tasks before exit
  local CURRENT_FUNC="finally"
  until [ "${#FINALCMDS[@]}" == 0 ] ; do
    log "DEBUG" "Executing pre-exit command: ${FINALCMDS[-1]}"
    eval "${FINALCMDS[-1]}"
    unset FINALCMDS[-1]
  done
}

checkpid () {
  # Check for and maintain pidfile
  # Usage: checkpid
  local CURRENT_FUNC="checkpid"
  local PIDFILE="${PIDFILE:-${0}.pid}"
  if [ ! -d "/proc/$$" ]; then
    quit "ERROR" "This function requires procfs. Are you on Linux?"
  elif [ -f "${PIDFILE}" ] && [ "$(cat "${PIDFILE}" 2> /dev/null)" != "$$" ] ; then
    quit "WARN" "This script is already running with PID $(cat "${PIDFILE}" 2> /dev/null), exiting"
  else
    echo -n "$$" > "${PIDFILE}"
    FINALCMDS+=("rm '${PIDFILE}'")
    log "DEBUG" "PID $$ has no conflicts and has been written to ${PIDFILE}"
  fi
}

requireuser () {
  # Checks to see if current user matches $REQUIREUSER and exits if not.
  # REQUIREUSER can be set as a variable or passed in as an argument.
  # Usage: requireuser [user]
  local CURRENT_FUNC="requireuser"
  local REQUIREUSER="${1:-$REQUIREUSER}"
  if [ -z $REQUIREUSER ] ; then
    quit "ERROR" "requireuser was called, but \$REQUIREUSER is not set"
  elif [ "$REQUIREUSER" != "$USER" ] ; then
    quit "ERROR" "Only $REQUIREUSER is allowed to run this script"
  else
    log "DEBUG" "User '$USER' matches '$REQUIREUSER' and is allowed to run this script"
  fi
}

usage () {
  # Print usage information
pprint << HERE
$0: An example script

Description:
Put your description here.

Options:
-h: Print this help
-s [path]: Source a bash file with extra functions and variables.
-v: Enables debugging output for this script
HERE
}

argparser () {
  # Accept command-line arguments
  # Usage:
  #   argparser "$@"
  # More info here: http://wiki.bash-hackers.org/howto/getopts_tutorial
  local CURRENT_FUNC="argparser"
  while getopts ":s:hv" OPT ; do
    case ${OPT} in
      h) usage ;;
      s) source "${OPTARG}" ;;
      v) set -x ; export LOGLEVEL=DEBUG ;;
      :) quit "ERROR" "Option '-${OPTARG}' requires an argument. For usage, try '${0} -h'." ;;
      *) quit "ERROR" "Option '-${OPTARG}' is not defined. For usage, try '${0} -h'." ;;
    esac
  done
}

prunner () {
  # Run commands in parallel
  # Options:
  #   -t [threads]
  #   -c [command to pass arguments to]
  # Usage:
  #   prunner "command arg" "command"
  #   prunner -c gzip *.txt
  #   find . | prunner -c 'echo found file:' -t 6
  local CURRENT_FUNC="prunner"
  local PQUEUE=()
  # Process option arguments
  while getopts ":c:t:" OPT ; do
    case ${OPT} in
      c) local PCMD="${OPTARG}" ;;
      t) local THREADS="${OPTARG}" ;;
      :) quit "ERROR" "Option '-${OPTARG}' requires an argument." ;;
      *) quit "ERROR" "Option '-${OPTARG}' is not defined." ;;
    esac
  done
  # Throw away option arguments so that non-option arguments can be queued
  shift $(($OPTIND-1))
  # Add non-option arguments to queue
  for ARG in "$@" ; do
    PQUEUE+=("$ARG")
  done
  # Add lines from stdin to queue
  if [ ! -t 0 ] ; then
    while read -r LINE ; do
      PQUEUE+=("$LINE")
    done
  fi
  local QCOUNT="${#PQUEUE[@]}"
  local INDEX=0
  log "INFO" "Starting parallel execution of $QCOUNT jobs with ${THREADS:-8} threads using command prefix '$PCMD'."
  until [ ${#PQUEUE[@]} == 0 ] ; do
    if [ "$(jobs -rp | wc -l)" -lt "${THREADS:-8}" ] ; then
      log "DEBUG" "Starting command in parallel ($(($INDEX+1))/$QCOUNT): ${PCMD} ${PQUEUE[$INDEX]}"
      eval "${PCMD} ${PQUEUE[$INDEX]}" |& log "DEBUG" || true &
      unset PQUEUE[$INDEX]
      ((INDEX++)) || true
    fi
  done
  wait
  log "INFO" "Parallel execution finished for $QCOUNT jobs."
}

# Trap for killing runaway processes and exiting
trap "quit 'ALERT' 'Exiting on signal' '3'" SIGINT SIGTERM

# Trap to do final tasks before exit
trap finally EXIT

# If a .conf file exists for this script, source it
if [ -f "${0}.conf" ] ; then
  source "${0}.conf"
fi
