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

#EE# function get_originals(){
  #EE# local __prefix=$(echo ${1} | cut -c 1-16)
  #EE# #EE# local __originals=${2}

  #EE# if [[ "CCS" == "${BACKEND}" ]]; then
    #EE# read -a originals <<< $(ice group list | grep -v 'Group Id' | grep " ${__prefix}" | awk '{print $1}')
  #EE# elif [[ "APPS" == "${BACKEND}" ]]; then
    #EE# read -a originals <<< $(cf apps | grep -v "^Getting" | grep -v "^OK" | grep -v "^[[:space:]]*$" | grep -v "^name" | grep "${__prefix}" | awk '{print $1}')
  #EE# else
    #EE# >&2 echo "ERROR: Unknown backend ${BACKEND}; expected one of \"CCS\" or \"APPS\""
    #EE# return 3
  #EE# fi
  
  #EE# echo ${#originals[@]} original groups found: ${originals[@]}
#EE# }

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

# Setup pipeline slave
cf apps
slave_setup
cf apps

#MK##EE# TODO: pass in originals variable
#MK#get_originals ${CF_APP}
originals=($(groupList))

successor="${CF_APP}_${BUILD_NUMBER}"

# Deploy the new version
# deployGroup "${successor}"
if (( ${#originals[@]} )); then
  echo "Not initial version"
else
  echo "Initial version,scaling"
  scaleGroup ${successor} 4
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

successor_grp=${CF_APP}_${UPDATE_ID}

echo "Original group: ${original_grp} (${original_grp_id})"
echo "Successor group: ${successor_grp}  (${UPDATE_ID})"

cf active-deploy-list --timeout 60s

# Do update if there is an original group
if [[ -n "${original_grp}" ]]; then
  echo "Beginning active-deploy update..."
 
  create_command="cf active-deploy-create ${original_grp} ${successor_grp} --manual --quiet --label Explore_${UPDATE_ID} --timeout 60s"
  
  if [[ -n "${RAMPUP}" ]]; then create_command="${create_command} --rampup ${RAMPUP}s"; fi
  #EE# if [[ -n "${TEST}" ]]; then create_command="${create_command} --test ${TEST}s"; fi
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
  #EE# wait_for_update $update rampdown 600 && rc=$? || rc=$?
  #EE# echo "wait result is $rc"
  
  wait_for_update $update test 600 && rc=$? || rc=$?
  
  cf active-deploy-advance $update
  
  echo "wait result is $rc"
  
  cf active-deploy-list
  
  #EE# if (( $rc )); then
    #EE# echo "ERROR: update failed"
    #EE# echo cf-active-deploy-rollback $update
    #EE# wait_for_update $update initial 600 && rc=$? || rc=$?
    #EE# cf active-deploy-delete $update -f
    #EE# exit 1
  #EE# fi
  
  if (( $rc )); then
    echo "Advance to testing failed; rolling back update $update"
    rollback $update || true
    if (( $rollback_rc )); then
      echo "WARN: Unable to rollback update"
    fi 
    
    # Cleanup - delete update record
    echo "Deleting update record"
    delete $update && delete_rc=$? || delete_rc=$?
    if (( $delete_rc )); then
      echo "WARN: Unable to delete update record $update"
    fi
  fi
  
fi
