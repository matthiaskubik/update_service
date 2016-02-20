#!/bin/bash

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

#set $DEBUG to 1 for set -x output
if [[ -n ${DEBUG} ]]; then
  set -x # trace steps
fi

SCRIPTDIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

AD_STEP_1=true 
source ${SCRIPTDIR}/check_and_set_env.sh

echo "TARGET_PLATFORM = $TARGET_PLATFORM"
echo "NAME = $NAME"
echo "AD_ENDPOINT = $AD_ENDPOINT"
echo "CONCURRENT_VERSIONS = $CONCURRENT_VERSIONS"
echo "PORT = $PORT"
echo "GROUP_SIZE = $GROUP_SIZE" 
echo "RAMPUP_DURATION = $RAMPUP_DURATION" 
echo "RAMPDOWN_DURATION = $RAMPDOWN_DURATION" 
echo "ROUTE_HOSTNAME = $ROUTE_HOSTNAME" 
echo "ROUTE_DOMAIN = $ROUTE_DOMAIN"

function exit_with_link() {
  local __status="${1}"
  local __message="${2}"

  local color=${green}
  if (( ${__status} )); then
    color="${red}"
  fi

  echo -e "${color}${__message}${no_color}"

  echo -e "${color}**********************************************************************"
  echo "Direct deployment URL:"
  echo "${update_url}"
  echo -e "**********************************************************************${no_color}"

  exit ${__status}
}

function get_detailed_message() {
__ad_endpoint="${1}" __update_id="${2}" python - <<CODE
import ccs
import os
ad_server = os.getenv('__ad_endpoint')
update_id = os.getenv('__update_id')
ads =  ccs.ActiveDeployService(ad_server)
update, reason = ads.show(update_id)
message = update.get('detailedMessage', '') if update is not None else 'Unable to read update record'
print(message)
CODE
}

# Delete update record
function delete_update() {
  local __update="${1}"

  delete ${__update} && delete_rc=$? || delete_rc=$?
  if (( ${delete_rc} )); then
    echo "WARN: Unable to delete update record ${__update}"
  fi
}

# Delete older updates and update record
function cleanup() {
  local __update="${1}"

  clean && clean_rc=$? || clean_rc=$?
  if (( ${clean_rc} )); then
    echo "WARN: Unable to delete old versions"
  fi
  delete_update ${__update}
}

# Rollback update and cleanup
function rollback_and_cleanup() {
  local __update="${1}"

  rollback ${__update}
  cleanup
}
# cd to target so can read ccs.py when needed (for route detection)
cd ${SCRIPTDIR}

originals=($(groupList))
successor="${NAME}"

# export version of this build
export UPDATE_ID=${BUILD_NUMBER}

# Determine which original groups has the desired route --> the current original
route="${ROUTE_HOSTNAME}.${ROUTE_DOMAIN}" 
ROUTED=($(getRouted "${route}" "${originals[@]}"))
echo ${#ROUTED[@]} of original groups routed to ${route}: ${ROUTED[@]}

# If more than one routed app, select only the oldest
if (( 1 < ${#ROUTED[@]} )); then
  echo "WARNING: More than one app routed to ${route}; updating the oldest"
fi

if (( 0 < ${#ROUTED[@]} )); then
  original_grp=${ROUTED[$(expr ${#ROUTED[@]} - 1)]}
  original_grp_id=${original_grp#_*}
fi

# At this point if original_grp is not set, we didn't find any routed apps; ie, is initial deploy

# map/scale original deployment if necessary
if [[ 1 = ${#originals[@]} ]] || [[ -z $original_grp ]]; then
  echo "INFO: Initial version, scaling"
  scaleGroup ${successor} ${GROUP_SIZE} && rc=$? || rc=$?
  if (( ${rc} )); then
    echo "ERROR: Failed to scale ${successor} to ${GROUP_SIZE} instances"
    exit ${rc}
  fi
  echo "INFO: Initial version, mapping route"
  mapRoute ${successor} ${ROUTE_DOMAIN} ${ROUTE_HOSTNAME} && rc=$? || rc=$?
  if (( ${rc} )); then
    echo "ERROR: Failed to map the route ${ROUTE_DOMAIN}.${ROUTE_HOSTNAME} to ${successor}"
    exit ${rc}
  fi
  exit 0
else
  echo "INFO: Not initial version"
fi

# If a problem was found with $AD_ENDPOINT, fail now
if [[ -n ${MUSTFAIL_ACTIVEDEPLOY} ]]; then
  echo -e "${red}Active deploy service unavailable; failing.${no_color}"
  # Cleanup - delete older updates
  clean && clean_rc=$? || clean_rc=$?
  if (( $clean_rc )); then
    echo "WARN: Unable to delete old versions."
  fi
  exit 128
fi

successor_grp=${NAME}

echo "INFO: Original group is ${original_grp} (${original_grp_id})"
echo "INFO: Successor group is ${successor_grp}  (${UPDATE_ID})"

# Do update if there is an original group
if [[ -n "${original_grp}" ]]; then
  echo "Beginning update with cf active-deploy-create ..."
 
  create_args="${original_grp} ${successor_grp} --manual --quiet --timeout 60s"
  
  if [[ -n "${RAMPUP_DURATION}" ]]; then create_args="${create_args} --rampup ${RAMPUP_DURATION}"; fi
  if [[ -n "${RAMPDOWN_DURATION}" ]]; then create_args="${create_args} --rampdown ${RAMPDOWN_DURATION}"; fi
  create_args="${create_args} --test 1s";
  
  echo "Executing update: cf active-deploy-create ${create_args}"

  active=$(find_active_update ${original_grp})
  if [[ -n ${active} ]]; then
    echo "Original group ${original_grp} already engaged in an active update; rolling it back"
    rollback ${active}
  fi
  # Check if it worked
  active=$(find_active_update ${original_grp})
  if [[ -n ${active} ]]; then
    echo -e "${red}ERROR: Original group ${original_grp} still engaged in an active update; rollback did not work. Exiting.${no_color}"
    with_retry active_deploy show ${active}
    exit 1
  fi

  # Now attempt to call the update
  update=$(create "${create_args}") && create_rc=$? || create_rc=$?
  #### grep for update id; this is done because a mistake in CLI v0.1.99 caused other things to be output
  ###update=$(active_deploy create ${create_args} | grep "^[0-9a-f]\{8\}-\([0-9a-f]\{4\}-\)\{3\}[0-9a-f]\{12\}$")
  #### error checking on update
  ###create_rc="${PIPESTATUS[0]}" grep_rc="${PIPESTATUS[1]}"
  # Unable to create update
  if (( ${create_rc} )); then
    echo -e "${red}ERROR: failed to create update; ${update}${no_color}"
    with_retry active_deploy list | grep "[[:space:]]${NAME}[[:space:]]"
    exit ${create_rc}
  fi

  echo "Initiated update: ${update}"
  with_retry active_deploy show $update --timeout 60s

  # Identify URL for visualization of update. To do this:
  #   (a) look up the active deploy api server (cf. service endpoint field of cf active-deplpy-service-info)
  #   (b) look up the GUI server associated with the active deploy api server (cf. update_gui_url field of response to info REST call
  #   (c) Construct URL
  ad_server_url=$(active_deploy service-info | grep "service endpoint: " | sed 's/service endpoint: //')
  #echo "Identified ad_server_url as: ${ad_server_url}"
  update_gui_url=$(curl -s ${ad_server_url}/v1/info/ | grep update_gui_url | awk '{print $2}' | sed 's/"//g' | sed 's/,//')
  #echo "Identified update_gui_url as: ${update_gui_url}"
  update_url="${update_gui_url}/deployments/${update}?ace_config={%22spaceGuid%22:%22${CF_SPACE_ID}%22}"
  #echo "Identified update_url as: ${update_url}"

  echo -e "${green}**********************************************************************"
  echo "Direct deployment URL:"
  echo "${update_url}"
  echo -e "**********************************************************************${no_color}"

  # Identify toolchain if available and send update details to it
  export PY_UPDATE_ID=$update
  curl -s --head -H "Authorization: ${TOOLCHAIN_TOKEN}" https://otc-api.stage1.ng.bluemix.net/api/v1/toolchains/${PIPELINE_TOOLCHAIN_ID}\?include\=everything | head -n 1 | grep "HTTP/1.[01] [23].." > /dev/null
  env_check=$?
  if [[ ${env_check} -eq '0' ]]; then
    echo "PIPELINE_TOOLCHAIN_ID=${PIPELINE_TOOLCHAIN_ID}"
    export TC_API_RES="$(curl -s -k -H "Authorization: ${TOOLCHAIN_TOKEN}" https://otc-api.stage1.ng.bluemix.net/api/v1/toolchains/${PIPELINE_TOOLCHAIN_ID}\?include\=everything)"
   #echo "***** TC_API_RES:"
   #echo ${TC_API_RES}

    echo ${TC_API_RES} | grep "invalid"
    if [ $? -eq 0 ]; then
      #error, invalid API token
      echo "WARNING: Invalid toolchain token."
      # Invalid toolchain token is not a reason to fail
    else
      #proceed normally
      export SERVICE_ID="$(python processJSON.py sid)"
      export AD_API_URL="$(python processJSON.py ad-url)"
      
      echo "SERVICE_ID=${SERVICE_ID}"
      echo "AD_API_URL=${AD_API_URL}"

      curl -s -X PUT --data "{\"organization_guid\": \"$CF_ORGANIZATION_ID\", \"ui_url\": \"$update_url\"}" -H "Authorization: ${TOOLCHAIN_TOKEN}" -H "Content-Type: application/json" "$AD_API_URL/v1/service_instances/$SERVICE_ID" > curlRes.json
      curl -s -X PUT --data "{\"update_id\": \"$PY_UPDATE_ID\", \"stage_name\": \"$IDS_STAGE_NAME\", \"space_id\": \"$CF_SPACE_ID\", \"ui_url\": \"$update_url\"}" -H "Authorization: ${TOOLCHAIN_TOKEN}" -H "Content-Type: application/json" "$AD_API_URL/register_deploy/$SERVICE_ID"
      if (( $? )); then
        echo "WARNING: Failed to record the update"
        # Inability to record an update is not a reason to fail
      fi
    fi
  else
    echo "INFO: Running in V1 environment, no broker available."
  fi
  
  # Wait for completion of rampup phase
  wait_phase_completion $update && rc=$? || rc=$?
  echo "wait result is $rc"
  case "$rc" in
    0) # phase done
    # continue (advance to test)
    echo "Phase done, advance to test"
    advance $update && advance_rc=$? || advance_rc=$?
    if (( ${advance_rc} )); then
      case "${advance_rc}" in
        0) # phase done
        echo "INFO: test phase complete"
        ;;
        1) # completed
        delete_update ${update}
        ;;
        2) # rolled back
        cleanup ${update}
        rollback_reason=$(get_detailed_message $ad_server_url $update)
        exit_message="${successor_grp} rolled back"
        if [[ -n "${rollback_reason}" ]]; then exit_message="${exit_message}.\nRollback caused by: ${rollback_reason}"; fi
        exit_with_link 2 "${exit_message}"
        ;;
        3) # failed
        exit_with_link 3 "Phase failed, manual intervension may be needed"
        ;;
        4) # paused
        exit_with_link 4 "ERROR: Resume failed, manual intervension may be needed"
        ;;
        5) # unknown
        rollback_and_cleanup ${update}
        exit_with_link 5 "ERROR: Unknown status or phase encountered"
        ;;
        9) # too long
        rollback_and_cleanup ${update}
        exit_with_link 9 "ERROR: Update took too long"
        ;;
        *)
        exit_with_link 1 "ERROR: Unknown problem occurred"
        ;;
      esac
      rollback_and_cleanup ${update}
      exit_with_link 6 "ERROR: advance to test phase failed."
    fi
    ;;

    1) # completed
    # cannot rollback; delete; return OK 
    echo "Cannot rollback, phase completed. Deleting update record"
    delete_udpate $update
    ;;

    2) # rolled back
    # delete; return ERROR
    
    # stop rolled back app
    out=$(stopGroup ${successor_grp})
    echo "${successor_grp} stopped after rollback"
    
    cleanup ${update}

    rollback_reason=$(get_detailed_message $ad_server_url $update)
    exit_message="${successor_grp} rolled back"
    if [[ -n "${rollback_reason}" ]]; then exit_message="${exit_message}.\nRollback caused by: ${rollback_reason}"; fi
    exit_with_link 2 "${exit_message}"
    ;;

    3) # failed
    # FAIL; don't delete; return ERROR -- manual intervension may be needed
    exit_with_link 3 "Phase failed, manual intervension may be needed"
    ;; 

    4) # paused; resume failed
    # FAIL; don't delete; return ERROR -- manual intervension may be needed
    exit_with_link 4 "ERROR: Resume failed, manual intervension may be needed"
    ;;

    5) # unknown status or phase
    #rollback; delete; return ERROR
    rollback_and_cleanup $update
    exit_with_link 5 "ERROR: Unknown status or phase encountered"
    ;;

    9) # takes too long
    #rollback; delete; return ERROR
    rollback_and_cleanup $update
    exit_with_link 9 "ERROR: Update took too long"
    ;;

    *)
    exit_with_link 1 "ERROR: Unknown problem occurred"
    ;;
  esac
  
  # Normal exist; show current update
  with_retry active_deploy show $update
  exit_with_link 0 "${successor_grp} successfully advanced to test phase"
fi
