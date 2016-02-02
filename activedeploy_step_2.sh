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

echo "EXT_DIR=$EXT_DIR"
if [[ -f $EXT_DIR/common/cf ]]; then
  PATH=$EXT_DIR/common:$PATH
fi
echo $PATH

# Pull in common methods
source "${SCRIPTDIR}/activedeploy_common.sh"

# Identify TARGET_PLATFORM (CloudFoundry or Container) and pull in specific implementations
if [[ -z ${TARGET_PLATFORM} ]]; then
  echo "ERROR: Target platform not specified"
  exit 1
fi
source "${SCRIPTDIR}/${TARGET_PLATFORM}.sh"

# Identify NAME if not set from other likely variables
if [[ -z ${NAME} ]] && [[ -n ${CF_APP_NAME} ]]; then
  export NAME="${CF_APP_NAME}"
fi

if [[ -z ${NAME} ]] && [[ -n ${CONTAINER_NAME} ]]; then
  export NAME="${CONTAINER_NAME}"
fi

if [[ -z ${NAME} ]]; then
  echo "Environment variable NAME must be set to the name of the successor application or container group"
  exit 1
fi

# Set default for ROUTE_HOSTNAME
if [[ -z ${ROUTE_HOSTNAME} ]]; then
  export ROUTE_HOSTNAME=$(echo $NAME | rev | cut -d_ -f2- | rev)
  echo "Route hostname not specified by environment variable ROUTE_HOSTNAME; using ${ROUTE_HOSTNAME}"
fi

# Set default for ROUTE_DOMAIN
defaulted_domain=0
# Strategy #1: Use the domain for the app with the same ROUTE_HOSTNAME as we are using
if [[ -z ${ROUTE_DOMAIN} ]]; then
  export ROUTE_DOMAIN=$(cf routes | awk -v hostname="${ROUTE_HOSTNAME}" '$2 == hostname {print $3}')
  defaulted_domain=1
fi
# Strategy #2: Use most commonly used domain
if [[ -z ${ROUTE_DOMAIN} ]]; then
  export ROUTE_DOMAIN=$(cf routes | tail -n +2 | grep -E '[a-z0-9]\.' | awk '{print $3}' | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
  defaulted_domain=1
fi
# Strategy #3: Use a domain available to the user
if [[ -z ${ROUTE_DOMAIN} ]]; then
  export ROUTE_DOMAIN=$(cf domains | grep -e 'shared' -e 'owned' | head -1 | awk '{print $1}')
  defaulted_domain=1
fi
if [[ -z ${ROUTE_DOMAIN} ]]; then
  echo "Route domain not specified by environment variable ROUTE_DOMAIN and no suitable alternative could be identified"
  exit 1
fi

if (( ${defaulted_domain} )); then
  echo "Route domain not specified by environment variable ROUTE_DOMAIN; using ${ROUTE_DOMAIN}"
fi

# Debug info about cf cli and active-deploy plugins
which cf
cf --version
active_deploy service-info

# Initial deploy case
originals=($(groupList))

route="${ROUTE_HOSTNAME}.${ROUTE_DOMAIN}"
ROUTED=($(getRouted "${route}" "${originals[@]}"))
echo ${#ROUTED[@]} of original groups routed to ${route}: ${ROUTED[@]}

# If more than one routed app, select only the oldest
if (( 1 < ${#ROUTED[@]} )); then
  echo "WARNING: More than one app routed to ${route}; updating the oldest"
fi

if (( 0 < ${#ROUTED[@]} )); then
  original_grp=${ROUTED[$(expr ${#ROUTED[@]} - 1)]}
fi

# At this point if original_grp is not set, we didn't find any routed apps; ie, is initial deploy

if [[ 1 = ${#originals[@]} ]] || [[ -z ${original_grp} ]] || [[ "${original_grp}" == "${NAME}" ]]; then
  echo "Initial version"
  exit 0
else
  echo "Not initial version"
fi

# Validate needed inputs or set defaults
# if CONCURRENT_VERSIONS not set assume default of 1 (keep just the latest deployed version)
if [[ -z ${CONCURRENT_VERSIONS} ]]; then export CONCURRENT_VERSIONS=1; fi

# Identify the active deploy in progress. We do so by looking for a deploy 
# involving the add / container named "${NAME}"
in_prog=$(active_deploy list | grep "${NAME}" | grep "in_progress")
read -a array <<< "$in_prog"
update_id=${array[0]}
echo "========> id in progress: ${update_id}"
if [[ -z "${update_id}" ]]; then
  echo "ERROR: Unable to identify an active update in progress for successor ${NAME}"
  active_deploy list
  exit 5
fi
active_deploy show ${update_id}

IFS=$'\n' properties=($(active_deploy show ${update_id} | grep ':'))
update_status=$(get_property 'status' ${properties[@]})

# TODO handle other statuses better: could be rolled back, rolling back, paused, failed, ...
# Insufficient to leave it and let the wait_phase_completion deal with it; the call to advance/rollback could fail
if [[ "${update_status}" != 'in_progress' ]]; then
  echo "Deployment in unexpected status: ${update_status}"
  rollback ${update_id}
  delete ${update_id}
  exit 1
fi

# If TEST_RESULT_FOR_AD not set, assume the test succeeded. If the value wasn't set, then the user
# didn't modify the test job. However, we got to this job, so the test job must have 
# completed successfully. Note that we are assuming that a test failure would terminate 
# the pipeline.  
if [[ -z ${TEST_RESULT_FOR_AD} ]]; then 
  TEST_RESULT_FOR_AD=0;
fi

# Either rampdown and complete (on test success) or rollback (on test failure)
if [[ ${TEST_RESULT_FOR_AD} -eq 0 ]]; then
  echo "Test success -- completing update ${update_id}"
  advance ${update_id}  && rc=$? || rc=$?
  # If failure doing advance, then rollback
  if (( $rc )); then
    echo "Advance to rampdown failed; rolling back update ${update_id}"
    rollback ${update_id} || true
    if (( $rollback_rc )); then
      echo "WARN: Unable to rollback update"
      echo $(wait_comment $rollback_rc)
    fi 
  fi
else
  echo "Test failure -- rolling back update ${update_id}"
  rollback ${update_id} && rc=$? || rc=$?
  if (( $rc )); then echo $(wait_comment $rc); fi
  # rc will be the exit code; we want a failure code if there was a rollback
  rc=2
fi

# Cleanup - delete older updates
clean && clean_rc=$? || clean_rc=$?
if (( $clean_rc )); then
  echo "WARN: Unable to delete old versions."
  echo $(wait_comment $clean_rc)
fi

# Cleanup - delete update record
echo "Deleting upate record"
delete ${update_id} && delete_rc=$? || delete_rc=$?
if (( $delete_rc )); then
  echo "WARN: Unable to delete update record ${update_id}"
fi

exit $rc
