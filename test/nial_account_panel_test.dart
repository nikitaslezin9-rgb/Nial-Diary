import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nial_diary/services/nial_account_panel.dart';
import 'package:nial_diary/services/nial_cloud.dart';

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
  testWidgets('регистрация проверяет почту и пароль до отправки', (
    tester,
  ) async {
    var requests = 0;
    final store = _MemoryStore();
    final cloud = NialCloudSync(
      client: MockClient((_) async {
        requests++;
        return http.Response('{}', 500);
      }),
      store: store,
      apiKey: 'key',
      projectId: 'demo',
      keyPrefix: 'nial_public_',
    );
    await cloud.load();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: NialAccountPanel(
              cloud: cloud,
              locked: false,
              onRestored: (_) async => 0,
            ),
          ),
        ),
      ),
    );
    expect(find.text('Зарегистрироваться по почте'), findsOneWidget);
    expect(find.text('Войти в аккаунт'), findsOneWidget);

    await tester.tap(find.text('Зарегистрироваться по почте'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(3));
    await tester.enterText(fields.at(0), 'не почта');
    await tester.tap(find.widgetWithText(FilledButton, 'Зарегистрироваться'));
    await tester.pump();
    expect(find.text('Проверь адрес почты.'), findsOneWidget);

    await tester.enterText(fields.at(0), 'me@example.com');
    await tester.enterText(fields.at(1), 'secret1');
    await tester.enterText(fields.at(2), 'secret2');
    await tester.tap(find.widgetWithText(FilledButton, 'Зарегистрироваться'));
    await tester.pump();
    expect(find.text('Пароли не совпадают.'), findsOneWidget);
    expect(requests, 0);

    store.values['nial_public_cloud_email_v1'] = 'me@example.com';
    await cloud.load();
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(find.text('me@example.com'), findsOneWidget);
    expect(find.text('Выйти из аккаунта'), findsOneWidget);
    expect(find.text('Я подтвердил почту'), findsOneWidget);
  });
}
