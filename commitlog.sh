#!/usr/bin/env bash

# Commit Log: Teacher online attendance/admin flexible review updates
# Date: 2026-04-13
#
# Included changes:
# 1) Teacher online tab updated:
#    - Reordered tabs to Past, Live, Upcoming.
#    - Removed Booking Overview card.
#    - Moved session counts into tab labels.
# 2) Online attendance action behavior:
#    - "Take" attendance is disabled/greyed for upcoming classes.
#    - "Take" is enabled only after class end time has passed.
#    - "Edit" uses a yellow action color to distinguish from "Take".
# 3) Teacher in-class and attendance screens:
#    - Removed in-class teacher hero card.
#    - Added syllabus session number display in attendance edit/take screen.
#    - Expanded attendance history cards with lesson and skill tags.
# 4) Admin flexible classes:
#    - Loaded/displayed both teacher and learner review stars per session.
#    - Replaced Homework block in session details popup with Teacher Comment.
#
# Notes:
# - Navigation callers that opened online upcoming tab were adjusted for new
#   tab order indexes.

set -euo pipefail

printf '%s\n' "Commit log prepared for teacher/admin attendance updates."
