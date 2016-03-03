#!/usr/bin/python

import requests
import sys
import json
import time
import os

api_res = os.environ.get('TC_API_RES')

api_res_json = json.loads(api_res)

service_id = 0
ad_broker_url = 0
pipeline_name = 0

for i in range(len(api_res_json['items'][0]['services'])):
  if "activedeploy" in api_res_json['items'][0]['services'][i]['service_id']:
    service_id = api_res_json['items'][0]['services'][i]['instance_id']
    ad_broker_url = api_res_json['items'][0]['services'][i]['url']

if sys.argv[1] == 'sid':
  print service_id

if sys.argv[1] == "ad-url":
  print ad_broker_url

if len(sys.argv[1]) == 36:
  for i in range(len(api_res_json['items'][0]['services'])):
  	if sys.argv[1] in api_res_json['items'][0]['services'][i]['instance_id']:
  		print api_res_json['items'][0]['services'][i]['parameters']['name']