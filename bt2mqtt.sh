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
# 1 - read devices.conf for device=MAC mappings and assume devices presence is -1
# 2 - store default bluetooth page timeout and set a custom one
# 3 - start while true loop, set cycle to 0 and repeat after POLL seconds
# 4 - increase cycle by 1 % CHECK_PRESENCE_CYCLE
# 5 - every 1/CHECK_PRESENCE_CYCLE cycles, if there are 100% present devices, check if they are still present
# 6 - every cycle, if there are devices with presence below 100%, update their presence (either reduce by DROP_RATE if absent or set it to 100 if present)
# 7 - wait POLL seconds and repeat from 4
# 8 - on exit, restore the default timeout


#-------- STATIC CONFIGS --------#
: ${POLL_INTERVAL:=3}           # main while loop interval in seconds
: ${CHECK_PRESENCE_CYCLE:=10}   # every 1/CHECK_PRESENCE_CYCLE cycles, check present
: ${DROP_RATE:=25}              # 1-100 rate at which a device becomes missing
: ${HCI_TIMEOUT_SECONDS:=2}     # timeout value to be set when attempting to ping a bluetooth device
: ${HCI_INTERFACE:="hci0"}      # HCI interface name
: ${L2PING_TIMEOUT:=1}          # timeout between l2ping checks
: ${EXEC_TIMEOUT:=3}            # maximum time to wait for l2ping execution results
: ${MQTT_HOST:="localhost"}     # MQTT host address
: ${MQTT_PORT:="1883"}          # MQTT host port
: ${MQTT_CLIENT_ID:="BT2MQTT"}  # MQTT publisher client ID
: ${MQTT_TOPIC:="bt2mqtt"}     # MQTT base topic path (should start with, but not end with, a slash)
: ${MQTT_QOS:=1}                # MQTT QOS setting (0 for at most once, 1 for at least once, 2 for exactly once)

#TODO: add MQTT auth support

# no need to change down from here
HCI_ONE_SECOND_BLOCKS=1600 # used to calculate HCI timeout blocks
(( HCI_TIMEOUT_BLOCKS = HCI_TIMEOUT_SECONDS * HCI_ONE_SECOND_BLOCKS ))
MQTT_TEMPLATE='{"presence":%s, "mac":"%s", "uptime":%s}'
LOOP=true

#--------------------------------#

#----- UTILITARY FUNCTIONS ------#

#### GENERIC UTILS ####
function log() {
    echo -e "\033[1m[$(date +"%F %T")]\033[0m\t $1"
}
#### BLUETOOTH MANAGEMENT ####

# TODO: assuming hci0 here
function getDefaultTimeout() {
	hciconfig hci0 pageto | sed -n -E "s/.*Page timeout: (.*) slots.*/\\1/p"
}
# TODO: assuming hci0 here
function setTimeout() {
	hciconfig $HCI_INTERFACE pageto $1
}

#### MQTT MESSAGING ####
function publishEvent() {
    device=$1
    addr=$2
    presence=$3
    uptime=$4
    #"$(date +%s%N)"
    message=$(printf "$MQTT_TEMPLATE" "$presence" "$addr" "$uptime")
    mosquitto_pub -h $MQTT_HOST -p $MQTT_PORT -i $MQTT_CLIENT_ID -q $MQTT_QOS \
                  -t "$MQTT_TOPIC/$device" -m "$message"
}

#### DEVICE MANAGEMENT ####
function checkDevice() {
	timeout -t $EXEC_TIMEOUT l2ping -s 0 -d 0 -c 1 -t $L2PING_TIMEOUT $1
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
        newPresence=$(( newPresence > DROP_RATE ? (newPresence - DROP_RATE) : 0 ))
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

# TODO: ensure we have access to an active bluetooth device
# ensure we're running as root
if [ "$EUID" -ne 0 ]; then
    log "Please run as root"
    exit 1
fi

# 1 - read devices from devices.conf file and assume devices presence is -1
fileName="conf/devices.conf"
readarray -t lines < "$fileName"
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
cycle=0
while $LOOP
do
    # 4 - increase cycle by 1 % CHECK_PRESENCE_CYCLE
    (( cycle=(cycle+1) % CHECK_PRESENCE_CYCLE ))

    # 5 - every 1/CHECK_PRESENCE_CYCLE cycles, if there are present devices, check if they are still present and reduce presence by DROP_RATE if they aren't
    if ! ((cycle % CHECK_PRESENCE_CYCLE)); then
        confirmPresent devices presences discoveredAt
    fi

    # 6 - every cycle, if there are non-present devices, check if they become present and change presence to 100 if they are
    checkNonPresent devices presences discoveredAt

    # 7 - wait POLL_INTERVAL seconds and repeat from 4
    sleep $POLL_INTERVAL
done

# 8 - on exit, restore the default timeout
onQuit

#-- the end --#