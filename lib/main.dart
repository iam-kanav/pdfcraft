import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import 'app.dart';
import 'core/services.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await pdfrxFlutterInitialize();
  final services = await AppServices.init();
  runApp(PdfCraftApp(services: services));
}
