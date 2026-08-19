# shellcheck shell=bash
# nook speedtest — measure the box's link, now or on a schedule.
#
# The measurement happens on the box, not here: what matters is what the nook
# can reach, and a laptop on the same wifi would be measuring its own link.

cmd_speedtest() {
  load_config
  need jq

  case ${1:-} in
    --auto)
      remote sudo systemctl enable --now nook-speedtest.timer
      echo "$NOOK will measure its link every six hours"
      return 0
      ;;
    --no-auto)
      remote sudo systemctl disable --now nook-speedtest.timer
      echo "automatic measurements off — nook speedtest still runs one now"
      return 0
      ;;
    --last)
      remote "cat $NOOK_DATA/www/speedtest.json 2>/dev/null" | speedtest_print ||
        die "$NOOK has never measured its link — run: nook speedtest"
      return 0
      ;;
    "") ;;
    *) die "usage: nook speedtest [--last | --auto | --no-auto]" ;;
  esac

  log "measuring $NOOK's link — about half a minute"
  remote nook-speedtest --quiet ||
    die "the measurement did not finish. Is the box online?"
  remote "cat $NOOK_DATA/www/speedtest.json" | speedtest_print
}

speedtest_print() {
  jq -r '
    "down       \(.down) Mbps",
    "up         \(.up) Mbps",
    "latency    \(.latency) ms",
    "measured   \(.at)"
  '
}
