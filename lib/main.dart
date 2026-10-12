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
    final canApply = _bytes != null && _text.text.trim().isNotEmpty && !_busy;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Overprint', style: TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _StepCard(
                  number: 1,
                  title: 'Choose a PDF',
                  child: _bytes == null
                      ? OutlinedButton.icon(
                          onPressed: _busy ? null : _pick,
                          icon: const Icon(Icons.upload_file),
                          label: const Padding(
                            padding: EdgeInsets.symmetric(vertical: 14),
                            child: Text('Tap to choose a PDF'),
                          ),
                        )
                      : ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.picture_as_pdf, color: cs.primary),
                          title: Text(_name, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                              '$_pages ${_pages == 1 ? 'page' : 'pages'} · ${(_bytes!.length / 1048576).toStringAsFixed(1)} MB'),
                          trailing: TextButton(onPressed: _busy ? null : _pick, child: const Text('Change')),
                        ),
                ),
                _StepCard(
                  number: 2,
                  title: 'Set the watermark',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: _text,
                        maxLength: 80,
                        onChanged: (_) => setState(() => _result = null),
                        decoration: const InputDecoration(
                          labelText: 'Watermark text',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 4),
                      SizedBox(
                        width: double.infinity,
                        child: SegmentedButton<WmStyle>(
                          segments: const [
                            ButtonSegment(value: WmStyle.diagonal, label: Text('Diagonal')),
                            ButtonSegment(value: WmStyle.straight, label: Text('Straight')),
                            ButtonSegment(value: WmStyle.tiled, label: Text('Tiled')),
                          ],
                          selected: {_style},
                          onSelectionChanged: (s) => setState(() {
                            _style = s.first;
                            _result = null;
                          }),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text('Size  ${_size.round()}'),
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
                      Text('Opacity  ${_opacity.round()}%'),
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
                      const Text('Colour'),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 14,
                        children: [
                          for (final e in _swatches.entries)
                            Semantics(
                              label: e.key,
                              selected: _color == e.value,
                              child: GestureDetector(
                                onTap: () => setState(() {
                                  _color = e.value;
                                  _result = null;
                                }),
                                child: Container(
                                  width: 40,
                                  height: 40,
                                  decoration: BoxDecoration(
                                    color: e.value,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: _color == e.value ? cs.primary : cs.outlineVariant,
                                      width: _color == e.value ? 3 : 1,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                _StepCard(
                  number: 3,
                  title: 'Apply and download',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      FilledButton(
                        onPressed: canApply ? _apply : null,
                        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                        child: const Text('Add watermark to all pages'),
                      ),
                      if (_busy) ...[
                        const SizedBox(height: 12),
                        const LinearProgressIndicator(),
                      ],
                      if (_message != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          _message!,
                          style: TextStyle(
                            color: _error ? cs.error : cs.onSurfaceVariant,
                            fontWeight: !_error && _result != null ? FontWeight.w600 : FontWeight.w400,
                          ),
                        ),
                      ],
                      if (_result != null) ...[
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: _save,
                          icon: const Icon(Icons.download),
                          label: const Text('Download PDF'),
                          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                        ),
                        if (!kIsWeb) ...[
                          const SizedBox(height: 8),
                          OutlinedButton.icon(
                            onPressed: _share,
                            icon: const Icon(Icons.share),
                            label: const Text('Share'),
                            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                          ),
                        ],
                      ],
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 16),
                  child: Text(
                    'Your PDF stays on this device.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StepCard extends StatelessWidget {
  const _StepCard({required this.number, required this.title, required this.child});

  final int number;
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 14),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: cs.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              CircleAvatar(
                radius: 13,
                backgroundColor: cs.primaryContainer,
                child: Text('$number', style: TextStyle(fontSize: 13, color: cs.onPrimaryContainer)),
              ),
              const SizedBox(width: 10),
              Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    );
  }
}
