#/bin/bash

#********************************************************************************
# Copyright 2016 IBM
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#********************************************************************************


# Remove white space from the start of string
# Usage: trim_start string
function trim_start() {
  if read -t 0 str; then
    sed -e 's/^[[:space:]]*//'
  else
    echo -e "$*" | sed -e 's/^[[:space:]]*//'
  fi
}


# Remove whitespace from the end of a string
# Usage: trim_end string
function trim_end () {
  if read -t 0 str; then
    sed -e 's/[[:space:]]*$//'
  else
    echo -e "$*" | sed -e 's/[[:space:]]*$//'
  fi
}


# Remove whitespace from the start and end of a string
# Usage trim string
function trim () {
  if read -t 0 str; then
    sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
  else
    echo -e "$*" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
  fi
}


# Get property value from array of strings of the form "key: value"
# Usage: get_property key array_of_properties
function get_property() {
  __key=$1; shift
  __properties=("$@")
  for e in "${__properties[@]}"; do
    if [[ $e =~ ${__key}:[[:space:]].* ]]; then
      trim $(echo $e | cut -d: -f2)
    fi
  done
}


# TODO - implement retry logic

# Wrap calls to cf active-deploy-* allowing user to just indicate the command being called.
# Allows for redirecting the calls to a non-default active deploy endpoint
function active_deploy() {
  local __command="${1}"
  shift

  if [[ -n "${AD_ENDPOINT}" ]]; then
    CF_ACTIVE_DEPLOY_ENDPOINT="${AD_ENDPOINT}" cf active-deploy-${__command} $*
  else
    cf active-deploy-${__command} $*
  fi
}


function advance() {
  __update_id="${1}"
  echo "Advancing update ${__update_id}"
  active_deploy show ${__update_id}

  active_deploy advance ${__update_id}
  wait_phase_completion ${__update_id} rampdown && rc=$? || rc=$?
  
  echo "Return code for advance is ${rc}"
  return ${rc}
}


function rollback() {
  __update_id="${1}"
  
  echo "Rolling back update ${__update_id}"
  active_deploy show ${__update_id}

  active_deploy rollback ${__update_id}
  wait_phase_completion ${__update_id} rampdown && rc=$? || rc=$?
  
  echo "Return code for rollback is ${rc}"
  return ${rc}
}


function delete() {
  __update_id="${1}"
  
  echo "Deleting update ${__update_id}"
  active_deploy show ${__update_id}

  active_deploy delete ${__update_id} --force
}

# Convert expression of the form HhMmSs to an integer representing seconds
function to_seconds() {
  local __time="${1}"
  local __orig_time=${__time}

  if [[ $__time != *h* ]]; then
    __time="0h${__time}"
  fi
  if [[ $__time != *m* ]]; then
    # already has an 'h'
    __time=$(echo $__time | sed 's/h/h0m/')
  fi
  if [[ $__time != *s ]]; then
    __time="${__time}0s"
  fi

  IFS=' ' read -r -a times <<< $(echo $__time | sed 's/h/ /' | sed 's/m/ /' | sed 's/s//')
  # >&2 echo "${__orig_time} ${__time} ${times[@]}"

  seconds=$(printf %0.f $(expr ${times[0]}*3600+${times[1]}*60+${times[2]} | bc))
  echo ${seconds}
}


# Wait for current phase to complete
# Usage: wait_phase_completion update_id max_wait
# Response codes:
#    0 - the is at the end of the current phase
#    1 - the update has a status of 'completed' (or the phase is the 'completed' phase)
#    2 - the update has a status of 'rolled back' (or the phase is the 'iniital' phase)
#    3 - the update has a status of'failed'
#    5 - the update has an unknown status or unknown phase
#    9 - waited 3x phase duration and it wasn't finished
function wait_phase_completion() {
  local __update_id="${1}"
  # Small default value to get us into the loop where we will compute it
  local __max_wait=10
  local __expected_duration=0

  if [[ -z ${__update_id} ]]; then
    >&2 echo "ERROR: Expected update identifier to be passed into wait_for" 
    return 1
  fi

  local start_time=$(date +%s)
  
  >&2 echo "Update ${__update_id} called wait at ${start_time}"
  
  local end_time=$(expr ${start_time} + ${__max_wait}) # initial end_time; will be udpated below	
  while (( $(date +%s) < ${end_time} )); do
    IFS=$'\n' properties=($(active_deploy show ${__update_id} | grep ':'))

    update_phase=$(get_property 'phase' ${properties[@]})
    update_status=$(get_property 'status' ${properties[@]})

    case "${update_status}" in
      completed) # whole update is completed
      return 1
      ;;
      rolled\ back)
      return 2
      ;;
      failed)
      return 3
      ;;
      paused)
      # attempt to resume
      >&2 echo "Update ${__update_id} is paused; attempting to resume"
      active_deploy resume ${__update_id}
      # TODO deal with failures
      ;;
      in_progress|rolling\ back)
      ;;
      *)
      >&2 echo "ERROR: Unknown status: ${update_status}"
      >&2 echo "${properties[@]}"
      return 5
      ;;
    esac

	# the status is 'in_progress'
    case "${update_phase}" in
      initial)
      # should only happen if status is rolled back -- so should never get here
      return 2
      ;;
      completed)
      # should only happen if status is completed -- so should never get here
      return 1
      ;;
      rampup|test|rampdown)
      ;;
      *)
      >&2 echo "ERROR: Unknown phase: ${update_phase}"
      return 5
    esac

    >&2 echo "Update ${__update_id} is ${update_status} in phase ${update_phase}"

    phase_progress=$(get_property "${update_phase} duration" ${properties[@]})
    if [[ "${phase_progress}" =~ completed* ]]; then
      # The phase is completed
      >&2 echo "Phase ${update_phase} is complete"
      return 0
    else
      >&2 echo "Phase ${update_phase} progress is: ${phase_progress}"
    fi
    # determine the expected time if haven't done so already; update end_time
    if [[ "0" = "${__expected_duration}" ]]; then
      __expected_duration=$(to_seconds $(echo ${phase_progress} | sed 's/.* of \(.*\)/\1/'))
      __max_wait=$(expr ${__expected_duration}*3 | bc)
      end_time=$(expr ${start_time} + ${__max_wait})
      >&2 echo "Phase ${update_phase} has an expected duration of ${__expected_duration}s; will wait ${__max_wait}s ending at ${end_time}"
    fi

    sleep 3
  done
  
  return 9 # took too long
}

function wait_comment() {

  local __rc="${1}"
  case "${__rc}" in
    0)
    echo "phase already complete"
    ;;
    1)
    echo "update already complete"
    ;;
    2)
    echo "update already rolled back"
    ;;
    3)
    echo "update failed"
    ;;
    4)
    echo "update paused and could not restart"
    ;;
    5)
    echo "unknown update"
    ;;
    9)
    echo "took too long"
    ;;
    *)
    echo "unknown reason: ${__rc}"
    ;;
  esac
}

# TODO : write definition
function clean() {

  # Identify list of build numbers to keep
  PATTERN=$(echo $NAME | rev | cut -d_ -f2- | rev)
  VERSION=$(echo $NAME | rev | cut -d_ -f1 | rev)
  for (( i=0; i < ${CONCURRENT_VERSIONS}; i++ )); do
    TO_KEEP[${i}]="${PATTERN}_$((${VERSION}-${i}))"
  done

  local NAME_ARRAY=($(groupList))

  for name in ${NAME_ARRAY[@]}; do
    version=$(echo "${name}" | sed 's#.*_##g')
    echo "Considering ${name} with version ${version}"
    if (( ${version} > ${VERSION} )); then
      echo "${name} has a version (${version}) greater than the current version (${VERSION})."
      echo "It will not be removed."
    elif [[ " ${TO_KEEP[@]} " == *" ${name} "* ]]; then
      echo "${name} will not be deleted"
    else # delete it
      echo "Removing ${name}"
      groupDelete "${name}"
    fi
  done
}