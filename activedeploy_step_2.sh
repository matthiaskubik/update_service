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

#set -x # trace steps

SCRIPTDIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
source ${SCRIPTDIR}/check_and_set_env.sh

#echo "EXT_DIR=$EXT_DIR"
#if [[ -f $EXT_DIR/common/cf ]]; then
#  PATH=$EXT_DIR/common:$PATH
#fi
#echo $PATH
#
## Pull in common methods
#source "${SCRIPTDIR}/activedeploy_common.sh"
#
## Identify TARGET_PLATFORM (CloudFoundry or Container) and pull in specific implementations
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
## Verify that AD_ENDPOINT is available (otherwise unset it)
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
## Debug info about cf cli and active-deploy plugins
#which cf
#cf --version
#active_deploy service-info

echo "TARGET_PLATFORM = $TARGET_PLATFORM"
echo "NAME = $NAME"
echo "AD_ENDPOINT = $AD_ENDPOINT"
echo "CONCURRENT_VERSIONS = $CONCURRENT_VERSIONS"

# Initial deploy case
originals=($(groupList))

if [[ 1 = ${#originals[@]} ]]; then
  echo "INFO: Initial version (single version deployed); exiting"
  exit 0
fi

# Identify the active deploy in progress. We do so by looking for a deploy 
# involving the add / container named "${NAME}"
in_prog=$(active_deploy list | grep "${NAME}" | grep "in_progress")
read -a array <<< "$in_prog"
update_id=${array[0]}
if [[ -z "${update_id}" ]]; then
  echo "INFO: Initial version (no update containing ${NAME}); exiting"
  active_deploy list
  exit 0
fi

echo "INFO: Not initial version (part of update ${update_id})"
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
  # First advance to rampdown phase
  advance ${update_id}  && rc=$? || rc=$?
  # If failure doing advance, then rollback
  if (( $rc )); then
    echo "ERROR: Advance to rampdown failed; rolling back update ${update_id}"
    rollback ${update_id} || true
    if (( $rollback_rc )); then
      echo "WARN: Unable to rollback update"
      echo $(wait_comment $rollback_rc)
    fi 
  fi
  # Second advance to final phase
  advance ${update_id} && rc=$? || rc=$?
  if (( $rc )); then
    echo "ERROR: Unable to advance to final phase"
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
