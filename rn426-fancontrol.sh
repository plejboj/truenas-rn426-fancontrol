#!/bin/bash
# Quiet, fail-safe fan controller for NETGEAR ReadyNAS RN426 on TrueNAS SCALE.
# Controls chassis fan2 through IT8622 pwm2.

set -uo pipefail
shopt -s nullglob

UNIT_NAME="rn426-fancontrol.service"
TAG="rn426-fancontrol"
SCRIPT_VERSION="2026-08-28.7"
HWMON_ROOT="${HWMON_ROOT:-/sys/class/hwmon}"

# Control-loop settings.
INTERVAL=15          # fixed interval between measurements and status lines
STALL_RPM=500        # anything below this is treated as a stalled fan
DOWN_CONFIRM=1       # reduce PWM on each cooler reading
DOWN_STEP=15         # maximum PWM reduction per 15-second cycle
STARTUP_WAIT=45      # seconds to wait for the IT8622 hwmon device
DEFAULT_PWM=128      # original/quiet-safe value used during boot and normal shutdown
MAX_PWM=255          # emergency full-speed value used only for alarms/failures
MIN_DRIVE_SENSORS=4 # this machine currently exposes four drivetemp sensors
MIN_CPU_SENSORS=1

HWMON=""
PWM=""
PWM_ENABLE=""
FAN_INPUT=""
CLEANUP_DONE=0
SHUTDOWN_REQUESTED=0

log() {
    printf '%s %s: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$TAG" "$*"
}

find_it8622() {
    local h name
    for h in "$HWMON_ROOT"/hwmon*; do
        [[ -r "$h/name" ]] || continue
        name=$(<"$h/name")
        case "$name" in
            it8622|it87)
                if [[ -e "$h/pwm2" && -e "$h/pwm2_enable" && -e "$h/fan2_input" ]]; then
                    printf '%s\n' "$h"
                    return 0
                fi
                ;;
        esac
    done
    return 1
}

load_and_discover() {
    local i

    if ! HWMON=$(find_it8622); then
        log "Laduje modul it87 dla IT8622."
        if ! modprobe it87 force_id=0x8622; then
            log "BLAD: nie udalo sie zaladowac modulu it87."
            return 1
        fi

        for ((i = 0; i < STARTUP_WAIT; i++)); do
            if HWMON=$(find_it8622); then
                break
            fi
            sleep 1
        done
    fi

    if [[ -z "$HWMON" ]]; then
        log "BLAD: nie znaleziono hwmon it8622 z pwm2 i fan2_input."
        return 1
    fi

    PWM="$HWMON/pwm2"
    PWM_ENABLE="$HWMON/pwm2_enable"
    FAN_INPUT="$HWMON/fan2_input"
    return 0
}

prepare_hardware() {
    load_and_discover || return 1

    if ! printf '1\n' > "$PWM_ENABLE"; then
        log "BLAD: nie mozna ustawic pwm2_enable=1."
        return 1
    fi

    # During boot keep the ReadyNAS original/default fan level.
    # Full speed is reserved for an actual alarm or sensor failure.
    if ! printf '%s\n' "$DEFAULT_PWM" > "$PWM"; then
        log "BLAD: nie mozna zapisac pwm2."
        return 1
    fi

    log "Wersja $SCRIPT_VERSION; kontroler: $HWMON; interwal ${INTERVAL}s; tryb reczny pwm2; start PWM=$DEFAULT_PWM."
    return 0
}

set_pwm() {
    local value=$1

    (( value < 0 )) && value=0
    (( value > MAX_PWM )) && value=$MAX_PWM

    printf '1\n' > "$PWM_ENABLE" || return 1
    printf '%s\n' "$value" > "$PWM"
}

cleanup() {
    local rc=${1:-0}
    local final_pwm=$MAX_PWM
    local reason="awaryjne wyjscie"

    (( CLEANUP_DONE == 0 )) || return 0
    CLEANUP_DONE=1

    # A normal service stop/reboot should not make the NAS unnecessarily loud.
    # Keep full speed only when the controller actually exits with an error.
    if (( SHUTDOWN_REQUESTED == 1 || rc == 0 )); then
        final_pwm=$DEFAULT_PWM
        reason="normalne zatrzymanie"
    fi

    if [[ -n "${PWM_ENABLE:-}" && -w "${PWM_ENABLE:-}" ]]; then
        printf '1\n' > "$PWM_ENABLE" 2>/dev/null || true
    fi
    if [[ -n "${PWM:-}" && -w "${PWM:-}" ]]; then
        printf '%s\n' "$final_pwm" > "$PWM" 2>/dev/null || true
        log "$reason: PWM=$final_pwm."
    fi
}

request_shutdown() {
    SHUTDOWN_REQUESTED=1
    exit 0
}

# Print: "maximum_temperature_C sensor_count" for a given hwmon name.
read_max_temp() {
    local wanted=$1
    local min_raw=$2
    local max_raw=$3
    local h name f raw temp
    local max=-999
    local count=0

    for h in "$HWMON_ROOT"/hwmon*; do
        [[ -r "$h/name" ]] || continue
        name=$(<"$h/name")
        [[ "$name" == "$wanted" ]] || continue

        for f in "$h"/temp*_input; do
            [[ -r "$f" ]] || continue
            raw=$(<"$f") || continue
            [[ "$raw" =~ ^-?[0-9]+$ ]] || continue

            # Ignore disconnected or nonsensical sensors.
            (( raw >= min_raw && raw <= max_raw )) || continue

            # Round upward so 39.1 C is handled as 40 C.
            temp=$(( (raw + 999) / 1000 ))
            (( temp > max )) && max=$temp
            ((count += 1))
        done
    done

    printf '%s %s\n' "$max" "$count"
}

# Quiet curve based on measured RN426 fan speeds:
# PWM 50 ~= 1130 RPM, 70 ~= 1310, 90 ~= 1483,
# 110 ~= 1658, 128 ~= 1819 on the calibrated machine.
drive_pwm_for_temp() {
    local t=$1
    if   (( t <= 40 )); then printf '50\n'
    elif (( t == 41 )); then printf '55\n'
    elif (( t == 42 )); then printf '60\n'
    elif (( t == 43 )); then printf '65\n'
    elif (( t == 44 )); then printf '70\n'
    elif (( t == 45 )); then printf '75\n'
    elif (( t == 46 )); then printf '80\n'
    elif (( t == 47 )); then printf '90\n'
    elif (( t == 48 )); then printf '105\n'
    elif (( t == 49 )); then printf '120\n'
    elif (( t == 50 )); then printf '140\n'
    elif (( t == 51 )); then printf '165\n'
    elif (( t == 52 )); then printf '195\n'
    elif (( t == 53 )); then printf '225\n'
    else                         printf '255\n'
    fi
}

# CPU is a backstop; drive temperature normally controls this NAS.
cpu_pwm_for_temp() {
    local t=$1
    if   (( t <= 54 )); then printf '50\n'
    elif (( t <= 59 )); then printf '70\n'
    elif (( t <= 64 )); then printf '100\n'
    elif (( t <= 69 )); then printf '140\n'
    elif (( t <= 74 )); then printf '200\n'
    else                       printf '255\n'
    fi
}

validate_curves() {
    local t expected
    local -a drive_expected=(
        "40:50" "41:55" "42:60" "43:65" "44:70" "45:75" "46:80"
        "47:90" "48:105" "49:120" "50:140" "51:165" "52:195"
        "53:225" "54:255"
    )

    for expected in "${drive_expected[@]}"; do
        t=${expected%%:*}
        [[ "$(drive_pwm_for_temp "$t")" == "${expected##*:}" ]] || return 1
    done

    [[ "$(cpu_pwm_for_temp 42)" == "50" ]] || return 1
    [[ "$(cpu_pwm_for_temp 66)" == "140" ]] || return 1
}

read_control_state() {
    local drive_temp drive_count cpu_temp cpu_count
    local drive_target cpu_target target current rpm

    read -r drive_temp drive_count < <(read_max_temp drivetemp 10000 80000)
    read -r cpu_temp cpu_count < <(read_max_temp coretemp 10000 120000)

    if (( drive_count < MIN_DRIVE_SENSORS || cpu_count < MIN_CPU_SENSORS )); then
        printf '%s\n' "SENSOR_ERROR drive_count=$drive_count cpu_count=$cpu_count"
        return 1
    fi

    drive_target=$(drive_pwm_for_temp "$drive_temp")
    cpu_target=$(cpu_pwm_for_temp "$cpu_temp")
    if (( drive_target > cpu_target )); then
        target=$drive_target
    else
        target=$cpu_target
    fi

    current=$(<"$PWM") || return 1
    rpm=$(<"$FAN_INPUT") || return 1

    printf '%s %s %s %s %s %s %s %s %s\n' \
        "$drive_temp" "$drive_count" "$cpu_temp" "$cpu_count" \
        "$drive_target" "$cpu_target" "$target" "$current" "$rpm"
}

run_daemon() {
    local drive_temp drive_count cpu_temp cpu_count
    local drive_target cpu_target target current rpm
    local applied first_reading=1 cool_readings=0
    local state cycle_started elapsed sleep_for

    if command -v flock >/dev/null 2>&1; then
        exec 9>/run/rn426-fancontrol.lock
        if ! flock -n 9; then
            log "BLAD: inna instancja kontrolera juz dziala."
            return 1
        fi
    fi

    if ! validate_curves; then
        log "BLAD: wewnetrzny test krzywych PWM nie przeszedl."
        return 1
    fi

    prepare_hardware || return 1
    trap request_shutdown INT TERM HUP
    trap 'cleanup $?' EXIT

    sleep 2

    while true; do
        cycle_started=$(date +%s)

        if [[ ! -w "$PWM" || ! -w "$PWM_ENABLE" || ! -r "$FAN_INPUT" ]]; then
            log "BLAD: zniknal interfejs IT8622; restart kontrolera."
            return 1
        fi

        state=$(read_control_state) || {
            set_pwm "$MAX_PWM" || return 1
            log "Brak kompletu czujnikow drivetemp/coretemp; PWM=$MAX_PWM. $state"
            elapsed=$(( $(date +%s) - cycle_started ))
            sleep_for=$(( INTERVAL - elapsed ))
            (( sleep_for < 1 )) && sleep_for=1
            sleep "$sleep_for"
            continue
        }

        read -r drive_temp drive_count cpu_temp cpu_count \
            drive_target cpu_target target current rpm <<< "$state"

        applied=$current
        if (( first_reading == 1 )); then
            applied=$target
            first_reading=0
            cool_readings=0
        elif (( target > current )); then
            # Temperature rise: react immediately.
            applied=$target
            cool_readings=0
        elif (( target < current )); then
            # Temperature fall: step down gradually; temperature rises are still immediate.
            ((cool_readings += 1))
            if (( cool_readings >= DOWN_CONFIRM )); then
                applied=$(( current - DOWN_STEP ))
                (( applied < target )) && applied=$target
                cool_readings=0
            fi
        else
            cool_readings=0
        fi

        if (( applied != current )); then
            set_pwm "$applied" || return 1
        fi

        # Fan2 on this machine is well above 1000 RPM even at PWM 50.
        if (( rpm < STALL_RPM )); then
            log "ALARM: fan2 ma tylko ${rpm} RPM; wymuszam PWM=$MAX_PWM."
            set_pwm "$MAX_PWM" || return 1
            sleep 5
            rpm=$(<"$FAN_INPUT") || return 1
            if (( rpm < STALL_RPM )); then
                log "ALARM: wentylator nadal nie osiaga $STALL_RPM RPM; restart kontrolera."
                return 1
            fi
            applied=$MAX_PWM
        fi

        log "HDDmax=${drive_temp}C(${drive_count}) HDDtarget=${drive_target} CPUmax=${cpu_temp}C(${cpu_count}) CPUtarget=${cpu_target} target=${target} PWM=${applied} fan=${rpm}RPM"

        # Keep the complete measurement-to-measurement and log period close to INTERVAL.
        elapsed=$(( $(date +%s) - cycle_started ))
        sleep_for=$(( INTERVAL - elapsed ))
        (( sleep_for < 1 )) && sleep_for=1
        sleep "$sleep_for"
    done
}

check_only() {
    local state

    if ! validate_curves; then
        log "BLAD: wewnetrzny test krzywych PWM nie przeszedl."
        return 1
    fi

    load_and_discover || return 1
    state=$(read_control_state) || {
        log "$state"
        return 1
    }

    local drive_temp drive_count cpu_temp cpu_count
    local drive_target cpu_target target current rpm
    read -r drive_temp drive_count cpu_temp cpu_count \
        drive_target cpu_target target current rpm <<< "$state"

    printf 'Wersja:    %s; interwal %ss\n' "$SCRIPT_VERSION" "$INTERVAL"
    printf 'Kontroler: %s\n' "$HWMON"
    printf 'Dyski:     max %s C, czujniki %s, zadany PWM %s\n' "$drive_temp" "$drive_count" "$drive_target"
    printf 'CPU:       max %s C, czujniki %s, zadany PWM %s\n' "$cpu_temp" "$cpu_count" "$cpu_target"
    printf 'Wynik:     target PWM %s; obecnie PWM %s; fan2 %s RPM\n' "$target" "$current" "$rpm"
}

show_curve() {
    local t

    if ! validate_curves; then
        log "BLAD: wewnetrzny test krzywych PWM nie przeszedl."
        return 1
    fi

    printf 'Wersja: %s; interwal %ss\n' "$SCRIPT_VERSION" "$INTERVAL"
    printf 'Krzywa HDD:\n'
    printf '  <=40C -> PWM %s\n' "$(drive_pwm_for_temp 40)"
    for t in 41 42 43 44 45 46 47 48 49 50 51 52 53; do
        printf '  %sC -> PWM %s\n' "$t" "$(drive_pwm_for_temp "$t")"
    done
    printf '  >=54C -> PWM %s\n' "$(drive_pwm_for_temp 54)"
    printf 'Krzywa CPU: <=54C:50, 55-59C:70, 60-64C:100, 65-69C:140, 70-74C:200, >=75C:255\n'
}

start_service() {
    local self
    self=$(readlink -f "$0")

    if systemctl is-active --quiet "$UNIT_NAME"; then
        log "$UNIT_NAME juz dziala."
        return 0
    fi

    systemctl reset-failed "$UNIT_NAME" 2>/dev/null || true

    systemd-run \
        --unit="$UNIT_NAME" \
        --collect \
        --property=Type=simple \
        --property=Restart=on-failure \
        --property=RestartSec=5s \
        --property=TimeoutStopSec=10s \
        "$self" daemon
}

stop_service() {
    systemctl stop "$UNIT_NAME" 2>/dev/null || true

    if load_and_discover; then
        printf '1\n' > "$PWM_ENABLE" 2>/dev/null || true
        printf '%s\n' "$DEFAULT_PWM" > "$PWM" 2>/dev/null || true
        log "Zatrzymano kontroler; ustawiono PWM=$DEFAULT_PWM."
    fi
}

usage() {
    cat <<EOF_USAGE
Uzycie: $0 [start|daemon|stop|restart|status|check|curve]

Bez argumentu wykonywany jest tryb start, odpowiedni dla TrueNAS POSTINIT.
EOF_USAGE
}

case "${1:-start}" in
    start)
        start_service
        ;;
    daemon)
        run_daemon
        ;;
    stop)
        stop_service
        ;;
    restart)
        stop_service
        start_service
        ;;
    status)
        systemctl status "$UNIT_NAME" --no-pager
        ;;
    check)
        check_only
        ;;
    curve)
        show_curve
        ;;
    *)
        usage
        exit 2
        ;;
esac
