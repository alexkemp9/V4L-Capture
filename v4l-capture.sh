#!/bin/bash
#
# Encode/transcode a video - see http://linuxtv.org/wiki/index.php/V4L_capturing
#
# Approximate system requirements for the default settings:
# * about 10GB disk space for every hour of the initial recording
# * about 1-2GB disk space for every hour of transcoded recordings
# * dual 1.5GHz processor
#
# V4L Capture Script - encode and transcode video
# Written between 2015 and 2020 by Andrew Sayers <v4l-capture-script@pileofstuff.org>
# To the extent possible under law, the author(s) have dedicated all copyright and related and neighboring rights to this software to the public domain worldwide. This software is distributed without any warranty.
# You should have received a copy of the CC0 Public Domain Dedication along with this software. If not, see <http://creativecommons.org/publicdomain/zero/1.0/>.

HELP_MESSAGE="Usage: $0 --init
       $0 --profile
       $0 --encode <directory> [duration]
       $0 --review <directory>

Record a video into a directory (one directory per video).

    --init      create an initial ~/.v4l-capturerc
                please edit this file before your first recording

    --profile   update ~/.v4l-capturerc with your system's default noise profile
                pause a tape or tune to a silent channel for the best profile

    --encode    create a faithful recording in the specified directory
                Specify a duration to finish recording after that amount of time

    --review    play a special copy of the video, designed to help find segment boundaries
                (you can run this from a second window while encoding)

Once you've encoded a file, the script in the same directory will explain how to transcode.
"

CONFIGURATION='#
# CONFIGURATION FOR V4L CAPTURE SCRIPT
# See http://linuxtv.org/wiki/index.php/V4L_capturing
#

#
# VARIABLES YOU NEED TO EDIT
# See the wiki page for details about finding these values
#

# Set these based on your hardware/location:
TV_NORM="PAL" # (search Wikipedia for the exact norm in your country)

AUDIO_DEVICE="hw:CARD=usbtv,DEV=0"

VIDEO_DEVICE="/dev/video0"
VIDEO_INPUT="1"
VIDEO_CONTROLS="brightness=128,contrast=64,saturation=64,hue=0"

# PAL video is approximately 720x576 resolution.  VHS tapes have about half the horizontal quality, but this post convinced me to encode at 720x576 anyway:
# http://forum.videohelp.com/threads/215570-Sensible-resolution-for-VHS-captures?p=1244415#post1244415
VIDEO_CAPABILITIES="video/x-raw, format=UYVY, framerate=25/1, width=720, height=576"
AUDIO_CAPABILITIES="audio/x-raw, rate=32000, channels=2"

# Encode settings:
ENCODE_VIDEO_FORMAT="libx264"
ENCODE_AUDIO_FORMAT="flac"
ENCODE_MUXER_FORMAT="matroska"
ENCODE_VIDEO_OPTIONS="-preset ultrafast -x264opts crf=18:keyint=50:min-keyint=5 -pix_fmt yuv420p" # change "18" to "0" for true lossless video
ENCODE_AUDIO_OPTIONS=""
ENCODE_MUXER_OPTIONS=""
ENCODE_EXTENSION="mkv"

# Transcode settings:
TRANSCODE_VIDEO_FORMAT="libx264"
TRANSCODE_AUDIO_FORMAT="libmp3lame"
TRANSCODE_MUXER_FORMAT="matroska"
TRANSCODE_VIDEO_OPTIONS="-flags +ilme+ildct -preset veryslow -crf 22 -pix_fmt yuv420p" # increase/decrease "22" for smaller files/better quality
TRANSCODE_AUDIO_OPTIONS="-b:a 256k" # for some reason, ffmpeg desyncs audio and video if "-q:a" is used instead of "-b:a"
TRANSCODE_MUXER_OPTIONS=""

#
# COMMON TRANSCODE SETTINGS
#

# For systems that do not automatically handle audio/video initialisation times:
DEFAULT_AUDIO_DELAY="0"

# Reducing noise:
DEFAULT_NOISE_REDUCTION="0.21"

# remove overscan:
DEFAULT_VIDEO_FILTERS="crop=(iw-10):(ih-14):3:0, pad=iw+10:ih+14:(ow-iw)/2:(oh-ih)/2"

# make all files are about as loud as each other (note: this filter uses sox instead of ffmpeg - see the man page for details):
DEFAULT_AUDIO_FILTERS="norm -1"

# Once you have set the above, record a silent source (e.g. a paused tape or silent TV channel)
# then call '"$0"' --profile to build a default noise profile
DEFAULT_NOISE_PROFILE=""
'

#
# CONFIGURATION SECTION
#

CONFIG_SCRIPT="$HOME/.v4l-capturerc"
[ -e "$CONFIG_SCRIPT" ] && source "$CONFIG_SCRIPT"

#
# OPTIONS FOR THE webm FILE:
# Detects several events that should help find segment boundaries
#

ENCODE_WEBM_VIDEO_OPTS="-crf 10 -b:v 512K -cpu-used 16 -g 20"
ENCODE_WEBM_AUDIO_OPTS=

# build the main image:
ENCODE_WEBM_FILTER_MAIN_IMAGE="
[0:v]
 crop=(iw-14):(ih-14):7:0,
 blackdetect=d=0.4,
 cropdetect=limit=14:round=16:reset=1,
 scale=352:(ih*352/iw),
 drawtext=text='%{pts\\:hms}': x=50: y=main_h-50: fontsize=24: fontcolor=white: borderw=3,
 pad=360:(ih+(ih*72/iw)+100):(ow-iw)/2,
 setpts=PREV_INPTS,
 setpts=PREV_INPTS [main_image]
"
# detect silence:
ENCODE_WEBM_FILTER_DETECT_SILENCE="[0:a] silencedetect=d=2:n=-25dB; [0:a] asplit=1 [wa]"

# build the waveform.  This visualisation doesn't let us align waveforms precisely to frames, so we cheat:
# pick a ridiculously high framerate, knowing all but the closest one to a video frame will be thrown away,
# then duplicate frame contents into nearby frames so whichever frames are picked contain about a video frame's worth of data
ENCODE_WEBM_FILTER_WAVEFORM_IMAGES=4 # reduce this number to save a little CPU during encoding
ENCODE_WEBM_FILTER_WAVEFORM="
[0:a] showwaves=s=$(( 72 / ENCODE_WEBM_FILTER_WAVEFORM_IMAGES ))x100:rate=$(( 25 * ENCODE_WEBM_FILTER_WAVEFORM_IMAGES )), split [waveform0][waveform1];
[waveform0] pad=72:ih [waveforms0];
$(
  for (( IMAGE=1; IMAGE < ENCODE_WEBM_FILTER_WAVEFORM_IMAGES-1; ++IMAGE ))
  do echo "[waveform$IMAGE] setpts=PREV_INPTS, split [waveform+$IMAGE][waveform$((IMAGE+1))]; [waveforms$((IMAGE-1))][waveform+$IMAGE] overlay=overlay_w*$IMAGE [waveforms$((IMAGE))];"
done )
[waveform$((ENCODE_WEBM_FILTER_WAVEFORM_IMAGES-1))]
 setpts=PREV_INPTS [waveform+$((ENCODE_WEBM_FILTER_WAVEFORM_IMAGES-1))];
 [waveforms$((ENCODE_WEBM_FILTER_WAVEFORM_IMAGES-2))][waveform+$((ENCODE_WEBM_FILTER_WAVEFORM_IMAGES-1))] overlay=overlay_w*$((ENCODE_WEBM_FILTER_WAVEFORM_IMAGES-1)) [waveform]
"

# build the small image:
ENCODE_WEBM_FILTER_SMALL_IMAGE="[0:v] scale=72:(ih*72/iw), pad=72:ih+100 [small_image]"

# combine image and waveform into film strip view:
ENCODE_WEBM_FILTER_FILM_STRIP="
[small_image][waveform] overlay=0:(main_h-overlay_h) [film_strip+0];
[film_strip+0]                    split [film_strip+1][to_combine+0]; [main_image][to_combine+0] overlay=72*0:(main_h-overlay_h) [combined+0];
[film_strip+1] setpts=PREV_INPTS, split [film_strip+2][to_combine+1]; [combined+0][to_combine+1] overlay=72*1:(main_h-overlay_h) [combined+1];
[film_strip+2] setpts=PREV_INPTS, split [film_strip+3][to_combine+2]; [combined+1][to_combine+2] overlay=72*2:(main_h-overlay_h) [combined+2];
[film_strip+3] setpts=PREV_INPTS, split [film_strip+4][to_combine+3]; [combined+2][to_combine+3] overlay=72*3:(main_h-overlay_h) [combined+3];
[film_strip+4] setpts=PREV_INPTS, split [film_strip+5][to_combine+4]; [combined+3][to_combine+4] overlay=72*4:(main_h-overlay_h) [combined+4];
[film_strip+5] setpts=PREV_INPTS                      [to_combine+5]; [combined+4][to_combine+5] overlay=72*5:(main_h-overlay_h) [wv]
"

ENCODE_WEBM_FILTER="
$ENCODE_WEBM_FILTER_MAIN_IMAGE;
$ENCODE_WEBM_FILTER_DETECT_SILENCE;
$ENCODE_WEBM_FILTER_WAVEFORM;
$ENCODE_WEBM_FILTER_SMALL_IMAGE;
$ENCODE_WEBM_FILTER_FILM_STRIP
"

#
# UTILITY FUNCTIONS
# You should only need to edit these if you're making significant changes to the way the script works
#

pluralise() {
    case "$1" in
        ""|0) return
            ;;
        1) echo "$1 $2, "
            ;;
        *) echo "$1 ${2}s, "
            ;;
    esac
}

timed_progress() {
    PADDING="$( echo -n "$MESSAGE" | tr -c '' ' ' )"
    CURRENT_TIME_MS="$2"
    TIME_REMAINING="$(( ( $(date +%s) - $START_TIME ) * ( $TOTAL_TIME_MS - $CURRENT_TIME_MS ) / $CURRENT_TIME_MS ))"
    HOURS_REMAINING=$(( $TIME_REMAINING / 3600 ))
    MINUTES_REMAINING=$(( ( $TIME_REMAINING - $HOURS_REMAINING*3600 ) / 60 ))
    SECONDS_REMAINING=$((   $TIME_REMAINING - $HOURS_REMAINING*3600 - $MINUTES_REMAINING*60 ))
    HOURS_REMAINING="$(   pluralise   $HOURS_REMAINING hour   )"
    MINUTES_REMAINING="$( pluralise $MINUTES_REMAINING minute )"
    SECONDS_REMAINING="$( pluralise $SECONDS_REMAINING second )"
    MESSAGE_REMAINING="$( echo "$HOURS_REMAINING$MINUTES_REMAINING$SECONDS_REMAINING" | sed -e 's/, $//' -e 's/\(.*\),/\1 and/' )"
    MESSAGE="$1 $(( 100 * CURRENT_TIME_MS / TOTAL_TIME_MS ))% ETA: $( date +%X -d "$TIME_REMAINING seconds" ) (about $MESSAGE_REMAINING)"
    MESSAGE="$( date +%c ) $MESSAGE" >&2
    echo -n $'\r'"$PADDING"$'\r'"$MESSAGE" >&2
}

ffmpeg_progress() {

    MESSAGE="$1..."

    echo -n $'\r'"$( date +%c ) $MESSAGE" >&2
    if [ -z "$TOTAL_TIME_MS" -o "$TOTAL_TIME_MS" = 0 ]
    then
        while IFS== read PARAMETER VALUE
        do
            if [ "$PARAMETER" = out_time ]
            then
                PADDING="$( echo -n "$MESSAGE" | tr -c '' ' ' )"
                MESSAGE="$( date +%c ) $1 ${VALUE/%???????/}" >&2
                echo -n $'\r'"$PADDING"$'\r'"$MESSAGE" >&2
            elif [ "$PARAMETER" = progress -a "$VALUE" = end ]
            then
                echo -n $'\r'"$( echo -n "$MESSAGE" | tr -c '' ' ' )"$'\r' >&2
                return
            fi
        done
    else
        while IFS== read PARAMETER VALUE
        do
            if [ "$PARAMETER" = out_time_ms ] && [ -n "$VALUE" -a "$VALUE" != 0 ]
            then
                timed_progress "$1" "$VALUE"
            elif [ "$PARAMETER" = progress -a "$VALUE" = end ]
            then
                echo -n $'\r'"$( echo -n "$MESSAGE" | tr -c '' ' ' )"$'\r' >&2
                return
            fi
        done
    fi

}

sox_progress() {

    MESSAGE="$1..."

    echo -n $'\r'"$( date +%c ) $MESSAGE" >&2
    read -d $'\r'
    while read -d $'\r' PERCENT TIME EXTRA
    do
        if [ "$TIME" = "00:00:00.00" ]
        then
            echo -n $'\r'"$( echo -n "$MESSAGE" | tr -c '' ' ' )"$'\r' >&2
        elif [ -n "$TIME" ]
        then
            timed_progress "$1" "$( parse_time "$TIME" )000"
        fi
    done
}

# convert 00:00:00.000 to a count in milliseconds
parse_time() {
    echo $((
        $(date -d "1970-01-01T${1}Z" +%s )*1000
        + $(
            echo "$1" | sed \
                -e 's/.*\.\([0-9]\)$/\100/' \
                -e 's/.*\.\([0-9][0-9]\)$/\10/' \
                -e 's/.*\.\([0-9][0-9][0-9]\)$/\1/' \
                -e '/^[0-9][0-9][0-9]$/! s/.*/0/' \
                -e 's/^0*\([0-9]\)/\1/'
        )
    ))
}

ms_to_s() {
    case "$1" in
        .  ) echo ".00$1" ;;
        .. ) echo ".0$1" ;;
        ...) echo ".$1" ;;
        *  ) echo "$1" | sed -e 's/\(.*\)\(...\)$/\1.\2/'
    esac
}

# get the full name of the script's directory
set_directory() {
    if [ -z "$1" ]
    then
        echo "$HELP_MESSAGE"
        exit 1
    else
        DIRECTORY="$( readlink -f "$1" )"
        FILE="$DIRECTORY/$( basename "$DIRECTORY" )"
    fi
}

# actual commands that do something interesting:
CMD_GST="gst-launch-1.0"
CMD_FFMPEG="nice -n +20 ffmpeg -loglevel 23"
CMD_FFPLAY="ffplay"
CMD_SOX="nice -n +20 sox"
CMD_MPV="mpv"

#
# MAIN LOOP
#

case "$1" in

    -i|--i|--in|--ini|--init)
        if [ -e "$CONFIG_SCRIPT" ]
        then
            echo "Please delete $CONFIG_SCRIPT if you want to recreate it"
        else
            echo "$CONFIGURATION" > "$CONFIG_SCRIPT"
            echo "Now edit $( tput setaf 4 )$CONFIG_SCRIPT$( tput sgr0 ) to match your system"
        fi
    ;;

    -p|--p|--pr|--pro|--prof|--profi|--profil|--profile)
        sed -i "$CONFIG_SCRIPT" -e '/^DEFAULT_NOISE_PROFILE=.*/d'
        echo "DEFAULT_NOISE_PROFILE='$( "$CMD_GST" -q alsasrc device="$AUDIO_DEVICE" ! wavenc ! fdsink | $CMD_SOX -t wav - -n trim 0 1 noiseprof | tr '\n' '\t' )'" >> "$CONFIG_SCRIPT"
        echo "Updated $CONFIG_SCRIPT with default noise profile"
    ;;

    -e|--e|--en|--enc|--enco|--encod|--encode)

        # Build a pipeline with sources being encoded as MPEG4 video and FLAC audio, then being muxed into a Matroska container.
        # FLAC and Matroska are used during encoding to ensure we don't lose much data between passes

        set_directory "$2"
        mkdir -p -- "$DIRECTORY" || exit

        if [ -z "$3" ]
        then
            DURATION_OPTIONS=
            TOTAL_TIME_MS=
        else
            DURATION_OPTIONS="-t $3"
            TOTAL_TIME_MS="$( parse_time "$3" )000"
        fi

        if [ -e "$FILE.$ENCODE_EXTENSION" ]
        then
            echo "Please delete the old $FILE.$ENCODE_EXTENSION before making a new recording"
            exit 1
        fi

        cat <<EOF > "$FILE.sh"
#!$0 --transcode
#
# The original $( basename "$FILE" ).$ENCODE_EXTENSION accurately represents the source.
# If you would like to get rid of imperfections in the source (e.g.
# splitting it into segments), edit then run this file.

#
# ORIGINAL FILE
#
# This is the original file:
original "$( basename "$FILE" ).$ENCODE_EXTENSION"


#
# AUDIO DELAY
#
# If you need to manually synchronise audio and video,
# set this to the duration in seconds (can be fractional):
#
audio_delay ${AUDIO_DELAY:-0.0}


#
# SYSTEM NOISE REDUCTION
#
# Your system will add a small amount of noise to any recording.
# You can undo this by specifying the amount of noise reduction
# (the default value is usually fine), and can optionally specify
# a time in the video to use for the noise profile.

# Uncomment the following line if you have configured a default
# noise profile with \`--profile\`:
#reduce_noise $DEFAULT_NOISE_REDUCTION

# If this video starts with silence, you can use that instead of
# the default noise profile.
#reduce_noise $DEFAULT_NOISE_REDUCTION 00:00:00-00:00:01

# Uncomment the following line to disable noise reduction:
#no_reduce_noise


#
# LOCAL SETTINGS
#
# You might want to override some settings, for example to filter
# videos based on the quality of this specific source.
#

TRANSCODE_VIDEO_FILTERS="$DEFAULT_VIDEO_FILTERS"

# See https://ffmpeg.org/ffmpeg-filters.html for information,
# Here are some examples - remove the leading '#' to make one work:

# lightly denoise a video - useful for good-quality VHS tapes:
#TRANSCODE_VIDEO_FILTERS="il=d:d:d, pp=tn, hqdn3d, il=i:i:i, $DEFAULT_VIDEO_FILTERS"
# significantly denoise interlaced video - useful for poor-quality VHS tapes:
#TRANSCODE_VIDEO_FILTERS="il=d:d:d, pp=tn, hqdn3d=luma_spatial=6:2:luma_tmp=20, il=i:i:i, $DEFAULT_VIDEO_FILTERS"
# significantly reduce "snow" (video noise) - not yet released as of ffmpeg 2.7:
#TRANSCODE_VIDEO_FILTERS="il=d:d:d, removegrain=9:0:0:0, pp=tn, il=i:i:i, $DEFAULT_VIDEO_FILTERS"

# Halve the picture size after applying all other video filters:
#TRANSCODE_VIDEO_FILTERS="\$TRANSCODE_VIDEO_FILTERS,scale=in_w/2:in_h/2"

# VHS LP recordings produce tape hiss above about 4KHz.
# This adds an audio filter to silence all noise above that range with minimal effect below it:
#TRANSCODE_AUDIO_FREQUENCY_RANGE="0 4000"
# add any other filters you like:
TRANSCODE_AUDIO_FILTERS="$DEFAULT_AUDIO_FILTERS"


#
# SEGMENTS
#
# You can split a video into one or more files.  To create a segment,
# add a line like this:
#
# segment "name of output file.avi" start-end start-end ...
#
# each "start-end" block specifies part of the file used in the segment.
# You can use this to e.g. split adverts out of a TV program
#

# Here are some examples - remove the leading '#' to make one work:

# create a file from the whole file:
#segment "videos/$( basename "$FILE" ).mkv"

# remove ad breaks from a half-hour program:
#segment "videos/$( basename "$FILE" ).mkv" 00:00:30-00:15:00 00:19:00-00:28:00

# split into two parts just over and hour:
#segment "videos/$( basename "$FILE" ) part 1.mkv" 00:00:00-01:00:05
#segment "videos/$( basename "$FILE" ) part 2.mkv" 00:59:55-01:00:05

# Advanced examples:
#
# show what a segment would look like with your video filters:
#play_segment "videos/$( basename "$FILE" ).mkv" 00:01:00-00:02:00
# build the audio and metadata files for a segment, but not the video:
#prepare_segment "videos/$( basename "$FILE" ) part 1.mkv" 00:01:00-00:02:00


# Create a playlist with all the segments above
# (adding multiple playlists will create 
playlist "$( basename "$FILE" ).m3u"
EOF
        chmod 755 "$FILE.sh"

        [ -n "$VIDEO_INPUT"    ] && v4l2-ctl --device="$VIDEO_DEVICE" --set-input "$VIDEO_INPUT" > >( grep -v '^Video input set to' )
        [ -n "$VIDEO_CONTROLS" ] && v4l2-ctl --device="$VIDEO_DEVICE" --set-ctrl "$VIDEO_CONTROLS"

        SUBTITLE_ID=1
        format_subtitle() {
            START="$( date -u +"%H:%M:%S,${1/*./}" -d @$1 )"
            END="$(   date -u +"%H:%M:%S,${2/*./}" -d @$2 )"
            MESSAGE="$3"
            echo "$((SUBTITLE_ID++))"
            echo "$START --> $END"
            echo "$MESSAGE"
            echo
        }

        process_ffmpeg_output() {
            sed -un \
                -e 's/.*Parsed_cropdetect.*t:0*\([0-9.]*\) crop=[-0-9]*:\([0-9]*\).*/crop \1 \2/p' \
                -e 's/.*silencedetect .* silence_start: \(.*\)$/silence_start \1/p' \
                -e 's/.*silencedetect .* silence_end: \([0-9.]*\).*/silence_end \1/p' \
                -e 's/.*blackdetect .* black_start:\([0-9.]*\) black_end:\([0-9.]*\).*/black \1 \2/p' \
                | {
                    format_subtitle 0 10 "Subtitles indicate possible ad breaks."
                    declare -A CROPS=()
                    CROP_START_TIME=0
                    CROP_END_TIME=0
                    CROP_COUNT=0
                    OLD_CROP=
                    while read MESSAGE_TYPE ARG1 ARG2
                    do
                        case "$MESSAGE_TYPE" in
                            silence_start)
                                if [ "${ARG1:0:1}" = "-" ]
                                then SILENCE_START="0"
                                else SILENCE_START="$ARG1"
                                fi
                                ;;
                            silence_end)
                                format_subtitle "$SILENCE_START" "$ARG1" "silence"
                                ;;
                            black)
                                format_subtitle "$ARG1" "$ARG2" "darkness"
                                ;;
                            crop) # need some more complex logic to build a useful message
                                if [ $(( ++CROP_COUNT )) -gt 250 ]
                                then
                                    MOST_FREQUENT=
                                    MOST_FREQUENCY=0
                                    for CROP in "${!CROPS[@]}"
                                    do
                                        if [ "${CROPS[$CROP]}" -gt "$MOST_FREQUENCY" ]
                                        then
                                            MOST_FREQUENT="${CROP:1}"
                                            MOST_FREQUENCY="${CROPS[$CROP]}"
                                        fi
                                    done
                                    if [ "$OLD_CROP" != "$MOST_FREQUENT" ]
                                    then
                                        if [ -n "$OLD_CROP" ]
                                        then
                                            CROP_MESSAGE="$( echo "$OLD_CROP" | sed -e 's/:/x/' -e 's/:/+/g' )"
                                            format_subtitle "$CROP_START_TIME" "$CROP_END_TIME" "image is $CROP_MESSAGE pixels high"
                                        fi
                                        CROP_START_TIME="$CROP_END_TIME"
                                    fi
                                    CROP_END_TIME="$ARG1"
                                    declare -A CROPS=()
                                    CROP_COUNT=0
                                    OLD_CROP="$MOST_FREQUENT"
                                fi
                                CROPS["x$ARG2"]="$(( CROPS["x$ARG2"] + 1 ))"
                                ;;
                        esac
                    done
                } > "$FILE.txt"
        }

        date +"%c $( tput setaf 4 )$FILE$( tput sgr0 ) started"
        START_TIME="$( date +%s )"
        # Encoding command:
        $CMD_FFMPEG \
            \
            -loglevel 32 \
            \
            $DURATION_OPTIONS \
            \
            -i <(
                $CMD_GST -q \
                    v4l2src device="$VIDEO_DEVICE" do-timestamp=true norm="$TV_NORM" pixel-aspect-ratio=1 \
                        ! $VIDEO_CAPABILITIES \
                        ! queue max-size-buffers=0 max-size-time=0 max-size-bytes=0 \
                        ! mux. \
                    alsasrc device="$AUDIO_DEVICE" do-timestamp=true \
                        ! $AUDIO_CAPABILITIES \
                        ! queue max-size-buffers=0 max-size-time=0 max-size-bytes=0 \
                        ! mux. \
                    matroskamux name=mux \
                        ! queue max-size-buffers=0 max-size-time=0 max-size-bytes=0 \
                        ! fdsink fd=1
            ) \
            \
            -filter_complex "$ENCODE_WEBM_FILTER" \
            \
            -c:v "$ENCODE_VIDEO_FORMAT" $ENCODE_VIDEO_OPTIONS \
            -c:a "$ENCODE_AUDIO_FORMAT" $ENCODE_AUDIO_OPTIONS \
            -f   "$ENCODE_MUXER_FORMAT" $ENCODE_MUXER_OPTIONS \
            "file:$FILE.$ENCODE_EXTENSION" \
            \
            -map [wv] -c:v libvpx    $ENCODE_WEBM_VIDEO_OPTS \
            -map [wa] -c:a libvorbis $ENCODE_WEBM_AUDIO_OPTS \
            -f webm \
            "file:$FILE.webm" \
            \
            -progress >( ffmpeg_progress "$( tput setaf 4 )$FILE$( tput sgr0 )" ) \
            \
            2> >( process_ffmpeg_output )

        echo >&2
        date +"%c $FILE.$ENCODE_EXTENSION finished"

        echo "Now see $( tput setaf 4 )$FILE.sh$( tput sgr0 )"
    ;;

    -r|--r|--re|--rev|--revi|--revie|--review)
        set_directory "$2"
        [ -d "$DIRECTORY/mpv-config" ] || mkdir "$DIRECTORY/mpv-config"

        cat > "$DIRECTORY/mpv-config/input.conf" <<END
Shift+MOUSE_BTN3 frame_step
Shift+MOUSE_BTN4 frame_back_step

Ctrl+Shift+MOUSE_BTN3 seek  0.5
Ctrl+Shift+MOUSE_BTN4 seek -0.5

MOUSE_BTN3 seek  5
MOUSE_BTN4 seek -5

Ctrl+MOUSE_BTN3 seek  200 - exact
Ctrl+MOUSE_BTN4 seek -200 - exact

Alt+MOUSE_BTN3 sub_seek  1
Alt+MOUSE_BTN4 sub_seek -1

END

        PREV_TIME=
        # Review command:
        $CMD_MPV --keep-open --ontop --pause --config-dir="$DIRECTORY/mpv-config" --term-status-msg 'TIME ${=time-pos}'$'\n' "$FILE.webm" 2>&1 | \
            while read TITLE TIME
            do
                if [ "$TITLE" = "TIME" -a "$TIME" != "$PREV_TIME" ]
                then
                    PREV_TIME="$TIME"
                    TIME="$( date --utc +"%H:%M:%S.${TIME/*./}" -d "@$TIME" )"
                    TIME="${TIME%000}"
                    echo -n "$TIME" | xclip
                fi
            done

        rm -rf "$DIRECTORY/mpv-config"
        ;;

    --transcode)

        # we use ffmpeg and sox here, as they have better tools

        HAVE_CREATED_SEGMENTS=
        PLAYLIST=$'#EXTM3U\n'

        HAVE_NOISE_PROFILE=true

        AUDIO_BITRATE="$( echo "$AUDIO_CAPABILITIES" | sed -ne 's/.*rate=\([0-9]*\).*/\1/p' )"
        if [ -z "$AUDIO_BITRATE" ]
        then
            echo "Please specify a rate in AUDIO_CAPABILITIES"
            exit
        fi

        original() {
            ORIGINAL="$1"
            ORIGINAL_METADATA="$(
                $CMD_FFMPEG -i "file:$ORIGINAL" -f ffmetadata - < /dev/null
                date -u +"DATE_DIGITIZED=%Y-%m-%d %H:%M:%S.000" -d @$( stat -c %Y "$ORIGINAL" )
            )"
        }

        no_reduce_noise() {
            NOISE_PROFILE=
            HAVE_NOISE_PROFILE=true
        }

        reduce_noise() {
            NOISE_REDUCTION="$1"
            NOISE_TIME="$2"
            if [ -z "$NOISE_REDUCTION" ]
            then
                echo "Please specify a noise reduction amount"
                exit 1
            fi
            if [ -z "$NOISE_TIME" ]
            then
                if [ -z "$DEFAULT_NOISE_PROFILE" ]
                then
                    cat <<END
Please specify a default noise profile.

Pause a tape (so only background noise is playing) then run:

	$0 --profile

This will save information about the background noise.

END
                    exit 1
                else
                    NOISE_PROFILE="$( echo "$DEFAULT_NOISE_PROFILE" | tr '\t' '\n' )"
                fi
            else
                NOISE_PROFILE="$( $CMD_FFMPEG -ss "${NOISE_TIME/-*/}" -i "file:$ORIGINAL" -t "${NOISE_TIME/*-/}" -vn -c:a pcm_s16le -f wav - | $CMD_SOX -t wav - -n noiseprof 2>/dev/null )"
            fi
            HAVE_NOISE_PROFILE=true
        }

        audio_delay() {
            if [[ "$1" =~ ^[0.]*$ ]]
            then AUDIO_DELAY=
            else AUDIO_DELAY="$1"
            fi
        }

        calculate_segment() {
            # Calculate segment options:
            if [ -z "$1" ]
            then
                SEGMENT_START_OPTS=
                SEGMENT_END_OPTS=
                CHAPTER_METADATA=
                VIDEO_FILTER_SPLIT=
                VIDEO_FILTER_LIST='[0:v]'
                AUDIO_FILTER_SPLIT=
                AUDIO_FILTER_LIST='[0:a]'
                CHAPTER_NUMBER=1
            else
                SEGMENT_START="${1/-*/}"
                CHAPTER_END="${1/*-/}"
                SEGMENT_START_MS="$( parse_time "$SEGMENT_START" )"
                SEGMENT_START_OPTS="-ss $SEGMENT_START"
                shift

                CHAPTER_END_MS="$(( $( parse_time "$CHAPTER_END" ) - SEGMENT_START_MS ))";
                TOTAL_TIME_MS="$CHAPTER_END_MS"
                CHAPTER_END_S="$( ms_to_s "$CHAPTER_END_MS" )";
                VIDEO_FILTER_SPLIT="[0:v] trim=end=$CHAPTER_END_S [v0]"
                AUDIO_FILTER_SPLIT="[0:a] atrim=end=$CHAPTER_END_S [a0]"
                VIDEO_FILTER_LIST="[v0] ";
                AUDIO_FILTER_LIST="[a0] ";
                CHAPTER_NUMBER=1
                if [ -z "$*" ]
                then CHAPTER_TITLE="$SEGMENT_TITLE"
                else CHAPTER_TITLE="Chapter $CHAPTER_NUMBER"
                fi
                CHAPTER_METADATA="[CHAPTER]
TIMEBASE=1/1000000000
START=0
END=${TOTAL_TIME_MS}000000
title=$CHAPTER_TITLE
"
                for CHAPTER in "$@"
                do
                    CHAPTER_START_MS="$(( $( parse_time "${CHAPTER/-*/}" ) - SEGMENT_START_MS ))";
                    CHAPTER_START_S="$( ms_to_s "$CHAPTER_START_MS" )";
                    CHAPTER_END_MS="$((   $( parse_time "${CHAPTER/*-/}" ) - SEGMENT_START_MS ))";
                    CHAPTER_END_S="$(   ms_to_s "$CHAPTER_END_MS" )";
                    VIDEO_FILTER_SPLIT="$VIDEO_FILTER_SPLIT ;
[0:v] trim=start=$CHAPTER_START_S:end=$CHAPTER_END_S,    setpts=PTS-STARTPTS [v$CHAPTER_NUMBER]"
                    AUDIO_FILTER_SPLIT="$AUDIO_FILTER_SPLIT ;
[0:a] atrim=start=$CHAPTER_START_S:end=$CHAPTER_END_S,    asetpts=PTS-STARTPTS [a$CHAPTER_NUMBER]"
                    VIDEO_FILTER_LIST="$VIDEO_FILTER_LIST[v$CHAPTER_NUMBER] ";
                    AUDIO_FILTER_LIST="$AUDIO_FILTER_LIST[a$CHAPTER_NUMBER] ";
                    CHAPTER_NUMBER="$(( CHAPTER_NUMBER + 1 ))"
                    CHAPTER_METADATA="${CHAPTER_METADATA}[CHAPTER]
TIMEBASE=1/1000000000
START=${TOTAL_TIME_MS}000000
END=$(( TOTAL_TIME_MS + CHAPTER_END_MS - CHAPTER_START_MS ))000000
title=Chapter $CHAPTER_NUMBER
"
                    TOTAL_TIME_MS="$(( TOTAL_TIME_MS + CHAPTER_END_MS - CHAPTER_START_MS ))"
                done

                TOTAL_TIME_MS="${TOTAL_TIME_MS}000" # microseconds -> milliseconds
            fi

            if [ -z "$TRANSCODE_VIDEO_FILTERS" ]
            then VIDEO_FILTER="$VIDEO_FILTER_SPLIT ;
${VIDEO_FILTER_LIST}concat=n=$CHAPTER_NUMBER [video]"
            else VIDEO_FILTER="$VIDEO_FILTER_SPLIT ;
${VIDEO_FILTER_LIST}concat=n=$CHAPTER_NUMBER, $TRANSCODE_VIDEO_FILTERS [video]"
            fi
            AUDIO_FILTER="$AUDIO_FILTER_SPLIT ;
${AUDIO_FILTER_LIST}concat=n=$CHAPTER_NUMBER:v=0:a=1 [audio]"
        }

        play_segment() {
            shift
            calculate_segment "$@"
            cat >&2 <<END
Suggested video filters:
END
            echo -n 'measuring...' >&2
            # Segment playback command:
            $CMD_FFPLAY $SEGMENT_START_OPTS -i "$ORIGINAL" -vf "$TRANSCODE_VIDEO_FILTERS, cropdetect=24:2:1500" 2> >(
                sed -une 's/.*t:0*\([0-9]*\)\.\([0-9]*\) \(crop=[0-9:]*\)$/\1\2 \3/p' | {
                    read START_TIME OLD_CROP
                    MESSAGE=
                    while read TIME CROP
                    do
                        DURATION="$(( TIME - START_TIME ))"
                        if [ "$CROP" != "$OLD_CROP" ]
                        then
                            [[ $DURATION -gt 2000000 ]] && echo -n $'\nmeasuring...' >&2
                            OLD_CROP="$CROP"
                            START_TIME="$TIME"
                            MESSAGE=
                            DURATION=0
                        fi
                        if [[ $DURATION -gt 2000000 ]]
                        then
                            echo -n $'\r'"$( echo -n "$MESSAGE" | tr -c '' ' ' )"$'\r' >&2
                            MESSAGE="TRANSCODE_VIDEO_FILTERS=\"$CROP, pad=$SOURCE_WIDTH:$SOURCE_HEIGHT:(ow-iw)/2:(oh-ih)/2\" # (measured good for ${DURATION/%??????/} second(s))"
                            echo -n "$MESSAGE" >&2
                        fi
                    done
                }
            )
            HAVE_CREATED_SEGMENTS=true
        }

        # build the components of a segment, but not the segment itself:
        prepare_segment() {
            PREPARE_SEGMENT=true
            segment "$@"
        }

        # build a segment:
        segment() {
            SEGMENT_FILENAME="$1" ; shift
            SEGMENT_TITLE="$( basename "${SEGMENT_FILENAME/\.*/}" )"
            HAVE_CREATED_SEGMENTS=true

            AUDIO_FILE="temp/$SEGMENT_TITLE.wav"
            METADATA_FILE="temp/$SEGMENT_TITLE.txt"

            if [ -z "$HAVE_NOISE_PROFILE" ]
            then
                echo "Please add a noise profile (for details, search your script for 'noise reduction')"
                exit 1
            fi

            CURRENT_STAGE=1
            STAGE_COUNT=2
            [ -e "$AUDIO_FILE" ] || STAGE_COUNT="$(( STAGE_COUNT + 1 ))"
            case "$SEGMENT_FILENAME" in
                *.mkv)
                    STAGE_COUNT=$(( STAGE_COUNT - 1 ))
                    ;;
                *.*)
                    ;;
                *)
                    echo "$( tput setaf 1 )Error:$( tput sgr0 ) please add a file extension for segment $( tput setaf 4 )$SEGMENT_FILENAME$( tput sgr0 )"
                    exit 1
            esac

            calculate_segment "$@"

            [ "$STAGE_COUNT" -eq 1 ] || date +"%c $( tput setaf 4 )$SEGMENT_FILENAME$( tput sgr0 ) started ($STAGE_COUNT stages)"

            case "$SEGMENT_FILENAME" in
                "$ORIGINAL")
                    echo "Can't create segment '$SEGMENT_FILENAME' - would have the same name as the original file"
                    return 1
                    ;;
                *.mkv)
                    # allow variable frame rate
                    FRAMERATE_OPTS=
                    ;;
                *)
                    START_TIME="$( date +%s )"
                    while IFS== read PARAMETER VALUE
                    do
                        if   [ "$PARAMETER" = frame ]
                        then FRAME=$VALUE
                        else
                            [ "$PARAMETER" = out_time_ms ] && OUT_TIME_MS="$VALUE"
                            echo $PARAMETER=$VALUE
                        fi
                        TOTAL_TIME_MS=$OUT_TIME_MS
                        FRAMERATE_OPTS="-r ${FRAME}000000/$OUT_TIME_MS"
                    done < <( $CMD_FFMPEG $SEGMENT_START_OPTS -i "file:$ORIGINAL" -filter_complex "$VIDEO_FILTER" -map '[video]' -vcodec rawvideo -an -f null /dev/null -progress /dev/stdout < /dev/null ) \
                         > >( ffmpeg_progress "$SEGMENT_FILENAME calculating framerate ($CURRENT_STAGE/$STAGE_COUNT)" )
                    CURRENT_STAGE=$(( CURRENT_STAGE + 1 ))
                    ;;
            esac

            mkdir -p "$( dirname "$SEGMENT_FILENAME" )" temp

            # Build metadata for segment:
            [ -e "$METADATA_FILE" ] || echo -n "$ORIGINAL_METADATA"$'\n'"; To add chapter titles etc., edit the values below then re-run."$'\n'"title=$SEGMENT_TITLE"$'\n'"$CHAPTER_METADATA" > "$METADATA_FILE"

            # Build audio file for segment:
            MESSAGE=
            if [ -e "$AUDIO_FILE" ]
            then
                AUDIO_TIME_MS="$( $CMD_SOX --info -D "$AUDIO_FILE" | sed -e 's/\.//' )"
                if [[ $AUDIO_TIME_MS -gt $TOTAL_TIME_MS ]]
                then
                    AUDIO_OFFSET_MS="$(( AUDIO_TIME_MS - TOTAL_TIME_MS ))"
                    AUDIO_LENGTH_WORD="long"
                    AUDIO_ERROR_SUGGESTION="if you really want your audio to continue past the end of your video, add some periods of black video"
                else
                    AUDIO_OFFSET_MS="$(( TOTAL_TIME_MS - AUDIO_TIME_MS ))"
                    AUDIO_LENGTH_WORD="short"
                    AUDIO_ERROR_SUGGESTION="if you really want silence at the end of your video, add silence to the end of the audio file"
                fi
                if [[ $AUDIO_OFFSET_MS -gt 1000000 ]]
                then
                    echo "$( tput setaf 1 )Error:$( tput sgr0 ) audio file $( tput setaf 4 )${SEGMENT_FILENAME/\.*/}.$( tput setaf 1 )wav$( tput sgr0 ) is ${AUDIO_OFFSET_MS/%??????/} seconds too $AUDIO_LENGTH_WORD"
                    echo "Please fix the problem and try again"
                    echo "  * to rebuild the audio automatically, delete the .wav file and re-run."
                    echo "  * $AUDIO_ERROR_SUGGESTION"
                    echo
                    return
                fi
            else
                START_TIME="$( date +%s )"
                # Step one: calculate audio delay
                case "${AUDIO_DELAY:0:1}X" in # Step two: shift the audio according to the audio delay
                    X)
                        # no audio delay
                        EXTRA_INPUT=
                        DELAY_FILTER=
                        OUT_STREAM="[audio]"
                        ;;
                    -)
                        # negative audio delay - trim start
                        EXTRA_INPUT=
                        DELAY_FILTER="; [audio] atrim=start=${AUDIO_DELAY:1} [trimmed_audio]"
                        OUT_STREAM="[trimmed_audio]"
                        ;;
                    *)
                        # positive audio delay - prepend silence
                        DELAY_FILTER="; aevalsrc=0:s=$AUDIO_BITRATE:c=2:d=$AUDIO_DELAY [padding]; [padding] [audio] concat=v=0:a=1 [padded_audio]"
                        OUT_STREAM="[padded_audio]"
                        ;;
                esac

                SOX_AUDIO_FILTERS="$TRANSCODE_AUDIO_FILTERS" # SOX audio filters transform the input, whereas $AUDIO_FILTER cuts it up
                if [ -n "$TRANSCODE_AUDIO_FREQUENCY_RANGE" ]
                then
                    LOWER_BOUND="${TRANSCODE_AUDIO_FREQUENCY_RANGE/ */}"
                    UPPER_BOUND="${TRANSCODE_AUDIO_FREQUENCY_RANGE/* /}"
                    for (( Hz=0; Hz<$LOWER_BOUND; Hz+=10 ))
                    do SOX_AUDIO_FILTERS="equalizer $Hz 1h -50 $SOX_AUDIO_FILTERS"
                    done
                    if [ "$UPPER_BOUND" -lt $(( AUDIO_BITRATE / 4 )) ]
                    then
                        for (( Hz="$UPPER_BOUND"; Hz<=$UPPER_BOUND+500; Hz+=10 ))
                        do SOX_AUDIO_FILTERS="equalizer $Hz 1h -50 $SOX_AUDIO_FILTERS"
                        done
                        for (( Hz="$UPPER_BOUND"; Hz<=$UPPER_BOUND*2; Hz+=50 ))
                        do SOX_AUDIO_FILTERS="equalizer $Hz 5h -90 $SOX_AUDIO_FILTERS"
                        done
                        for (( Hz="$UPPER_BOUND"*2; Hz<=$(( AUDIO_BITRATE / 2 )); Hz+=100 ))
                        do SOX_AUDIO_FILTERS="equalizer $Hz 10h -120 $SOX_AUDIO_FILTERS"
                        done
                    else
                        for (( Hz="$UPPER_BOUND"; Hz<=$(( AUDIO_BITRATE / 2 )); Hz+=50 ))
                        do SOX_AUDIO_FILTERS="equalizer $Hz 5h -90 $SOX_AUDIO_FILTERS"
                        done
                    fi
                fi

                # Step two: audio extraction command
                START_TIME="$( date +%s )"
                if [ -z "$NOISE_PROFILE" ] # Step three: denoise based on the default noise profile, then normalise audio levels
                then $CMD_SOX --temp "$( dirname "$AUDIO_FILE" )" -S -t wav - "$AUDIO_FILE"                                                                $SOX_AUDIO_FILTERS
                else $CMD_SOX --temp "$( dirname "$AUDIO_FILE" )" -S -t wav - "$AUDIO_FILE" noisered <( echo "$NOISE_PROFILE" ) "${NOISE_REDUCTION:-0.21}" $SOX_AUDIO_FILTERS
                fi \
                    2> >( sox_progress "$( tput setaf 4 )$SEGMENT_FILENAME$( tput sgr0 ) creating audio ($CURRENT_STAGE/$STAGE_COUNT)" ) \
                    < <(
                    $CMD_FFMPEG \
                                $SEGMENT_START_OPTS \
                                -i "file:$ORIGINAL" \
                                -filter_complex "$AUDIO_FILTER$DELAY_FILTER" \
                                -map "$OUT_STREAM" \
                                -vn -f wav -
                    )
                CURRENT_STAGE=$(( CURRENT_STAGE + 1 ))
            fi
            echo -n $'\r'"$( echo -n "$MESSAGE" | tr -c '' ' ' )"$'\r' >&2

            OUT_TIME_S="${OUT_TIME_MS/%??????/}"
            PLAYLIST="$PLAYLIST
#EXTINF:${OUT_TIME_S:-0},$SEGMENT_TITLE
$SEGMENT_FILENAME
"

            if [ -z "$PREPARE_SEGMENT" ]
            then
                if [ -e "$SEGMENT_FILENAME" ]
                then
                    date +"%c: renamed old $( tput setaf 4 )$SEGMENT_FILENAME$( tput sgr0 ) to $( tput setaf 4 )$SEGMENT_FILENAME.old$( tput sgr0 )"
                    mv "$SEGMENT_FILENAME" "$SEGMENT_FILENAME.old"
                fi

                # Build video file for segment:
                START_TIME="$( date +%s )"
                if [ "$STAGE_COUNT" -eq 1 ]
                then STAGE_MESSAGE=
                else STAGE_MESSAGE=" creating video ($CURRENT_STAGE/$STAGE_COUNT)"
                fi

                # Transcoding command:
                $CMD_FFMPEG \
                    \
                    -loglevel 16 \
                    \
                    -progress file://>( ffmpeg_progress "$( tput setaf 4 )$SEGMENT_FILENAME$( tput sgr0 )$STAGE_MESSAGE" ) \
                    \
                    $SEGMENT_START_OPTS -i "file:$ORIGINAL" \
                    -i "file:$AUDIO_FILE" \
                    -i "file:$METADATA_FILE" \
                    \
                    -filter_complex "$VIDEO_FILTER" \
                    \
                    -c:v "$TRANSCODE_VIDEO_FORMAT" $TRANSCODE_VIDEO_OPTIONS \
                    -c:a "$TRANSCODE_AUDIO_FORMAT" $TRANSCODE_AUDIO_OPTIONS \
                    -f   "$TRANSCODE_MUXER_FORMAT" $TRANSCODE_MUXER_OPTIONS \
                    \
                    -map 1:0 -map [video] -map_metadata 2 -map_chapters 2 \
                    -metadata "$( date -u +"DATE_ENCODED=%Y-%m-%d %H:%M:%S.000" )" \
                    $FRAMERATE_OPTS \
                    "file:$SEGMENT_FILENAME" \
                    || exit 1

                sleep 0.1 # quick-and-dirty way to ensure ffmpeg_progress finishes before we print the next line
                date +"%c $( tput setaf 4 )$SEGMENT_FILENAME$( tput sgr0 ) finished"
            fi

            PREPARE_SEGMENT=

        }

        playlist() {
            echo "$PLAYLIST" > "$1"
            PLAYLIST=$'#EXTM3U\n'
            date +"%c $( tput setaf 4 )$1$( tput sgr0 ) created"
        }

        PREPARE_SEGMENT=
        SCRIPT_FILE="$( readlink -f "$2" )"
        cd "$( dirname "$SCRIPT_FILE" )"
        source "$SCRIPT_FILE"

        [ -z "$HAVE_CREATED_SEGMENTS" ] && echo "Please specify at least one segment"

    ;;

    *)
        echo "$HELP_MESSAGE"

esac
