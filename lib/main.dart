import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

const apiUrl = 'https://agrosenser360.onrender.com';

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

  double get _areaM2 {
    if (_puntos.length < 3) return 0;
    final o = _puntos[0];
    final kx = 111320 * math.cos(o.latitude * math.pi / 180);
    const ky = 110574;
    double s = 0;
    for (var i = 0; i < _puntos.length; i++) {
      final a = _puntos[i];
      final b = _puntos[(i + 1) % _puntos.length];
      s += (a.longitude - o.longitude) * kx * (b.latitude - o.latitude) * ky -
          (b.longitude - o.longitude) * kx * (a.latitude - o.latitude) * ky;
    }
    return s.abs() / 2;
  }

  List<LatLng> _anillo(List r) => [
        for (final c in r)
          LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble())
      ];

  List get _zonas =>
      _res == null ? [] : (_res!['zones']['features'] as List);

  Color _color(dynamic f) =>
      (f['properties']['level'] as num) == 2 ? Colors.red : Colors.orange;

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

  void _verZonas() {
    final zonas = _zonas;
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
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
                      leading: Icon(Icons.warning_amber, color: _color(f)),
                      title: Text(
                          '${f['properties']['priority']} · ${f['properties']['area_ha']} ha'),
                      subtitle: Text(
                          '${(f['properties']['center'][1] as num).toStringAsFixed(5)}, ${(f['properties']['center'][0] as num).toStringAsFixed(5)}'),
                      onTap: () {
                        Navigator.pop(context);
                        _mapa.move(
                          LatLng((f['properties']['center'][1] as num).toDouble(),
                              (f['properties']['center'][0] as num).toDouble()),
                          18,
                        );
                      },
                    ),
                ],
              ),
      ),
    );
  }

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
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(_error!, style: const TextStyle(color: Colors.red)),
        ),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _puntos.isEmpty || _cargando
                ? null
                : () => setState(() => _puntos.removeLast()),
            icon: const Icon(Icons.undo),
            label: const Text('Deshacer'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _puntos.isEmpty || _cargando
                ? null
                : () => setState(() => _puntos.clear()),
            icon: const Icon(Icons.delete_outline),
            label: const Text('Borrar'),
          ),
        ),
      ]),
      const SizedBox(height: 8),
      SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: _puntos.length < 3 || _cargando ? null : _analizar,
          icon: const Icon(Icons.eco),
          label: const Text('Analizar NDVI'),
        ),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final conResultado = _res != null;
    return Scaffold(
      appBar: AppBar(title: const Text('AgroSenser360')),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _mapa,
                  options: MapOptions(
                    initialCenter: const LatLng(19.2314, -70.2210),
                    initialZoom: 16,
                    maxZoom: 19,
                    onTap: (_, p) {
                      if (!conResultado && !_cargando) {
                        setState(() => _puntos.add(p));
                      }
                    },
                  ),
                  children: [
                    TileLayer(
                      urlTemplate:
                          'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
                      userAgentPackageName: 'com.agrosenser.agrosenser360',
                      maxNativeZoom: 19,
                    ),
                    if (conResultado && _verNdvi && _overlay != null)
                      OverlayImageLayer(overlayImages: [_overlay!]),
                    if (_puntos.length >= 3)
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
