import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../core/firebase/firebase_session.dart';

/// Append one row to the first sheet (tab name [sheetTab], default `Sheet1`).
class GoogleSheetsClient {
  GoogleSheetsClient._();

  static Uri _appendUri(String spreadsheetId, String sheetTab) {
    final enc = Uri.encodeComponent('$sheetTab!A1');
    return Uri.parse(
      'https://sheets.googleapis.com/v4/spreadsheets/'
      '$spreadsheetId/values/$enc:append?valueInputOption=USER_ENTERED'
      '&insertDataOption=INSERT_ROWS',
    );
  }

  static Future<void> appendRow({
    required String spreadsheetId,
    required List<String> cells,
    String sheetTab = 'Sheet1',
  }) async {
    final headers = await FirebaseSession.googleWorkspaceAuthHeaders();
    final body = <String, dynamic>{
      'values': <List<String>>[cells],
    };
    final res = await http.post(
      _appendUri(spreadsheetId.trim(), sheetTab),
      headers: <String, String>{
        ...headers,
        'Content-Type': 'application/json; charset=utf-8',
      },
      body: jsonEncode(body),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError(
        'Sheets API ${res.statusCode}: '
        '${res.body.length > 280 ? '${res.body.substring(0, 280)}…' : res.body}',
      );
    }
  }
}
