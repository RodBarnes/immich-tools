#!/bin/bash

show_syntax() {
    echo "Syntax: $(basename $0) [-d|datetime <datetime>] [-z|tz <timezone-offset>] [-t|lat latitude] [-n|lng longitude] <filename>"
    echo "Where:  <filename> is the name of the file to be updated."
    echo "        <datetime> is the value to be applied to DateTimeOriginal"
    echo "        <timezone-offset> is the value to be applied to OffsetTimeOriginal"
    echo "        <latitude> is the GPS latitude value"
    echo "        <longitude> is the GPS longitude value"
}

arg_short=d:z:g:a:
arg_long=datetime:,tz:,gps:,alt:
arg_opts=$(getopt --options "$arg_short" --long "$arg_long" --name "$0" -- "$@")
if [ $? != 0 ]; then
  show_syntax
  exit 1
fi

eval set -- "$arg_opts"
while true; do
  case "$1" in
    -d|--datetime)
        datetime="$2"
        shift 2
        ;;
    -z|--tz)
        offset="$2"
        shift 2
        ;;
    -g|--gps)
        gps="$2"
        shift 2
        ;;
    -a|--alt)
        alt="$2"
        shift 2
        ;;
    --) # End of options
        shift
        break
        ;;
    *)
        echo "Error parsing arguments: arg=$1"
        exit 1
        ;;
  esac
done

if [ $# == 0 ]; then
  show_syntax
  exit 1
fi

args=(-GPSAltitudeRef=0 -overwrite_original)

if [[ "$datetime" != "" ]]; then
    args+=(-EXIF:DateTimeOriginal="$datetime")
fi

if [[ "$offset" != "" ]]; then
    args+=(-EXIF:OffsetTimeOriginal="$offset")
fi

if [[ "$gps" != "" ]]; then
    lat="${gps%%,*}"
    [[ "$lat" == -* ]] && latref="S" || latref="N"
    lng="${gps#*,}"
    [[ "$lng" == -* ]] && lngref="W" || lngref="E"
    args+=(-GPSLatitude="$lat" -GPSLatitudeRef="$latref" -GPSLongitude="$lng" -GPSLongitudeRef="$lngref")
    alt="${alt:-0}"
    args+=(-GPSAltitude="$alt")
fi

filename="$1"
args+=("$filename")

exiftool "${args[@]}"
exiftool -gps:all -time:all -a "$filename"
