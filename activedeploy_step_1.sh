#!/bin/bash

SCRIPTDIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

set -x
find . -print

# Pull in common methods
source ${SCRIPTDIR}/activedeploy_common.sh

# Identify BACKEND (APPS or CONTAINERS) and pull in specific implementations
if [[ -z ${BACKEND} ]]; then
  echo "ERROR: Backend not specified"
  exit 1
fi
source "${SCRIPTDIR}/${BACKEND}.sh"

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

# Validate needed inputs or set defaults

#init## Setup pipeline slave
#init#cf apps
#init#slave_setup
#init#cf apps
which cf
cf --version

originals=($(groupList))
successor="${NAME}_${BUILD_NUMBER}"

# map/scale original deployment if necessary
if (( ${#originals[@]} )); then
  echo "Not initial version"
else
  echo "Initial version,scaling"
  scaleGroup ${successor} ${SCALE}
  echo "Initial version, mapping route"
  mapRoute ${successor} ${ROUTE_DOMAIN} ${ROUTE_HOSTNAME}
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

successor_grp=${NAME}_${UPDATE_ID}

echo "Original group: ${original_grp} (${original_grp_id})"
echo "Successor group: ${successor_grp}  (${UPDATE_ID})"

cf active-deploy-list --timeout 60s

# Do update if there is an original group
if [[ -n "${original_grp}" ]]; then
  echo "Beginning active-deploy update..."
 
  create_command="cf active-deploy-create ${original_grp} ${successor_grp} --manual --quiet --label Explore_${UPDATE_ID} --timeout 60s"
  
  if [[ -n "${RAMPUP}" ]]; then create_command="${create_command} --rampup ${RAMPUP}s"; fi
  if [[ -n "${RAMPDOWN}" ]]; then create_command="${create_command} --rampdown ${RAMPDOWN}s"; fi
  
  echo "Executing update: ${create_command}"
  update=$(${create_command})
  
  if (( $? )); then
    echo "Failed to initiate active deployment; error was:"
    echo ${update}
    exit 1
  fi
  
  echo "Initiated update: ${update}"
  cf active-deploy-show $update --timeout 60s
  
  # Wait for completion
  wait_for_update $update test 600 && rc=$? || rc=$?
  
  cf active-deploy-advance $update
  
  echo "wait result is $rc"
  
  cf active-deploy-list
  
  if (( $rc )); then
    echo "Advance from rampup failed; rolling back update $update"
    rollback $update || true
    if (( $rollback_rc )); then
      echo "WARN: Unable to rollback update"
      cf active-deploy-list $update
    fi 
    
    # Cleanup - delete update record
    echo "Deleting update record"
    delete $update && delete_rc=$? || delete_rc=$?
    if (( $delete_rc )); then
      echo "WARN: Unable to delete update record $update"
    fi
    exit 1
  fi
  
fi
