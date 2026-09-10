#!/bin/sh
# swaybar status line for a basic Alpine Linux (busybox) sway setup.
# Uses only /proc, /sys, busybox awk/date/sleep — plus `iw` (apk add iw)
# for the wifi SSID + signal. If you use iwd instead, see the comment below.
#
# Icons are codepoints that exist in Cozette (Nerd Fonts / Material subset):
#    U+F1FE           -> cpu
#    U+E706 (nf-dev)    -> ram
#   直/睊 U+FAA8/FAA9 -> wifi up / down
#   󰁹..󰂄 U+F0079-F0084   -> battery levels / charging
#   📂 U+1F4C2          -> disk (free on /)
#   墳 奔 奄 婢 U+FA7D-FA80 -> volume >50% / 1-50% / 0% / muted
#    U+F7CA           -> headphones plugged in
#   📆 U+1F4C6          -> date
#   🕐..🕧 U+1F550-1F567 -> clock face (nearest half hour), before the time

# find the wireless interface once
wifi_dev=
for d in /sys/class/net/*/wireless; do
    [ -e "$d" ] || continue
    wifi_dev=${d%/wireless}
    wifi_dev=${wifi_dev##*/}
    break
done

prev_total=0
prev_idle=0

# JSON-escape backslashes and quotes (SSIDs can contain them)
esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# i3bar/swaybar JSON protocol: header, then an endless array of block arrays.
# click_events makes swaybar send clicked blocks back to us on stdin.
printf '{"version":1,"click_events":true}\n[\n[]\n'

# click handler: left-clicking the volume block toggles mute
# (the bar picks up the new state on the next tick)
exec 3<&0    # keep a handle on stdin: async jobs may get /dev/null as fd 0
(
    while read -r ev; do
        case "$ev" in
            *'"name":"vol"'*'"button":1'*|*'"button":1'*'"name":"vol"'*)
                pactl set-sink-mute @DEFAULT_SINK@ toggle ;;
        esac
    done
) <&3 &

while :; do
    # --- cpu: delta of /proc/stat between iterations ---
    read -r _ u n s idl iow irq sirq steal _ < /proc/stat
    total=$(( u + n + s + idl + ${iow:-0} + ${irq:-0} + ${sirq:-0} + ${steal:-0} ))
    idle=$(( idl + ${iow:-0} ))
    d_total=$(( total - prev_total ))
    d_idle=$(( idle - prev_idle ))
    cpu=0
    [ "$d_total" -gt 0 ] && cpu=$(( (d_total - d_idle) * 100 / d_total ))
    prev_total=$total
    prev_idle=$idle

    # --- ram: percentage + MB used, from /proc/meminfo ---
    ram=$(awk '/^MemTotal/{t=$2} /^MemAvailable/{a=$2} END{printf "%d%% %dM", (t-a)*100/t, (t-a)/1024}' /proc/meminfo)

    # --- disk: free space on / ---
    disk=$(df -h / | awk 'END{u=$4; sub(/^[0-9.]+/,"",u); printf "%d%s", $4, u}')

    # --- volume: via pactl (apk add pulseaudio-utils; pipewire-pulse works too) ---
    vol=$(pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null | awk '
        match($0, /[0-9]+%/) { print substr($0, RSTART, RLENGTH - 1); exit }')
    [ -n "$vol" ] && [ "$(pactl get-sink-mute @DEFAULT_SINK@ 2>/dev/null)" = "Mute: yes" ] && vol=off

    # headphones: U+F7CA icon when the default sink's active port is a headphone port
    hp=$(pactl list sinks 2>/dev/null | awk -v d="$(pactl get-default-sink 2>/dev/null)" '
        $1 == "Name:" { cur = ($2 == d) }
        cur && /Active Port:/ { if ($3 ~ /headphone/) print "on"; exit }')
    hpicon=
    [ "$hp" = "on" ] && hpicon=" "

    case "$vol" in
        off) vicon=婢; vol="mute" ;;
        "")  vicon=婢; vol="n/a" ;;
        0)   vicon=奄; vol="0%" ;;
        *)   if [ "$vol" -gt 50 ]; then vicon=墳; else vicon=奔; fi
             vol="$vol%" ;;
    esac
    vol_color=
    case "$vol" in mute|n/a) vol_color="#808080" ;; esac

    # --- wifi: SSID + signal via iw (dBm mapped to ~0-100%) ---
    # iwd users: swap the iw call for
    #   iwctl station "$wifi_dev" show
    # and parse the "Connected network" and "RSSI" lines instead.
    wifi="睊 down"
    wifi_color="#808080"           # grey when disconnected
    if [ -n "$wifi_dev" ]; then
        w=$(iw dev "$wifi_dev" link 2>/dev/null | awk -F': ' '
            /SSID:/   { ssid = $2 }
            /signal:/ { split($2, a, " ")
                        s = (a[1] + 100) * 2
                        if (s > 100) s = 100; if (s < 0) s = 0
                        sig = int(s) }
            END { if (ssid != "") printf "%d %s", sig, ssid }')
        if [ -n "$w" ]; then
            sig=${w%% *}
            ssid=${w#* }
            wifi="直 $ssid ${sig}%"
            wifi_color=
            [ "$sig" -lt 40 ] && wifi_color="#f0c674"   # yellow when weak
        fi
    fi

    # --- battery ---
    bat=
    for b in /sys/class/power_supply/BAT*; do
        [ -r "$b/capacity" ] || continue
        cap=$(cat "$b/capacity")
        st=$(cat "$b/status")
        if [ "$st" = "Charging" ]; then
            icon=󰂄
        else
            case $(( cap / 10 )) in
                10) icon=󰁹 ;;
                9)  icon=󰂂 ;;
                8)  icon=󰂁 ;;
                7)  icon=󰂀 ;;
                6)  icon=󰁿 ;;
                5)  icon=󰁾 ;;
                4)  icon=󰁽 ;;
                3)  icon=󰁼 ;;
                2)  icon=󰁻 ;;
                1)  icon=󰁺 ;;
                *)  icon=󰂃 ;;   # <10%: battery-alert
            esac
        fi
        # --- time remaining: energy/power (µWh/µW) or charge/current (µAh/µA) ---
        # units cancel, so minutes = e * 60 / p either way
        rem=
        e=0 p=0
        if [ -r "$b/energy_now" ] && [ -r "$b/power_now" ]; then
            e=$(cat "$b/energy_now"); p=$(cat "$b/power_now")
            [ "$st" = "Charging" ] && [ -r "$b/energy_full" ] && e=$(( $(cat "$b/energy_full") - e ))
        elif [ -r "$b/charge_now" ] && [ -r "$b/current_now" ]; then
            e=$(cat "$b/charge_now"); p=$(cat "$b/current_now")
            [ "$st" = "Charging" ] && [ -r "$b/charge_full" ] && e=$(( $(cat "$b/charge_full") - e ))
        fi
        if [ "$p" -gt 0 ] && { [ "$st" = "Discharging" ] || [ "$st" = "Charging" ]; }; then
            mins=$(( e * 60 / p ))
            rem=$(printf ' %d:%02d' $(( mins / 60 )) $(( mins % 60 )))
        fi

        bat="$icon ${cap}%$rem"
        bat_color=
        bat_urgent=
        if [ "$st" != "Charging" ]; then
            if   [ "$cap" -lt 10 ]; then bat_color="#cc6666"; bat_urgent=1
            elif [ "$cap" -lt 20 ]; then bat_color="#cc6666"
            elif [ "$cap" -lt 40 ]; then bat_color="#f0c674"
            fi
        fi
        break
    done

    # --- date & time: clock-face icon picked by nearest half hour ---
    set -- $(date '+%I %M %d/%m/%Y %H:%M')
    h=${1#0}; m=${2#0}; today=$3; clock=$4
    ock="🕐 🕑 🕒 🕓 🕔 🕕 🕖 🕗 🕘 🕙 🕚 🕛"     # U+1F550-1F55B: 1..12 o'clock
    half="🕜 🕝 🕞 🕟 🕠 🕡 🕢 🕣 🕤 🕥 🕦 🕧"   # U+1F55C-1F567: half past 1..12
    if [ "$m" -lt 15 ]; then       pick=$ock
    elif [ "$m" -lt 45 ]; then     pick=$half
    else h=$(( h % 12 + 1 ));      pick=$ock
    fi
    set -- $pick
    eval "cicon=\${$h}"

    blocks="{\"name\":\"cpu\",\"full_text\":\" ${cpu}%\"}"
    blocks="$blocks,{\"name\":\"ram\",\"full_text\":\" $ram\"}"
    blocks="$blocks,{\"name\":\"disk\",\"full_text\":\"📂 $disk free\"}"
    blocks="$blocks,{\"name\":\"wifi\",\"full_text\":\"$(esc "$wifi")\"${wifi_color:+,\"color\":\"$wifi_color\"}}"
    blocks="$blocks,{\"name\":\"vol\",\"full_text\":\"$hpicon$vicon $vol\"${vol_color:+,\"color\":\"$vol_color\"}}"
    [ -n "$bat" ] && blocks="$blocks,{\"name\":\"bat\",\"full_text\":\"$bat\"${bat_color:+,\"color\":\"$bat_color\"}${bat_urgent:+,\"urgent\":true}}"
    blocks="$blocks,{\"name\":\"date\",\"full_text\":\"📆 $today $cicon $clock\"}"

    printf ',[%s]\n' "$blocks"
    sleep 5
done
