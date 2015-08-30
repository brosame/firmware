#!/bin/sh

set -eu

if [ "$#" -lt 2 ] || [ -z "$1" ]; then
   echo "Bad parameter! IP as parameter is needed."
   echo "e.g."
   echo "      mtr-oni.sh 192.168.0.33"
   echo
   exit
fi >&2

oni_tracert_mtr_helper.sh "$1" method-mtr
