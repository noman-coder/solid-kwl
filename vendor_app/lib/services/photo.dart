import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';

import '../theme.dart';

/// Photo ke kaam mein jo masla aaye uska saaf (Roman Urdu) message. [openSettings] true ho to
/// screen "Settings kholein" ka button dikha sakti hai (ijazat band ho).
class PhotoException implements Exception {
  final String message;
  final bool openSettings;
  const PhotoException(this.message, {this.openSettings = false});

  @override
  String toString() => message;
}

/// Compress ke baad tayyar photo (upload ke liye).
class PhotoResult {
  final File file;
  final int bytes;
  final int width;
  final int height;
  const PhotoResult(this.file, this.bytes, this.width, this.height);
}

/// Phase V9-B: product ki photo - camera / gallery, crop, upload se pehle compress.
///
/// Compress: lambi side ~1280 px, quality ~80, target 1 MB se kam (server limit 5 MB). Bari photo ho to
/// quality / size thori thori kam karke dobara koshish karta hai.
/// Android 13+ par gallery ke liye system photo picker chalta hai (extra ijazat nahi); camera system camera
/// app se khulta hai (is liye CAMERA permission manifest mein nahi chahiye).
class PhotoService {
  static const int maxSide = 1280;
  static const int targetBytes = 1024 * 1024;

  /// (lambi side, quality) - pehli jo [targetBytes] mein aa jaye.
  static const List<(int, int)> _attempts = [(1280, 80), (1280, 70), (1024, 65), (800, 60), (640, 50)];

  static final ImagePicker _picker = ImagePicker();

  /// Compressed photos yahan rakhi jati hain (draft ke liye). Phone ka cache folder hai.
  static Directory get dir => Directory('${Directory.systemTemp.path}/vendor_photos');

  /// Sirf apne folder ki file hi hatayi jati hai.
  static bool isOurs(String path) => path.startsWith(dir.path);

  static Future<void> deleteIfOurs(String? path) async {
    if (path == null || path.isEmpty || !isOurs(path)) return;
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// Camera ya gallery se photo chunein. Cancel par null.
  static Future<String?> pick(ImageSource source) async {
    try {
      final x = await _picker.pickImage(source: source, maxWidth: 2400, maxHeight: 2400, imageQuality: 92);
      return x?.path;
    } on PlatformException catch (e) {
      final c = e.code.toLowerCase();
      if (c.contains('denied') || c.contains('permission')) {
        throw PhotoException(
          source == ImageSource.camera
              ? 'Camera ki ijazat band hai. Phone ki Settings mein Camera ki ijazat dein.'
              : 'Photos ki ijazat band hai. Phone ki Settings mein ijazat dein.',
          openSettings: true,
        );
      }
      throw PhotoException(source == ImageSource.camera
          ? 'Camera nahi khul saka. Gallery se photo chunein ya dobara koshish karein.'
          : 'Gallery nahi khul saki. Dobara koshish karein.');
    } catch (_) {
      throw const PhotoException('Photo nahi chuni ja saki. Dobara koshish karein.');
    }
  }

  /// App ko system ne photo lete waqt band kar diya ho to wo photo wapas lo (Android).
  static Future<String?> recoverLost() async {
    if (!Platform.isAndroid) return null;
    try {
      final r = await _picker.retrieveLostData();
      if (r.isEmpty) return null;
      final files = r.files;
      if (files != null && files.isNotEmpty) return files.first.path;
      return r.file?.path;
    } catch (_) {
      return null;
    }
  }

  /// Crop screen. Cancel par null (photo chunna rok diya). Crop kharab ho jaye to photo waisi hi (bina crop).
  static Future<String?> crop(String path) async {
    try {
      final c = await ImageCropper().cropImage(
        sourcePath: path,
        compressFormat: ImageCompressFormat.jpg,
        compressQuality: 92,
        uiSettings: [
          AndroidUiSettings(
            toolbarTitle: 'Photo crop karein',
            toolbarColor: kTealDark,
            toolbarWidgetColor: Colors.white,
            activeControlsWidgetColor: kTeal,
            initAspectRatio: CropAspectRatioPreset.square,
            lockAspectRatio: false,
          ),
        ],
      );
      return c?.path;
    } catch (_) {
      return path;
    }
  }

  static Future<(int, int)?> _size(Uint8List bytes) async {
    try {
      final buf = await ui.ImmutableBuffer.fromUint8List(bytes);
      final d = await ui.ImageDescriptor.encoded(buf);
      final r = (d.width, d.height);
      d.dispose();
      buf.dispose();
      return r;
    } catch (_) {
      return null;
    }
  }

  /// Photo ko chhota karo (JPEG). [maxMb] server ki hadd (form-data `max_image_mb`).
  /// Na ho sake to PhotoException.
  static Future<PhotoResult> compress(String srcPath, {int maxMb = 5}) async {
    final src = File(srcPath);
    if (!await src.exists()) throw const PhotoException('Photo mili nahi. Dobara chunein.');
    final srcBytes = await src.readAsBytes();
    final dims = await _size(srcBytes);
    await dir.create(recursive: true);
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final hardLimit = math.max(1, maxMb) * 1024 * 1024 - 64 * 1024;

    PhotoResult? best;
    for (var i = 0; i < _attempts.length; i++) {
      final (side, quality) = _attempts[i];
      int tw = side;
      int th = side;
      if (dims != null) {
        final long = math.max(dims.$1, dims.$2);
        final scale = long > side ? side / long : 1.0; // chhoti photo ko bara nahi karte
        tw = math.max(1, (dims.$1 * scale).round());
        th = math.max(1, (dims.$2 * scale).round());
      }
      final out = '${dir.path}/p_${stamp}_$i.jpg';
      XFile? x;
      try {
        x = await FlutterImageCompress.compressAndGetFile(
          srcPath,
          out,
          minWidth: tw,
          minHeight: th,
          quality: quality,
          format: CompressFormat.jpeg,
        );
      } catch (_) {
        x = null;
      }
      if (x == null) continue;
      final f = File(x.path);
      final n = await f.length();
      if (n <= 0) continue;
      final old = best;
      if (old == null || n < old.bytes) {
        best = PhotoResult(f, n, tw, th);
        if (old != null) await deleteIfOurs(old.file.path);
      } else {
        await deleteIfOurs(f.path);
      }
      if (n <= targetBytes) break;
    }
    if (best == null) {
      throw const PhotoException('Photo chhoti nahi ho saki. Koi doosri photo chunein.');
    }
    if (best.bytes > hardLimit) {
      await deleteIfOurs(best.file.path);
      throw PhotoException('Photo $maxMb MB se bari hai aur chhoti nahi ho saki. Koi doosri photo chunein.');
    }
    return best;
  }
}

/// Bytes ko "850 KB" / "1.2 MB" likho.
String fileSizeText(int bytes) {
  if (bytes >= 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  return '${(bytes / 1024).round()} KB';
}
