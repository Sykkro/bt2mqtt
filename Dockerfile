FROM --platform=$BUILDPLATFORM alpine:3.12 AS build
ARG TARGETPLATFORM
ARG BUILDPLATFORM

FROM alpine:3.12
RUN apk update 
RUN apk add bash 
RUN apk add bluez 
RUN apk add bluez-deprecated 
RUN apk add mosquitto-clients

COPY bt2mqtt.sh /bt2mqtt.sh
RUN chmod +x /bt2mqtt.sh
ENTRYPOINT ["/bt2mqtt.sh"]