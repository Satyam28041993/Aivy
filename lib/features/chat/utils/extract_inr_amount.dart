import 'number_context_parser.dart';

/// Parses a monetary amount from free text (context: ₹, "N lena", "N din", clock).
double? extractInrAmountFromText(String text) {
  return parseNumbersWithContext(text).amount;
}
