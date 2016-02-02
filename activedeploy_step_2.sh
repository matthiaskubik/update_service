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

###################################################################################
# function clean() {

  # # Identify list of build numbers to keep
  # PATTERN=$(echo $NAME | rev | cut -d_ -f2- | rev)
  # VERSION=$(echo $NAME | rev | cut -d_ -f1 | rev)
  # for (( i=0; i < ${CONCURRENT_VERSIONS}; i++ )); do
    # TO_KEEP[${i}]="${PATTERN}_$((${VERSION}-${i}))"
  # done

  # local NAME_ARRAY=($(groupList))

  # for name in ${NAME_ARRAY[@]}; do
    # version=$(echo "${name}" | sed 's#.*_##g')
    # echo "Considering ${name} with version ${version}"
    # if (( ${version} > ${VERSION} )); then
      # echo "${name} has a version (${version}) greater than the current version (${VERSION})."
      # echo "It will not be removed."
    # elif [[ " ${TO_KEEP[@]} " == *" ${name} "* ]]; then
      # echo "${name} will not be deleted"
    # else # delete it
      # echo "Removing ${name}"
      # groupDelete "${name}"
    # fi
  # done
# }

###################################################################################

# Debug info about cf cli and active-deploy plugins
which cf
cf --version
active_deploy service-info

# Initial deploy case
originals=($(groupList))
if [[ 1 = ${#originals[@]} ]]; then
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
