#!/usr/bin/env bash
# Bring up the sim (Gazebo GUI + camera-rendering server + ArduPilot SITL) and leave it running:
#
#   Terminal 1:  bash scripts/sim_up.sh          # (set DISPLAY if your X display isn't :0)
#   Terminal 2:  mavlink-mcp --enable-actuation --camera gazebo
#
#   bash scripts/sim_up.sh --check               # preflight only: report what's missing, don't launch
#
# Machine-specific bits are AUTO-DETECTED (gz path, NVIDIA EGL vendor file, X auth) and overridable
# via env: ARDUPILOT_GAZEBO, ARDUPILOT_HOME, SIM_WORLD, GPU_ENV, DISPLAY.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
AGZ="${ARDUPILOT_GAZEBO:-$HOME/ardupilot_gazebo}"
AP="${ARDUPILOT_HOME:-$HOME/ardupilot}"
WORLD="${SIM_WORLD:-${AGENT_WORLD:-$REPO/worlds/iris_field_vision.sdf}}"
CAM="/world/iris_runway/model/iris_with_gimbal/model/gimbal/link/pitch_link/sensor/camera/image/enable_streaming"
DISP="${DISPLAY:-:0}"
GZ="$(command -v gz || true)"
GZBIN="$(dirname "$GZ" 2>/dev/null || echo /usr/bin)"

# ---- detect the GPU render env (the #1 thing that differs between machines) ----
# The NVIDIA EGL vendor file's name/number varies; find it rather than hard-code it.
EGL_JSON="$(ls /usr/share/glvnd/egl_vendor.d/*nvidia*.json 2>/dev/null | head -1)"
have_nv=0; command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1 && have_nv=1
if [ -n "${GPU_ENV:-}" ]; then
  :                                                   # caller supplied the exact render env
elif [ "$have_nv" = 1 ] && [ -n "$EGL_JSON" ]; then
  GPU_ENV="__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia __EGL_VENDOR_LIBRARY_FILENAMES=$EGL_JSON"
else
  GPU_ENV=""
fi
XAUTH=""; [ -f "$HOME/.Xauthority" ] && XAUTH="XAUTHORITY=$HOME/.Xauthority"

preflight() {
  local fail=0
  echo "-- preflight --"
  if [ -n "$GZ" ]; then echo "  ok   gz: $GZ ($("$GZ" sim --version 2>/dev/null | head -1))"
  else echo "  FAIL gz not found -- install Gazebo Harmonic (scripts/bootstrap.sh)"; fail=1; fi
  if ls "$AGZ"/build/*ArduPilotPlugin* >/dev/null 2>&1; then echo "  ok   ardupilot_gazebo plugin: $AGZ/build"
  else echo "  FAIL ArduPilotPlugin not built at $AGZ/build -- run scripts/setup_plugin.sh"; fail=1; fi
  if [ -x "$AP/build/sitl/bin/arducopter" ]; then echo "  ok   SITL: $AP/build/sitl/bin/arducopter"
  else echo "  FAIL arducopter not built at $AP -- set ARDUPILOT_HOME (see README)"; fail=1; fi
  [ -f "$WORLD" ] && echo "  ok   world: $WORLD" || { echo "  FAIL world not found: $WORLD"; fail=1; }
  # graphics: warn (not fatal -- headless server still runs, just camera/GUI may not)
  if [ "$have_nv" = 1 ] && [ -n "$GPU_ENV" ]; then echo "  ok   NVIDIA render: EGL=${EGL_JSON:-<GPU_ENV override>}"
  else echo "  WARN no NVIDIA EGL detected -> HEADLESS CAMERA will render BLACK (software fallback)."
       echo "       install the NVIDIA driver, or set GPU_ENV=... if your files live elsewhere."; fi
  if [ -n "$XAUTH" ] || xset q >/dev/null 2>&1; then echo "  ok   display: $DISP (GUI window will open)"
  else echo "  WARN no reachable X display ($DISP) -> no GUI window; the headless server + agent still work."; fi
  return $fail
}

preflight || { echo ">> fix the FAILs above, then re-run."; exit 1; }
[ "${1:-}" = "--check" ] && { echo ">> preflight only; not launching."; exit 0; }

# The stock gimbal camera is 2.0 rad and carries a zoom plugin that silently overrides the SDF
# FOV. Re-applying is cheap and idempotent, so do it here rather than trust people to remember.
GZ_GIMBAL_MODEL="$AGZ/models/gimbal_small_3d/model.sdf" bash "$REPO/scripts/patch_sim_camera.sh" \
  >/dev/null 2>&1 && echo ">> gimbal camera patched (1.2 rad, no zoom plugin, joints published)"

mkdir -p /tmp/gzrt
echo ">> cleanup any old sim"
pkill -9 -f 'gz[ ]sim' 2>/dev/null || true
pkill -9 -f 'arducopte[r]' 2>/dev/null || true
sleep 2

# Server and GUI MUST be separate processes: a combined `gz sim -r` does not render the camera
# SENSOR (only the GUI view). Server renders sensors (headless EGL) + streams; GUI shows the window.
echo ">> Gazebo SERVER (renders camera sensor, headless) -- detached"
# shellcheck disable=SC2086
setsid env -i HOME="$HOME" PATH="$GZBIN:/usr/local/bin:/usr/bin:/bin" LANG=C.UTF-8 XDG_RUNTIME_DIR=/tmp/gzrt \
  $GPU_ENV \
  GZ_SIM_SYSTEM_PLUGIN_PATH="$AGZ/build" \
  GZ_SIM_RESOURCE_PATH="$AGZ/models:$AGZ/worlds:$REPO/models" \
  "$GZ" sim -v4 -s -r --headless-rendering "$WORLD" >/tmp/gz_server.log 2>&1 < /dev/null &

for _ in $(seq 1 60); do ss -lun 2>/dev/null | grep -q 9002 && break; sleep 1; done
sleep 3
echo ">> Gazebo GUI client on $DISP (a window should open; harmless if you have no display) -- detached"
# shellcheck disable=SC2086
setsid env -i HOME="$HOME" PATH="$GZBIN:/usr/local/bin:/usr/bin:/bin" LANG=C.UTF-8 \
  DISPLAY="$DISP" $XAUTH \
  $GPU_ENV \
  GZ_SIM_RESOURCE_PATH="$AGZ/models:$AGZ/worlds:$REPO/models" \
  "$GZ" sim -g >/tmp/gz_gui.log 2>&1 < /dev/null &
sleep 4
echo ">> enable camera stream (re-sent a few times so it sticks once the sensor is ready)"
( for _ in $(seq 1 8); do
    env -i HOME="$HOME" PATH="$GZBIN:/usr/local/bin:/usr/bin:/bin" \
      "$GZ" topic -t "$CAM" -m gz.msgs.Boolean -p "data: 1" >/dev/null 2>&1 || true
    sleep 2
  done ) &

echo
echo "================================================================"
echo " Gazebo is up. In ANOTHER terminal start the MCP server:"
echo
echo "   mavlink-mcp --enable-actuation --camera gazebo"
echo
echo " Then ask your agent:  take off to 20 m, point the camera down, fly 30 m north,"
echo "                       take a photo and tell me what you see, then RTL"
echo
echo " (Give it ~30-60s for GPS/EKF before taking off.)"
echo " THIS terminal runs SITL in the foreground -- keep it open. Ctrl-C stops SITL AND Gazebo."
echo "================================================================"
echo

# One clean shutdown: Ctrl-C (or any exit) stops SITL and tears down the detached Gazebo too.
cleanup() { echo; echo ">> stopping SITL + Gazebo"; pkill -9 -f 'gz[ ]sim' 2>/dev/null || true; }
trap cleanup EXIT INT TERM

echo ">> ArduPilot SITL (Gazebo physics) -- foreground, keep this terminal open"
cd "$AP"
./build/sitl/bin/arducopter --model JSON --slave 0 -I0 \
  --defaults ./Tools/autotest/default_params/copter.parm,./Tools/autotest/default_params/gazebo-iris.parm
