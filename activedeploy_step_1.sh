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

SCRIPTDIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

set -x
find . -print
echo "EXT_DIR=$EXT_DIR"
if [[ -f $EXT_DIR/common/cf ]]; then
  PATH=$EXT_DIR/common:$PATH
fi
echo $PATH

# Pull in common methods
source ${SCRIPTDIR}/activedeploy_common.sh

# Identify TARGET_PLATFORM (CloudFoundry or Containers) and pull in specific implementations
if [[ -z ${TARGET_PLATFORM} ]]; then
  echo "ERROR: Target platform not specified"
  exit 1
fi
source "${SCRIPTDIR}/${TARGET_PLATFORM}.sh"

###################################################################################

#EE# acting funny, fix later
function find_route(){
  local __originals=()
  read -a __originals <<< $(echo ${@})
  echo ${#__originals[@]}
  local __routed=()
  
  oldIFS=$IFS
  IFS=': ,'
  for i in "${__originals[@]}"
  do   
     echo "Checking routes for ${i}:"
     read -a route_list <<< $(cf app ${i} | grep -v "^Showing" | grep -v "^OK" | grep -v "^[[:space:]]*$" | grep "^urls:")
     #echo $'${route_list[@]:1}\n'
   
     if (( 1 < ${#route_list[@]} )); then
       for j in "${route_list[@]}"
	   do
	      if [[ "${j}" == "${route}" ]]; then
		    __routed+=("${i}")
		    break
		  fi
	   done
     fi  
     unset route_list
     echo ${__routed}
  done
  IFS=$oldIFS
  
  echo ${__routed}
}

###################################################################################

if [[ -z ${GROUP_SIZE} ]]; then
  export GROUP_SIZE=1
  echo "Group size not specified; using 1"
fi

if [[ -z ${RAMPUP_DURATION} ]]; then
  export RAMPUP_DURATION="5m"
  echo "Rampup duration not specified; using ${RAMPUP_DURATION}"
fi

if [[ -z ${RAMPDOWN_DURATION} ]]; then
  export RAMPDOWN_DURATION="5m"
  echo "Group size not specified; using ${RAMPDOWN_DURATION}"
fi

which cf
cf --version
cf apps

originals=($(groupList))
successor="${NAME}"

# map/scale original deployment if necessary
if [[ 1 = ${#originals[@]} ]]; then
  echo "Initial version, scaling"
  scaleGroup ${successor} ${GROUP_SIZE}
  echo "Initial version, mapping route"
  mapRoute ${successor} ${ROUTE_DOMAIN} ${ROUTE_HOSTNAME}
  exit 0
else
  echo "Not initial version"
fi

# export version of this build
export UPDATE_ID=${BUILD_NUMBER}

# Determine which original groups has the desired route --> the current original
export route="${ROUTE_HOSTNAME}.${ROUTE_DOMAIN}" 
ROUTED=()

#EE# TODO: make this a function
oldIFS=$IFS
IFS=': ,'
for i in "${originals[@]}"
do   
   echo "Checking routes for ${i}:"
   read -a route_list <<< $(cf app ${i} | grep -v "^Showing" | grep -v "^OK" | grep -v "^[[:space:]]*$" | grep -v "^name" | grep "^urls:")
   #echo $'${route_list[@]:1}\n'
   
   if (( 1 < ${#route_list[@]} )); then
     for j in "${route_list[@]}"
	 do
	    if [[ "${j}" == "${route}" ]]; then
		  ROUTED+=(${i})
		  break
		fi
	 done
   fi  
   unset route_list
done
IFS=$oldIFS

echo ${#ROUTED[@]} of original groups routed to ${route}: ${ROUTED[@]}

if (( 1 < ${#ROUTED[@]} )); then
  echo "WARNING: Selecting only oldest to reroute"
fi

if (( 0 < ${#ROUTED[@]} )); then
  original_grp=${ROUTED[$(expr ${#ROUTED[@]} - 1)]}
  original_grp_id=${original_grp#_*}
fi

successor_grp=${NAME}

echo "Original group: ${original_grp} (${original_grp_id})"
echo "Successor group: ${successor_grp}  (${UPDATE_ID})"

cf active-deploy-list --timeout 60s

# Do update if there is an original group
if [[ -n "${original_grp}" ]]; then
  echo "Beginning update with cf active-deploy-create ..."
 
  create_command="cf active-deploy-create ${original_grp} ${successor_grp} --manual --quiet --label Explore_${UPDATE_ID} --timeout 60s"
  
  if [[ -n "${RAMPUP_DURATION}" ]]; then create_command="${create_command} --rampup ${RAMPUP_DURATION}"; fi
  if [[ -n "${RAMPDOWN_DURATION}" ]]; then create_command="${create_command} --rampdown ${RAMPDOWN_DURATION}"; fi
  create_command="${create_command} --test 1s";
  
  echo "Executing update: ${create_command}"
  update=$(${create_command})
  
  if (( $? )); then
    echo "Failed to initiate active deployment; error was:"
    echo ${update}
    exit 1
  fi
  
  echo "Initiated update: ${update}"
  cf active-deploy-show $update --timeout 60s
  
  # Wait for completion of rampup phase
  # wait_for_update $update test 600 && rc=$? || rc=$?
  wait_phase_completion $update && rc=$? || rc=$?
  echo "wait result is $rc"
 case "$rc" in
    0) # phase done
    # continue (advance to test)
    echo "Phase done, advance to test"
    cf active-deploy-advance $update
    ;;
    1) # completed
    # cannot rollback; delete; return OK 
    echo "Cannot rollback, phase completed. Deleting update record"
    delete $update
    ;;
    2) # rolled back
    # delete; return ERROR
    echo "Rolled back, Deleting update record."
    delete $update
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
    delete $update
    exit 5
    ;;
    9) # takes too long
    #rollback; delete; return ERROR
    echo "Timeout"
    rollback $update
    delete $update
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
#      cf active-deploy-list $update
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
#    cf active-deploy-advance $update
#  fi

  cf active-deploy-list
fi
