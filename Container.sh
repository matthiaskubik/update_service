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


MIN_MAX_WAIT=180


# Return list of names of existing versions
# Usage: groupList
function groupList() {
python - <<CODE
import ccs
import os
import sys
s = ccs.ContainerCloudService()
groups = s.list_groups(timeout=30)
names = [g.get('Name', '') for g in groups]
print('{}'.format(' '.join(names)))
CODE
}


# Delete a group
# Usage groupDelete name
function groupDelete() {
__name="${1}" python - <<CODE
import ccs
import os
import sys
s = ccs.ContainerCloudService()
name = os.getenv('__name')
deleted, group, reason = s.forced_delete_group(name, timeout=90)
if not deleted:
  sys.stderr.write('Delete failed: {}\n'.format(reason))
sys.exit(0 if deleted else 1)
CODE
}


# Map a route to a group
# Usage: mapRoute name domain host
function mapRoute() {
__name="${1}" __domain="${2}" __host="${3}" python - <<CODE
import ccs
import os
import sys
s = ccs.ContainerCloudService()
name = os.getenv('__name')
domain = os.getenv('__domain')
hostname = os.getenv('__host')
mapped, group, reason = s.map(hostname, domain, name, timeout=90)
if not mapped:
  sys.stderr.write('Map of route to group failed: {}\n'.format(reason))
sys.exit(0 if mapped else 1)
CODE
}


# Change number of instances in a group
# Usage: scaleGroup name size
function scaleGroup() {
__name="${1}" __size="${2}" python - <<CODE
import ccs
import os
import sys
s = ccs.ContainerCloudService()
name = os.getenv('__name')
size = os.getenv('__size')
scaled, group, reason = s.resize(name, size, timeout=90)
if not scaled:
  sys.stderr.write('Group resize failed: {}\n'.format(reason))
sys.exit(0 if scaled else 1)
CODE
}


# Get the routes mapped to a group
# Usage: getRoutes name
function getRoutes() {
__name="${1}" python - <<CODE
import ccs
import os
import sys
s = ccs.ContainerCloudService()
name = os.getenv('__name')
group, reason = s.inspect_group(name, timeout=30)
if group is None:
  sys.stderr.write("Can't read group: {}\n".format(reason))
  sys.exit(1)
else:
  routes = group.get('Routes', [])
  print('{}'.format(' '.join(routes)))
CODE
}


# TODO: implement
# Stop a group
# Usage: stopGroup name
function stopGroup() {
  local __name="${1}"

  echo "Stopping group ${__name} (UNIMPLEMENTED)"
}


# TODO: implement
# Determine if a group is in the stopped state
# Ussage: isStopped name
function isStopped() {
  local __name="${1}"

  echo "false"
}

