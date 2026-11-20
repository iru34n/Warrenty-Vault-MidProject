import 'package:shared_preferences/shared_preferences.dart';
import '../models/purchase.dart';

String formatClock(int hour, int minute) {
  final h12 = hour % 12 == 0 ? 12 : hour % 12;
  final suffix = hour < 12 ? 'AM' : 'PM';
  return '$h12:${minute.toString().padLeft(2, '0')} $suffix';
}

/// Everything the user can customise about expiry reminders.
class NotificationPrefs {
  static const int maxLeadTimes = 8;
  static const List<int> presetLeadDays = [1, 3, 7, 14, 30, 60, 90];
  static const List<int> soonWindowChoices = [7, 14, 30, 60, 90];

  final bool enabled;
  /// Days before the expiry date at which a reminder is sent (unique, newest-first order = largest first).
  final List<int> leadDays;
  final int hour;
  final int minute;
  final bool notifyOnExpiry;
  final bool catchUp;
  final bool sound;
  final bool vibrate;
  final int expiringSoonDays;

  const NotificationPrefs({
    this.enabled = true,
    this.leadDays = const [7],
    this.hour = 9,
    this.minute = 0,
    this.notifyOnExpiry = true,
    this.catchUp = true,
    this.sound = true,
    this.vibrate = true,
    this.expiringSoonDays = 30,
  });

  static List<int> normalizeLeadDays(Iterable<int> days) {
    final unique = days.where((d) => d >= 1 && d <= 365).toSet().toList()..sort((a, b) => b.compareTo(a));
    return unique.length > maxLeadTimes ? unique.sublist(0, maxLeadTimes) : unique;
  }

  NotificationPrefs copyWith({
    bool? enabled,
    List<int>? leadDays,
    int? hour,
    int? minute,
    bool? notifyOnExpiry,
    bool? catchUp,
    bool? sound,
    bool? vibrate,
    int? expiringSoonDays,
  }) =>
      NotificationPrefs(
        enabled: enabled ?? this.enabled,
        leadDays: leadDays == null ? this.leadDays : normalizeLeadDays(leadDays),
        hour: (hour ?? this.hour).clamp(0, 23).toInt(),
        minute: (minute ?? this.minute).clamp(0, 59).toInt(),
        notifyOnExpiry: notifyOnExpiry ?? this.notifyOnExpiry,
        catchUp: catchUp ?? this.catchUp,
        sound: sound ?? this.sound,
        vibrate: vibrate ?? this.vibrate,
        expiringSoonDays: (expiringSoonDays ?? this.expiringSoonDays).clamp(1, 365).toInt(),
      );

  /// One-line description shown on the Settings tile.
  String get summary {
    if (!enabled) return 'Turned off';
    final parts = <String>[];
    if (leadDays.isNotEmpty) {
      parts.add('${leadDays.join(', ')} ${leadDays.length == 1 && leadDays.first == 1 ? 'day' : 'days'} before at ${formatClock(hour, minute)}');
    }
    if (notifyOnExpiry) parts.add('on expiry day');
    return parts.isEmpty ? 'No reminders selected' : parts.join(' and ');
  }
}

class BackupPrefs {
  static const List<String> autoChoices = ['off', 'daily', 'weekly', 'monthly'];
  static const List<int> keepChoices = [1, 2, 3, 5, 10];

  final bool includePhotos;
  final int keepCount;
  final String autoFrequency;
  final int? lastBackupMs;

  const BackupPrefs({this.includePhotos = true, this.keepCount = 3, this.autoFrequency = 'off', this.lastBackupMs});

  BackupPrefs copyWith({bool? includePhotos, int? keepCount, String? autoFrequency, int? lastBackupMs}) => BackupPrefs(
        includePhotos: includePhotos ?? this.includePhotos,
        keepCount: (keepCount ?? this.keepCount).clamp(1, 10).toInt(),
        autoFrequency: autoChoices.contains(autoFrequency ?? this.autoFrequency) ? (autoFrequency ?? this.autoFrequency) : 'off',
        lastBackupMs: lastBackupMs ?? this.lastBackupMs,
      );

  int get autoIntervalDays => switch (autoFrequency) { 'daily' => 1, 'weekly' => 7, 'monthly' => 30, _ => 0 };

  DateTime? get lastBackup => lastBackupMs == null ? null : DateTime.fromMillisecondsSinceEpoch(lastBackupMs!);

  bool isAutoDue(DateTime now) {
    final interval = autoIntervalDays;
    if (interval == 0) return false;
    final last = lastBackup;
    if (last == null) return true;
    return now.difference(last) >= Duration(days: interval);
  }
}

class ExportPrefs {
  /// Empty list means "all columns".
  final List<String> csvColumns;
  final String csvStatus;
  final String csvCategory;
  final bool csvBom;
  final bool zipIncludePhotos;
  final bool zipIncludeCsv;

  const ExportPrefs({
    this.csvColumns = const [],
    this.csvStatus = 'All',
    this.csvCategory = 'All',
    this.csvBom = true,
    this.zipIncludePhotos = true,
    this.zipIncludeCsv = false,
  });

  ExportPrefs copyWith({
    List<String>? csvColumns,
    String? csvStatus,
    String? csvCategory,
    bool? csvBom,
    bool? zipIncludePhotos,
    bool? zipIncludeCsv,
  }) =>
      ExportPrefs(
        csvColumns: csvColumns ?? this.csvColumns,
        csvStatus: csvStatus ?? this.csvStatus,
        csvCategory: csvCategory ?? this.csvCategory,
        csvBom: csvBom ?? this.csvBom,
        zipIncludePhotos: zipIncludePhotos ?? this.zipIncludePhotos,
        zipIncludeCsv: zipIncludeCsv ?? this.zipIncludeCsv,
      );
}

class AppSettings {
  AppSettings._();
  static final AppSettings instance = AppSettings._();

  NotificationPrefs notifications = const NotificationPrefs();
  BackupPrefs backup = const BackupPrefs();
  ExportPrefs export = const ExportPrefs();

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final lead = prefs.getStringList('notif_lead_days');
    notifications = NotificationPrefs(
      enabled: prefs.getBool('notif_enabled') ?? true,
      leadDays: lead == null ? const [7] : NotificationPrefs.normalizeLeadDays(lead.map((e) => int.tryParse(e) ?? 0)),
      hour: (prefs.getInt('notif_hour') ?? 9).clamp(0, 23).toInt(),
      minute: (prefs.getInt('notif_minute') ?? 0).clamp(0, 59).toInt(),
      notifyOnExpiry: prefs.getBool('notif_on_expiry') ?? true,
      catchUp: prefs.getBool('notif_catch_up') ?? true,
      sound: prefs.getBool('notif_sound') ?? true,
      vibrate: prefs.getBool('notif_vibrate') ?? true,
      expiringSoonDays: (prefs.getInt('notif_soon_days') ?? 30).clamp(1, 365).toInt(),
    );
    backup = const BackupPrefs().copyWith(
      includePhotos: prefs.getBool('backup_include_photos') ?? true,
      keepCount: prefs.getInt('backup_keep_count') ?? 3,
      autoFrequency: prefs.getString('backup_auto') ?? 'off',
      lastBackupMs: prefs.getInt('backup_last_ms'),
    );
    export = ExportPrefs(
      csvColumns: prefs.getStringList('csv_columns') ?? const [],
      csvStatus: prefs.getString('csv_status') ?? 'All',
      csvCategory: prefs.getString('csv_category') ?? 'All',
      csvBom: prefs.getBool('csv_bom') ?? true,
      zipIncludePhotos: prefs.getBool('zip_include_photos') ?? true,
      zipIncludeCsv: prefs.getBool('zip_include_csv') ?? false,
    );
    expiringSoonWindowDays = notifications.expiringSoonDays;
  }

  Future<void> saveNotifications(NotificationPrefs value) async {
    notifications = value;
    expiringSoonWindowDays = value.expiringSoonDays;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('notif_enabled', value.enabled);
    await prefs.setStringList('notif_lead_days', value.leadDays.map((e) => e.toString()).toList());
    await prefs.setInt('notif_hour', value.hour);
    await prefs.setInt('notif_minute', value.minute);
    await prefs.setBool('notif_on_expiry', value.notifyOnExpiry);
    await prefs.setBool('notif_catch_up', value.catchUp);
    await prefs.setBool('notif_sound', value.sound);
    await prefs.setBool('notif_vibrate', value.vibrate);
    await prefs.setInt('notif_soon_days', value.expiringSoonDays);
  }

  Future<void> saveBackup(BackupPrefs value) async {
    backup = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('backup_include_photos', value.includePhotos);
    await prefs.setInt('backup_keep_count', value.keepCount);
    await prefs.setString('backup_auto', value.autoFrequency);
    if (value.lastBackupMs != null) await prefs.setInt('backup_last_ms', value.lastBackupMs!);
  }

  Future<void> saveExport(ExportPrefs value) async {
    export = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('csv_columns', value.csvColumns);
    await prefs.setString('csv_status', value.csvStatus);
    await prefs.setString('csv_category', value.csvCategory);
    await prefs.setBool('csv_bom', value.csvBom);
    await prefs.setBool('zip_include_photos', value.zipIncludePhotos);
    await prefs.setBool('zip_include_csv', value.zipIncludeCsv);
  }
}
