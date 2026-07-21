enum IntentType {
  reminder,
  followUp,
  quotation,
  task,
  unknown,
}

Map<String, dynamic> parseIntent(String input) {
  final normalizedInput = input.trim().toLowerCase();

  if (normalizedInput.isEmpty) {
    return {
      'intent': IntentType.unknown,
      'data': {
        'originalInput': input,
        'normalizedInput': normalizedInput,
        'matchedKeywords': <String>[],
      },
    };
  }

  final reminderKeywords = <String>['call', 'remind', 'yaad'];
  final followUpKeywords = <String>['follow up', 'baad me'];
  final quotationKeywords = <String>['quotation', 'price', '₹'];
  final taskKeywords = <String>['task', 'karna hai'];

  final reminderMatches = _findMatches(normalizedInput, reminderKeywords);
  if (reminderMatches.isNotEmpty) {
    return {
      'intent': IntentType.reminder,
      'data': _buildData(
        input: input,
        normalizedInput: normalizedInput,
        matchedKeywords: reminderMatches,
      ),
    };
  }

  final followUpMatches = _findMatches(normalizedInput, followUpKeywords);
  if (followUpMatches.isNotEmpty) {
    return {
      'intent': IntentType.followUp,
      'data': _buildData(
        input: input,
        normalizedInput: normalizedInput,
        matchedKeywords: followUpMatches,
      ),
    };
  }

  final quotationMatches = _findMatches(normalizedInput, quotationKeywords);
  if (quotationMatches.isNotEmpty) {
    return {
      'intent': IntentType.quotation,
      'data': _buildData(
        input: input,
        normalizedInput: normalizedInput,
        matchedKeywords: quotationMatches,
      ),
    };
  }

  final taskMatches = _findMatches(normalizedInput, taskKeywords);
  if (taskMatches.isNotEmpty) {
    return {
      'intent': IntentType.task,
      'data': _buildData(
        input: input,
        normalizedInput: normalizedInput,
        matchedKeywords: taskMatches,
      ),
    };
  }

  return {
    'intent': IntentType.unknown,
    'data': _buildData(
      input: input,
      normalizedInput: normalizedInput,
      matchedKeywords: const <String>[],
    ),
  };
}

List<String> _findMatches(String normalizedInput, List<String> keywords) {
  return keywords.where(normalizedInput.contains).toList();
}

Map<String, dynamic> _buildData({
  required String input,
  required String normalizedInput,
  required List<String> matchedKeywords,
}) {
  return {
    'originalInput': input,
    'normalizedInput': normalizedInput,
    'matchedKeywords': matchedKeywords,
  };
}
