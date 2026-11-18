const _monthsShort = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
];
const _monthsLong = [
  'January', 'February', 'March', 'April', 'May', 'June', 'July',
  'August', 'September', 'October', 'November', 'December'
];

String fmtSize(num mb) {
  if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(2)} GB';
  if (mb < 1) {
    final kb = (mb * 1024).round();
    return '${kb < 1 ? 1 : kb} KB';
  }
  final isInt = mb.truncateToDouble() == mb;
  return '${isInt ? mb.toStringAsFixed(0) : mb.toStringAsFixed(1)} MB';
}

String fmtDuration(num s) {
  final n = s < 0 ? 0 : s.floor();
  if (n >= 60) return '${n ~/ 60}m ${n % 60}s';
  return '${n}s';
}

/// Live-transfer formatter: takes BYTES (engine events are byte-based),
/// unlike [fmtSize] which takes the history's megabyte convention.
String fmtBytes(num b) {
  if (b >= 1099511627776) return '${(b / 1099511627776).toStringAsFixed(2)} TB';
  if (b >= 1073741824) return '${(b / 1073741824).toStringAsFixed(2)} GB';
  if (b >= 1048576) {
    final mb = b / 1048576;
    return '${mb.truncateToDouble() == mb ? mb.toStringAsFixed(0) : mb.toStringAsFixed(1)} MB';
  }
  if (b >= 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
  return '${b < 1 ? 1 : b.round()} B';
}

/// File-type icon (bLinker icon names) from a file name's extension.
String fileIconFor(String name) {
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  if (['jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'bmp', 'dng']
      .contains(ext)) return 'photo';
  if (['mp4', 'mkv', 'mov', 'avi', 'webm', '3gp'].contains(ext)) return 'video';
  if (['mp3', 'm4a', 'flac', 'wav', 'ogg', 'aac', 'opus'].contains(ext)) {
    return 'music';
  }
  return 'file';
}

String initials(String name) => name
    .split(RegExp(r"[\s'’]+"))
    .where((x) => x.isNotEmpty)
    .take(2)
    .map((x) => x[0])
    .join()
    .toUpperCase();

String dateText(String iso) {
  final d = DateTime.tryParse(iso);
  if (d == null) return '';
  return '${_monthsShort[d.month - 1]} ${d.day}';
}

String fullDate(String iso) {
  final d = DateTime.tryParse(iso);
  if (d == null) return '';
  final h = d.hour == 0 ? 12 : (d.hour > 12 ? d.hour - 12 : d.hour);
  final ampm = d.hour >= 12 ? 'PM' : 'AM';
  final mm = d.minute.toString().padLeft(2, '0');
  return '${_monthsLong[d.month - 1]} ${d.day}, ${d.year} · $h:$mm $ampm';
}
