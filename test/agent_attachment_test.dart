import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:aivy/features/agent/models/agent_attachment.dart';

void main() {
  group('canSendAgentTurn', () {
    test('allows a caption with no file', () {
      expect(canSendAgentTurn(text: 'hello', attachmentCount: 0), isTrue);
    });

    test('allows a file with nothing typed', () {
      expect(canSendAgentTurn(text: '   ', attachmentCount: 1), isTrue);
    });

    test('refuses an empty send', () {
      expect(canSendAgentTurn(text: '', attachmentCount: 0), isFalse);
    });
  });

  group('normalizeAgentMime', () {
    test('accepts jpeg png webp pdf', () {
      expect(normalizeAgentMime('image/jpeg'), 'image/jpeg');
      expect(normalizeAgentMime('image/jpg'), 'image/jpeg');
      expect(normalizeAgentMime('image/png'), 'image/png');
      expect(normalizeAgentMime('application/pdf'), 'application/pdf');
    });

    test('guesses from the file name when the picker is mute', () {
      expect(normalizeAgentMime('', fileName: 'card.JPG'), 'image/jpeg');
      expect(normalizeAgentMime('', fileName: 'rates.pdf'), 'application/pdf');
    });

    test('rejects excel and powerpoint', () {
      expect(normalizeAgentMime('application/vnd.ms-excel'), isNull);
      expect(normalizeAgentMime('', fileName: 'deck.pptx'), isNull);
    });
  });

  group('safeAgentFileName', () {
    test('strips spaces so Storage and the server path check agree', () {
      expect(safeAgentFileName('my card.jpg'), 'my_card.jpg');
    });

    test('keeps a boring name alone', () {
      expect(safeAgentFileName('rates.pdf'), 'rates.pdf');
    });
  });

  group('AgentFileRef', () {
    test('payload is path + mime + name, never bytes', () {
      const ref = AgentFileRef(
        storagePath: 'users/u1/agent_files/1_card.jpg',
        mimeType: 'image/jpeg',
        name: 'card.jpg',
      );
      expect(ref.toPayload(), {
        'storagePath': 'users/u1/agent_files/1_card.jpg',
        'mimeType': 'image/jpeg',
        'name': 'card.jpg',
      });
    });
  });

  group('AgentPendingFile', () {
    test('knows a pdf from a photo', () {
      final pdf = AgentPendingFile(
        name: 'rates.pdf',
        mimeType: 'application/pdf',
        bytes: Uint8List(1),
      );
      expect(pdf.isPdf, isTrue);
      expect(pdf.isImage, isFalse);
    });
  });
}
