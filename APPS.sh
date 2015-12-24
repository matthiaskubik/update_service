#!/bin/bash


# Return list of names of existing versions
# Usage: groupList
function groupList() {
  # cf apps | awk -v pattern="${CF_APP}_[0-9]\*" '$1 ~ pattern {print $1}'
  cf apps | grep "^${CF_APP}_[0-9]*[[:space:]]" | cut -d' ' -f1
  ## TODO error checking on result of cf apps call
}


# Delete a group
# Usage groupDelete name
function groupDelete() {
  cf delete ${1} -f
  ## TODO error checking on result of cf delete call
}


# Create a new version with 1 member and no routes
# Usage: deployGroup name
function deployGroup() {
  local __name="${1}"
  
  cf push "${__name}" --no-route -i 1 && rc=$? || rc=$?
  return ${rc}
}


# Map a route to a group
# Usage: mapRoute name domain host
function mapRoute() {
  local __name="${1}"
  local __domain="${2}"
  local __host="${3}"
  
  cf map-route ${__name} ${__domain} -n ${host} && rc=$? || rc=$?
  return ${rc}
}


# Change number of instances in a group
# Usage: scaleGroup name size
function scaleGroup() {
  local __name="${1}"
  local __size=${2}
  
  cf scale ${__name} -i ${__size} && rc=$? || rc=$?
  return ${rc}
}