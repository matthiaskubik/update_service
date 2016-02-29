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

SCRIPTDIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
source ${SCRIPTDIR}/check_and_set_env.sh

log_and_echo $INFO "TARGET_PLATFORM = $TARGET_PLATFORM"
log_and_echo $INFO "NAME = $NAME"
log_and_echo $INFO "AD_ENDPOINT = $AD_ENDPOINT"
log_and_echo $INFO "CONCURRENT_VERSIONS = $CONCURRENT_VERSIONS"

# cd to target so can read ccs.py when needed (for group deletion)
cd ${SCRIPTDIR}

# Initial deploy case
originals=($(groupList))

# Nothing to do in initial deploy scenario
if [[ 1 = ${#originals[@]} ]]; then
  echo "INFO: Initial version (single version deployed); exiting"
  exit 0
fi

# If a problem was found with $AD_ENDPOINT, fail now
if [[ -n ${MUSTFAIL_ACTIVEDEPLOY} ]]; then
  echo -e "${red}Active deploy service unavailable; failing.${no_color}"
  exit 128
fi

# Identify URL for visualization of update. To do this:
# The active deploy api server and GUI server were computed in check
show_link "Deployment URL" \
          "${update_gui_url}/deployments/${update}?ace_config={%22spaceGuid%22:%22${CF_SPACE_ID}%22}" \
          ${green}

# Identify the active deploy in progress. We do so by looking for a deploy 
# involving the add / container named "${NAME}"
in_prog=$(with_retry active_deploy list | grep "${NAME}" | grep "in_progress")
read -a array <<< "$in_prog"
update_id=${array[0]}
if [[ -z "${update_id}" ]]; then
  echo "INFO: Initial version (no update containing ${NAME}); exiting"
  with_retry active_deploy list
  exit 0
fi

echo "INFO: Not initial version (part of update ${update_id})"
with_retry active_deploy show ${update_id}

IFS=$'\n' properties=($(with_retry active_deploy show ${update_id} | grep ':'))
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
