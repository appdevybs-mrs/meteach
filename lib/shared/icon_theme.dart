import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

class IconBubble extends StatelessWidget {
  final IconData icon;
  final Color color;
  final Color? backgroundColor;
  final double size;
  final double containerSize;

  const IconBubble({
    super.key,
    required this.icon,
    required this.color,
    this.backgroundColor,
    this.size = 22,
    this.containerSize = 44,
  });

  @override
  Widget build(BuildContext context) {
    final bg = backgroundColor ?? color.withValues(alpha: 0.12);

    return Container(
      width: containerSize,
      height: containerSize,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(containerSize * 0.32),
        border: Border.all(color: color.withValues(alpha: 0.15)),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.08),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Icon(icon, color: color, size: size),
    );
  }
}

class IconBubbleLarge extends StatelessWidget {
  final IconData icon;
  final Color color;
  final double size;
  final double containerSize;

  const IconBubbleLarge({
    super.key,
    required this.icon,
    required this.color,
    this.size = 28,
    this.containerSize = 56,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: containerSize,
      height: containerSize,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(containerSize * 0.30),
        border: Border.all(color: color.withValues(alpha: 0.12)),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.06),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Icon(icon, color: color, size: size),
    );
  }
}

class AdminIcons {
  static const learners = FontAwesomeIcons.userGraduate;
  static const classes = Icons.class_rounded;
  static const payments = FontAwesomeIcons.moneyBillWave;
  static const finance = FontAwesomeIcons.chartLine;
  static const schedule = Icons.calendar_view_week_rounded;
  static const attendance = FontAwesomeIcons.clipboardCheck;
  static const courses = Icons.menu_book_rounded;
  static const studyCoach = FontAwesomeIcons.graduationCap;
  static const courseReviews = Icons.reviews_rounded;
  static const onlineBooking = FontAwesomeIcons.calendarCheck;
  static const reminders = Icons.notifications_active_rounded;
  static const priorityAlerts = FontAwesomeIcons.bullhorn;
  static const activityCenter = FontAwesomeIcons.magnifyingGlassChart;
  static const notificationAudit = FontAwesomeIcons.bellConcierge;
  static const staff = FontAwesomeIcons.usersGear;
  static const adminMail = FontAwesomeIcons.envelopesBulk;
  static const wages = FontAwesomeIcons.coins;
  static const teacherAvailability = FontAwesomeIcons.userClock;
  static const subscriptions = FontAwesomeIcons.userPlus;
  static const certificates = Icons.workspace_premium_rounded;
  static const fileManager = Icons.folder_open_rounded;
  static const sharedFiles = Icons.folder_shared_rounded;
  static const publicGallery = FontAwesomeIcons.images;
  static const contract = FontAwesomeIcons.fileContract;
  static const settings = Icons.settings_rounded;
  static const windowAccess = FontAwesomeIcons.lockOpen;
  static const jobApplications = FontAwesomeIcons.briefcase;
  static const adminTodo = Icons.task_alt_rounded;
  static const diary = FontAwesomeIcons.bookOpen;
  static const instructions = FontAwesomeIcons.bookOpenReader;

  static const navLearners = Icons.people_alt_rounded;
  static const navPayments = FontAwesomeIcons.coins;
  static const navClasses = Icons.school_rounded;
  static const navHome = Icons.home_rounded;
  static const navLogout = Icons.logout_rounded;
}

class LearnerIcons {
  static const courses = Icons.menu_book_rounded;
  static const booking = FontAwesomeIcons.calendarCheck;
  static const mail = FontAwesomeIcons.envelope;
  static const reminders = Icons.notifications_active_rounded;
  static const homework = FontAwesomeIcons.bookOpen;
  static const gallery = FontAwesomeIcons.images;
  static const stories = FontAwesomeIcons.book;
  static const games = FontAwesomeIcons.gamepad;
  static const studyCoach = FontAwesomeIcons.lightbulb;
  static const profile = Icons.person_rounded;
  static const regulations = Icons.policy_rounded;
  static const theme = Icons.palette_rounded;
  static const logout = Icons.logout_rounded;
  static const menu = Icons.menu_rounded;
  static const instructions = FontAwesomeIcons.bookOpenReader;

  static const recordedCourse = Icons.play_circle_fill_rounded;
  static const flexibleCourse = FontAwesomeIcons.wifi;
  static const privateCourse = Icons.person_rounded;
  static const inClassCourse = Icons.groups_rounded;
  static const defaultCourse = Icons.menu_book_rounded;

  static const joinNow = FontAwesomeIcons.video;
  static const upcoming = Icons.upcoming_rounded;
  static const contactSchool = FontAwesomeIcons.phone;
  static const creditsWallet = Icons.account_balance_wallet_rounded;
}

class TeacherIcons {
  static const classes = Icons.school_rounded;
  static const schedule = Icons.schedule_rounded;
  static const mail = FontAwesomeIcons.envelope;
  static const reminders = Icons.alarm_rounded;
  static const onlineBooking = FontAwesomeIcons.calendarCheck;
  static const gallery = FontAwesomeIcons.images;
  static const syllabi = FontAwesomeIcons.bookBookmark;
  static const wages = FontAwesomeIcons.coins;
  static const logout = Icons.logout_rounded;
  static const menu = Icons.menu_rounded;

  static const profile = Icons.person_rounded;
  static const calendarSchedule = Icons.calendar_today_rounded;
  static const games = FontAwesomeIcons.gamepad;
  static const stories = FontAwesomeIcons.book;
  static const onlineCircle = FontAwesomeIcons.video;
  static const regulations = Icons.policy_rounded;
  static const shared = Icons.folder_shared_rounded;
  static const myPlatform = Icons.hub_rounded;
  static const theme = Icons.palette_rounded;
  static const instructions = FontAwesomeIcons.bookOpenReader;

  static const mailStat = FontAwesomeIcons.envelope;
  static const homeworkStat = FontAwesomeIcons.bookOpen;
  static const reminderStat = Icons.alarm_rounded;
  static const learnersStat = FontAwesomeIcons.userGroup;
  static const onlineStat = FontAwesomeIcons.video;

  static const liveIndicator = Icons.circle;
  static const soonWarning = Icons.warning_amber_rounded;
  static const countdown = Icons.timer_rounded;
  static const videoCall = FontAwesomeIcons.video;
  static const inPerson = Icons.access_time_rounded;

  static const chevron = Icons.chevron_right_rounded;
  static const overviewLearners = Icons.groups_rounded;
  static const overviewOnline = Icons.videocam_rounded;
  static const nextClassCalendar = Icons.calendar_today_rounded;
  static const nextClassSchedule = Icons.schedule_rounded;
  static const nextClassBadge = Icons.badge_rounded;
  static const themeSelected = Icons.check_circle_rounded;
  static const themeUnselected = Icons.circle_outlined;
}

class MainIcons {
  static const school = Icons.school_rounded;
  static const shield = FontAwesomeIcons.shieldHalved;
  static const premium = Icons.workspace_premium_rounded;
  static const openInNew = Icons.open_in_new_rounded;
  static const groups = Icons.groups_rounded;
  static const brokenImage = Icons.broken_image_outlined;
  static const schedule = Icons.schedule_rounded;
  static const timer = Icons.timer_outlined;
  static const info = Icons.info_outline_rounded;
  static const chevronRight = Icons.chevron_right_rounded;
  static const close = Icons.close_rounded;
  static const search = Icons.search_rounded;
  static const logout = Icons.logout_rounded;
  static const palette = Icons.palette_outlined;

  static const calendar = Icons.calendar_today_rounded;
  static const accessTime = Icons.access_time_filled_rounded;
  static const notes = Icons.notes_rounded;
  static const star = Icons.star_rounded;
  static const starBorder = Icons.star_border_rounded;
  static const listAlt = Icons.list_alt_rounded;
  static const imageNotSupported = Icons.image_not_supported_rounded;
  static const howToReg = Icons.how_to_reg_rounded;
  static const category = Icons.category_rounded;
  static const payments = Icons.payments_rounded;
  static const systemUpdate = Icons.system_update_rounded;
  static const person = Icons.person_rounded;
  static const arrowForward = Icons.arrow_forward_rounded;
  static const eventBusy = Icons.event_busy_rounded;
  static const videocam = Icons.videocam_rounded;
  static const playCircle = Icons.play_circle_fill_rounded;
  static const photoLibrary = Icons.photo_library_rounded;
  static const photo = Icons.photo_rounded;
  static const checkCircle = Icons.check_circle_rounded;
  static const infoCircle = Icons.info_outline_rounded;
}
