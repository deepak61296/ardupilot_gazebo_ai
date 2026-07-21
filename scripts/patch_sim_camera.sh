#!/usr/bin/env bash
# Make the sim gimbal camera match our vision math + look less fisheye.
#
# ardupilot_gazebo's gimbal_small_3d ships a 2.0 rad (~114deg) horizontal FOV. That's very wide
# (distorted, everything looks tiny) AND it mismatches the fov_rad=1.2 our geo-tagging assumes
# (precision_land / survey.search_area), so computed target coordinates come out ~1.5x off.
# This narrows it to 1.2 rad (~69deg): better image + correct geo-tags. Idempotent; re-run on any
# machine after installing ardupilot_gazebo. No repo paths, no perf cost (same resolution).
set -u
GIMBAL="${GZ_GIMBAL_MODEL:-$HOME/ardupilot_gazebo/models/gimbal_small_3d/model.sdf}"
[ -f "$GIMBAL" ] || { echo "not found: $GIMBAL (set GZ_GIMBAL_MODEL)"; exit 1; }
sed -i 's#<horizontal_fov>2.0</horizontal_fov>#<horizontal_fov>1.2</horizontal_fov>#' "$GIMBAL"
echo "camera FOV now: $(grep -oE '<horizontal_fov>[^<]+' "$GIMBAL" | head -1 | cut -d'>' -f2) rad  ($GIMBAL)"

# Remove the CameraZoomPlugin: it re-applies its own baseline FOV (2.0 rad) to the rendered
# stream at startup, silently overriding the SDF FOV above -- rendered geometry then disagrees
# with camera_info and every geo-tag comes out ~2.2x short. We don't use zoom.
sed -i '/CameraZoomPlugin/,/<\/plugin>/d' "$GIMBAL"
grep -q "CameraZoomPlugin" "$GIMBAL" && { echo "FAILED to remove CameraZoomPlugin"; exit 1; } \
  || echo "CameraZoomPlugin: removed (rendered FOV now matches the SDF)"

# Publish the gimbal joints' ACTUAL positions. The mount slews slowly, so geo-tagging what the
# camera sees must read the real joint angles (the FC reports its target, not the gz joint).
sed -i '/gz-sim-joint-state-publisher-system/,/<\/plugin>/d' "$GIMBAL"   # replace any old block
sed -i 's#^\( *\)</model>#\1  <plugin filename="gz-sim-joint-state-publisher-system" name="gz::sim::systems::JointStatePublisher">\n\1    <joint_name>roll_joint</joint_name>\n\1    <joint_name>pitch_joint</joint_name>\n\1    <joint_name>yaw_joint</joint_name>\n\1  </plugin>\n\1</model>#' "$GIMBAL"
grep -q "yaw_joint</joint_name>" "$GIMBAL" && echo "gimbal joint state publisher: present" \
  || { echo "FAILED to add joint state publisher"; exit 1; }
