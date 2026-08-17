import 'package:intl/intl.dart';

extension DateTimeFormatter on DateTime {
  String format() {
    return DateFormat.yMMMd().add_Hm().format(this);
  }

  String formatSubscriptionUpdate({DateTime? now}) {
    final local = toLocal();
    final reference = (now ?? DateTime.now()).toLocal();
    final updatedToday = local.year == reference.year && local.month == reference.month && local.day == reference.day;

    return updatedToday ? DateFormat.Hm().format(local) : DateFormat.MMMd().add_Hm().format(local);
  }
}
