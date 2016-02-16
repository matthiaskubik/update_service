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


# Method that does something only if DEBUG is set
function debugme() {
  [[ -n ${DEBUG} ]] && "$@" || :
}


# Default value; should be sert in target platform specific files (CloudFoundry.sh, Container.sh, etc)
if [[ -z ${MIN_MAX_WAIT} ]]; then MIN_MAX_WAIT=90; fi

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


# Execute a function up to $WITH_RETRIES_MAX_RETRIES (default 3) times.
# Retries are done in only certain circumstances (cf. computation of ${retry}).
# Currently, the only reason is a failure to contact the database.
# A short sleep of $WITH_RETRIES_SLEEP seconds (default 2s) is exectued between attempts.
function with_retry() {
  if [[ -z ${WITH_RETRIES_SLEEP} ]]; then WITH_RETRIES_SLEEP=2; fi
  if [[ -z ${WITH_RETRIES_MAX_RETRIES} ]]; then WITH_RETRIES_MAX_RETRIES=3; fi

  attempt=0
  retry=true
  while [[ -n ${retry} ]] && (( ${attempt} < ${WITH_RETRIES_MAX_RETRIES} )); do
    if [[ -n ${DEBUG} ]]; then >&2 echo "Attempt ${attempt}"; fi
    let attempt=attempt+1
    $* > /tmp/$$ && rc=$? || rc=$?
    if (( ${rc} )); then
      # "BXNAD0315" is "Error contacting the database."
      retry=$(grep -e "BXNAD0315" /tmp/$$)
      if [[ -n ${retry} ]] && (( ${attempt} < ${WITH_RETRIES_MAX_RETRIES} )); then
        >&2 echo "with_retry() call FAILED: ${retry}"
        if [[ -n ${DEBUG} ]]; then >&2 echo "Retrying in ${WITH_RETRIES_SLEEP} seconds"; fi
        sleep ${WITH_RETRIES_SLEEP}
      fi
    else retry=
    fi
  done
  cat /tmp/$$
  rm -f /tmp/$$
  return ${rc}
}


function advance() {
  __update_id="${1}"
  echo "Advancing update ${__update_id}"
  with_retry active_deploy show ${__update_id}

  active_deploy advance ${__update_id}
  wait_phase_completion ${__update_id} rampdown && rc=$? || rc=$?
  
  echo "Return code for advance is ${rc}"
  return ${rc}
}


function rollback() {
  __update_id="${1}"
  
  echo "Rolling back update ${__update_id}"
  with_retry active_deploy show ${__update_id}

  active_deploy rollback ${__update_id}
  wait_phase_completion ${__update_id} rampdown && rc=$? || rc=$?
  
  # stop rolled back app
  properties=($(with_retry active_deploy show ${__update_id} | grep "successor group: "))
  str1=${properties[@]}
  str2=${str1#*": "}
  app_name=${str2%" app"*}
  # TODO replace the above 4 lines with these using our get_properties() utility method
  #IFS=$'\n' properties=($(with_retry active_deploy show ${__update_id} | grep ':'))
  #app_name=$(get_property 'successor group' ${properties[@]} | sed -e '#s/ app.*$##')
  out=$(stopGroup ${app_name})
  echo "${app_name} stopped after rollback"
  
  echo "Return code for rollback is ${rc}"
  return ${rc}
}


function delete() {
  __update_id="${1}"
  
  # Keep records for now
  echo "Not deleting update ${__update_id}"
  
  # echo "Deleting update ${__update_id}"
  # with_retry active_deploy show ${__update_id}
  # active_deploy delete ${__update_id} --force
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
    IFS=$'\n' properties=($(with_retry active_deploy show ${__update_id} | grep ':'))

    update_phase=$(get_property 'phase' ${properties[@]})
    update_status=$(get_property 'status' ${properties[@]})

    case "${update_status}" in
      completed) # whole update is completed
      return 0
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

	# the status is 'in_progress' or 'rolling back'
    case "${update_phase}" in
      initial)
      # should only happen if status is rolled back -- which happens when we finish rolling back
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

    if [[ "in_progress" == "${update_status}" ]]; then
      phase_progress=$(get_property "${update_phase} duration" ${properties[@]})
      if [[ "${phase_progress}" =~ completed* ]]; then
        # The phase is completed
        >&2 echo "Phase ${update_phase} is complete"
        return 0
      else
        >&2 echo "Phase ${update_phase} progress is: ${phase_progress}"
      fi
    fi # if [[ "in_progress" == "${update_status}" ]]
    # determine the expected time if haven't done so already; update end_time
    if [[ "0" = "${__expected_duration}" ]]; then
      __expected_duration=$(to_seconds $(echo ${phase_progress} | sed 's/.* of \(.*\)/\1/'))
      __max_wait=$(expr ${__expected_duration}*3 | bc)
      if (( ${__max_wait} < ${MIN_MAX_WAIT} )); then __max_wait=${MIN_MAX_WAIT}; fi
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


# Clean up (delete) old versions of the application/container groups.
# Keeps the currently routed group (ie, current version), the latest deployment (if it failed) and 
# up to CONCURRENT_VERSIONS-1 other active groups (other stopped groups are removed)
# Usage: clean
#   Required environment variable NAME - the name of the current deployed group
#                                 CONCURRENT_VERSIONS - the number of concurrent versions to keep
function clean() {
  # Identify list of build numbers to keep
  PATTERN=$(echo $NAME | rev | cut -d_ -f2- | rev)
  VERSION=$(echo $NAME | rev | cut -d_ -f1 | rev)

  candidates=($(groupList))
  debugme echo "clean(): Found ${#candidates[@]} versions: ${candidates[@]}"

  VERSIONS=()
  for c in "${candidates[@]}"; do
    v=$(echo ${c} | rev | cut -d_ -f1 | rev)
    VERSIONS+=(${v})
  done

  SORTED_VERSIONS=($(for i in ${VERSIONS[@]}; do echo $i; done | sort -n))
  debugme echo "clean(): Found sorted ${#SORTED_VERSIONS[@]} versions: ${SORTED_VERSIONS[@]}"

  # Iterate in reverse (most recent to oldest)
  CURRENT_VERSION=
  MOST_RECENT=
  KEPT=()
  for (( idx=${#SORTED_VERSIONS[@]}-1; idx>=0; idx-- )); do
    candidate="${PATTERN}_${SORTED_VERSIONS[$idx]}"
    debugme echo "clean(): Considering candidate ${candidate}"

    # Keep most recent with a route
    if [[ -z ${CURRENT_VERSION} ]] && [[ -n $(getRoutes "${candidate}") ]]; then
      # The current version is the first version with a route that we find (recall: reverse order)
      CURRENT_VERSION="${candidate}"
      KEPT+=(${candidate})
      echo "clean(): Identified current version: ${CURRENT_VERSION}; keeping"

    # Delete groups with versions greater than the version of the group just deployed (VERSION)
    # This represents a group deployed using a previous (or another!) pipeline.
    # Eventually, the existence of the group will become an issue (name conflict) so delete it now.
    elif (( ${SORTED_VERSIONS[$idx]} > ${VERSION} )); then
      echo "clean(): Deleting group ${candidate} from previous pipeline"
      groupDelete "${candidate}"

    # Keep the most recent without a route IF the current version has has not been found
    # This is the most recent deploy but it failed (was rolled back)
    elif [[ -z ${CURRENT_VERSION} ]] &&  [[ -z ${MOST_RECENT} ]]; then
      MOST_RECENT="${candidate}"
      # Don't record this in the list of those that were KEPT; it is extra
      echo "clean(): Current deployment (${MOST_RECENT}) failed; keeping for debug purposes"

    # Delete any (older) stopped groups -- they were failed deploys
    elif [[ "true" == "$(isStopped ${candidate})" ]]; then
      echo "clean(): Deleting group ${candidate} (group is in stopped state)"
      groupDelete "${candidate}"

    # If we've kept enough, delete the group
    elif (( ${#KEPT[@]} >= ${CONCURRENT_VERSIONS} )); then
      echo "clean(): Deleting group ${candidate} (already identified sufficient versions to keep)"
      groupDelete "${candidate}"

    # Otherwise keep the group
    else
      KEPT+=(${candidate})
      echo "clean(): Keeping group ${candidate}"
    fi

  done

  echo "clean(): Summary: keeping ${KEPT[@]} ${MOST_RECENT}"
}


# Retrieve a list of apps/groups to which a specific route is mapped
# Usage: getRouted route candidate_apps
function getRouted() {
  local __route="${1}"; shift
  local __apps=("$@")

  >&2 echo "Looking for application with route ${__route} among ${__apps[@]}"

  local __routed_apps=()
  for app in "${__apps[@]}"; do
    # >&2 echo "Considering app: $app"
    app_routes=($(getRoutes ${app}))
    # >&2 echo "Routes for $app are: ${app_routes[@]}"
    for rt in ${app_routes[@]}; do
      if [[ "${rt}" == "${__route}" ]]; then
        # >&2 echo "FOUND app: ${app}"
        __routed_apps+=(${app})
        break
      fi
    done
  done

  >&2 echo "${__route} is routed to ${__routed_apps[@]}"
  echo "${__routed_apps[@]}"
}


# Utility function to validate that $AD_ENDPOINT supports $CF_TARGET as a backend. Returns 0 if so, non-zero otherwise.
# Usage: supports_target active_deploy_endpoint target_environment_endpoint
function supports_target() {
__ad_url="${1}" __cf_url="${2}" python - <<CODE
import json
import os
import requests
import sys
ad_url = os.getenv("__ad_url")
cf_url = os.getenv("__cf_url")
try:
  r = requests.get('{}/v1/info/'.format(ad_url), timeout=10)
  info = json.loads(r.text)
  for backend in info.get("cloud_backends", []):
    print backend
    if backend == cf_url:
      sys.exit(0)
  sys.exit(1)
except Exception, e:
  print e
  sys.exit(2)
CODE
}

