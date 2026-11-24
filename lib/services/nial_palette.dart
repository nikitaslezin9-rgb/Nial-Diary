import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

final nialPalette = ValueNotifier<String>('green');
final _prefs = SharedPreferencesAsync();
Future<void> _queue = Future<void>.value();
int _revision = 0;
const _key = 'nial_palette_v1';
const _labels = {
  'green': 'Зелёная',
  'orange': 'Оранжевая',
  'burgundy': 'Бордовая',
};

Future<void> nialLoadPalette() async {
  final revision = _revision;
  try {
    final saved = await _prefs.getString(_key);
    if (revision == _revision && _labels.containsKey(saved))
      nialPalette.value = saved!;
  } catch (_) {
    /* Keep the default; do not overwrite stored data. */
  }
}

Future<void> _select(String value, BuildContext context) async {
  _revision++;
  nialPalette.value = value;
  final operation = _queue.then((_) => _prefs.setString(_key, value));
  _queue = operation.then<void>(
    (_) {},
    onError: (Object error, StackTrace stack) {},
  );
  try {
    await operation;
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Палитра применена, но не сохранена. Выбери её ещё раз.',
          ),
        ),
      );
    }
  }
}

ThemeData nialBuildTheme(bool dark) {
  final hue = switch (nialPalette.value) {
    'orange' => 35.0,
    'burgundy' => 355.0,
    _ => 125.0,
  };
  Color tone(double lightness, [double saturation = .28]) => HSLColor.fromAHSL(
    1,
    hue,
    nialPalette.value == 'burgundy'
        ? (saturation * 1.5).clamp(0.0, .60).toDouble()
        : saturation,
    lightness,
  ).toColor();
  final scheme =
      ColorScheme.fromSeed(
        seedColor: tone(.48),
        brightness: dark ? Brightness.dark : Brightness.light,
      ).copyWith(
        surface: tone(dark ? .16 : .97, .20),
        onSurface: tone(dark ? .92 : .19, .18),
        onSurfaceVariant: tone(dark ? .75 : .36, .15),
        primary: tone(dark ? .80 : .34),
        onPrimary: tone(dark ? .16 : .99, .15),
        primaryContainer: tone(dark ? .76 : .86, .30),
        onPrimaryContainer: tone(.18, .20),
        secondary: tone(dark ? .78 : .38, .22),
        onSecondary: tone(dark ? .16 : .99, .15),
        secondaryContainer: tone(dark ? .26 : .90, .23),
        onSecondaryContainer: tone(dark ? .93 : .20, .16),
        tertiary: tone(dark ? .77 : .38, .22),
        onTertiary: tone(dark ? .16 : .99, .15),
        tertiaryContainer: tone(dark ? .28 : .89, .23),
        onTertiaryContainer: tone(dark ? .93 : .20, .16),
        surfaceContainerLowest: tone(dark ? .09 : .99, .16),
        surfaceContainerLow: tone(dark ? .13 : .96, .18),
        surfaceContainer: tone(dark ? .18 : .94, .20),
        surfaceContainerHigh: tone(dark ? .22 : .92, .20),
        surfaceContainerHighest: tone(dark ? .26 : .90, .20),
        outline: tone(dark ? .53 : .56, .12),
        outlineVariant: tone(dark ? .30 : .82, .15),
      );
  return ThemeData(
    useMaterial3: true,
    brightness: scheme.brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: tone(dark ? .10 : .94, .22),
  );
}

class NialPalettePicker extends StatelessWidget {
  const NialPalettePicker({super.key});
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String>(
    valueListenable: nialPalette,
    builder: (context, selected, child) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Цветовая тема',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        const Text('Пастельная палитра для всего приложения'),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final entry in _labels.entries)
              ChoiceChip(
                label: Text(entry.value),
                avatar: CircleAvatar(
                  radius: 8,
                  backgroundColor: switch (entry.key) {
                    'orange' => const Color(0xffedc6a7),
                    'burgundy' => const Color(0xffd9a1aa),
                    _ => const Color(0xffbfd6b7),
                  },
                ),
                selected: selected == entry.key,
                onSelected: (_) => _select(entry.key, context),
              ),
          ],
        ),
      ],
    ),
  );
}
