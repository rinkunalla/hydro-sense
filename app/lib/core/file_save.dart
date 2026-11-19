// Saves a text file in the browser (the website's Download CSV). The phone
// app never calls it, so the Android build gets a stub without browser APIs.
export 'file_save_stub.dart' if (dart.library.js_interop) 'file_save_web.dart';
