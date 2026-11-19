import 'dart:typed_data';
import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Downloads [text] as a file named [name] (UTF-8 with a BOM, so Excel opens
/// accented names correctly).
void saveTextFile(String name, String text, {String type = 'text/csv'}) {
  final bytes = [0xEF, 0xBB, 0xBF, ...utf8.encode(text)];
  final blob = web.Blob(
    [Uint8List.fromList(bytes).toJS].toJS,
    web.BlobPropertyBag(type: '$type;charset=utf-8'),
  );
  final url = web.URL.createObjectURL(blob);
  web.HTMLAnchorElement()
    ..href = url
    ..download = name
    ..click();
  web.URL.revokeObjectURL(url);
}
