#!/bin/bash
#
#
#################################################
#    _     _   ____                  _   _      #
#   | |__ | |_|___ \ _ __ ___   __ _| |_| |_    #
#   | '_ \| __| __) | '_ ` _ \ / _` | __| __|   #
#   | |_) | |_ / __/| | | | | | (_| | |_| |_    #
#   |_.__/ \__|_____|_| |_| |_|\__, |\__|\__|   #
#                                 |_|           #
#################################################
#
#
# This script does the following steps:
#
# 1 - read $BT2MQTT_FILE_NAME for device=MAC mappings and assume devices presence is -1
# 2 - store default bluetooth page timeout and set a custom one
# 3 - start while true loop, set cycle to 0 and repeat after POLL seconds
# 4 - increase cycle by 1 % BT2MQTT_CHECK_PRESENCE_CYCLE
# 5 - every 1/BT2MQTT_CHECK_PRESENCE_CYCLE cycles, if there are 100% present devices, check if they are still present
# 6 - every cycle, if there are devices with presence below 100%, update their presence (either reduce by BT2MQTT_DROP_RATE if absent or set it to 100 if present)
# 7 - wait POLL seconds and repeat from 4
# 8 - on exit, restore the default timeout


#-------- STATIC CONFIGS --------#
: ${BT2MQTT_FILE_NAME:="conf/devices.conf"}  # file path for the configured bluetooth devices to scan
: ${BT2MQTT_POLL_INTERVAL:=3}                # main while loop interval in seconds
: ${BT2MQTT_CHECK_PRESENCE_CYCLE:=10}        # every 1/BT2MQTT_CHECK_PRESENCE_CYCLE cycles, check present
: ${BT2MQTT_DROP_RATE:=25}                   # 1-100 rate at which a device becomes missing
: ${BT2MQTT_HCI_TIMEOUT_SECONDS:=2}          # timeout value to be set when attempting to ping a bluetooth device
: ${BT2MQTT_HCI_INTERFACE:="hci0"}           # HCI interface name
: ${BT2MQTT_L2PING_TIMEOUT:=1}               # timeout between l2ping checks
: ${BT2MQTT_EXEC_TIMEOUT:=3}                 # maximum time to wait for l2ping execution results
: ${BT2MQTT_MQTT_HOST:="localhost"}          # MQTT host address
: ${BT2MQTT_MQTT_PORT:="1883"}               # MQTT host port
: ${BT2MQTT_MQTT_CLIENT_ID:="BT2MQTT"}       # MQTT publisher client ID
: ${BT2MQTT_MQTT_TOPIC:="bt2mqtt"}           # MQTT base topic path (should start with, but not end with, a slash)
: ${BT2MQTT_MQTT_QOS:=1}                     # MQTT QOS setting (0 for at most once, 1 for at least once, 2 for exactly once)

#TODO: add MQTT auth support

# no need to change down from here
HCI_ONE_SECOND_BLOCKS=1600 # used to calculate HCI timeout blocks
(( HCI_TIMEOUT_BLOCKS = BT2MQTT_HCI_TIMEOUT_SECONDS * HCI_ONE_SECOND_BLOCKS ))
MQTT_TEMPLATE='{"presence":%s, "mac":"%s", "uptime":%s}'
LOOP=true

#--------------------------------#

#----- UTILITARY FUNCTIONS ------#

#### GENERIC UTILS ####
function log() {
    echo -e "\033[1m[$(date +"%F %T")]\033[0m\t $1"
}

function dumpConfig() {
    log " ****************** STARTED ******************"
    log " Configurations:"
    log "- BT2MQTT_FILE_NAME = $BT2MQTT_FILE_NAME"
    log "- BT2MQTT_POLL_INTERVAL = $BT2MQTT_POLL_INTERVAL"
    log "- BT2MQTT_CHECK_PRESENCE_CYCLE = $BT2MQTT_CHECK_PRESENCE_CYCLE"
    log "- BT2MQTT_DROP_RATE = $BT2MQTT_DROP_RATE"
    log "- BT2MQTT_HCI_TIMEOUT_SECONDS = $BT2MQTT_HCI_TIMEOUT_SECONDS"
    log "- BT2MQTT_HCI_INTERFACE = $BT2MQTT_HCI_INTERFACE"
    log "- BT2MQTT_L2PING_TIMEOUT = $BT2MQTT_L2PING_TIMEOUT"
    log "- BT2MQTT_EXEC_TIMEOUT = $BT2MQTT_EXEC_TIMEOUT"
    log "- BT2MQTT_MQTT_HOST = $BT2MQTT_MQTT_HOST"
    log "- BT2MQTT_MQTT_PORT = $BT2MQTT_MQTT_PORT"
    log "- BT2MQTT_MQTT_CLIENT_ID = $BT2MQTT_MQTT_CLIENT_ID"
    log "- BT2MQTT_MQTT_TOPIC = $BT2MQTT_MQTT_TOPIC"
    log "- BT2MQTT_MQTT_QOS = $BT2MQTT_MQTT_QOS"
    log " *********************************************"
}

#### BLUETOOTH MANAGEMENT ####

function getDefaultTimeout() {
	hciconfig $BT2MQTT_HCI_INTERFACE pageto | sed -n -E "s/.*Page timeout: (.*) slots.*/\\1/p"
}

function setTimeout() {
	hciconfig $BT2MQTT_HCI_INTERFACE pageto $1
}

#### MQTT MESSAGING ####
function publishEvent() {
    device=$1
    addr=$2
    presence=$3
    uptime=$4
    #"$(date +%s%N)"
    message=$(printf "$MQTT_TEMPLATE" "$presence" "$addr" "$uptime")
    mosquitto_pub -h $BT2MQTT_MQTT_HOST -p $BT2MQTT_MQTT_PORT -i $BT2MQTT_MQTT_CLIENT_ID -q $BT2MQTT_MQTT_QOS \
                  -t "$BT2MQTT_MQTT_TOPIC/$device" -m "$message"
}

#### DEVICE MANAGEMENT ####
function checkDevice() {
	timeout $BT2MQTT_EXEC_TIMEOUT l2ping -s 0 -d 0 -c 1 -t $BT2MQTT_L2PING_TIMEOUT $1
}

function updatePresence() {
    device=$1
    addr=$2
    presences=$3
    discoveredAt=$4
    currentPresence=${presences[$device]}
    newPresence=$currentPresence
    # ping device
    checkDevice "$addr" &> /dev/null
    if [ $? -eq 0 ]; then
        # device is up, increment presence
        newPresence=100
    else
        # device is down, decrement presence
        newPresence=$(( newPresence > BT2MQTT_DROP_RATE ? (newPresence - BT2MQTT_DROP_RATE) : 0 ))
    fi


    if [ $currentPresence -ne $newPresence ]; then
        log "* [$addr] Device '$device' presence updated from $currentPresence to $newPresence *"
        presences[$device]=$newPresence
        now=$(date +%s)
        if [ $currentPresence -le 0 ]; then # just discovered, update discoveredAt
            discoveredAt[$device]=$now
        fi
        discovery=${discoveredAt[$device]}
        ((uptime=now-discovery))
        publishEvent $device $addr $newPresence $uptime
    fi
}

function confirmPresent() {
    devices=$1
    presences=$2
    discoveredAt=$3
    log "START confirming presences..."
    for device in "${!devices[@]}"; do
        if [ ! $device == "0" ] && [ "${presences[$device]}" == "100" ]; then
            updatePresence $device "${devices[$device]}" $presences $discoveredAt
        fi
    done
    log "DONE confirming presences."
}

function checkNonPresent() {
    devices=$1
    presences=$2
    discoveredAt=$3
    log "START checking absences..."
    for device in "${!devices[@]}"; do
        if [ ! $device == "0" ] && [ ! "${presences[$device]}" == "100" ]; then
            updatePresence $device "${devices[$device]}" $presences $discoveredAt
        fi
    done
    log "DONE checking absences."
}

#--------------------------------#

# ensure we're running as root
if [ "$EUID" -ne 0 ]; then
    log "Please run as root"
    exit 1
fi

# ensure required binaries are installed
REQUIRED_CMDS="hcitool hciconfig mosquitto_pub l2ping timeout"
 
for i in $REQUIRED_CMDS
do
        # command -v will return >0 when the $i is not found
	command -v $i >/dev/null && continue || { echo "$i command not found."; exit 1; }
done

# ensure configured device exists
(hcitool dev | grep "$BT2MQTT_HCI_INTERFACE") &> /dev/null || { echo "Interface '$BT2MQTT_HCI_INTERFACE' not found" ; exit 1; }

# 1 - read devices from devices.conf file and assume devices presence is -1
readarray -t lines < "$BT2MQTT_FILE_NAME"
declare -A devices
declare -A presences
declare -A discoveredAt
for line in "${lines[@]}"; do
	devices[${line%%=*}]=${line#*=}
    presences[${line%%=*}]=-1
    discoveredAt[${line%%=*}]=-1
done

# 2 - store default bluetooth page timeout and set a custom one

DEFAULT_TIMEOUT=$(getDefaultTimeout)

# trap ctrl-c and call onQuit()
trap onQuit INT

function onQuit() {
	LOOP=false
	log "** quitting; restoring default timeout **"
	setTimeout $DEFAULT_TIMEOUT
    exit 0;
}

# 3 - start while true loop, set cycle to 0 and repeat after POLL seconds
dumpConfig
cycle=0
while $LOOP
do
    # 4 - increase cycle by 1 % BT2MQTT_CHECK_PRESENCE_CYCLE
    (( cycle=(cycle+1) % BT2MQTT_CHECK_PRESENCE_CYCLE ))

    # 5 - every 1/BT2MQTT_CHECK_PRESENCE_CYCLE cycles, if there are present devices, check if they are still present and reduce presence by BT2MQTT_DROP_RATE if they aren't
    if ! ((cycle % BT2MQTT_CHECK_PRESENCE_CYCLE)); then
        confirmPresent devices presences discoveredAt
    fi

    # 6 - every cycle, if there are non-present devices, check if they become present and change presence to 100 if they are
    checkNonPresent devices presences discoveredAt

    # 7 - wait BT2MQTT_POLL_INTERVAL seconds and repeat from 4
    sleep $BT2MQTT_POLL_INTERVAL
done

# 8 - on exit, restore the default timeout
onQuit

#-- the end --#