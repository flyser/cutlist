#!/bin/bash

# Default configuration. You can adjust this in ~/.config/cutlist/cutlistrc using
# the same syntax as below (or any other bash script)
FILE_EXTENSION="mkv"


set -e

if [[ -e "${HOME}/.config/cutlist/cutlistrc" ]]; then
  source "${HOME}/.config/cutlist/cutlistrc"
fi

if [[ $# -ne 2 ]]; then
  echo "Usage:"
  echo "  $0 videofile cutlist"
  exit 1
fi

function timecode_to_int() {
  [[ "x$1" = "x" ]] && return
  if [[ "$1" =~ ^((0*([0-9]+):)?0*([0-9]+):)?0*([0-9]+)(\.([0-9]{1,3}))? ]]; then
    VALUE=$((${BASH_REMATCH[5]}))
    [[ -n "${BASH_REMATCH[4]}" ]] && VALUE=$((${BASH_REMATCH[4]}*60+$VALUE))
    [[ -n "${BASH_REMATCH[3]}" ]] && VALUE=$((${BASH_REMATCH[3]}*60*60+$VALUE))
    VALUE=$(($VALUE*1000))
    
    if [[ -n "${BASH_REMATCH[7]}" ]]; then
      VALUE=$(($VALUE+10#$(printf %-3s ${BASH_REMATCH[7]} | sed s_\ _0_g)))
    fi
    echo "${VALUE}"
  else
    echo "Invalid timecode '$1', aborting." >&2
    exit 1
  fi
}

function int_to_timecode() {
    MILLISECONDS="$(($1%1000))"
    SECS="$(($1/1000%60))"
    MINUTES="$(($1/1000/60%60))"
    HOURS="$(($1/1000/60/60))"
    
    if [[ $HOURS -ne 0 ]]; then
        printf "%d:%02d:%02d" $HOURS $MINUTES $SECS
    elif [[ $MINUTES -ne 0 ]]; then
        printf "%d:%02d" $MINUTES $SECS
    else
        printf "%d" $SECS
    fi
    if [[ ${MILLISECONDS} -ne 0 ]]; then
        printf ".%03d" $MILLISECONDS | sed s_0*\$__
    fi
}


function run_ffmpeg() {
  INPUTFILE=$1 ; shift
  OUTPUTFILE=$1 ; shift
  PARTFILES=()
  
  counter=0
  for k in $@ ; do
    FROM="$(sed "s_-.*\$__" <<< "$k")"
    TO="$(sed "s_^.*-__" <<< "$k")"
    ffmpeg_opts=""
    
    if [[ "x$TO" != "x" ]]; then
      if [[ "x$FROM" != "x" ]]; then
        TO="$((${TO}-${FROM}))"
      fi
      TO="-to $(int_to_timecode "$TO")"
    fi
    if [[ "x$FROM" != "x" ]]; then
      FROM="-ss $(int_to_timecode "$FROM")"
    fi
    
    
    echo ffmpeg $FROM -i "$INPUTFILE" $TO -c copy -avoid_negative_ts 1 -movflags +faststart "${OUTPUTFILE}-part${counter}.${FILE_EXTENSION}"
    
    ffmpeg $FROM -i "$INPUTFILE" $TO -c copy -avoid_negative_ts 1 -movflags +faststart "${OUTPUTFILE}-part${counter}.${FILE_EXTENSION}"
    PARTFILES=(${PARTFILES[@]} "${OUTPUTFILE}-part${counter}.${FILE_EXTENSION}")
    ((counter++)) || true # *facepalm*
  done
  
  if [[ "x${PARTFILES[1]}" = "x" ]]; then
    echo "just moving the file"
    mv "${PARTFILES[0]}" "${OUTPUTFILE}.${FILE_EXTENSION}"
  else
    echo ffmpeg -f concat -i "$(for f in ${PARTFILES[@]} ; do echo -n "$f," ; done)" -c copy -movflags +faststart "${OUTPUTFILE}.${FILE_EXTENSION}"
    ffmpeg -f concat -i <(for f in ${PARTFILES[@]} ; do echo "file '$PWD/$f'" ; done) -c copy -movflags +faststart "${OUTPUTFILE}.${FILE_EXTENSION}" &>/dev/null
    rm "${PARTFILES[@]}"
  fi
  
}

INPUTFILE="$1"

for action in "" "do" ; do
  OUTPUTFILE=""
  CUTLIST=()
  while IFS='' read -u 10 -r i ; do
    if egrep -Eq "^\S+:\s*\$" <<< "$i" ; then
      # $i is a new filename or empty
      if [[ "x$OUTPUTFILE" != "x" && "x$action" = "xdo" ]]; then
        run_ffmpeg "$INPUTFILE" "$OUTPUTFILE" "${CUTLIST[@]}"
      fi
      OUTPUTFILE="$(sed -r "s_^(\S+):\s*\$_\1_" <<< "$i")"
      if [[ -e "${OUTPUTFILE}.${FILE_EXTENSION}" ]] || ls "${OUTPUTFILE}"-part*."${FILE_EXTENSION}" &>/dev/null ; then
        echo "Output file '${OUTPUTFILE}.${FILE_EXTENSION}' or '${OUTPUTFILE}-part*.${FILE_EXTENSION}' already exists, exiting." >&2
        exit 1
      fi
      CUTLIST=()
    elif egrep -Eq "^\s+\S*\s*-\s*\S*\s*\$" <<< "$i" ; then
      # $i is a new cut maker
      if [[ "x$OUTPUTFILE" = "x" ]]; then
        echo "cutlists before output filename given? '$i'" >&2
        exit 1
      fi
      FROM="$(timecode_to_int "$(sed -r "s_^\s+(\S*)\s*-\s*(\S*)\s*\$_\1_" <<< "$i")")"
      TO="$(timecode_to_int "$(sed -r "s_^\s+(\S*)\s*-\s*(\S*)\s*\$_\2_" <<< "$i")")"
      if [[ -n "$FROM" && -n "$TO" && $((${TO}-${FROM})) -le 0 ]]; then
        echo "Negative timespan: '$i', aborting." >&2
        exit 1
      fi
      
      CUTLIST=(${CUTLIST[@]} "${FROM}-${TO}")
      
    elif egrep -Eq "^\s*\$" <<< "$i" ; then
      true # whitespace line
    else
      echo "Invalid syntax: '$i'" >&2
      exit 1
    fi
  done 10< "$2"
  if [[ "x$action" = "xdo" ]]; then
    run_ffmpeg "$INPUTFILE" "$OUTPUTFILE" "${CUTLIST[@]}"
  fi
done
