import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const apiUrl = 'https://agrosenser360.onrender.com';

const hallazgos = <String, String>{
  'Sin cultivo (construcción, patio o camino)': 'sin_cultivo',
  'Suelo descubierto o compactado': 'problema',
  'Exceso de humedad o encharcamiento': 'problema',
  'Falta de humedad': 'problema',
  'Daño visible en las plantas': 'problema',
  'Maleza': 'problema',
  'Cultivo con aspecto normal': 'normal',
  'Otro': 'otro',
};

class _Hip {
  final String titulo, evidencia, apoya;
  final List<String> comprobar;
  const _Hip(this.titulo, this.evidencia, this.apoya, this.comprobar);
}

void main() => runApp(const AgroSenserApp());

class AgroSenserApp extends StatelessWidget {
  const AgroSenserApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'AgroSenser360',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: Colors.green, useMaterial3: true),
        home: const FincaScreen(),
      );
}

class FincaScreen extends StatefulWidget {
  const FincaScreen({super.key});

  @override
  State<FincaScreen> createState() => _FincaScreenState();
}

class _FincaScreenState extends State<FincaScreen> {
  final MapController _mapa = MapController();
  final List<LatLng> _puntos = [
    const LatLng(19.2332320, -70.2225132),
    const LatLng(19.2338363, -70.2195373),
    const LatLng(19.2290517, -70.2192312),
    const LatLng(19.2289200, -70.2228324),
  ];

  bool _cargando = false;
  String? _error;
  Map<String, dynamic>? _res;
  OverlayImage? _overlay;
  bool _verNdvi = true;
  Map<String, List<Map<String, dynamic>>> _insp = {};

  @override
  void initState() {
    super.initState();
    _cargarInsp();
  }

  // ---------- Almacenamiento local ----------
  Future<void> _cargarInsp() async {
    final sp = await SharedPreferences.getInstance();
    final s = sp.getString('inspecciones');
    if (s == null) return;
    final m = jsonDecode(s) as Map<String, dynamic>;
    setState(() {
      _insp = m.map((k, v) => MapEntry(
          k,
          (v as List)
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList()));
    });
  }

  Future<void> _guardarInsp() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString('inspecciones', jsonEncode(_insp));
  }

  // ---------- Geometría ----------
  double get _areaM2 {
    if (_puntos.length < 3) return 0;
    final o = _puntos[0];
    final kx = 111320 * math.cos(o.latitude * math.pi / 180);
    const ky = 110574.0;
    double s = 0;
    for (var i = 0; i < _puntos.length; i++) {
      final a = _puntos[i];
      final b = _puntos[(i + 1) % _puntos.length];
      s += (a.longitude - o.longitude) * kx * (b.latitude - o.latitude) * ky -
          (b.longitude - o.longitude) * kx * (a.latitude - o.latitude) * ky;
    }
    return s.abs() / 2;
  }

  double _distBordeM(LatLng p) {
    if (_puntos.length < 2) return double.infinity;
    final kx = 111320 * math.cos(p.latitude * math.pi / 180);
    const ky = 110574.0;
    double mejor = double.infinity;
    for (var i = 0; i < _puntos.length; i++) {
      final a = _puntos[i];
      final b = _puntos[(i + 1) % _puntos.length];
      final ax = (a.longitude - p.longitude) * kx;
      final ay = (a.latitude - p.latitude) * ky;
      final bx = (b.longitude - p.longitude) * kx;
      final by = (b.latitude - p.latitude) * ky;
      final dx = bx - ax;
      final dy = by - ay;
      final l2 = dx * dx + dy * dy;
      var t = l2 == 0 ? 0.0 : ((-ax) * dx + (-ay) * dy) / l2;
      t = t.clamp(0.0, 1.0).toDouble();
      final px = ax + t * dx;
      final py = ay + t * dy;
      final d = math.sqrt(px * px + py * py);
      if (d < mejor) mejor = d;
    }
    return mejor;
  }

  bool _dentro(LatLng p, List<LatLng> r) {
    var d = false;
    for (var i = 0, j = r.length - 1; i < r.length; j = i++) {
      final a = r[i];
      final b = r[j];
      if ((a.latitude > p.latitude) != (b.latitude > p.latitude) &&
          p.longitude <
              (b.longitude - a.longitude) *
                      (p.latitude - a.latitude) /
                      (b.latitude - a.latitude) +
                  a.longitude) {
        d = !d;
      }
    }
    return d;
  }

  List<LatLng> _anillo(List r) => [
        for (final c in r)
          LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble())
      ];

  List get _zonas =>
      _res == null ? [] : (_res!['zones']['features'] as List);

  Color _color(dynamic f) =>
      (f['properties']['level'] as num) == 2 ? Colors.red : Colors.orange;

  LatLng _centro(dynamic f) {
    final c = f['properties']['center'];
    return LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble());
  }

  String _claveZona(dynamic f) {
    final c = _centro(f);
    return '${c.latitude.toStringAsFixed(4)},${c.longitude.toStringAsFixed(4)}';
  }

  bool _inspeccionada(dynamic f) => (_insp[_claveZona(f)] ?? []).isNotEmpty;

  dynamic _zonaEn(LatLng p) {
    for (final f in _zonas) {
      final ring = _anillo(f['geometry']['coordinates'][0] as List);
      if (_dentro(p, ring)) return f;
    }
    dynamic mejor;
    double md = 30;
    for (final f in _zonas) {
      final d = const Distance().as(LengthUnit.Meter, p, _centro(f));
      if (d < md) {
        md = d;
        mejor = f;
      }
    }
    return mejor;
  }

  String _resumen() {
    int ins = 0, p = 0, s = 0, n = 0;
    for (final f in _zonas) {
      final l = _insp[_claveZona(f)];
      if (l == null || l.isEmpty) continue;
      ins++;
      final g = l.last['grupo'];
      if (g == 'problema') {
        p++;
      } else if (g == 'sin_cultivo') {
        s++;
      } else if (g == 'normal') {
        n++;
      }
    }
    return 'Inspeccionadas $ins de ${_zonas.length} · con problema $p · sin cultivo $s · normales $n';
  }

  // ---------- Análisis ----------
  Future<void> _analizar() async {
    setState(() {
      _cargando = true;
      _error = null;
    });
    try {
      final anillo = [
        for (final p in _puntos) [p.longitude, p.latitude]
      ];
      anillo.add(anillo.first);
      final r = await http
          .post(
            Uri.parse('$apiUrl/analyze'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'geometry': {
                'type': 'Polygon',
                'coordinates': [anillo]
              },
              'days': 60
            }),
          )
          .timeout(const Duration(seconds: 240));
      if (r.statusCode == 200) {
        final res = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
        final b = res['bounds'];
        final Uint8List png = base64Decode(res['ndvi_png_base64'] as String);
        setState(() {
          _res = res;
          _verNdvi = true;
          _overlay = OverlayImage(
            bounds: LatLngBounds(
              LatLng((b['south'] as num).toDouble(), (b['west'] as num).toDouble()),
              LatLng((b['north'] as num).toDouble(), (b['east'] as num).toDouble()),
            ),
            imageProvider: MemoryImage(png),
          );
        });
      } else {
        var msg = 'Error ${r.statusCode}';
        try {
          final d = jsonDecode(utf8.decode(r.bodyBytes));
          if (d['detail'] is String) msg = d['detail'] as String;
        } catch (_) {}
        setState(() => _error = msg);
      }
    } catch (e) {
      setState(() => _error =
          'No se pudo conectar con el servidor. Revisa tu internet e intenta otra vez.');
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  void _nueva() => setState(() {
        _res = null;
        _overlay = null;
        _error = null;
      });

  // ---------- Lista de zonas ----------
  void _verZonas() {
    final zonas = List.of(_zonas);
    zonas.sort((a, b) {
      final ia = _inspeccionada(a) ? 1 : 0;
      final ib = _inspeccionada(b) ? 1 : 0;
      if (ia != ib) return ia - ib;
      return (b['properties']['level'] as num)
          .compareTo(a['properties']['level'] as num);
    });
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: zonas.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Text('No se marcaron zonas para inspeccionar.'),
              )
            : ListView(
                shrinkWrap: true,
                children: [
                  for (final f in zonas)
                    ListTile(
                      leading: _inspeccionada(f)
                          ? const Icon(Icons.check_circle, color: Colors.blue)
                          : Icon(Icons.warning_amber, color: _color(f)),
                      title: Text(
                          '${f['properties']['priority']} · ${f['properties']['area_ha']} ha'),
                      subtitle: Text(_inspeccionada(f)
                          ? 'Inspeccionada: ${_insp[_claveZona(f)]!.last['hallazgo']}'
                          : 'Pendiente de inspección'),
                      onTap: () {
                        Navigator.pop(ctx);
                        _mapa.move(_centro(f), 18);
                        _detalleZona(f);
                      },
                    ),
                ],
              ),
      ),
    );
  }

  // ---------- Ficha de la zona ----------
  List<_Hip> _hipotesis(double dBorde) {
    final cerca = dBorde < 40;
    final dTxt = dBorde.isFinite ? '${dBorde.round()} m' : 'distancia desconocida';
    return [
      _Hip(
        'Posible superficie sin cultivo',
        cerca ? 'media' : 'baja',
        'La zona está a $dTxt del borde de la finca.',
        const [
          'Compara con la imagen satelital de alta resolución',
          'Recorre la zona y mira si hay construcciones, caminos o suelo sin sembrar',
        ],
      ),
      const _Hip(
        'Posible exceso o falta de agua en el suelo',
        'baja',
        'Aún no hay dato de humedad (NDMI) para esta zona.',
        [
          'Mira si hay charcos, suelo agrietado o plantas marchitas',
          'Mide la humedad a unos 20 cm y compárala con una zona sana',
          'Revisa el drenaje y la pendiente',
        ],
      ),
      const _Hip(
        'Posible limitación del suelo o de nutrientes',
        'baja',
        'Solo hay un dato de vigor, sin análisis de suelo.',
        [
          'Revisa la compactación: ¿cuesta clavar una varilla?',
          'Toma una muestra en la zona y otra en una zona sana, a la misma profundidad y el mismo día',
          'Envíalas a un laboratorio y compara los resultados',
        ],
      ),
      const _Hip(
        'Posible daño en las plantas (plaga, enfermedad u otro)',
        'baja',
        'No hay evidencia directa, solo el vigor bajo.',
        [
          'Examina hojas, tallos y raíces de varias plantas',
          'Mira si el daño empieza en un punto y se extiende',
          'Fotografía lo que encuentres',
        ],
      ),
    ];
  }

  Widget _tarjetaHip(_Hip h) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.black26),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: Text(h.titulo,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.grey.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text('Evidencia ${h.evidencia}',
                    style: const TextStyle(fontSize: 12)),
              ),
            ]),
            const SizedBox(height: 6),
            Text(h.apoya, style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 6),
            const Text('Qué comprobar:',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            for (final c in h.comprobar)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('• $c', style: const TextStyle(fontSize: 13)),
              ),
          ],
        ),
      );

  void _detalleZona(dynamic f) {
    final centro = _centro(f);
    final dBorde = _distBordeM(centro);
    final nivel = (f['properties']['level'] as num) == 2 ? 'inspeccionar' : 'vigilar';
    final previas = _insp[_claveZona(f)] ?? [];
    final coord =
        '${centro.latitude.toStringAsFixed(5)}, ${centro.longitude.toStringAsFixed(5)}';
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Zona para $nivel · ${f['properties']['area_ha']} ha',
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w600)),
                Text(coord, style: const TextStyle(color: Colors.black54)),
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.amber.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Text(
                    'Esto no es un diagnóstico. El NDVI mide el vigor de la vegetación, no la causa. Estas son hipótesis que hay que comprobar en campo.',
                    style: TextStyle(fontSize: 13),
                  ),
                ),
                const SizedBox(height: 14),
                const Text('Posibles causas a investigar',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                for (final h in _hipotesis(dBorde)) _tarjetaHip(h),
                const Text('Muestreo sugerido',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(
                    '• Punto 1: centro de la zona ($coord)\n'
                    '• Punto 2: un punto sano del mismo cultivo, a más de 30 m de cualquier zona marcada\n'
                    'Toma los dos el mismo día y a la misma profundidad, para poder compararlos.',
                    style: const TextStyle(fontSize: 13)),
                if (previas.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Text('Inspecciones registradas (${previas.length})',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  for (final p in previas)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                          '• ${(p['fecha'] as String).substring(0, 10)}: ${p['hallazgo']}${p['muestra'] == true ? ' · con muestra de suelo' : ''}',
                          style: const TextStyle(fontSize: 13)),
                    ),
                ],
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _formulario(f);
                    },
                    icon: const Icon(Icons.assignment_turned_in),
                    label: const Text('Registrar inspección'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _formulario(dynamic f) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => FormInspeccion(
        onGuardar: (reg) async {
          reg['imagen'] = _res?['scene_date'];
          final k = _claveZona(f);
          setState(() {
            _insp.putIfAbsent(k, () => <Map<String, dynamic>>[]).add(reg);
          });
          await _guardarInsp();
          if (ctx.mounted) Navigator.pop(ctx);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Inspección guardada')));
          }
        },
      ),
    );
  }

  // ---------- Panel inferior ----------
  Widget _dato(Color c, String titulo, Object? valor) => Expanded(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 3),
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: c.withOpacity(0.15),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: c),
          ),
          child: Column(children: [
            Text('$valor ha', style: const TextStyle(fontWeight: FontWeight.bold)),
            Text(titulo, style: const TextStyle(fontSize: 12)),
          ]),
        ),
      );

  Widget _panel() {
    if (_res != null) {
      final r = _res!;
      final ha = r['ha'] as Map;
      return Column(children: [
        Text(
          'Imagen del ${r['scene_date']} · NDVI promedio ${r['ndvi_mean']}',
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Row(children: [
          _dato(Colors.green, 'normal', ha['normal']),
          _dato(Colors.orange, 'vigilar', ha['vigilar']),
          _dato(Colors.red, 'inspeccionar', ha['inspeccionar']),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => setState(() => _verNdvi = !_verNdvi),
              icon: Icon(_verNdvi ? Icons.visibility_off : Icons.visibility),
              label: Text(_verNdvi ? 'Ocultar NDVI' : 'Ver NDVI'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FilledButton.icon(
              onPressed: _verZonas,
              icon: const Icon(Icons.list),
              label: Text('Zonas (${_zonas.length})'),
            ),
          ),
        ]),
        const SizedBox(height: 6),
        Text(_resumen(),
            textAlign: TextAlign.center, style: const TextStyle(fontSize: 12)),
        const Text('Toca una zona del mapa para ver qué comprobar.',
            style: TextStyle(fontSize: 12, color: Colors.black54)),
        TextButton(onPressed: _nueva, child: const Text('Volver a editar la finca')),
      ]);
    }
    final m2 = _areaM2;
    return Column(children: [
      Text(
        m2 == 0
            ? 'Toca el mapa para marcar las esquinas de la finca'
            : 'Área: ${(m2 / 10000).toStringAsFixed(2)} ha  ·  ${(m2 / 629).round()} tareas  ·  ${_puntos.length} puntos',
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
      if (_error != null)
        Padd             if (_puntos.length >= 3)
                      PolygonLayer(polygons: [
                        Polygon(
                          points: List.of(_puntos),
                          color: conResultado
                              ? Colors.transparent
                              : Colors.green.withOpacity(0.25),
                          isFilled: !conResultado,
                          borderColor: Colors.yellowAccent,
                          borderStrokeWidth: 3,
                        ),
                      ]),
                    if (conResultado)
                      PolygonLayer(polygons: [
                        for (final f in _zonas)
                          Polygon(
                            points: _anillo(f['geometry']['coordinates'][0] as List),
                            holePointsList: [
                              for (var i = 1;
                                  i < (f['geometry']['coordinates'] as List).length;
                                  i++)
                                _anillo(f['geometry']['coordinates'][i] as List)
                            ],
                            color: _color(f).withOpacity(0.35),
                            isFilled: true,
                            borderColor: _color(f),
                            borderStrokeWidth: 2,
                          ),
                      ]),
                    if (!conResultado)
                      MarkerLayer(markers: [
                        for (final p in _puntos)
                          Marker(
                            point: p,
                            width: 16,
                            height: 16,
                            child: Container(
                              decoration: BoxDecoration(
                                color: Colors.white,
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.green, width: 3),
                              ),
                            ),
                          ),
                      ]),
                  ],
                ),
                const Positioned(
                  left: 6,
                  bottom: 4,
                  child: Text(
                    'Imágenes © Esri, Maxar, Earthstar Geographics',
                    style: TextStyle(
                      fontSize: 10,
                      color: Colors.white,
                      shadows: [Shadow(blurRadius: 3)],
                    ),
                  ),
                ),
                if (_cargando)
                  Positioned.fill(
                    child: Container(
                      color: Colors.black54,
                      child: const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              CircularProgressIndicator(),
                              SizedBox(height: 16),
                              Text(
                                'Analizando imágenes de satélite…\nLa primera vez puede tardar 1 o 2 minutos.',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Colors.white, fontSize: 16),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(padding: const EdgeInsets.all(12), child: _panel()),
          ),
        ],
      ),
    );
  }
}
