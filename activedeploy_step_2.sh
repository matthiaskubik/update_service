#!/bin/bash

SCRIPTDIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

set -x # trace steps

# Log some helpful information for debugging
env
find . -print

# Pull in common methods
source ${SCRIPTDIR}/activedeploy_common.sh

###################################################################################
###################################################################################

# Validate needed inputs
if [[ -z ${BACKEND} ]]; then
  echo "ERROR: Backend not specified"
  exit 1
fi

# Setup pipeline slave
slave_setup

# Identify the active deploy in progress. We do so by looking for a deploy 
# involving the add / container named "${CF_APP}_${UPDATE_ID}"
in_prog=$(cf active-deploy-list | grep "${CF_APP}_${UPDATE_ID}")
read -a array <<< "$in_prog"
CREATE=${array[0]}
echo "========> id in progress: ${CREATE}"
cf active-deploy-show ${CREATE}

IFS=$'\n' properties=($(cf active-deploy-show ${CREATE} | grep ':'))
update_status=$(get_property 'status' ${properties[@]})
if [[ "${update_status}" != 'in_progress' ]]; then
  echo "Deployment in unexpected status: ${update_status}"
  rollback ${CREATE}
  delete ${CREATE}
  exit 1
fi



if [ "$USER_TEST" = true ]; then
  "Test success -- completing update ${CREATE}"
  advance ${CREATE}  && rc=$? || rc=$?
  # If failure doing advance, then rollback
  if (( $rc )); then
    echo "Advance to rampdown failed; rolling back update ${CREATE}"
    rollback ${CREATE} || true 
  fi
else
  echo "Test failure -- rolling back update ${CREATE}"
  rollback ${CREATE} && rc=$? || rc=$?
fi

# Cleanup - delete update record
delete ${CREATE}
exit $rc
