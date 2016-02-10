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
if [ $DEBUG -eq '1' ]; then
  set -x # trace steps
fi

#############
# Colors    #
#############
export green='\e[0;32m'
export red='\e[0;31m'
export label_color='\e[0;33m'
export no_color='\e[0m' # No Color

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

successor_grp=${NAME}

echo "INFO: Original group is ${original_grp} (${original_grp_id})"
echo "INFO: Successor group is ${successor_grp}  (${UPDATE_ID})"

active_deploy list --timeout 60s

# Do update if there is an original group
if [[ -n "${original_grp}" ]]; then
  echo "Beginning update with cf active-deploy-create ..."
 
  create_args="${original_grp} ${successor_grp} --manual --quiet --timeout 60s"
  
  if [[ -n "${RAMPUP_DURATION}" ]]; then create_args="${create_args} --rampup ${RAMPUP_DURATION}"; fi
  if [[ -n "${RAMPDOWN_DURATION}" ]]; then create_args="${create_args} --rampdown ${RAMPDOWN_DURATION}"; fi
  create_args="${create_args} --test 1s";
  
  echo "Executing update: cf active-deploy-create ${create_args}"
  update=$(active_deploy create ${create_args})

  # Identify URL for visualization of update. To do this:
  #   (a) look up the active deploy api server (cf. service endpoint field of cf active-deplpy-service-info)
  #   (b) look up the GUI server associated with the active deploy api server (cf. update_gui_url field of response to info REST call
  #   (c) Construct URL
  ad_server_url=$(active_deploy service-info | grep "service endpoint: " | sed 's/service endpoint: //')
  echo "Identified ad_server_url as: ${ad_server_url}"
  update_gui_url=$(curl -s ${ad_server_url}/v1/info/ | grep update_gui_url | awk '{print $2}' | sed 's/"//g' | sed 's/,//')
  echo "Identified update_gui_url as: ${update_gui_url}"
  update_url="${update_gui_url}/deployments/${update}?ace_config={%22spaceGuid%22:%22${CF_SPACE_ID}%22}"
  echo "Identified update_url as: ${update_url}"

  # Identify toolchain if available and send update details to it
  export PY_UPDATE_ID=$update
  curl -s --head -H "Authorization: ${TOOLCHAIN_TOKEN}" https://otc-api.stage1.ng.bluemix.net/api/v1/toolchains/${PIPELINE_TOOLCHAIN_ID}\?include\=everything | head -n 1 | grep "HTTP/1.[01] [23].." > /dev/null
  env_check=$?
  if [[ ${env_check} -eq '0' ]]; then
    export TC_API_RES="$(curl -s -k -H "Authorization: ${TOOLCHAIN_TOKEN}" https://otc-api.stage1.ng.bluemix.net/api/v1/toolchains/${PIPELINE_TOOLCHAIN_ID}\?include\=everything)"

    echo ${TC_API_RES} | grep "invalid"
    if [ $? -eq 0 ]; then
      #error, invalid API token
      echo "Invalid toolchain token, exiting..."
      exit 1
    else
      #proceed normally
      export SERVICE_ID="$(python processJSON.py sid)"
      export AD_API_URL="$(python processJSON.py ad-url)"
      
      curl -s -X PUT --data "{\"organization_guid\": \"$CF_ORGANIZATION_ID\", \"ui_url\": \"$update_url\"}" -H "Authorization: ${TOOLCHAIN_TOKEN}" -H "Content-Type: application/json" "$AD_API_URL/v1/service_instances/$SERVICE_ID" > curlRes.json
      curl -s -X PUT --data "{\"update_id\": \"$PY_UPDATE_ID\", \"stage_name\": \"$IDS_STAGE_NAME\", \"space_id\": \"$CF_SPACE_ID\"}" -H "Authorization: ${TOOLCHAIN_TOKEN}" -H "Content-Type: application/json" "$AD_API_URL/register_deploy/$SERVICE_ID"
      python processJSON.py
    fi
    
    if (( $? )); then
      echo "Failed to initiate active deployment; error was:"
      echo ${update}
      exit 1
    fi
  else
    echo "Running in V1 environment, no broker available."
  fi
  
  echo "Initiated update: ${update}"
  active_deploy show $update --timeout 60s

  # Always log URL to visualization of update
  #if [[ ${env_check} -ne '0' ]]; then
    echo "**********************************************************************"
    echo "${green}Direct deployment URL: ${update_url} ${no_color}"
    echo "**********************************************************************"
  #fi
  
  # Wait for completion of rampup phase
  wait_phase_completion $update && rc=$? || rc=$?
  echo "wait result is $rc"
 case "$rc" in
    0) # phase done
    # continue (advance to test)
    echo "Phase done, advance to test"
    active_deploy advance $update
    ;;
    1) # completed
    # cannot rollback; delete; return OK 
    echo "Cannot rollback, phase completed. Deleting update record"
    delete $update
    ;;
    2) # rolled back
    # delete; return ERROR
    
    # stop rolled back app
    properties=($(active_deploy show $update | grep "successor group: "))
    str1=${properties[@]}
    str2=${str1#*": "}
    app_name=${str2%" app"*}
    out=$(stopGroup ${app_name})
    echo "${app_name} stopped after rollback"
    
    echo "Rolled back, Deleting update record."
    # Cleanup - delete older updates
    clean && clean_rc=$? || clean_rc=$?
    if (( $clean_rc )); then
      echo "WARN: Unable to delete old versions."
      echo $(wait_comment $clean_rc)
    fi
    # Cleanup - delete update record
    echo "Deleting upate record"
    delete $update && delete_rc=$? || delete_rc=$?
    if (( $delete_rc )); then
      echo "WARN: Unable to delete update record ${update_id}"
    fi
    #delete $update
    exit 2
    ;;
    3) # failed
    # FAIL; don't delete; return ERROR -- manual intervension may be needed
    echo "Phase failed, manual intervension may be needed"
    exit 3
    ;; 
    4) # paused; resume failed
    # FAIL; don't delete; return ERROR -- manual intervension may be needed
    echo "Resume failed, manual intervension may be needed"
    exit 4
    ;;
    5) # unknown status or phase
    #rollback; delete; return ERROR
    echo "Unknown status or phase"
    rollback $update
    # Cleanup - delete older updates
    clean && clean_rc=$? || clean_rc=$?
    if (( $clean_rc )); then
      echo "WARN: Unable to delete old versions."
      echo $(wait_comment $clean_rc)
    fi
    # Cleanup - delete update record
    echo "Deleting upate record"
    delete $update && delete_rc=$? || delete_rc=$?
    if (( $delete_rc )); then
      echo "WARN: Unable to delete update record ${update_id}"
    fi
    #delete $update
    exit 5
    ;;
    9) # takes too long
    #rollback; delete; return ERROR
    echo "Timeout"
    rollback $update
    # Cleanup - delete older updates
    clean && clean_rc=$? || clean_rc=$?
    if (( $clean_rc )); then
      echo "WARN: Unable to delete old versions."
      echo $(wait_comment $clean_rc)
    fi
    # Cleanup - delete update record
    echo "Deleting upate record"
    delete $update && delete_rc=$? || delete_rc=$?
    if (( $delete_rc )); then
      echo "WARN: Unable to delete update record ${update_id}"
    fi
    #delete $update
    exit 9
    ;;
    *)
    echo "Problems occurred"
    exit 1
    ;;
  esac
  
#  if (( $rc )); then
#    echo "Rampup failed; rolling back update $update"
#    echo $(wait_comment $rc)
#    rollback $update || true
#    if (( $rollback_rc )); then
#      echo "WARN: Unable to rollback update"
#      active_deploy list $update
#    fi 
#    
#    # Cleanup - delete update record
#    echo "Deleting update record"
#    delete $update && delete_rc=$? || delete_rc=$?
#    if (( $delete_rc )); then
#      echo "WARN: Unable to delete update record $update"
#    fi
#    exit 1
#  else
#    # no error ... advance to test phase
#    active_deploy advance $update
#  fi

  active_deploy list
fi
