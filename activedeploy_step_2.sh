#!/bin/bash

SCRIPTDIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

set -x # trace steps

# Log some helpful information for debugging
env
find . -print

# Pull in common methods
source "${SCRIPTDIR}/activedeploy_common.sh"

# Identify BACKEND (APPS or CONTAINERS) and pull in specific implementations
if [[ -z ${BACKEND} ]]; then
  echo "ERROR: Backend not specified"
  exit 1
fi
source "${SCRIPTDIR}/${BACKEND}.sh"

###################################################################################
function clean() {

  # Identify list of build numbers to keep
  for (( i=0; i < ${CONCURRENT_VERSIONS}; i++ )); do
    TO_KEEP[${i}]="${CF_APP}_$((${BUILD_NUMBER}-${i}))"
  done

  local NAME_ARRAY=($(groupList))

  for name in ${NAME_ARRAY[@]}; do
    version=$(echo "${name}" | sed 's#.*_##g')
    echo "Considering ${name} with version ${version}"
    if (( ${version} >= ${BUILD_NUMBER} )); then
      echo "${name} has a version (${version}) greater than the current version (${BUILD_NUMBER})."
      echo "It will not be removed."
    elif [[ " ${TO_KEEP[@]} " == *" ${name} "* ]]; then
      echo "${name} will not be deleted"
    else # delete it
      echo "Removing ${name}"
      # groupDelete "${name}"
    fi
  done
}

###################################################################################

# Validate needed inputs or set defaults
# if CONCURRENT_VERSIONS not set assume default of 1 (keep just the latest deployed version)
if [[ -z ${CONCURRENT_VERSIONS} ]]; then export CONCURRENT_VERSIONS=1; fi

# If USER_TEST not set, assume the test succeeded. If the value wasn't set, then the user
# didn't modify the test job. However, we got to this job, so the test job must have 
# completed successfully. Note that we are assuming that a test failure would terminate 
# the pipeline.  
if [[ -z ${USER_TEST} ]]; then export USER_TEST="true"; fi

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

# Either rampdown and complete (on test success) or rollback (on test failure)
if [ "$USER_TEST" = true ]; then
  "Test success -- completing update ${CREATE}"
  advance ${CREATE}  && rc=$? || rc=$?
  # If failure doing advance, then rollback
  if (( $rc )); then
    echo "Advance to rampdown failed; rolling back update ${CREATE}"
    rollback ${CREATE} || true
    if (( $rollback_rc )); then
      echo "WARN: Unable to rollback update"
    fi 
  fi
else
  echo "Test failure -- rolling back update ${CREATE}"
  rollback ${CREATE} && rc=$? || rc=$?
fi

# Cleanup - delete older updates
clean && clean_rc=$? || clean_rc=$?
if (( $clean_rc )); then
  echo "WARN: Unable to delete old versions."
fi

# Cleanup - delete update record
echo "Deleting upate record"
delete ${CREATE} && delete_rc=$? || delete_rc=$?
if (( $delete_rc )); then
  echo "WARN: Unable to delete update record ${CREATE}"
fi

exit $rc
