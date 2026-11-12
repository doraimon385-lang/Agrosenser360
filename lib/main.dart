import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

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
  // Contorno inicial: las 4 esquinas de Hacienda Taveras
  final List<LatLng> _puntos = [
    const LatLng(19.2332320, -70.2225132),
    const LatLng(19.2338363, -70.2195373),
    const LatLng(19.2290517, -70.2192312),
    const LatLng(19.2289200, -70.2228324),
  ];

  double get _areaM2 {
    if (_puntos.length < 3) return 0;
    final o = _puntos[0];
    final kx = 111320 * math.cos(o.latitude * math.pi / 180);
    const ky = 110574;
    double s = 0;
    for (var i = 0; i < _puntos.length; i++) {
      final a = _puntos[i];
      final b = _puntos[(i + 1) % _puntos.length];
      final ax = (a.longitude - o.longitude) * kx;
      final ay = (a.latitude - o.latitude) * ky;
      final bx = (b.longitude - o.longitude) * kx;
      final by = (b.latitude - o.latitude) * ky;
      s += ax * by - bx * ay;
    }
    return s.abs() / 2;
  }

  @override
  Widget build(BuildContext context) {
    final m2 = _areaM2;
    return Scaffold(
      appBar: AppBar(title: const Text('AgroSenser360')),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                FlutterMap(
                  options: MapOptions(
                    initialCenter: const LatLng(19.2314, -70.2210),
                    initialZoom: 16,
                    maxZoom: 19,
                    onTap: (_, punto) => setState(() => _puntos.add(punto)),
                  ),
                  children: [
                    TileLayer(
                      urlTemplate:
                          'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
                      userAgentPackageName: 'com.agrosenser.agrosenser360',
                      maxNativeZoom: 19,
                    ),
                    if (_puntos.length >= 3)
                      PolygonLayer(polygons: [
                        Polygon(
                          points: List.of(_puntos),
                          color: Colors.green.withOpacity(0.25),
                          isFilled: true,
                          borderColor: Colors.yellowAccent,
                          borderStrokeWidth: 3,
                        ),
                      ]),
                    if (_puntos.length == 2)
                      PolylineLayer(polylines: [
                        Polyline(
                          points: List.of(_puntos),
                          color: Colors.yellowAccent,
                          strokeWidth: 3,
                        ),
                      ]),
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
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  Text(
                    m2 == 0
                        ? 'Toca el mapa para marcar las esquinas de la finca'
                        : 'Área: ${(m2 / 10000).toStringAsFixed(2)} ha  ·  ${(m2 / 629).round()} tareas  ·  ${_puntos.length} puntos',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _puntos.isEmpty
                              ? null
                              : () => setState(() => _puntos.removeLast()),
                          icon: const Icon(Icons.undo),
                          label: const Text('Deshacer'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _puntos.isEmpty
                              ? null
                              : () => setState(() => _puntos.clear()),
                          icon: const Icon(Icons.delete_outline),
                          label: const Text('Borrar'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _puntos.length < 3
                          ? null
                          : () => ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Próximamente: análisis NDVI con Sentinel-2'),
                                ),
                              ),
                      icon: const Icon(Icons.eco),
                      label: const Text('Analizar NDVI'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
