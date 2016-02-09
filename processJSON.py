#!/usr/bin/python

import requests
import sys
import json
import time
import os
import urllib2

LABEL_GREEN = '\033[0;32m'
STARS = "**********************************************************************"
LABEL_NO_COLOR = '\033[0m'

api_res = os.environ.get('TC_API_RES')

api_res_json = json.loads(api_res)

service_id = 0
ad_broker_url = 0

for i in range(len(api_res_json['items'][0]['services'])):
  if "activedeploy" in api_res_json['items'][0]['services'][i]['_id']:
    service_id = api_res_json['items'][0]['services'][i]['_id']
    ad_broker_url = api_res_json['items'][0]['services'][i]['url']

if len(sys.argv) == 1:
  with open("curlRes.json") as json_file:
        url_json = json.load(json_file)

  print LABEL_GREEN
  print STARS
  print "Dashboard URL:"
  print url_json['dashboard_url']
  print STARS
  print LABEL_NO_COLOR
  exit()

if sys.argv[1] == 'sid':
  print service_id

if sys.argv[1] == "ad-url":
  print ad_broker_url