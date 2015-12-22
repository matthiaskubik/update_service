#!/bin/bash

function groupList() {
  cf apps | awk -v pattern="${CONTAINER_NAME}_[0-9]\*" '$1 ~ pattern {print $1}'
  ## TODO error checking on result of cf apps call
}

function groupDelete() {
  cf delete ${1} --force
  ## TODO error checking on result of cf delete call
}


