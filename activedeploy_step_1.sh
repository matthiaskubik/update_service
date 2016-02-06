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

set -x # trace steps

SCRIPTDIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

AD_STEP_1=true 
source ${}/check_and_set_env.sh

#echo "EXT_DIR=$EXT_DIR"
#if [[ -f $EXT_DIR/common/cf ]]; then
#  PATH=$EXT_DIR/common:$PATH
#fi
#echo $PATH
#
## Pull in common methods
#source ${SCRIPTDIR}/activedeploy_common.sh
## TODO: modify extensions to do this in activedeploy_*/_init.sh instead of activedeploy_common/init.sh
## TODO: remove from here
#source ${EXT_DIR}/common/utilities/logging_utils.sh
#
## Identify TARGET_PLATFORM (CloudFoundry or Containers) and pull in specific implementations
#if [[ -z ${TARGET_PLATFORM} ]]; then
#  echo "ERROR: Target platform not specified"
#  exit 1
#fi
#source "${SCRIPTDIR}/${TARGET_PLATFORM}.sh"
#
## Identify NAME if not set from other likely variables
#if [[ -z ${NAME} ]] && [[ -n ${CF_APP_NAME} ]]; then
#  export NAME="${CF_APP_NAME}"
#fi
#
#if [[ -z ${NAME} ]] && [[ -n ${CONTAINER_NAME} ]]; then
#  export NAME="${CONTAINER_NAME}"
#fi
#
#if [[ -z ${NAME} ]]; then
#  echo "Environment variable NAME must be set to the name of the successor application or container group"
#  exit 1
#fi
#
## Set default for PORT
#if [[ -z ${PORT} ]]; then
#  export PORT=80
#  echo "Port not specified by environment variable PORT; using ${PORT}"
#fi
#
## Set default for GROUP_SIZE
#if [[ -z ${GROUP_SIZE} ]]; then
#  export GROUP_SIZE=1
#  echo "Group size not specified by environment variable GROUP_SIZE; using ${GROUP_SIZE}"
#fi
#
## Set default for RAMPUP_DURATION
#if [[ -z ${RAMPUP_DURATION} ]]; then
#  export RAMPUP_DURATION="5m"
#  echo "Rampup duration not specified by environment variable RAMPUP_DURATION; using ${RAMPUP_DURATION}"
#fi
#
## Set default for RAMPDOWN_DURATION
#if [[ -z ${RAMPDOWN_DURATION} ]]; then
#  export RAMPDOWN_DURATION="5m"
#  echo "Rampdown duration not specified by environment variable RAMPDOWN_DURATION; using ${RAMPDOWN_DURATION}"
#fi
#
## Set default for ROUTE_HOSTNAME
#if [[ -z ${ROUTE_HOSTNAME} ]]; then
#  export ROUTE_HOSTNAME=$(echo $NAME | rev | cut -d_ -f2- | rev)
#  echo "Route hostname not specified by environment variable ROUTE_HOSTNAME; using ${ROUTE_HOSTNAME}"
#fi
#
## Set default for ROUTE_DOMAIN
#defaulted_domain=0
## Strategy #1: Use the domain for the app with the same ROUTE_HOSTNAME as we are using
#if [[ -z ${ROUTE_DOMAIN} ]]; then
#  export ROUTE_DOMAIN=$(cf routes | awk -v hostname="${ROUTE_HOSTNAME}" '$2 == hostname {print $3}')
#  defaulted_domain=1
#fi
## Strategy #2: Use most commonly used domain
#if [[ -z ${ROUTE_DOMAIN} ]]; then
#  export ROUTE_DOMAIN=$(cf routes | tail -n +2 | grep -E '[a-z0-9]\.' | awk '{print $3}' | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
#  defaulted_domain=1
#fi
## Strategy #3: Use a domain available to the user
#if [[ -z ${ROUTE_DOMAIN} ]]; then
#  export ROUTE_DOMAIN=$(cf domains | grep -e 'shared' -e 'owned' | head -1 | awk '{print $1}')
#  defaulted_domain=1
#fi
#if [[ -z ${ROUTE_DOMAIN} ]]; then
#  echo "Route domain not specified by environment variable ROUTE_DOMAIN and no suitable alternative could be identified"
#  exit 1
#fi
#
#if (( ${defaulted_domain} )); then
#  echo "Route domain not specified by environment variable ROUTE_DOMAIN; using ${ROUTE_DOMAIN}"
#fi
#
## Verify that AD_ENDPOINT is available (otherwise unset it)
## If it is available, further validate that $AD_ENDPOINT supports $CF_TARGET as a backend
#if [[ -n "${AD_ENDPOINT}" ]]; then
#  up=$(timeout 10 curl -s ${AD_ENDPOINT}/health_check/ | grep status | grep up)
#  if [[ -z "${up}" ]]; then
#    echo "WARNING: Unable to validate availability of ${AD_ENDPOINT}; reverting to default endpoint"
#    export AD_ENDPOINT=
#  else
#    supports_target ${AD_ENDPOINT} ${CF_TARGET_URL} 
#    if (( $? )); then
#      echo "WARNING: Selected Active Deploy service (${AD_ENDPOINT}) does not support target environment (${CF_TARGET_URL}); reverting to default service"
#      AD_ENDPOINT=
#    fi
#  fi
#fi
#
## Set default (1) for CONCURRENT_VERSIONS
#if [[ -z ${CONCURRENT_VERSIONS} ]]; then export CONCURRENT_VERSIONS=2; fi
#
## debug info
#which cf
#cf --version
#active_deploy service-info

echo "TARGET_PLATFORM = $TARGET_PLATFORM"
echo "NAME = $NAME"
echo "AD_ENDPOINT = $AD_ENDPOINT"
echo "CONCURRENT_VERSIONS = $CONCURRENT_VERSIONS"
echo "PORT = $PORT"
echo "GROUP_SIZE = $GROUP_SIZE" 
echo "RAMPUP_DURATION = $RAMPUP_DURATION" 
echo "RAMPDOWN_DURATION = $RAMPDOWN_DURATION" 
echo "ROUTE_HOSTNAME = $ROUTE_HOSTNAME" 
echo ""ROUTE_DOMAIN = $ROUTE_DOMAIN"

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
  
  if (( $? )); then
    echo "Failed to initiate active deployment; error was:"
    echo ${update}
    exit 1
  fi
  
  echo "Initiated update: ${update}"
  active_deploy show $update --timeout 60s

  # Identify AD UI server
  ad_server_url=$(active_deploy service-info | grep "service endpoint: " | sed 's/service endpoint: //')
  echo "Identified ad_server_url as: ${update_url}"
  update_gui_url=$(curl -s ${ad_server_url}/v1/info/ | grep update_gui_url | awk '{print $2}' | sed 's/"//g' | sed 's/,//')
  update_url="${update_gui_url}/deployments/${update}?ace_config={%22spaceGuid%22:%22${CF_SPACE_ID}%22}"
  echo "Identified update_url as: ${update_url}"
  
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
    out=$(cf stop ${app_name})
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
