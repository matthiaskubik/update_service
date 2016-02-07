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

###################
################### Common to both step_1 and step_2
###################

echo "EXT_DIR=$EXT_DIR"
if [[ -f $EXT_DIR/common/cf ]]; then
  PATH=$EXT_DIR/common:$PATH
fi
echo $PATH

# Pull in common methods
source ${SCRIPTDIR}/activedeploy_common.sh
# TODO: modify extensions to do this in activedeploy_*/_init.sh instead of activedeploy_common/init.sh
# TODO: remove from here
source ${EXT_DIR}/common/utilities/logging_utils.sh

# Identify TARGET_PLATFORM (CloudFoundry or Containers) and pull in specific implementations
if [[ -z ${TARGET_PLATFORM} ]]; then
  echo "WARNING: Target platform not specified; defaulting to 'CloudFoundry'"
  export TARGET_PLATFORM='CloudFoundry'
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

# Verify that AD_ENDPOINT is available (otherwise unset it)
# If it is available, further validate that $AD_ENDPOINT supports $CF_TARGET as a backend
if [[ -n "${AD_ENDPOINT}" ]]; then
  up=$(timeout 10 curl -s ${AD_ENDPOINT}/health_check/ | grep status | grep up)
  if [[ -z "${up}" ]]; then
    echo "WARNING: Unable to validate availability of ${AD_ENDPOINT}; reverting to default endpoint"
    export AD_ENDPOINT=
  else
    supports_target ${AD_ENDPOINT} ${CF_TARGET_URL} 
    if (( $? )); then
      echo "WARNING: Selected Active Deploy service (${AD_ENDPOINT}) does not support target environment (${CF_TARGET_URL}); reverting to default service"
      AD_ENDPOINT=
    fi
  fi
fi

# Set default (1) for CONCURRENT_VERSIONS
if [[ -z ${CONCURRENT_VERSIONS} ]]; then export CONCURRENT_VERSIONS=2; fi

###################
################### Needed only for step_1
###################

if [[ -n $AD_STEP_1 ]]; then
  # Set default for PORT
  if [[ -z ${PORT} ]]; then
    export PORT=80
    echo "Port not specified by environment variable PORT; using ${PORT}"
  fi

  # Set default for GROUP_SIZE
  if [[ -z ${GROUP_SIZE} ]]; then
    export GROUP_SIZE=1
    echo "Group size not specified by environment variable GROUP_SIZE; using ${GROUP_SIZE}"
  fi

  # Set default for RAMPUP_DURATION
  if [[ -z ${RAMPUP_DURATION} ]]; then
    export RAMPUP_DURATION="5m"
    echo "Rampup duration not specified by environment variable RAMPUP_DURATION; using ${RAMPUP_DURATION}"
  fi

  # Set default for RAMPDOWN_DURATION
  if [[ -z ${RAMPDOWN_DURATION} ]]; then
    export RAMPDOWN_DURATION="5m"
    echo "Rampdown duration not specified by environment variable RAMPDOWN_DURATION; using ${RAMPDOWN_DURATION}"
  fi

  # Set default for ROUTE_HOSTNAME
  if [[ -z ${ROUTE_HOSTNAME} ]]; then
    export ROUTE_HOSTNAME=$(echo $NAME | rev | cut -d_ -f2- | rev | sed -e 's#_#-##g')
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

fi # if [[ -n ${AD_STEP_1} ]]; then

# debug info
which cf
cf --version
active_deploy service-info
