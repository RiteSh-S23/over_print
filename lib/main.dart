import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

void main() => runApp(const OverprintApp());

class OverprintApp extends StatelessWidget {
  const OverprintApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Overprint',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF12284C),
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFF12284C),
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const HomePage(),
    );
  }
}

enum WmStyle { diagonal, straight, tiled }

const _brand = Color(0xFF12284C);
const _green = Color(0xFF208454);
const _red = Color(0xFFD63345);
const _muted = Color(0xFF777B91);

/// Arguments for the background isolate (plain data only: paths, not bytes).
class _Job {
  _Job(this.inPath, this.outPath, this.text, this.style, this.sizePct,
      this.opacity, this.color);
  final String inPath;
  final String outPath;
  final String text;
  final int style; // WmStyle index
  final double sizePct; // 0.04 - 0.24 of page width
  final double opacity; // 0.05 - 0.60
  final int color; // ARGB
}

/// Reads the PDF from disk, watermarks every page, writes the result to disk
/// and returns the output path. No PDF bytes ever cross the isolate boundary.
String _applyWatermark(_Job job) {
  final doc = PdfDocument(inputBytes: File(job.inPath).readAsBytesSync());
  final style = WmStyle.values[job.style];
  final r = (job.color >> 16) & 0xFF,
      g = (job.color >> 8) & 0xFF,
      b = job.color & 0xFF;

  try {
    final brush = PdfSolidBrush(PdfColor(r, g, b));
    double? lastW;
    PdfStandardFont? font;
    Size? ts;
    double fontSize = 0;

    for (var i = 0; i < doc.pages.count; i++) {
      final page = doc.pages[i];
      final size = page.getClientSize();
      final w = size.width, h = size.height;

      if (lastW != w || font == null || ts == null) {
        fontSize = w * job.sizePct * (style == WmStyle.tiled ? 0.45 : 1.0);
        font = PdfStandardFont(PdfFontFamily.helvetica, fontSize,
            style: PdfFontStyle.bold);
        ts = font.measureString(job.text);
        final cap = style == WmStyle.diagonal
            ? w * 1.15
            : style == WmStyle.straight
            ? w * 0.9
            : double.infinity;
        if (ts.width > cap) {
          fontSize = fontSize * cap / ts.width;
          font = PdfStandardFont(PdfFontFamily.helvetica, fontSize,
              style: PdfFontStyle.bold);
          ts = font.measureString(job.text);
        }
        lastW = w;
      }

      final f = font;
      final t = ts;
      final gfx = page.graphics;
      gfx.save();
      gfx.setTransparency(job.opacity);
      gfx.translateTransform(w / 2, h / 2);

      void drawAt(double x, double y) {
        gfx.drawString(
          job.text,
          f,
          brush: brush,
          bounds: Rect.fromLTWH(
              x - t.width / 2, y - t.height / 2, t.width, t.height),
        );
      }

      if (style == WmStyle.diagonal) {
        gfx.rotateTransform(-45);
        drawAt(0, 0);
      } else if (style == WmStyle.straight) {
        drawAt(0, 0);
      } else {
        gfx.rotateTransform(-30);
        final reach = math.sqrt(w * w + h * h) / 2 + t.width;
        final sx = t.width * 1.35 + t.height;
        final sy = t.height * 4.2;
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

    File(job.outPath).writeAsBytesSync(doc.saveSync(), flush: true);
    return job.outPath;
  } finally {
    doc.dispose();
  }
}

/// One selected PDF (kept on disk) and, once processed, its output file.
class _PdfItem {
  _PdfItem(this.id, this.name, this.path, this.size);

  final int id;
  final String name;
  final String path;
  final int size;

  String? outPath;
  bool failed = false;

  String get outName =>
      '${name.replaceAll(RegExp(r'\.pdf$', caseSensitive: false), '')}-watermarked.pdf';
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const int _maxBytes = 400 * 1024 * 1024;
  static const int _saveAllId = -1;

  final _text = TextEditingController();
  final List<_PdfItem> _items = [];
  int _nextId = 0;

  WmStyle _style = WmStyle.diagonal;
  double _size = 12; // percent of page width
  double _opacity = 22; // percent
  Color _color = const Color(0xFF7D8494);

  bool _picking = false; // file picker / reading selection
  bool _busy = false; // watermarking
  int _current = -1; // index being processed
  int _done = 0;
  int? _savingId; // item id being saved, or _saveAllId
  String? _message;
  bool _error = false;

  static const _swatches = <String, Color>{
    'Grey': Color(0xFF7D8494),
    'Red': Color(0xFFD6332B),
    'Blue': Color(0xFF2A3FE0),
    'Black': Color(0xFF111111),
  };

  List<_PdfItem> get _ready => _items.where((e) => e.outPath != null).toList();
  bool get _saving => _savingId != null;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _say(String? msg, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _message = msg;
      _error = error;
    });
  }

  void _deleteOutput(_PdfItem i) {
    final p = i.outPath;
    if (p != null) {
      try {
        File(p).deleteSync();
      } catch (_) {}
    }
    i.outPath = null;
    i.failed = false;
  }

  /// Deletes previously generated files when any setting changes.
  void _invalidate() {
    for (final i in _items) {
      _deleteOutput(i);
    }
  }

  Future<Directory> _outDir() async {
    final base = await getTemporaryDirectory();
    final dir = Directory('${base.path}/overprint_out');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<void> _pick() async {
    if (_picking || _busy) return;
    HapticFeedback.selectionClick();
    setState(() {
      _picking = true;
      _message = null;
    });

    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['pdf'],
        allowMultiple: true,
        withData: false, // never load file contents into memory
      );
      if (res == null || res.files.isEmpty) return;

      final added = <_PdfItem>[];
      var tooBig = 0, unreadable = 0;

      for (final f in res.files) {
        final path = f.path;
        if (path == null) {
          unreadable++;
          continue;
        }
        if (f.size > _maxBytes) {
          tooBig++;
          continue;
        }
        added.add(_PdfItem(_nextId++, f.name, path, f.size));
      }

      if (!mounted) return;
      setState(() {
        _invalidate();
        _items.addAll(added);
        final problems = <String>[];
        if (tooBig > 0) problems.add('$tooBig over 400 MB');
        if (unreadable > 0) problems.add('$unreadable could not be read');
        if (problems.isNotEmpty) {
          _message = 'Skipped: ${problems.join(', ')}.';
          _error = true;
        } else if (added.isNotEmpty) {
          _message = 'Added ${added.length} ${added.length == 1 ? 'PDF' : 'PDFs'}.';
          _error = false;
        }
      });
      if (added.isNotEmpty) HapticFeedback.lightImpact();
    } catch (_) {
      _say('The files could not be read. Try choosing them again.', error: true);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  void _removeId(int id) {
    setState(() {
      final idx = _items.indexWhere((e) => e.id == id);
      if (idx < 0) return;
      _deleteOutput(_items[idx]);
      _items.removeAt(idx);
      _message = null;
    });
  }

  Future<void> _clearAll() async {
    HapticFeedback.mediumImpact();
    setState(() {
      _invalidate();
      _items.clear();
      _message = null;
    });
    try {
      // Frees the copies the picker made in the app cache.
      await FilePicker.platform.clearTemporaryFiles();
    } catch (_) {}
  }

  Future<void> _apply() async {
    final text = _text.text.trim();
    if (_items.isEmpty || text.isEmpty || _busy) return;
    HapticFeedback.mediumImpact();

    setState(() {
      _busy = true;
      _done = 0;
      _current = 0;
      _invalidate();
      _message = null;
      _error = false;
    });

    final dir = await _outDir();
    var failed = 0;

    for (var i = 0; i < _items.length; i++) {
      final item = _items[i];
      if (!mounted) return;
      setState(() => _current = i);

      try {
        // One file at a time keeps peak memory to a single document.
        item.outPath = await compute(
          _applyWatermark,
          _Job(
            item.path,
            '${dir.path}/${item.id}-${item.outName}',
            text,
            _style.index,
            _size / 100,
            _opacity / 100,
            _color.value,
          ),
        );
      } catch (_) {
        item.failed = true;
        failed++;
      }

      if (!mounted) return;
      setState(() => _done = i + 1);
    }

    final ok = _items.length - failed;
    if (!mounted) return;
    setState(() {
      _busy = false;
      _current = -1;
      if (failed == 0) {
        _message = 'Done. Watermark added to $ok ${ok == 1 ? 'PDF' : 'PDFs'}.';
        _error = false;
      } else {
        _message = '$ok done, $failed failed. The failed PDFs may be '
            'password protected, damaged, or too large for this device\'s memory.';
        _error = ok == 0;
      }
    });
    HapticFeedback.heavyImpact();
  }

  /// Opens the Android share sheet with the file(s) streamed from disk.
  /// From there the user can pick "Save to device", Drive, WhatsApp, etc.
  Future<void> _shareFiles(List<_PdfItem> items, int id) async {
    if (_saving) return;
    final files = [
      for (final i in items)
        if (i.outPath != null)
          XFile(i.outPath!, mimeType: 'application/pdf', name: i.outName),
    ];
    if (files.isEmpty) return;

    HapticFeedback.selectionClick();
    setState(() => _savingId = id);
    try {
      // Let the loader paint before the share sheet takes over.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await Share.shareXFiles(files);
    } catch (_) {
      _say('Could not open the share sheet. Try fewer files at a time.',
          error: true);
    } finally {
      if (mounted) setState(() => _savingId = null);
    }
  }

  String _sizeLabel(int bytes) => bytes >= 1048576
      ? '${(bytes / 1048576).toStringAsFixed(1)} MB'
      : '${(bytes / 1024).toStringAsFixed(0)} KB';

  Widget _spinner({Color color = Colors.white, double size = 18}) => SizedBox(
    width: size,
    height: size,
    child: CircularProgressIndicator(strokeWidth: 2.5, color: color),
  );

  // ---------------------------------------------------------------- Step 1

  Widget _dropZone() {
    return InkWell(
      onTap: (_busy || _picking) ? null : _pick,
      borderRadius: BorderRadius.circular(17),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 25, horizontal: 15),
        decoration: BoxDecoration(
          color: const Color(0xFFF1F4FA),
          borderRadius: BorderRadius.circular(17),
          border: Border.all(color: const Color(0xFFAFC0DE), width: 1.3),
        ),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: _picking
              ? Column(
            key: const ValueKey('picking'),
            children: [
              const SizedBox(
                width: 55,
                height: 55,
                child: CircularProgressIndicator(
                  strokeWidth: 4,
                  color: _brand,
                ),
              ),
              const SizedBox(height: 13),
              const Text(
                'Reading your files…',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  color: Color(0xFF282747),
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Large PDFs can take a few seconds',
                style: TextStyle(fontSize: 12, color: _muted),
              ),
              const SizedBox(height: 14),
              const LinearProgressIndicator(
                minHeight: 4,
                color: _brand,
                borderRadius: BorderRadius.all(Radius.circular(4)),
              ),
            ],
          )
              : Column(
            key: const ValueKey('idle'),
            children: [
              Container(
                width: 55,
                height: 55,
                decoration: BoxDecoration(
                  color: const Color(0xFFD6DFEE),
                  borderRadius: BorderRadius.circular(17),
                ),
                child: const Icon(
                  Icons.cloud_upload_rounded,
                  color: _brand,
                  size: 29,
                ),
              ),
              const SizedBox(height: 13),
              const Text(
                'Tap to upload your PDFs',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  color: Color(0xFF282747),
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Select one or more PDFs (up to 400 MB each)',
                style: TextStyle(fontSize: 12, color: _muted),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusLabel(_PdfItem item, int index) {
    String text;
    Color color = _muted;
    if (item.outPath != null) {
      text = 'Done';
      color = const Color(0xFF248653);
    } else if (item.failed) {
      text = 'Failed';
      color = _red;
    } else if (_busy && index == _current) {
      text = 'Processing…';
      color = _brand;
    } else if (_busy) {
      text = 'Waiting';
    } else {
      text = 'Ready to watermark';
    }
    return Text(
      '${_sizeLabel(item.size)}  •  $text',
      style: TextStyle(
        fontSize: 11,
        color: color,
        fontWeight: color == _muted ? FontWeight.w400 : FontWeight.w600,
      ),
    );
  }

  Widget _statusIcon(_PdfItem item, int index) {
    if (item.outPath != null) {
      return const Icon(Icons.check_circle_rounded,
          color: Color(0xFF248653), size: 22);
    }
    if (item.failed) {
      return const Icon(Icons.error_rounded, color: _red, size: 22);
    }
    if (_busy && index == _current) {
      return _spinner(color: _brand, size: 20);
    }
    if (_busy) {
      return const Icon(Icons.schedule_rounded, color: Color(0xFFB0B2C2), size: 20);
    }
    return const SizedBox.shrink();
  }

  Widget _fileTile(int index) {
    final item = _items[index];
    final active = _busy && index == _current;

    return _AppearIn(
      key: ValueKey('appear-${item.id}'),
      child: Dismissible(
        key: ValueKey('file-${item.id}'),
        direction: _busy ? DismissDirection.none : DismissDirection.endToStart,
        onDismissed: (_) {
          HapticFeedback.lightImpact();
          _removeId(item.id);
        },
        background: Container(
          margin: const EdgeInsets.only(bottom: 9),
          padding: const EdgeInsets.only(right: 20),
          alignment: Alignment.centerRight,
          decoration: BoxDecoration(
            color: const Color(0xFFFFE8E8),
            borderRadius: BorderRadius.circular(16),
          ),
          child: const Icon(Icons.delete_rounded, color: _red),
        ),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          margin: const EdgeInsets.only(bottom: 9),
          padding: const EdgeInsets.all(11),
          decoration: BoxDecoration(
            color: active ? const Color(0xFFE8EDF6) : const Color(0xFFF7F8FC),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: active ? const Color(0xFF3A5B94) : const Color(0xFFE7E8F0),
              width: active ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 46,
                decoration: BoxDecoration(
                  color: const Color(0xFFFFE8E8),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.picture_as_pdf_rounded,
                    color: _red, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF202137),
                      ),
                    ),
                    const SizedBox(height: 4),
                    _statusLabel(item, index),
                  ],
                ),
              ),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                transitionBuilder: (c, a) =>
                    ScaleTransition(scale: a, child: c),
                child: KeyedSubtree(
                  key: ValueKey(
                      '${item.outPath != null}-${item.failed}-$active-$_busy'),
                  child: _statusIcon(item, index),
                ),
              ),
              IconButton(
                tooltip: 'Remove',
                onPressed: _busy ? null : () => _removeId(item.id),
                icon: const Icon(Icons.close_rounded, color: _muted, size: 20),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _fileList() {
    final totalSize = _items.fold<int>(0, (s, e) => s + e.size);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < _items.length; i++) _fileTile(i),
        const SizedBox(height: 3),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: (_busy || _picking) ? null : _pick,
                icon: _picking
                    ? _spinner(color: _brand, size: 16)
                    : const Icon(Icons.add_rounded),
                label: Text(_picking ? 'Reading files…' : 'Add more PDFs'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(44),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(13),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 9),
            TextButton(
              onPressed: (_busy || _picking) ? null : _clearAll,
              child: const Text('Clear all'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '${_items.length} ${_items.length == 1 ? 'file' : 'files'}'
              '  •  ${_sizeLabel(totalSize)} in total'
              '${_busy ? '' : '  •  swipe left to remove'}',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 11, color: _muted),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- Step 3

  Widget _progressCard() {
    final total = _items.length;
    final name = (_current >= 0 && _current < total) ? _items[_current].name : '';
    return _AppearIn(
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFFE8EDF6),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: const Color(0xFFC4D1E8)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _spinner(color: _brand, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Watermarking ${math.min(_current + 1, total)} of $total',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                      color: Color(0xFF282747),
                    ),
                  ),
                ),
                Text(
                  '$_done/$total done',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: _brand,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            // Indeterminate for a single file (no measurable progress);
            // determinate across files when there are several.
            TweenAnimationBuilder<double>(
              duration: const Duration(milliseconds: 400),
              tween: Tween(begin: 0, end: total > 1 ? _done / total : 0),
              builder: (_, v, __) => LinearProgressIndicator(
                value: total > 1 ? v : null,
                minHeight: 6,
                color: _brand,
                backgroundColor: const Color(0xFFD3DDEE),
                borderRadius: const BorderRadius.all(Radius.circular(6)),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              name.isEmpty ? 'Large files can take a while.' : name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: _muted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _readyPanel(List<_PdfItem> ready) {
    return _AppearIn(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              color: const Color(0xFFF0F8F3),
              border: Border.all(color: const Color(0xFFD4EBDD)),
              borderRadius: BorderRadius.circular(15),
            ),
            child: Row(
              children: [
                const Icon(Icons.task_alt_rounded,
                    color: Color(0xFF248653), size: 27),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        ready.length == 1
                            ? 'Your PDF is ready'
                            : '${ready.length} PDFs are ready',
                        style: const TextStyle(
                            fontWeight: FontWeight.w800, fontSize: 13),
                      ),
                      const SizedBox(height: 3),
                      const Text(
                        'Tap save to store it on your device',
                        style: TextStyle(
                            color: Color(0xFF62816D), fontSize: 11),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.picture_as_pdf_rounded,
                    color: Colors.red.shade400, size: 25),
              ],
            ),
          ),
          const SizedBox(height: 12),
          for (final item in ready)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
              decoration: BoxDecoration(
                color: _savingId == item.id
                    ? const Color(0xFFF0F8F3)
                    : const Color(0xFFF7F8FC),
                borderRadius: BorderRadius.circular(13),
                border: Border.all(
                  color: _savingId == item.id
                      ? const Color(0xFFB9DFC8)
                      : const Color(0xFFE7E8F0),
                ),
              ),
              child: Row(
                children: [
                  const Icon(Icons.picture_as_pdf_rounded,
                      color: _red, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      item.outName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF202137),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Save / share',
                    onPressed:
                    _saving ? null : () => _shareFiles([item], item.id),
                    icon: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: _savingId == item.id
                          ? _spinner(color: _green, size: 20)
                          : const Icon(Icons.download_rounded,
                          color: _green, size: 22),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 4),
          FilledButton.icon(
            // No-op while saving keeps the button's colour instead of greying out.
            onPressed: _saving ? () {} : () => _shareFiles(ready, _saveAllId),
            icon: _savingId == _saveAllId
                ? _spinner()
                : const Icon(Icons.download_rounded),
            label: Text(
              _savingId == _saveAllId
                  ? 'Opening share sheet…'
                  : ready.length == 1
                  ? 'Save watermarked PDF'
                  : 'Save all (${ready.length} PDFs)',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            style: FilledButton.styleFrom(
              backgroundColor: _green,
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(52),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(15),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ----------------------------------------------------------------- Build

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textOk = _text.text.trim().isNotEmpty;
    final canStart = _items.isNotEmpty && textOk && !_picking;
    final ready = _ready;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.asset(
                'assets/icon/app_icon.png',
                width: 38,
                height: 38,
                fit: BoxFit.cover,
                // Falls back to the old icon if the logo file is missing.
                errorBuilder: (_, __, ___) => Container(
                  width: 38,
                  height: 38,
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      colors: [Color(0xFF12284C), Color(0xFF1A3665)],
                    ),
                  ),
                  child: const Icon(Icons.layers_rounded,
                      color: Colors.white, size: 23),
                ),
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
                    color: _muted,
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
                        Color(0xFF12284C),
                        Color(0xFF1A3665),
                        Color(0xFF24467F),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(25),
                    boxShadow: [
                      BoxShadow(
                        color: _brand.withOpacity(0.20),
                        blurRadius: 24,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: Stack(
                    children: [
                      Positioned(
                        right: -22,
                        top: -24,
                        child: Image.asset(
                          'assets/icon/icon_foreground.png',
                          width: 150,
                          height: 150,
                          fit: BoxFit.contain,
                          // Falls back to the old PDF icon if the file is missing.
                          errorBuilder: (_, __, ___) => Icon(
                            Icons.picture_as_pdf_rounded,
                            size: 110,
                            color: Colors.white.withOpacity(0.10),
                          ),
                        ),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.16),
                              borderRadius: BorderRadius.circular(30),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.auto_awesome_rounded,
                                    size: 14, color: Color(0xFFFFC83D)),
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
                            'Make your\nGKYaadRahega PDFs.',
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
                                'of multiple PDFs in just a few clicks.',
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
                  style: TextStyle(color: _muted, fontSize: 13),
                ),
                const SizedBox(height: 20),

                // Step 1
                _StepCard(
                  number: 1,
                  title: 'Choose your PDFs',
                  done: _items.isNotEmpty,
                  child: AnimatedSize(
                    duration: const Duration(milliseconds: 250),
                    alignment: Alignment.topCenter,
                    curve: Curves.easeOut,
                    child: _items.isEmpty ? _dropZone() : _fileList(),
                  ),
                ),

                // Step 2
                _StepCard(
                  number: 2,
                  title: 'Customize watermark',
                  done: textOk,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: SizedBox(
                          width: 150,
                          child: _WatermarkPreview(
                            text: _text.text,
                            style: _style,
                            sizePct: _size / 100,
                            opacity: _opacity / 100,
                            color: _color,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Center(
                        child: Text(
                          'Live preview',
                          style: TextStyle(fontSize: 10, color: _muted),
                        ),
                      ),
                      const SizedBox(height: 16),
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
                        onChanged: (_) => setState(_invalidate),
                        decoration: const InputDecoration(
                          hintText: 'Watermark',
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
                                  onTap: () {
                                    HapticFeedback.selectionClick();
                                    setState(() {
                                      _style = item.style;
                                      _invalidate();
                                    });
                                  },
                                  borderRadius: BorderRadius.circular(14),
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 180),
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 13, horizontal: 4),
                                    decoration: BoxDecoration(
                                      color: _style == item.style
                                          ? const Color(0xFFE8EDF6)
                                          : const Color(0xFFF7F8FC),
                                      borderRadius: BorderRadius.circular(14),
                                      border: Border.all(
                                        color: _style == item.style
                                            ? const Color(0xFF3A5B94)
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
                                              ? _brand
                                              : _muted,
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
                                                ? _brand
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
                          const Icon(Icons.format_size_rounded,
                              size: 18, color: _brand),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text(
                              'Text size',
                              style: TextStyle(
                                  fontWeight: FontWeight.w700, fontSize: 13),
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
                          _invalidate();
                        }),
                      ),
                      Row(
                        children: [
                          const Icon(Icons.opacity_rounded,
                              size: 18, color: _brand),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text(
                              'Opacity',
                              style: TextStyle(
                                  fontWeight: FontWeight.w700, fontSize: 13),
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
                          _invalidate();
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
                              onTap: () {
                                HapticFeedback.selectionClick();
                                setState(() {
                                  _color = e.value;
                                  _invalidate();
                                });
                              },
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
                                            ? _brand
                                            : const Color(0xFFDADCE6),
                                        width: _color == e.value ? 3 : 1,
                                      ),
                                    ),
                                    child: _color == e.value
                                        ? const Icon(Icons.check_rounded,
                                        size: 15, color: Colors.white)
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
                  done: ready.isNotEmpty && !_busy,
                  child: AnimatedSize(
                    duration: const Duration(milliseconds: 250),
                    alignment: Alignment.topCenter,
                    curve: Curves.easeOut,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        FilledButton.icon(
                          // No-op while busy keeps the purple look with the spinner.
                          onPressed:
                          !canStart ? null : (_busy ? () {} : _apply),
                          icon: _busy
                              ? _spinner()
                              : const Icon(Icons.auto_awesome_rounded,
                              size: 19),
                          label: Text(
                            _busy
                                ? 'Processing…'
                                : _items.length > 1
                                ? 'Add watermark to ${_items.length} PDFs'
                                : 'Add watermark to all pages',
                            style: const TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 14),
                          ),
                          style: FilledButton.styleFrom(
                            backgroundColor: _brand,
                            foregroundColor: Colors.white,
                            disabledBackgroundColor: const Color(0xFFE5E5ED),
                            disabledForegroundColor: const Color(0xFF9698A8),
                            minimumSize: const Size.fromHeight(54),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(15),
                            ),
                          ),
                        ),
                        if (_items.isEmpty || !textOk)
                          Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: Text(
                              _items.isEmpty
                                  ? 'Add at least one PDF to continue.'
                                  : 'Enter your watermark text to continue.',
                              textAlign: TextAlign.center,
                              style:
                              const TextStyle(fontSize: 11, color: _muted),
                            ),
                          ),
                        if (_busy) ...[
                          const SizedBox(height: 14),
                          _progressCard(),
                        ],
                        if (_message != null && !_busy) ...[
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
                                      : Icons.check_circle_outline_rounded,
                                  size: 19,
                                  color: _error
                                      ? _red
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
                        if (ready.isNotEmpty && !_busy) ...[
                          const SizedBox(height: 16),
                          _readyPanel(ready),
                        ],
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.shield_outlined,
                        size: 15, color: cs.onSurfaceVariant),
                    const SizedBox(width: 6),
                    Text(
                      'Designed By Ritesh Singh ·',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11),
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
        color: const Color(0xFFE8EDF6),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        value,
        style: const TextStyle(
          color: _brand,
          fontSize: 12,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

/// Fades and slides its child in once when first built.
class _AppearIn extends StatelessWidget {
  const _AppearIn({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      tween: Tween(begin: 0, end: 1),
      builder: (_, v, c) => Opacity(
        opacity: v,
        child: Transform.translate(offset: Offset(0, (1 - v) * 12), child: c),
      ),
      child: child,
    );
  }
}

/// A small mock page that reflects the chosen watermark settings live.
class _WatermarkPreview extends StatelessWidget {
  const _WatermarkPreview({
    required this.text,
    required this.style,
    required this.sizePct,
    required this.opacity,
    required this.color,
  });

  final String text;
  final WmStyle style;
  final double sizePct;
  final double opacity;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final label = text.trim().isEmpty ? 'Watermark' : text.trim();

    return AspectRatio(
      aspectRatio: 0.72,
      child: LayoutBuilder(
        builder: (context, box) {
          final w = box.maxWidth;
          var fs = w * sizePct * (style == WmStyle.tiled ? 0.45 : 1.0);

          // Rough width estimate so long text is scaled down like in the PDF.
          final est = label.length * fs * 0.62;
          final cap = style == WmStyle.diagonal
              ? w * 1.15
              : style == WmStyle.straight
              ? w * 0.9
              : double.infinity;
          if (est > cap) fs = fs * cap / est;

          final ts = TextStyle(
            fontSize: fs,
            fontWeight: FontWeight.w800,
            color: color.withOpacity(opacity),
          );

          Widget label0() => Text(
            label,
            style: ts,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.visible,
          );

          Widget mark;
          switch (style) {
            case WmStyle.diagonal:
              mark = Transform.rotate(angle: -math.pi / 4, child: label0());
              break;
            case WmStyle.straight:
              mark = label0();
              break;
            case WmStyle.tiled:
              mark = Transform.rotate(
                angle: -math.pi / 6,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var r = 0; r < 9; r++)
                      Padding(
                        padding: EdgeInsets.symmetric(vertical: fs * 1.1),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (r.isOdd) SizedBox(width: fs * 2.5),
                            for (var c = 0; c < 5; c++)
                              Padding(
                                padding:
                                EdgeInsets.symmetric(horizontal: fs * 0.7),
                                child: label0(),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              );
              break;
          }

          return AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFE0E2EC)),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF202044).withOpacity(0.08),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Stack(
                children: [
                  // Faux page content
                  Positioned.fill(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (var i = 0; i < 12; i++)
                            Container(
                              height: 4,
                              width: i % 4 == 3 ? w * 0.45 : double.infinity,
                              margin: EdgeInsets.only(bottom: i == 0 ? 12 : 7),
                              decoration: BoxDecoration(
                                color: const Color(0xFFEDEEF4),
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: OverflowBox(
                      maxWidth: double.infinity,
                      maxHeight: double.infinity,
                      child: Center(child: mark),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _StepCard extends StatelessWidget {
  const _StepCard({
    required this.number,
    required this.title,
    required this.child,
    this.done = false,
  });

  final int number;
  final String title;
  final bool done;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(21),
        border: Border.all(
          color: done ? const Color(0xFFBFE3CE) : const Color(0xFFE9EAF2),
        ),
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
              AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: done ? const Color(0xFFE3F5EA) : const Color(0xFFE8EDF6),
                  borderRadius: BorderRadius.circular(11),
                ),
                alignment: Alignment.center,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
                  child: done
                      ? const Icon(Icons.check_rounded,
                      key: ValueKey('done'),
                      color: Color(0xFF248653),
                      size: 20)
                      : Text(
                    number.toString().padLeft(2, '0'),
                    key: const ValueKey('num'),
                    style: const TextStyle(
                      color: _brand,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
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
              Icon(
                number == 1
                    ? Icons.upload_file_rounded
                    : number == 2
                    ? Icons.tune_rounded
                    : Icons.ios_share_rounded,
                color: const Color(0xFFB0B2C2),
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