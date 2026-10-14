import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

// ------------------------------------------------------------- constants ----
const kBg = Color(0xFF120D0A);
const kLeather = Color(0xFF3B2618);
const kPaper = Color(0xFFFAF6EC);
const kGold = Color(0xFFC9A24D);
const kInk = Color(0xFF3A2E22);

const double kPageAspect = 0.8; // page width / page height
const double kMarginX = 0.08; // fraction of page width
const double kMarginY = 0.065; // fraction of page height
final double kAreaAspect =
    (kPageAspect * (1 - 2 * kMarginX)) / (1 - 2 * kMarginY);

const String kSerif = 'serif';

// ------------------------------------------------------------------ main ----
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations(
      [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  PaintingBinding.instance.imageCache.maximumSizeBytes = 180 << 20;
  runApp(const YamApp());
}

class YamApp extends StatelessWidget {
  const YamApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'YAM Album',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
            seedColor: kGold, brightness: Brightness.dark),
      ),
      home: const AlbumScreen(),
    );
  }
}

// ----------------------------------------------------------------- model ----
class Photo {
  final String path;
  final double ratio; // width / height
  const Photo(this.path, this.ratio);
}

enum PageKind { title, gallery, end, blank }

class AlbumPage {
  final PageKind kind;
  final List<Photo> photos;
  final List<Rect> rects; // unit rects inside the padded page area
  final int number;
  final String title;
  final String subtitle;
  const AlbumPage({
    required this.kind,
    this.photos = const [],
    this.rects = const [],
    this.number = 0,
    this.title = '',
    this.subtitle = '',
  });
}

// ------------------------------------------------------- layout engine ----
List<List<Rect>> _candidates(int n) {
  const g = 0.03;
  switch (n) {
    case 2:
      return [
        [
          const Rect.fromLTWH(0, 0, 1, (1 - g) / 2),
          const Rect.fromLTWH(0, (1 + g) / 2, 1, (1 - g) / 2),
        ],
        [
          const Rect.fromLTWH(0, 0, (1 - g) / 2, 1),
          const Rect.fromLTWH((1 + g) / 2, 0, (1 - g) / 2, 1),
        ],
      ];
    case 3:
      return [
        [
          const Rect.fromLTWH(0, 0, 1, 0.56),
          const Rect.fromLTWH(0, 0.56 + g, (1 - g) / 2, 1 - 0.56 - g),
          const Rect.fromLTWH((1 + g) / 2, 0.56 + g, (1 - g) / 2, 1 - 0.56 - g),
        ],
        [
          const Rect.fromLTWH(0, 0, 0.58, 1),
          const Rect.fromLTWH(0.58 + g, 0, 1 - 0.58 - g, (1 - g) / 2),
          const Rect.fromLTWH(0.58 + g, (1 + g) / 2, 1 - 0.58 - g, (1 - g) / 2),
        ],
        [
          const Rect.fromLTWH(0, 0, 1, (1 - 2 * g) / 3),
          const Rect.fromLTWH(0, (1 - 2 * g) / 3 + g, 1, (1 - 2 * g) / 3),
          const Rect.fromLTWH(0, 2 * ((1 - 2 * g) / 3 + g), 1, (1 - 2 * g) / 3),
        ],
      ];
    case 4:
      return [
        [
          const Rect.fromLTWH(0, 0, (1 - g) / 2, (1 - g) / 2),
          const Rect.fromLTWH((1 + g) / 2, 0, (1 - g) / 2, (1 - g) / 2),
          const Rect.fromLTWH(0, (1 + g) / 2, (1 - g) / 2, (1 - g) / 2),
          const Rect.fromLTWH((1 + g) / 2, (1 + g) / 2, (1 - g) / 2, (1 - g) / 2),
        ],
      ];
  }
  return [
    [const Rect.fromLTWH(0, 0, 1, 1)]
  ];
}

List<Rect> bestLayout(List<double> ratios) {
  final n = ratios.length;
  if (n == 1) {
    // single photo: fit without cropping, centered
    final r = ratios[0];
    double w, h;
    if (r > kAreaAspect) {
      w = 1;
      h = kAreaAspect / r;
    } else {
      h = 1;
      w = r / kAreaAspect;
    }
    return [Rect.fromLTWH((1 - w) / 2, (1 - h) / 2, w, h)];
  }
  final cands = _candidates(n);
  var best = cands.first;
  var bestCost = double.infinity;
  for (final c in cands) {
    var cost = 0.0;
    for (var i = 0; i < n; i++) {
      final cellAspect = c[i].width * kAreaAspect / c[i].height;
      cost += (math.log(cellAspect / ratios[i])).abs();
    }
    if (cost < bestCost) {
      bestCost = cost;
      best = c;
    }
  }
  return best;
}

List<AlbumPage> buildPages(
    List<Photo> photos, String title, String subtitle) {
  final pages = <AlbumPage>[
    AlbumPage(kind: PageKind.title, title: title, subtitle: subtitle),
  ];
  const pattern = [1, 3, 2, 4, 2, 1, 3, 2];
  var i = 0;
  var k = 0;
  while (i < photos.length) {
    final n = math.min(pattern[k % pattern.length], photos.length - i);
    final group = photos.sublist(i, i + n);
    pages.add(AlbumPage(
      kind: PageKind.gallery,
      photos: group,
      rects: bestLayout(group.map((p) => p.ratio).toList()),
      number: pages.length + 1,
    ));
    i += n;
    k++;
  }
  pages.add(const AlbumPage(kind: PageKind.end));
  if (pages.length.isOdd) pages.add(const AlbumPage(kind: PageKind.blank));
  return pages;
}

// ---------------------------------------------------------------- screen ----
class AlbumScreen extends StatefulWidget {
  const AlbumScreen({super.key});

  @override
  State<AlbumScreen> createState() => _AlbumScreenState();
}

class _AlbumScreenState extends State<AlbumScreen>
    with SingleTickerProviderStateMixin {
  final List<Photo> photos = [];
  List<AlbumPage> pages = [];
  String title = 'Our Wedding';
  String subtitle = '';

  late final AnimationController ctrl;
  int spread = 0; // current spread (pair of pages)
  int base = 0; // leaf sits between spread `base` and `base + 1`
  bool dragging = false;
  int dragDir = 0;
  bool busy = false;
  String busyMsg = '';

  int get lastSpread => math.max(pages.length ~/ 2 - 1, 0);

  @override
  void initState() {
    super.initState();
    ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 500));
  }

  @override
  void dispose() {
    ctrl.dispose();
    super.dispose();
  }

  // ------------------------------------------------------- photo loading ----
  Future<double> _ratioOf(String path) {
    final c = Completer<double>();
    final stream = ResizeImage(FileImage(File(path)), width: 200)
        .resolve(const ImageConfiguration());
    late ImageStreamListener l;
    l = ImageStreamListener((info, _) {
      if (!c.isCompleted) {
        c.complete(info.image.width / info.image.height);
      }
      stream.removeListener(l);
    }, onError: (e, s) {
      if (!c.isCompleted) c.complete(1.0);
      stream.removeListener(l);
    });
    stream.addListener(l);
    return c.future;
  }

  Future<void> _pick() async {
    if (busy) return;
    List<XFile> files;
    try {
      files = await ImagePicker().pickMultiImage(
        maxWidth: 1600,
        imageQuality: 85,
      );
    } catch (e) {
      _toast('Could not open the gallery: $e');
      return;
    }
    if (files.isEmpty) return;

    setState(() {
      busy = true;
      busyMsg = 'Preparing your album...';
    });
    final wasEmpty = photos.isEmpty;
    for (final f in files) {
      photos.add(Photo(f.path, await _ratioOf(f.path)));
    }
    pages = buildPages(photos, title, subtitle);
    spread = wasEmpty ? 0 : math.min(spread, lastSpread);
    base = spread;
    ctrl.value = 0;
    setState(() => busy = false);
    if (wasEmpty && mounted) _editTitle();
  }

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(m), duration: const Duration(seconds: 4)));
  }

  Future<void> _editTitle() async {
    final t = TextEditingController(text: title);
    final s = TextEditingController(text: subtitle);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Album details'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: t,
              decoration: const InputDecoration(labelText: 'Names / Title'),
            ),
            TextField(
              controller: s,
              decoration: const InputDecoration(labelText: 'Date / Subtitle'),
            ),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Save')),
        ],
      ),
    );
    if (ok == true) {
      setState(() {
        if (t.text.trim().isNotEmpty) title = t.text.trim();
        subtitle = s.text.trim();
        pages = buildPages(photos, title, subtitle);
      });
    }
  }

  // ------------------------------------------------------- page turning ----
  Future<void> _settle(double target) async {
    final dist = (ctrl.value - target).abs();
    await ctrl.animateTo(
      target,
      duration: Duration(milliseconds: (150 + 450 * dist).round()),
      curve: Curves.easeInOutCubic,
    );
    if (!mounted) return;
    final newSpread = target == 1 ? base + 1 : base;
    ctrl.value = 0;
    setState(() {
      spread = newSpread;
      base = newSpread;
    });
  }

  void _next() {
    if (ctrl.isAnimating || dragging || spread >= lastSpread) return;
    base = spread;
    ctrl.value = 0;
    _settle(1);
  }

  void _prev() {
    if (ctrl.isAnimating || dragging || spread <= 0) return;
    base = spread - 1;
    ctrl.value = 1;
    _settle(0);
  }

  void _dragStart(DragStartDetails d) {
    if (ctrl.isAnimating) return;
    dragging = true;
    dragDir = 0;
  }

  void _dragUpdate(DragUpdateDetails d, double pw) {
    if (!dragging) return;
    if (dragDir == 0) {
      if (d.delta.dx < 0 && spread < lastSpread) {
        dragDir = 1;
        base = spread;
        ctrl.value = 0;
      } else if (d.delta.dx > 0 && spread > 0) {
        dragDir = -1;
        base = spread - 1;
        ctrl.value = 1;
      } else {
        return;
      }
    }
    ctrl.value = (ctrl.value - d.delta.dx / pw).clamp(0.0, 1.0);
  }

  void _dragEnd(DragEndDetails d) {
    if (!dragging) return;
    dragging = false;
    if (dragDir == 0) return;
    final vx = d.primaryVelocity ?? 0;
    var target = ctrl.value > 0.5 ? 1.0 : 0.0;
    if (vx < -600) target = 1.0;
    if (vx > 600) target = 0.0;
    _settle(target);
  }

  // ------------------------------------------------------------- widgets ----
  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return Scaffold(
      backgroundColor: kBg,
      body: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: const BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment.center,
                  radius: 1.0,
                  colors: [Color(0xFF2A1D14), kBg],
                ),
              ),
            ),
          ),
          if (pages.isEmpty) _welcome() else _bookArea(size),
          if (pages.isNotEmpty)
            Positioned(
              top: 8,
              right: 12,
              child: Row(children: [
                _roundBtn(Icons.edit_outlined, _editTitle),
                const SizedBox(width: 8),
                _roundBtn(Icons.add_photo_alternate_outlined, _pick),
              ]),
            ),
          if (busy)
            Positioned.fill(
              child: Container(
                color: const Color(0xCC000000),
                alignment: Alignment.center,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const CircularProgressIndicator(color: kGold),
                  const SizedBox(height: 16),
                  Text(busyMsg,
                      style: const TextStyle(color: Colors.white, fontSize: 16)),
                ]),
              ),
            ),
        ],
      ),
    );
  }

  Widget _roundBtn(IconData icon, VoidCallback onTap) {
    return Material(
      color: const Color(0x66000000),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(icon, color: kGold, size: 22),
        ),
      ),
    );
  }

  Widget _welcome() {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('YAM PICTURE',
            style: TextStyle(
                color: kGold, fontSize: 16, letterSpacing: 6, fontWeight: FontWeight.w500)),
        const SizedBox(height: 10),
        Container(width: 60, height: 1, color: kGold),
        const SizedBox(height: 14),
        const Text('Digital Album',
            style: TextStyle(
                color: Color(0xFFF3E9D2),
                fontSize: 44,
                fontFamily: kSerif,
                fontStyle: FontStyle.italic)),
        const SizedBox(height: 26),
        FilledButton.icon(
          onPressed: _pick,
          style: FilledButton.styleFrom(
            backgroundColor: kGold,
            foregroundColor: const Color(0xFF1A120B),
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
          ),
          icon: const Icon(Icons.photo_library_outlined),
          label: const Text('Choose Photos', style: TextStyle(fontSize: 16)),
        ),
      ]),
    );
  }

  Widget _bookArea(Size size) {
    final ph = math.min(size.height * 0.92, size.width * 0.94 / (2 * kPageAspect));
    final pw = ph * kPageAspect;
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: _dragStart,
        onHorizontalDragUpdate: (d) => _dragUpdate(d, pw),
        onHorizontalDragEnd: _dragEnd,
        onTapUp: (d) {
          final x = d.localPosition.dx;
          if (x > size.width * 0.72) {
            _next();
          } else if (x < size.width * 0.28) {
            _prev();
          }
        },
        child: Stack(
          alignment: Alignment.center,
          children: [
            _book(pw, ph),
            Positioned(
              bottom: 2,
              child: Text(
                '${spread + 1} / ${lastSpread + 1}',
                style: TextStyle(
                    color: kGold.withOpacity(0.7), fontSize: 11, letterSpacing: 2),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _book(double pw, double ph) {
    final pad = ph * 0.025;
    return Container(
      padding: EdgeInsets.all(pad),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF4A3020), kLeather, Color(0xFF2E1D12)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(8),
        boxShadow: const [
          BoxShadow(color: Color(0xB3000000), blurRadius: 30, offset: Offset(0, 12)),
        ],
      ),
      child: SizedBox(
        width: pw * 2,
        height: ph,
        child: AnimatedBuilder(
          animation: ctrl,
          builder: (context, _) => _spread(pw, ph),
        ),
      ),
    );
  }

  Widget _spread(double pw, double ph) {
    final b = base;
    final v = ctrl.value;
    final angle = v * math.pi;
    final shade = math.sin(angle);

    final leftUnder = _page(2 * b, true, pw, ph);
    final front = _page(2 * b + 1, false, pw, ph);
    final back = _page(2 * (b + 1), true, pw, ph);

    final showFront = angle < math.pi / 2;
    final leafFace = showFront
        ? front
        : Transform(
            alignment: Alignment.center,
            transform: Matrix4.rotationY(math.pi),
            child: back,
          );

    final leaf = Transform(
      alignment: Alignment.centerLeft,
      transform: Matrix4.identity()
        ..setEntry(3, 2, 0.35 / pw)
        ..rotateY(angle),
      child: Stack(children: [
        leafFace,
        Positioned.fill(
          child: IgnorePointer(
            child: ColoredBox(color: Color.fromRGBO(0, 0, 0, 0.30 * shade)),
          ),
        ),
      ]),
    );

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(left: 0, top: 0, child: leftUnder),
        if (v > 0)
          Positioned(
            left: pw,
            top: 0,
            child: Stack(children: [
              _page(2 * (b + 1) + 1, false, pw, ph),
              Positioned.fill(
                child: IgnorePointer(
                  child: ColoredBox(color: Color.fromRGBO(0, 0, 0, 0.18 * shade)),
                ),
              ),
            ]),
          ),
        Positioned(left: pw, top: 0, child: leaf),
      ],
    );
  }

  // one physical page
  Widget _page(int index, bool isLeft, double pw, double ph) {
    final AlbumPage p =
        index < pages.length ? pages[index] : const AlbumPage(kind: PageKind.blank);

    Widget content;
    switch (p.kind) {
      case PageKind.title:
        content = _titlePage(p, pw, ph);
        break;
      case PageKind.gallery:
        content = _galleryPage(p, pw, ph);
        break;
      case PageKind.end:
        content = _endPage(pw, ph);
        break;
      case PageKind.blank:
        content = const SizedBox.shrink();
        break;
    }

    return SizedBox(
      width: pw,
      height: ph,
      child: Stack(children: [
        const Positioned.fill(child: ColoredBox(color: kPaper)),
        Positioned.fill(child: content),
        // soft shadow toward the spine
        Positioned(
          top: 0,
          bottom: 0,
          left: isLeft ? null : 0,
          right: isLeft ? 0 : null,
          width: pw * 0.14,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: isLeft ? Alignment.centerRight : Alignment.centerLeft,
                  end: isLeft ? Alignment.centerLeft : Alignment.centerRight,
                  colors: const [Color(0x40000000), Color(0x00000000)],
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _titlePage(AlbumPage p, double pw, double ph) {
    return Stack(children: [
      Positioned.fill(
        child: Padding(
          padding: EdgeInsets.all(pw * 0.05),
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: kGold, width: 1.2),
            ),
          ),
        ),
      ),
      Center(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: pw * 0.12),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('YAM PICTURE',
                style: TextStyle(
                    color: kGold, fontSize: pw * 0.034, letterSpacing: 4)),
            SizedBox(height: ph * 0.04),
            Container(width: pw * 0.2, height: 1, color: kGold),
            SizedBox(height: ph * 0.05),
            Text(
              p.title,
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: kInk,
                  fontSize: pw * 0.095,
                  fontFamily: kSerif,
                  fontStyle: FontStyle.italic,
                  height: 1.15),
            ),
            SizedBox(height: ph * 0.05),
            Container(width: pw * 0.2, height: 1, color: kGold),
            if (p.subtitle.isNotEmpty) ...[
              SizedBox(height: ph * 0.04),
              Text(
                p.subtitle.toUpperCase(),
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: kInk.withOpacity(0.75),
                    fontSize: pw * 0.036,
                    letterSpacing: 3),
              ),
            ],
          ]),
        ),
      ),
    ]);
  }

  Widget _endPage(double pw, double ph) {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text('Thank you',
            style: TextStyle(
                color: kInk,
                fontSize: pw * 0.11,
                fontFamily: kSerif,
                fontStyle: FontStyle.italic)),
        SizedBox(height: ph * 0.04),
        Container(width: pw * 0.2, height: 1, color: kGold),
        SizedBox(height: ph * 0.04),
        Text('YAM PICTURE',
            style: TextStyle(color: kGold, fontSize: pw * 0.034, letterSpacing: 4)),
      ]),
    );
  }

  Widget _galleryPage(AlbumPage p, double pw, double ph) {
    final mx = pw * kMarginX;
    final my = ph * kMarginY;
    final aw = pw - 2 * mx;
    final ah = ph - 2 * my;
    final dpr = MediaQuery.of(context).devicePixelRatio;

    final tiles = <Widget>[];
    for (var i = 0; i < p.photos.length; i++) {
      final r = p.rects[i];
      final w = r.width * aw;
      final h = r.height * ah;
      final portrait = p.photos[i].ratio < 1;
      final cw = (w * dpr).clamp(240.0, 1100.0).round();
      tiles.add(Positioned(
        left: r.left * aw,
        top: r.top * ah,
        width: w,
        height: h,
        child: DecoratedBox(
          decoration: const BoxDecoration(
            boxShadow: [
              BoxShadow(
                  color: Color(0x40000000), blurRadius: 6, offset: Offset(0, 2)),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: Image.file(
              File(p.photos[i].path),
              fit: BoxFit.cover,
              alignment: portrait ? const Alignment(0, -0.3) : Alignment.center,
              cacheWidth: cw,
              filterQuality: FilterQuality.medium,
              gaplessPlayback: true,
              errorBuilder: (c, e, s) => const ColoredBox(
                color: Color(0xFFDDD5C4),
                child: Center(child: Icon(Icons.broken_image_outlined)),
              ),
            ),
          ),
        ),
      ));
    }

    return Stack(children: [
      Positioned(
        left: mx,
        top: my,
        width: aw,
        height: ah,
        child: Stack(children: tiles),
      ),
      Positioned(
        left: 0,
        right: 0,
        bottom: my * 0.28,
        child: Center(
          child: Text(
            '${p.number}',
            style: TextStyle(
                color: kInk.withOpacity(0.5), fontSize: ph * 0.026, letterSpacing: 1),
          ),
        ),
      ),
    ]);
  }
}
