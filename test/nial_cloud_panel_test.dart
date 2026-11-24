import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nial_diary/services/nial_cloud.dart';
import 'package:nial_diary/services/nial_cloud_panel.dart';

class _MemoryStore implements NialCloudStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }
}

void main() {
  testWidgets('переключатель спрашивает согласие и отправляет записи', (
    tester,
  ) async {
    var commits = 0;
    final cloud = NialCloudSync(
      client: MockClient((request) async {
        if (request.url.path.endsWith('accounts:signUp')) {
          return http.Response(
            jsonEncode({
              'idToken': 'id',
              'refreshToken': 'refresh',
              'localId': 'uid',
              'expiresIn': '3600',
            }),
            200,
          );
        }
        commits++;
        return http.Response('{}', 200);
      }),
      store: _MemoryStore(),
      apiKey: 'key',
      projectId: 'demo',
    );
    await tester.runAsync(cloud.load);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: NialCloudPanel(
              cloud: cloud,
              locked: false,
              snapshot: () => [
                NialCloudEntry(
                  id: 'a',
                  title: 'Заголовок',
                  text: 'Текст',
                  date: DateTime.utc(2026, 11, 24),
                  favorite: false,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(find.textContaining('Выключена'), findsOneWidget);

    // Отмена в диалоге ничего не включает.
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.text('Включить облачную копию?'), findsOneWidget);
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(cloud.status.value.enabled, isFalse);
    expect(commits, 0);

    // Согласие включает копию и сразу отправляет записи.
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('Включить'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(cloud.status.value.enabled, isTrue);
    expect(commits, 1);
    expect(find.textContaining('Последняя отправка'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
