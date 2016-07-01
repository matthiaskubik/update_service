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

export LANG=en_US  # Hard-coded because there is a defect w/ en_US.UTF-8

# Colors
export green='\e[0;32m'
export red='\e[0;31m'
export label_color='\e[0;33m'
export no_color='\e[0m' # No Color

echo "EXT_DIR=$EXT_DIR"
if [[ -f $EXT_DIR/common/cf ]]; then
  PATH=$EXT_DIR/common:$PATH
fi
echo $PATH

# Pull in common methods
source ${SCRIPTDIR}/activedeploy_common.sh

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

# Verify that AD_ENDPOINT is available (otherwise set MUSTFAIL_ACTIVEDEPLOY)
# If it is available, further validate that $AD_ENDPOINT supports $CF_TARGET as a backend
if [[ -n "${AD_ENDPOINT}" ]]; then
  up=$(timeout 10 curl -s ${AD_ENDPOINT}/health_check/ | grep status | grep up)
  if [[ -z "${up}" ]]; then
    echo -e "${red}ERROR: Unable to validate availability of Active Deploy service ${AD_ENDPOINT}; failing active deploy${no_color}"
    export MUSTFAIL_ACTIVEDEPLOY=true
  else
    supports_target ${AD_ENDPOINT} ${CF_TARGET_URL} 
    if (( $? )); then
      echo -e "${red}ERROR: Selected Active Deploy service (${AD_ENDPOINT}) does not support target environment (${CF_TARGET_URL}); failing active deploy${no_color}"
      export MUSTFAIL_ACTIVEDEPLOY=true
    fi
  fi
fi

# Check and set CCS_API_HOST
if [[ -z ${CCS_API_HOST} ]]; then 
  # If AD_ENDPOINT is runnig on stage1, switch to the appropriate CCS
  if [[ ${AD_ENDPOINT} == *".stage1."* ]]; then
    export CCS_API_HOST="https://containers-api.stage1.ng.bluemix.net"
  else
    export CCS_API_HOST="https://containers-api.ng.bluemix.net"
  fi
fi

# Set default (1) for CONCURRENT_VERSIONS
if [[ -z ${CONCURRENT_VERSIONS} ]]; then export CONCURRENT_VERSIONS=2; fi

# Check if the pipeline is in the context of a toolchain by querying the toolchain broker. 
# If so, set TOOLCHAIN_AVAILABLE to 1; otherwise to 0
curl -s --head -H "Authorization: ${TOOLCHAIN_TOKEN}" https://otc-api.stage1.ng.bluemix.net/api/v1/toolchains/${PIPELINE_TOOLCHAIN_ID}\?include\=everything | head -n 1 | grep "HTTP/1.[01] [23].." > /dev/null
if (( $? )); then TOOLCHAIN_AVAILABLE=0; else TOOLCHAIN_AVAILABLE=1; fi
export TOOLCHAIN_AVAILABLE


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
if [[ -n ${DEBUG} ]]; then
  which cf
  cf --version
  active_deploy service-info
fi

function show_link() {
  local __label="${1}"
  local __link="${2}"
  local __color="${no_color}"
  if (( $# > 2 )); then __color="${3}"; fi

  echo -e "${__color}**********************************************************************"
  echo "${__label}"
  echo "${__link}"
  echo -e "**********************************************************************${no_color}"
}


# Identify URL for visualization of updates associated with this space. To do this:
#   (a) look up the active deploy api server (cf. service endpoint field of cf active-deplpy-service-info)
#   (b) look up the GUI server associated with the active deploy api server (cf. update_gui_url field of response to info REST call
#   (c) Construct URL
ad_server_url=$(active_deploy service-info | grep "service endpoint: " | sed 's/service endpoint: //')
update_gui_url=$(curl -s ${ad_server_url}/v1/info/ | grep update_gui_url | awk '{print $2}' | sed 's/"//g' | sed 's/,//')

show_link "Deployments for space ${CF_SPACE_ID}" "${update_gui_url}/deployments?ace_config={%22spaceGuid%22:%22${CF_SPACE_ID}%22}" ${green}

