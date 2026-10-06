/// One client visit from the DSR, as `functions/src/agent/visitStore.ts`
/// writes it.
class VisitRecord {
  const VisitRecord({
    required this.id,
    required this.visitDateMs,
    required this.dateLabel,
    required this.clientName,
    required this.contactPerson,
    required this.contactPhone,
    required this.location,
    required this.visitType,
    required this.products,
    required this.discussion,
    required this.status,
    required this.nextStep,
    required this.followUpMs,
    required this.followUpLabel,
    required this.inSheet,
  });

  final String id;
  final int visitDateMs;
  final String dateLabel;
  final String clientName;
  final String contactPerson;
  final String contactPhone;
  final String location;
  final String visitType;
  final String products;
  final String discussion;
  final String status;
  final String nextStep;
  final int followUpMs;
  final String followUpLabel;

  /// Copied to the DSR Google Sheet yet.
  final bool inSheet;

  DateTime get visitDate => DateTime.fromMillisecondsSinceEpoch(visitDateMs);

  bool get hasFollowUp => followUpMs > 0;

  static String _s(Object? v) => v == null ? '' : v.toString().trim();

  static int _n(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(_s(v)) ?? 0;
  }

  factory VisitRecord.fromMap(String id, Map<String, dynamic> d) {
    final row = d['sheetRow'];
    return VisitRecord(
      id: id,
      visitDateMs: _n(d['visitDateMs']),
      dateLabel: _s(d['dateLabel']),
      clientName: _s(d['clientName']),
      contactPerson: _s(d['contactPerson']),
      contactPhone: _s(d['contactPhone']),
      location: _s(d['location']),
      visitType: _s(d['visitType']),
      products: _s(d['products']),
      discussion: _s(d['discussion']),
      status: _s(d['status']),
      nextStep: _s(d['nextStep']),
      followUpMs: _n(d['followUpMs']),
      followUpLabel: _s(d['followUpLabel']),
      inSheet: row is num && row > 0,
    );
  }

  /// Every searchable field, for the one search box.
  List<String> get searchFields => [
        clientName,
        contactPerson,
        contactPhone,
        location,
        visitType,
        products,
        discussion,
        status,
        nextStep,
      ];
}

/// The DSR Google Sheet in the user's Drive.
class DsrSheet {
  const DsrSheet({required this.spreadsheetId, required this.url});

  final String spreadsheetId;
  final String url;

  String get openUrl =>
      url.isNotEmpty ? url : 'https://docs.google.com/spreadsheets/d/$spreadsheetId/edit';

  /// Google exports the whole sheet as a real .xlsx file from this address,
  /// in the user's own Google session — no copy of the data leaves their
  /// account, and Excel opens it as it is.
  String get xlsxUrl => 'https://docs.google.com/spreadsheets/d/$spreadsheetId/export?format=xlsx';
}
