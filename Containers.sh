#!/bin/bash

## TODO use Osthanes ice utilities
#

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
  local __name="${1}"
  
  ice group rm --force ${__name} 
  ## wait for delete to complete?
}


# Map a route to a group
# Usage: mapRoute name domain host
function mapRoute() {
  local __name="${1}"
  local __domain="${2}"
  local __host="${3}"
  
  ice route map --hostname ${__host} --domain ${__domain} ${__name} && rc=$? || rc=$?
  return ${rc}
}


# Change number of instances in a group
# Usage: scaleGroup name size
function scaleGroup() {
  local __name="${1}"
  local __size=${2}
  
  #TODO: ice group update --max ${__size} ${__name} && rc=$? || rc=$?
  ice group update --desired ${__size} ${__name} && rc=$? || rc=$?
  return ${rc}
}
