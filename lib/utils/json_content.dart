import 'dart:convert';

import 'package:marten/utils/link_parsers.dart';

Object? decodeJsonContent(String content) {
  return jsonDecode(normalizeJsonContentInput(content));
}

String normalizeJsonContentInput(String content) {
  final decoded = safeDecodeBase64(content);
  return _firstCompleteJsonValue(decoded) ?? _stripJsonBoundaryPadding(decoded);
}

String canonicalJsonContent(String content) {
  return jsonEncode(decodeJsonContent(content));
}

String _stripJsonBoundaryPadding(String value) {
  var start = 0;
  var end = value.length;

  while (start < end && _isJsonBoundaryPadding(value.codeUnitAt(start))) {
    start++;
  }
  while (end > start && _isJsonBoundaryPadding(value.codeUnitAt(end - 1))) {
    end--;
  }

  return start == 0 && end == value.length ? value : value.substring(start, end);
}

bool _isJsonBoundaryPadding(int codeUnit) {
  return codeUnit == 0 ||
      codeUnit == 0xFEFF ||
      codeUnit == 0x20 ||
      codeUnit == 0x09 ||
      codeUnit == 0x0A ||
      codeUnit == 0x0D;
}

String? _firstCompleteJsonValue(String value) {
  var start = 0;
  while (start < value.length && _isJsonBoundaryPadding(value.codeUnitAt(start))) {
    start++;
  }
  if (start >= value.length) return null;

  final first = value.codeUnitAt(start);
  if (first != 0x7B && first != 0x5B) return null;

  final stack = <int>[];
  if (first == 0x7B) {
    stack.add(0x7D);
  } else {
    stack.add(0x5D);
  }
  var inString = false;
  var escaping = false;

  for (var i = start + 1; i < value.length; i++) {
    final codeUnit = value.codeUnitAt(i);

    if (inString) {
      if (escaping) {
        escaping = false;
      } else if (codeUnit == 0x5C) {
        escaping = true;
      } else if (codeUnit == 0x22) {
        inString = false;
      }
      continue;
    }

    if (codeUnit == 0x22) {
      inString = true;
      continue;
    }

    if (codeUnit == 0x7B) {
      stack.add(0x7D);
      continue;
    }
    if (codeUnit == 0x5B) {
      stack.add(0x5D);
      continue;
    }
    if (codeUnit == 0x7D || codeUnit == 0x5D) {
      if (stack.isEmpty || stack.removeLast() != codeUnit) return null;
      if (stack.isEmpty) return value.substring(start, i + 1);
    }
  }

  return null;
}
