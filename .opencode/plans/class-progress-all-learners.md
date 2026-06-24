# Plan: Fix "All Learners" Stats Multiplication in Class Progress Screen

## Problem
When a teacher selects "All learners" in `TeacherClassProgressScreen`, per-learner stats (consumed, present, absent) are summed across all learners. For a class with 6 sessions and 5 learners, this shows "30 sessions" instead of 6.

## Changes (4 edits in `lib/teacher/teacher_class_progress_screen.dart`)

### 1. Variable section in `_headerHeroCard` (around line 960)
Add `totalSessionsHeld`, `avgPresent`, `avgAbsent` after the summing loop.

### 2. Stats display in `_headerHeroCard` (lines 1088-1118)
Replace the single stats Row with conditional rendering:
- **Specific learner**: keep current (Used, Paid, Left, Present, Absent)
- **All learners**: show two rows — (Sessions, Avg present, Avg absent) + (Paid, Used, Left)

### 3. New method `_allLearnersTable`
A compact card listing each learner's name, present/absent, and progress bar + %. Shows only when `!_hasLearnerSelected`.

### 4. ListView insertion (around line 766)
Add `_allLearnersTable(p)` after `_headerHeroCard(p)`, only when `!_hasLearnerSelected`.
