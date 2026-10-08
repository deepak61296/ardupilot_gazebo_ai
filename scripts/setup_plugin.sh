#!/usr/bin/env bash
# Clone and build ArduPilot's Gazebo plugin, then patch its gimbal camera.
#
# This repo deliberately does NOT vendor the plugin or its models: they are LGPL, they carry
# ~30 MB of meshes, and they are better tracked from upstream. We ship the worlds and the
# camera patch instead.
#
#   bash scripts/setup_plugin.sh                    # clones to ~/ardupilot_gazebo
#   ARDUPILOT_GAZEBO=/opt/agz bash scripts/setup_plugin.sh
set -eu

REPO="$(cd "$(dirname "$0")/.." && pwd)"
AGZ="${ARDUPILOT_GAZEBO:-$HOME/ardupilot_gazebo}"
UPSTREAM="https://github.com/ArduPilot/ardupilot_gazebo.git"

command -v gz >/dev/null 2>&1 || {
  echo "Gazebo not found. Install Gazebo Harmonic:"
  echo "  https://gazebosim.org/docs/harmonic/install_ubuntu"
  exit 1
}

if [ ! -d "$AGZ/.git" ]; then
  echo ">> cloning $UPSTREAM -> $AGZ"
  git clone "$UPSTREAM" "$AGZ"
else
  echo ">> already cloned: $AGZ"
fi

if ! ls "$AGZ"/build/*ArduPilotPlugin* >/dev/null 2>&1; then
  echo ">> building the plugin (needs libgz-sim8-dev, rapidjson-dev, gstreamer plugins)"
  mkdir -p "$AGZ/build"
  cd "$AGZ/build"
  cmake .. -DCMAKE_BUILD_TYPE=RelWithDebInfo && make -j"$(nproc)" || {
    echo
    echo "build failed. Most likely a missing dependency; on Ubuntu:"
    echo "  sudo apt install libgz-sim8-dev rapidjson-dev libopencv-dev libgstreamer1.0-dev \\"
    echo "    libgstreamer-plugins-base1.0-dev gstreamer1.0-plugins-bad gstreamer1.0-libav gstreamer1.0-gl"
    exit 1
  }
else
  echo ">> already built: $AGZ/build"
fi

# Narrow the camera and drop the zoom plugin that overrides it. Idempotent.
GZ_GIMBAL_MODEL="$AGZ/models/gimbal_small_3d/model.sdf" bash "$REPO/scripts/patch_sim_camera.sh"

echo
echo "done. Now: bash scripts/sim_up.sh --check"
