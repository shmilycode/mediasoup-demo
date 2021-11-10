#!/usr/bin/env bash
 
#SERVER_URL=https://192.168.12.90:15025
#ROOM_ID=0fmkkzxl
#PRODUCER_ID=c77e8b4b-98c7-4e20-b519-566053d79fad
#MEDIA_FILE=./output/res_video.webm
 
function show_usage()
{
	echo
	echo "USAGE"
	echo "-----"
	echo
	echo "  SERVER_URL=https://my.mediasoup-demo.org:4443 ROOM_ID=test PRODUCER_ID=c4a1ed8b-0d71-422d-a9c0-7fed44bf05bc"
	echo
	echo "  where:"
	echo "  - SERVER_URL is the URL of the mediasoup-demo API server"
	echo "  - ROOM_ID is the id of the mediasoup-demo room (it must exist in advance)"
	echo
	echo "REQUIREMENTS"
	echo "------------"
	echo
	echo "  - ffmpeg: stream audio and video (https://www.ffmpeg.org)"
	echo "  - httpiei: command line HTTP client (https://httpie.org)"
	echo "  - jq: command-line JSON processor (https://stedolan.github.io/jq)"
	echo
}
 
echo
 
 
if [ "$(command -v ffmpeg)" == "" ] ; then
	>&2 echo "ERROR: ffmpeg command not found, must install FFmpeg"
	show_usage
	exit 1
fi
 
if [ "$(command -v http)" == "" ] ; then
	>&2 echo "ERROR: http command not found, must install httpie"
	show_usage
	exit 1
fi
 
if [ "$(command -v jq)" == "" ] ; then
	>&2 echo "ERROR: jq command not found, must install jq"
	show_usage
	exit 1
fi
 
set -e
 
BROADCASTER_ID=$(LC_CTYPE=C tr -dc A-Za-z0-9 < /dev/urandom | fold -w ${1:-32} | head -n 1)
HTTPIE_COMMAND="http --check-status --verify=no"
VIDEO_SSRC=128827720
VIDEO_PT=101
#
# Verify that a room with id ROOM_ID does exist by sending a simlpe HTTP GET.
# If not abort since we are not allowed to initiate a room..
#
echo ">>> verifying that room '${ROOM_ID}' exists..."
 
res=$(${HTTPIE_COMMAND} \
	GET ${SERVER_URL}/rooms/${ROOM_ID} \
	2> /dev/null)
 
#
# Create a Broadcaster entity in the server by sending a POST with our metadata.
# Note that this is not related to mediasoup at all, but will become just a JS
# object in the Node.js application to hold our metadata and mediasoup Transports
# and Producers.
#
echo ">>> creating Puller..."
 
${HTTPIE_COMMAND} \
	POST ${SERVER_URL}/rooms/${ROOM_ID}/broadcasters \
	id="${BROADCASTER_ID}" \
	displayName="Broadcaster" \
	device:='{"name": "recorder"}' \
	rtpCapabilities:=${res} \
	> /dev/null
 
#
# Upon script termination delete the Broadcaster in the server by sending a
# HTTP DELETE.
#
trap 'echo ">>> script exited with status code $?"; ${HTTPIE_COMMAND} DELETE ${SERVER_URL}/rooms/${ROOM_ID}/broadcasters/${BROADCASTER_ID} > /dev/null' EXIT
 
#
# Create a PlainTransport in the mediasoup to pull  video using plain RTP
# over UDP. Do it via HTTP post specifying type:"plain" and comedia:false and
# rtcpMux:false.
#
echo ">>> creating mediasoup PlainTransport for consumer video..."
 
res=$(${HTTPIE_COMMAND} \
	POST ${SERVER_URL}/rooms/${ROOM_ID}/broadcasters/${BROADCASTER_ID}/transports \
	type="plain" \
	comedia:=false \
	rtcpMux:=true \
	2> /dev/null)
 
#
# Parse JSON response into Shell variables and extract the PlainTransport id,
# IP, port and RTCP port.
#
eval "$(echo ${res} | jq -r '@sh "transportId=\(.id) transportIp=\(.ip) transportPort=\(.port) transportRtcpPort=\(.rtcpPort)"')"
 
 
 
echo ">>> PlainTransport Connect ..."
 
${HTTPIE_COMMAND} -v \
	POST ${SERVER_URL}/rooms/${ROOM_ID}/broadcasters/${BROADCASTER_ID}/transports/${transportId}/plainconnect \
	ip="127.0.0.1" \
	port:=${RTP_PORT} \
	rtcpport:=${RTCP_PORT} \
	> /dev/null
 
#echo ${res}
 
 
echo ">>> creating mediasoup video consumer..."
 
res1=$(${HTTPIE_COMMAND} \
	POST ${SERVER_URL}/rooms/${ROOM_ID}/broadcasters/${BROADCASTER_ID}/transports/${transportId}/consume?producerId=${PRODUCER_ID} \
		2> /dev/null)
 
echo "creat consumer res :"
echo ${res1}
eval "$(echo ${res1} | jq -r '@sh "consumeId=\(.id)"')"
 
echo ">>> resume ..."
# echo ${consumeId}
 
${HTTPIE_COMMAND} -v \
	POST ${SERVER_URL}/rooms/${ROOM_ID}/broadcasters/${BROADCASTER_ID}/consume/${consumeId}/resume \
		> /dev/null
 
runAfterSleep() {
    local duration=$1
    local command=$2
    local echoMessage=$3
    sleep ${duration}
    echo ${echoMessage}
    ${HTTPIE_COMMAND} -v POST ${command} > /dev/null
}
 
runAfterSleep 1s ${SERVER_URL}/rooms/${ROOM_ID}/broadcasters/${BROADCASTER_ID}/consume/${consumeId}/requestKeyFrame ">>> request keyFrame..." &
 
echo ">>> running ffmpeg..."
#ffmpeg -thread_queue_size 1024 -protocol_whitelist "file,udp,rtp" -i ${SDP_FILE} -vcodec copy -y ${MEDIA_FILE} -v trace
ffplay -flags low_delay -probesize 32 -analyzeduration 0 -sync ext -protocol_whitelist "file,udp,rtp" -i ${SDP_FILE} -v debug
# ffmpeg -thread_queue_size 1024 -protocol_whitelist "file,udp,rtp" -i video.sdp -vcodec h264 -y output.mp4
# ffmpeg -protocol_whitelist "file,udp,rtp" -i video.sdp -vcodec copy -f rtp_mpegts rtp://192.168.12.90:10000
