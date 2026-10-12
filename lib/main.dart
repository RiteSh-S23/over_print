import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

import 'download_stub.dart' if (dart.library.js_interop) 'download_web.dart';

void main() => runApp(const OverprintApp());

class OverprintApp extends StatelessWidget {
  const OverprintApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Overprint',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF2A3FE0),
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFF2A3FE0),
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const HomePage(),
    );
  }
}

enum WmStyle { diagonal, straight, tiled }

/// Arguments for the background isolate (must be plain data).
class _Job {
  _Job(this.bytes, this.text, this.style, this.sizePct, this.opacity, this.color);
  final Uint8List bytes;
  final String text;
  final int style; // WmStyle index
  final double sizePct; // 0.04 - 0.24 of page width
  final double opacity; // 0.05 - 0.60
  final int color; // ARGB
}

/// Adds the watermark to every page and returns the new PDF bytes.
Uint8List _applyWatermark(_Job job) {
  final doc = PdfDocument(inputBytes: job.bytes);
  final style = WmStyle.values[job.style];
  final r = (job.color >> 16) & 0xFF, g = (job.color >> 8) & 0xFF, b = job.color & 0xFF;

  for (var i = 0; i < doc.pages.count; i++) {
    final page = doc.pages[i];
    final size = page.getClientSize();
    final w = size.width, h = size.height;

    var fontSize = w * job.sizePct * (style == WmStyle.tiled ? 0.45 : 1.0);
    var font = PdfStandardFont(PdfFontFamily.helvetica, fontSize, style: PdfFontStyle.bold);
    var ts = font.measureString(job.text);
    final cap = style == WmStyle.diagonal
        ? w * 1.15
        : style == WmStyle.straight
            ? w * 0.9
            : double.infinity;
    if (ts.width > cap) {
      fontSize = fontSize * cap / ts.width;
      font = PdfStandardFont(PdfFontFamily.helvetica, fontSize, style: PdfFontStyle.bold);
      ts = font.measureString(job.text);
    }

    final gfx = page.graphics;
    final brush = PdfSolidBrush(PdfColor(r, g, b));
    gfx.save();
    gfx.setTransparency(job.opacity);
    gfx.translateTransform(w / 2, h / 2);

    void drawAt(double x, double y) {
      gfx.drawString(
        job.text,
        font,
        brush: brush,
        bounds: Rect.fromLTWH(x - ts.width / 2, y - ts.height / 2, ts.width, ts.height),
      );
    }

    if (style == WmStyle.diagonal) {
      gfx.rotateTransform(-45);
      drawAt(0, 0);
    } else if (style == WmStyle.straight) {
      drawAt(0, 0);
    } else {
      gfx.rotateTransform(-30);
      final reach = math.sqrt(w * w + h * h) / 2 + ts.width;
      final sx = ts.width * 1.35 + ts.height;
      final sy = ts.height * 4.2;
      var row = 0;
      for (var y = -reach; y <= reach; y += sy, row++) {
        final off = row.isOdd ? sx / 2 : 0.0;
        for (var x = -reach + off; x <= reach; x += sx) {
          drawAt(x, y);
        }
      }
    }
    gfx.restore();
  }

  final out = Uint8List.fromList(doc.saveSync());
  doc.dispose();
  return out;
}

int _countPages(Uint8List bytes) {
  final doc = PdfDocument(inputBytes: bytes);
  final n = doc.pages.count;
  doc.dispose();
  return n;
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _text = TextEditingController(text: 'CONFIDENTIAL');

  Uint8List? _bytes;
  String _name = '';
  int _pages = 0;

  WmStyle _style = WmStyle.diagonal;
  double _size = 12; // percent of page width
  double _opacity = 22; // percent
  Color _color = const Color(0xFF7D8494);

  bool _busy = false;
  Uint8List? _result;
  String? _message;
  bool _error = false;

  static const _swatches = <String, Color>{
    'Grey': Color(0xFF7D8494),
    'Red': Color(0xFFD6332B),
    'Blue': Color(0xFF2A3FE0),
    'Black': Color(0xFF111111),
  };

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _say(String? msg, {bool error = false}) {
    setState(() {
      _message = msg;
      _error = error;
    });
  }

  Future<void> _pick() async {
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['pdf'],
        withData: true,
      );
      if (res == null || res.files.isEmpty) return;
      final f = res.files.first;
      final bytes = f.bytes ?? (f.path != null ? await File(f.path!).readAsBytes() : null);
      if (bytes == null) {
        _say('The file could not be read. Try choosing it again.', error: true);
        return;
      }
      final pages = await compute(_countPages, bytes);
      setState(() {
        _bytes = bytes;
        _name = f.name;
        _pages = pages;
        _result = null;
        _message = null;
      });
    } catch (_) {
      _say('This PDF could not be opened. It may be damaged or password protected.', error: true);
    }
  }

  Future<void> _apply() async {
    final bytes = _bytes;
    final text = _text.text.trim();
    if (bytes == null || text.isEmpty) return;
    setState(() {
      _busy = true;
      _result = null;
      _message = 'Adding watermark to $_pages ${_pages == 1 ? 'page' : 'pages'}…';
      _error = false;
    });
    try {
      final out = await compute(
        _applyWatermark,
        _Job(bytes, text, _style.index, _size / 100, _opacity / 100, _color.value),
      );
      setState(() {
        _result = out;
        _message = 'Done. Watermark added to $_pages ${_pages == 1 ? 'page' : 'pages'}.';
        _error = false;
      });
    } catch (_) {
      _say('The watermark could not be added. Use Latin letters and numbers, or check that the PDF is not protected.',
          error: true);
    } finally {
      setState(() => _busy = false);
    }
  }

  String get _outName => '${_name.replaceAll(RegExp(r'\.pdf$', caseSensitive: false), '')}-watermarked.pdf';

  Future<void> _save() async {
    final out = _result;
    if (out == null) return;
    if (kIsWeb) {
      try {
        downloadBytes(out, _outName);
        _say('Downloaded $_outName. Check your browser downloads.');
      } catch (_) {
        _say('The file could not be downloaded. Allow downloads for this site and try again.', error: true);
      }
      return;
    }
    try {
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Save watermarked PDF',
        fileName: _outName,
        type: FileType.custom,
        allowedExtensions: const ['pdf'],
        bytes: out,
      );
      if (path != null || Platform.isAndroid || Platform.isIOS) {
        _say('Saved $_outName.');
      }
    } catch (_) {
      _say('The file could not be saved. Try Share instead.', error: true);
    }
  }

  Future<void> _share() async {
    final out = _result;
    if (out == null) return;
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$_outName');
    await file.writeAsBytes(out, flush: true);
    await Share.shareXFiles([XFile(file.path, mimeType: 'application/pdf')]);
  }


  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final canApply =
        _bytes != null && _text.text.trim().isNotEmpty && !_busy;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF5145E5), Color(0xFF8175FF)],
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.layers_rounded,
                color: Colors.white,
                size: 23,
              ),
            ),
            const SizedBox(width: 11),
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Overprint',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 19,
                    letterSpacing: -0.5,
                  ),
                ),
                Text(
                  'Designed by Ritesh Singh',
                  style: TextStyle(
                    fontSize: 9,
                    letterSpacing: 1.5,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF777B91),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(18, 10, 18, 28),
              children: [
                // Hero section
                Container(
                  padding: const EdgeInsets.all(23),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Color(0xFF5145E5),
                        Color(0xFF7165F5),
                        Color(0xFF9488FF),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(25),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF5145E5).withOpacity(0.20),
                        blurRadius: 24,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: Stack(
                    children: [
                      Positioned(
                        right: -5,
                        top: -7,
                        child: Icon(
                          Icons.picture_as_pdf_rounded,
                          size: 110,
                          color: Colors.white.withOpacity(0.10),
                        ),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.16),
                              borderRadius: BorderRadius.circular(30),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.auto_awesome_rounded,
                                    size: 14, color: Colors.white),
                                SizedBox(width: 6),
                                Text(
                                  'SIMPLE. SECURE. EFFICIENT.',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    letterSpacing: 1,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 19),
                          const Text(
                            'Make your PDFs\nstand out.',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 29,
                              height: 1.15,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.8,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            'Add professional watermarks to every page '
                                'in just a few clicks.',
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.85),
                              fontSize: 13,
                              height: 1.6,
                            ),
                          ),
                          const SizedBox(height: 19),
                          const Row(
                            children: [
                              Icon(Icons.verified_user_rounded,
                                  size: 15, color: Colors.white),
                              SizedBox(width: 7),
                              Text(
                                'Files processed on your device',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 25),

                const Text(
                  'Create your watermark',
                  style: TextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                    color: Color(0xFF9CA2BD),
                  ),
                ),
                const SizedBox(height: 5),
                const Text(
                  'Follow these three steps to get started.',
                  style: TextStyle(
                    color: Color(0xFF777B91),
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 20),

                // Step 1
                _StepCard(
                  number: 1,
                  title: 'Choose your PDF',
                  child: _bytes == null
                      ? InkWell(
                    onTap: _busy ? null : _pick,
                    borderRadius: BorderRadius.circular(17),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        vertical: 25,
                        horizontal: 15,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF7F6FF),
                        borderRadius: BorderRadius.circular(17),
                        border: Border.all(
                          color: const Color(0xFFCDC8FF),
                          width: 1.3,
                        ),
                      ),
                      child: Column(
                        children: [
                          Container(
                            width: 55,
                            height: 55,
                            decoration: BoxDecoration(
                              color: const Color(0xFFE9E6FF),
                              borderRadius: BorderRadius.circular(17),
                            ),
                            child: const Icon(
                              Icons.cloud_upload_rounded,
                              color: Color(0xFF5145E5),
                              size: 29,
                            ),
                          ),
                          const SizedBox(height: 13),
                          const Text(
                            'Tap to upload your PDF',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                              color: Color(0xFF282747),
                            ),
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            'Select a PDF from your device',
                            style: TextStyle(
                              fontSize: 12,
                              color: Color(0xFF777B91),
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                      : Container(
                    padding: const EdgeInsets.all(13),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF7F8FC),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: const Color(0xFFE7E8F0),
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 48,
                          height: 52,
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFE8E8),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(
                            Icons.picture_as_pdf_rounded,
                            color: Color(0xFFD63345),
                            size: 26,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 5),
                              Text(
                                '$_pages ${_pages == 1 ? 'page' : 'pages'}'
                                    '  •  '
                                    '${(_bytes!.length / 1048576).toStringAsFixed(1)} MB',
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Color(0xFF777B91),
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: 'Change PDF',
                          onPressed: _busy ? null : _pick,
                          icon: const Icon(
                            Icons.swap_horiz_rounded,
                            color: Color(0xFF5145E5),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // Step 2
                _StepCard(
                  number: 2,
                  title: 'Customize watermark',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Watermark text',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF555970),
                        ),
                      ),
                      const SizedBox(height: 9),
                      TextField(
                        controller: _text,
                        maxLength: 80,
                        onChanged: (_) => setState(() => _result = null),
                        decoration: const InputDecoration(
                          hintText: 'e.g. CONFIDENTIAL',
                          prefixIcon: Icon(Icons.text_fields_rounded),
                          counterStyle: TextStyle(fontSize: 10),
                        ),
                      ),
                      const SizedBox(height: 16),

                      const Text(
                        'Watermark style',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF555970),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          for (final item in [
                            (
                            style: WmStyle.diagonal,
                            label: 'Diagonal',
                            icon: Icons.north_east_rounded,
                            ),
                            (
                            style: WmStyle.straight,
                            label: 'Straight',
                            icon: Icons.horizontal_rule_rounded,
                            ),
                            (
                            style: WmStyle.tiled,
                            label: 'Tiled',
                            icon: Icons.grid_view_rounded,
                            ),
                          ])
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.only(right: 7),
                                child: InkWell(
                                  onTap: () => setState(() {
                                    _style = item.style;
                                    _result = null;
                                  }),
                                  borderRadius: BorderRadius.circular(14),
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 180),
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 13,
                                      horizontal: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: _style == item.style
                                          ? const Color(0xFFF0EEFF)
                                          : const Color(0xFFF7F8FC),
                                      borderRadius: BorderRadius.circular(14),
                                      border: Border.all(
                                        color: _style == item.style
                                            ? const Color(0xFF7668F5)
                                            : const Color(0xFFE8E9F1),
                                        width: _style == item.style ? 1.5 : 1,
                                      ),
                                    ),
                                    child: Column(
                                      children: [
                                        Icon(
                                          item.icon,
                                          size: 21,
                                          color: _style == item.style
                                              ? const Color(0xFF5145E5)
                                              : const Color(0xFF777B91),
                                        ),
                                        const SizedBox(height: 8),
                                        Text(
                                          item.label,
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: _style == item.style
                                                ? FontWeight.w700
                                                : FontWeight.w500,
                                            color: _style == item.style
                                                ? const Color(0xFF5145E5)
                                                : const Color(0xFF555970),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 23),

                      Row(
                        children: [
                          const Icon(
                            Icons.format_size_rounded,
                            size: 18,
                            color: Color(0xFF5145E5),
                          ),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text(
                              'Text size',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                              ),
                            ),
                          ),
                          _valuePill('${_size.round()}%'),
                        ],
                      ),
                      Slider(
                        value: _size,
                        min: 4,
                        max: 24,
                        divisions: 20,
                        onChanged: (v) => setState(() {
                          _size = v;
                          _result = null;
                        }),
                      ),
                      Row(
                        children: [
                          const Icon(
                            Icons.opacity_rounded,
                            size: 18,
                            color: Color(0xFF5145E5),
                          ),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text(
                              'Opacity',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                              ),
                            ),
                          ),
                          _valuePill('${_opacity.round()}%'),
                        ],
                      ),
                      Slider(
                        value: _opacity,
                        min: 5,
                        max: 60,
                        divisions: 55,
                        onChanged: (v) => setState(() {
                          _opacity = v;
                          _result = null;
                        }),
                      ),
                      const SizedBox(height: 12),

                      const Text(
                        'Watermark colour',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                          color: Color(0xFF555970),
                        ),
                      ),
                      const SizedBox(height: 13),
                      Wrap(
                        spacing: 14,
                        runSpacing: 12,
                        children: [
                          for (final e in _swatches.entries)
                            InkWell(
                              onTap: () => setState(() {
                                _color = e.value;
                                _result = null;
                              }),
                              borderRadius: BorderRadius.circular(30),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  AnimatedContainer(
                                    duration: const Duration(milliseconds: 160),
                                    width: 27,
                                    height: 27,
                                    decoration: BoxDecoration(
                                      color: e.value,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: _color == e.value
                                            ? const Color(0xFF5145E5)
                                            : const Color(0xFFDADCE6),
                                        width: _color == e.value ? 3 : 1,
                                      ),
                                    ),
                                    child: _color == e.value
                                        ? const Icon(
                                      Icons.check_rounded,
                                      size: 15,
                                      color: Colors.white,
                                    )
                                        : null,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    e.key,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: _color == e.value
                                          ? FontWeight.w700
                                          : FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),

                // Step 3
                _StepCard(
                  number: 3,
                  title: 'Apply and export',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      FilledButton.icon(
                        onPressed: canApply ? _apply : null,
                        icon: const Icon(Icons.auto_awesome_rounded, size: 19),
                        label: const Text(
                          'Add watermark to all pages',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                        ),
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF5145E5),
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: const Color(0xFFE5E5ED),
                          disabledForegroundColor: const Color(0xFF9698A8),
                          minimumSize: const Size.fromHeight(54),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(15),
                          ),
                        ),
                      ),
                      if (_busy) ...[
                        const SizedBox(height: 15),
                        const LinearProgressIndicator(
                          borderRadius: BorderRadius.all(Radius.circular(8)),
                          color: Color(0xFF5145E5),
                        ),
                      ],
                      if (_message != null) ...[
                        const SizedBox(height: 14),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: _error
                                ? const Color(0xFFFFEEEE)
                                : const Color(0xFFF0F8F3),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                _error
                                    ? Icons.error_outline_rounded
                                    : _result != null
                                    ? Icons.check_circle_outline_rounded
                                    : Icons.info_outline_rounded,
                                size: 19,
                                color: _error
                                    ? const Color(0xFFD63345)
                                    : const Color(0xFF248653),
                              ),
                              const SizedBox(width: 9),
                              Expanded(
                                child: Text(
                                  _message!,
                                  style: TextStyle(
                                    fontSize: 12,
                                    height: 1.5,
                                    color: _error
                                        ? const Color(0xFFB42332)
                                        : const Color(0xFF276749),
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      if (_result != null) ...[
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.all(13),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF0F8F3),
                            border: Border.all(
                              color: const Color(0xFFD4EBDD),
                            ),
                            borderRadius: BorderRadius.circular(15),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.task_alt_rounded,
                                color: Color(0xFF248653),
                                size: 27,
                              ),
                              const SizedBox(width: 10),
                              const Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Your PDF is ready',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w800,
                                        fontSize: 13,
                                      ),
                                    ),
                                    SizedBox(height: 3),
                                    Text(
                                      'Watermark successfully applied',
                                      style: TextStyle(
                                        color: Color(0xFF62816D),
                                        fontSize: 11,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Icon(
                                Icons.picture_as_pdf_rounded,
                                color: Colors.red.shade400,
                                size: 25,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: _save,
                          icon: const Icon(Icons.download_rounded),
                          label: const Text(
                            'Download watermarked PDF',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF208454),
                            foregroundColor: Colors.white,
                            minimumSize: const Size.fromHeight(52),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(15),
                            ),
                          ),
                        ),
                        if (!kIsWeb) ...[
                          const SizedBox(height: 9),
                          OutlinedButton.icon(
                            onPressed: _share,
                            icon: const Icon(Icons.share_rounded),
                            label: const Text('Share PDF'),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size.fromHeight(48),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ],
                  ),
                ),

                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.shield_outlined,
                      size: 15,
                      color: cs.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Private by design · Processed on your device',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _valuePill(String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFFF0EEFF),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        value,
        style: const TextStyle(
          color: Color(0xFF5145E5),
          fontSize: 12,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}


class _StepCard extends StatelessWidget {
  const _StepCard({
    required this.number,
    required this.title,
    required this.child,
  });

  final int number;
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(21),
        border: Border.all(color: const Color(0xFFE9EAF2)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF202044).withOpacity(0.035),
            blurRadius: 18,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: const Color(0xFFF0EEFF),
                  borderRadius: BorderRadius.circular(11),
                ),
                alignment: Alignment.center,
                child: Text(
                  number.toString().padLeft(2, '0'),
                  style: const TextStyle(
                    color: Color(0xFF5145E5),
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: Color(0xFF202137),
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
              if (number == 1)
                const Icon(
                  Icons.upload_file_rounded,
                  color: Color(0xFFB0B2C2),
                  size: 20,
                )
              else if (number == 2)
                const Icon(
                  Icons.tune_rounded,
                  color: Color(0xFFB0B2C2),
                  size: 20,
                )
              else
                const Icon(
                  Icons.ios_share_rounded,
                  color: Color(0xFFB0B2C2),
                  size: 20,
                ),
            ],
          ),
          const SizedBox(height: 19),
          child,
        ],
      ),
    );
  }
}