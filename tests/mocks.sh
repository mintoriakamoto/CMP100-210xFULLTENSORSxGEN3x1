# shellcheck shell=bash
# Bash mocks spliced into sbin/cmp100-unlock by tests/test_unlock_flow.py.
# They replace every hardware-touching command. $SANDBOX is the fake root.
ev() { printf '%s\n' "$*" >> "$SANDBOX/events"; }
systemctl() {
    ev "systemctl $*"
    case "$*" in
        *ActiveState*) echo inactive ;;
        *is-active*|*is-enabled*) return 1 ;;
        *) : ;;
    esac
}
# Nobody holds a node unless MOCK_HELD_NODES lists its basename
# (e.g. MOCK_HELD_NODES="card1 renderD128"); match on basename so a test can name
# a node without knowing the sandbox path the harness rewrote it into.
fuser() {
    local arg n
    for arg in "$@"; do
        n=$(basename "$arg")
        case " ${MOCK_HELD_NODES:-} " in *" $n "*) return 0 ;; esac
    done
    return 1
}
sleep() { :; }
sync() { :; }
timeout() { shift; "$@"; }
modinfo() { echo "$(uname -r) SMP mod_unload"; }
modprobe() {
    ev "modprobe $*"
    if [[ $* == *nouveau* ]]; then
        mkdir -p "$SANDBOX/sys/module/nouveau/parameters"
        printf 2 > "$SANDBOX/sys/module/nouveau/parameters/modeset"
        printf 1 > "$SANDBOX/sys/module/nouveau/parameters/noaccel"
        printf 0 > "$SANDBOX/sys/module/nouveau/parameters/runpm"
    fi
}
rmmod() {
    ev "rmmod $*"
    [[ $1 == gv100_nouveau_acr_hook ]] && rmdir "$SANDBOX/sys/module/$1"
    [[ $1 == nouveau ]] && rm -rf "$SANDBOX/sys/module/nouveau"
    return 0
}
insmod() { ev "insmod $*"; mkdir "$SANDBOX/sys/module/gv100_nouveau_acr_hook"; touch "$SANDBOX/armed"; }
dmesg() { cat "$SANDBOX/dmesg"; }
card_of_addr() { case $1 in 0x1*) echo 0000:01:00.0 ;; 0x2*) echo 0000:05:00.0 ;; esac; }
reg() { cat "$SANDBOX/regs/$1/$2" 2>/dev/null || echo 0x00000000; }
busybox() { # devmem ADDR 32 [VALUE]
    local addr=$2 val=${4:-} card off
    card=$(card_of_addr "$addr")
    off=$(( addr & 0x0fffffff ))
    case $off in
        $((0x409664))) reg "$card" tensor ;;
        $((0x88610)))  reg "$card" policy ;;
        $((0x8872c)))  reg "$card" vector ;;
        $((0x88084)))  echo 0x00453C12 ;;
        $((0x880a4)))  echo 0x00000006 ;;
        $((0x880a8)))  echo 0x00000002 ;;
        $((0x2157c))|$((0x21580))) echo "${MOCK_FUSED:-0x00000000}" ;;
        $((0x8841c)))
            if [[ -n $val ]]; then
                ev "misc1_write $card $val"
                printf '%s' "$val" > "$SANDBOX/regs/$card/misc1"
                # clamp cleared while pre-POST -> card can train Gen3 on next upstream retrain
                [[ -e $SANDBOX/regs/$card/prepost ]] && touch "$SANDBOX/regs/$card/gen3ok"
            else
                [[ -s $SANDBOX/regs/$card/misc1 ]] && cat "$SANDBOX/regs/$card/misc1" || echo 0xC0346500
            fi ;;
        $((0x88088)))  reg "$card" status ;;
        $((0x8c040)))
            if [[ -n $val ]]; then
                ev "xp_write $card $val"
                printf '%s' "$val" > "$SANDBOX/regs/$card/xp"
                if (( (val & 1) )) && [[ -z ${MOCK_NO_GEN2:-} ]]; then
                    printf 0x10120142 > "$SANDBOX/regs/$card/status"
                    printf 2 > "$SANDBOX/regs/$card/lnksta"
                fi
            else
                # CHANGE_SPEED self-clears
                printf '0x%08x' "$(( $(reg "$card" xp) & ~1 ))"
            fi ;;
        *) echo 0x00000000 ;;
    esac
}
setpci() {
    ev "setpci $*"
    local s=$2 f=${3%%=*} v=${3#*=}
    case $f in
        CAP_EXP+0c.l) echo 00000043 ;;
        CAP_EXP+10.w)
            # retrain from upstream port: children with gen3ok train to Gen3
            if [[ $v == 0020:0020 ]]; then
                local c
                for c in 0000:01:00.0 0000:05:00.0; do
                    if [[ $(reg "$c" upstream) == "$s" && -e $SANDBOX/regs/$c/gen3ok && -z ${MOCK_NO_GEN3:-} ]]; then
                        printf 3 > "$SANDBOX/regs/$c/lnksta"; printf 0x10130143 > "$SANDBOX/regs/$c/status"
                    fi
                done
            fi ;;
        CAP_EXP+12.w)
            if [[ $s == devices ]]; then   # upstream port: reports the fastest child link, never "training"
                local best=1 c
                for c in 0000:01:00.0 0000:05:00.0; do (( $(reg "$c" lnksta) > best )) && best=$(reg "$c" lnksta); done
                printf '000%s\n' "$best"
            else
                printf '000%s\n' "$(reg "$s" lnksta)"
            fi ;;
        CAP_EXP+30.w) echo 0042 ;;
        COMMAND) echo 0007 ;;
        *) : ;;
    esac
}
nvidia-smi() {
    ev "nvidia-smi"
    local c
    for c in 0000:01:00.0 0000:05:00.0; do
        if [[ -L $SANDBOX/sys/bus/pci/devices/$c/driver && $(readlink "$SANDBOX/sys/bus/pci/devices/$c/driver") == *nvidia ]]; then
            printf '0000%s, %s, %s\n' "$c" "$(reg "$c" lnksta)" 2
        fi
    done
}
io_write() {
    local value=$1 path=$2 drv sha c
    ev "write $value ${path#"$SANDBOX"}"
    case $path in
        */unbind)
            [[ $value == "${MOCK_STICKY_UNBIND:-}" ]] && return 0
            rm -f "$SANDBOX/sys/bus/pci/devices/$value/driver" ;;
        */reset)
            # SBR: back to POR state, clamp restored, Gen1, tensor 0x999, pre-POST window open
            c=${path%/reset}; c=${c##*/}
            printf 0xC0346500 > "$SANDBOX/regs/$c/misc1"; printf 1 > "$SANDBOX/regs/$c/lnksta"
            printf 0x10110141 > "$SANDBOX/regs/$c/status"; printf 0x00000999 > "$SANDBOX/regs/$c/tensor"
            rm -f "$SANDBOX/regs/$c/gen3ok"; touch "$SANDBOX/regs/$c/prepost" ;;
        */bind)
            drv=${path%/bind}; drv=${drv##*/}
            rm -f "$SANDBOX/regs/$value/prepost"   # any driver bind POSTs the card
            ln -sfn "../../drivers/$drv" "$SANDBOX/sys/bus/pci/devices/$value/driver"
            if [[ $drv == nouveau && -e $SANDBOX/armed ]]; then
                rm "$SANDBOX/armed"
                sha=$(sha256sum "$SANDBOX/lib/firmware/nvidia/gv100/acr/ucode_load.bin" | cut -c1-64)
                case $sha in
                    "$TENSOR_SHA") printf 0x00000888 > "$SANDBOX/regs/$value/tensor" ;;
                    "$POLICY_SHA") printf 0x00000001 > "$SANDBOX/regs/$value/policy" ;;
                    "$VECTOR_SHA") printf 0x00000006 > "$SANDBOX/regs/$value/vector" ;;
                esac
                echo "[ 1.0] gv100_nouveau_acr_hook: BOOT_RETURN call=1 function_rc=0 tensor_409664=$(reg "$value" tensor)" >> "$SANDBOX/dmesg"
            fi ;;
        *) printf '%s' "$value" > "$path" ;;
    esac
}
