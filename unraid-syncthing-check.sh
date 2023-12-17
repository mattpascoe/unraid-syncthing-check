#!/bin/bash
#
# MDP: 2023-12-16
#
# A simple check script to validate the status of a syncthing instance from an unraid server.
# Probably make this a plugin, but for now set it up via a cron in a User Script setup.
#
# Assumptions:
#  this check will happen once or twice a day.
#  each time it checks, it will have no state of the last time. so current
#  status is the state of things
#
#  you can toggle if it sends alerts by setting ENV SEND_ALERTS=1
#
# TODO: if a device is paused, maybe skip it from alerts on lastseen

if [ -z ${SYNCTHING_API} ]; then echo "Syncthing api key is unset" && exit 1; fi
if [ -z ${SYNCTHING_URL} ]; then export SYNCTHING_URL=127.0.0.1; fi
if [ -z ${SYNCTHING_PORT} ]; then export SYNCTHING_PORT=8384; fi
if [ -z ${SEND_ALERTS} ]; then export SEND_ALERTS=0; fi

LASTSCAN_THRESH=86400
LASTSEEN_THRESH=86400

notify() {
  echo "$2"
  if [ "$SEND_ALERTS" -eq 1 ];then
    if [[ -f /usr/local/emhttp/webGui/scripts/notify ]]; then
      /usr/local/emhttp/webGui/scripts/notify -i "$([[ $2 == ALERT* ]] && echo alert || echo normal)" -s "SyncthingCheck: $1" -d "$2" #-m "$2"
    fi
  fi
}

# Get the current time in seconds since the epoch
CUR_TIME=$(date +%s)

declare -A DEVNAMES DEV_PAUSE DEV_CONNECTED DEV_ADDR DEV_SEEN DEV_LASTSEENDIFF
declare -A FOLDER_LABEL FOLDER_ERRORS FOLDER_STATE FOLDER_NEEDTOTAL FOLDER_PATH FOLDER_LASTSCAN FOLDER_LASTSCANDIFF

# define the common curl command syntax
CURLCMD="curl -s -X GET -H 'X-API-Key: $SYNCTHING_API' http://$SYNCTHING_URL:$SYNCTHING_PORT"

# Get my own device id so we can ignore it
MYID=$(eval "$CURLCMD/rest/system/status"|jq -r .myID)

# Get config and connection data
ST_CONFIG=$(eval "$CURLCMD/rest/config")
CONNECTIONS=$(eval "$CURLCMD/rest/system/connections")
DEVSTATS=$(eval "$CURLCMD/rest/stats/device")
FOLDSTATS=$(eval "$CURLCMD/rest/stats/folder")

# set an array of all our device IDs and folders
# Wow! mapfile does not allow upper case variables
mapfile -t devids  < <(echo $ST_CONFIG|jq -r '.devices[].deviceID')
mapfile -t folders < <(echo $ST_CONFIG|jq -r '.folders[]|.id')


# Loop through each device ID and gather some data
for DEVID in "${devids[@]}"; do
  if [ $DEVID == $MYID ]; then
    continue
  fi

  DEVNAMES["$DEVID"]="$(echo "$ST_CONFIG" | jq -r --arg var "$DEVID" '.devices[] | select(.deviceID == $var) | .name')"
  DEV_PAUSE["$DEVID"]=$(echo "$ST_CONFIG" | jq -r --arg var "$DEVID" '.devices[] | select(.deviceID == $var) | .paused')
  #DEV_ADDR["$DEVID"]="$(echo "$ST_CONFIG" | jq -r --arg var "$DEVID" '.devices[] | select(.deviceID == $var) | .address')"

  DEV_CONNECTED["$DEVID"]=$(echo "$CONNECTIONS" | jq -r '.connections.'"\"$DEVID\""'.connected')
  LASTSEEN=$(echo "$DEVSTATS" | jq -r '.'"\"$DEVID\""'.lastSeen')
  LASTSEEN_SECONDS=$(date -d "$LASTSEEN" +%s)

  DEV_SEEN["$DEVID"]=$LASTSEEN
  DEV_LASTSEENDIFF["$DEVID"]=$((CUR_TIME - LASTSEEN_SECONDS))

  echo "${DEVNAMES["$DEVID"]} paused: ${DEV_PAUSE["$DEVID"]} connected: ${DEV_CONNECTED["$DEVID"]} lastseen: ${DEV_SEEN["$DEVID"]}"
done

echo
for FOLDER in "${folders[@]}"; do
  FOLDER_STAT=$(eval "$CURLCMD/rest/db/status?folder=$FOLDER")
  # Pull elements from the json and assign them to local variables
  eval "$(echo $FOLDER_STAT|jq -r '{errors,state,needTotalItems}| to_entries | .[] | .key + "=" + (.value | @sh)')"
  FOLDER_ERRORS["$FOLDER"]=$errors
  FOLDER_STATE["$FOLDER"]=$state
  FOLDER_NEEDTOTAL["$FOLDER"]=$needTotalItems

  eval "$(echo $ST_CONFIG|jq -r --arg var "$FOLDER" '.folders[] | select(.id == $var) | {"label",path}| to_entries | .[] | .key + "=" + (.value | @sh)')"
  FOLDER_LABEL["$FOLDER"]=$label
  FOLDER_PATH["$FOLDER"]=$path

  LASTSCAN=$(echo "$FOLDSTATS"  | jq -r '.'"\"$FOLDER\""'.lastScan')
  LASTSCAN_SECONDS=$(date -d "$LASTSCAN" +%s)

  # Calculate the time difference in seconds
  FOLDER_LASTSCAN["$FOLDER"]=$LASTSCAN
  FOLDER_LASTSCANDIFF["$FOLDER"]=$((CUR_TIME - LASTSCAN_SECONDS))

  echo "${FOLDER_LABEL["$FOLDER"]} [$FOLDER] needs:$needTotalItems lastscan: $LASTSCAN "
done

echo
# real checks
for key in "${!DEVNAMES[@]}"; do
  #if [ "${DEV_CONNECTED[$key]}" == "false" ]; then
  #  MSG="ALERT: ${DEVNAMES[$key]} is not connected since ${DEV_SEEN[$key]}"
  #  notify "Device Not Connected" "$MSG"
  #fi
  if [ ${DEV_LASTSEENDIFF[$key]} -gt $LASTSEEN_THRESH ]; then
    MSG="ALERT: ${DEVNAMES[$key]} has not been seen since ${DEV_LASTSEEN[$key]} (diff ~ ${DEV_LASTSEENDIFF[$key]} Sec) "
    notify "Device Not Seen Recently" "$MSG"
  fi
done

for key in "${folders[@]}"; do
  if [ ${FOLDER_NEEDTOTAL[$key]} -gt 0 ]; then
    MSG="ALERT: ${FOLDER_STATE[$key]} ~ ${FOLDER_LABEL[$key]} [$key] still needs to update ${FOLDER_NEEDTOTAL[$key]} items going to local path ${FOLDER_PATH[$key]}"
    notify "Folder Needs Update" "$MSG"
  fi
  if [ ${FOLDER_LASTSCANDIFF[$key]} -gt $LASTSCAN_THRESH ]; then
    MSG="ALERT: ${FOLDER_STATE[$key]} ~ ${FOLDER_LABEL[$key]} [$key] has not been scanned since ${FOLDER_LASTSCAN[$key]} (diff ~ ${FOLDER_LASTSCANDIFF[$key]} Sec) "
    notify "Folder Not Scanned Recently" "$MSG"
  fi
done
