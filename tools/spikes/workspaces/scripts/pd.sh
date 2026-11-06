#!/bin/sh
# CLI against the Phase D isolated daemon.
exec env -u DIETER_TURN_TOKEN -u DIETER_CARD_ID DIETER_HOME=/Volumes/External/dieter-spike/phase-d/home /Volumes/External/dieter-spike/phase-d-bin/dieter "$@"
