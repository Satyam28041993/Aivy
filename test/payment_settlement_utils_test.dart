import 'package:aivy/features/payments/utils/payment_settlement_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PaymentSettlementUtils', () {
    test('effectiveRemainingFromDueMap prefers remainingAmount', () {
      expect(
        PaymentSettlementUtils.effectiveRemainingFromDueMap({
          'originalAmount': 1000,
          'paidAmount': 200,
          'remainingAmount': 750,
        }),
        750.0,
      );
    });

    test('effectiveRemainingFromDueMap falls back to original minus paid', () {
      expect(
        PaymentSettlementUtils.effectiveRemainingFromDueMap({
          'originalAmount': 1000,
          'paidAmount': 300,
        }),
        700.0,
      );
    });

    test('isOpenDueStatus includes partial_pending', () {
      expect(PaymentSettlementUtils.isOpenDueStatus('partial_pending'), isTrue);
      expect(PaymentSettlementUtils.isOpenDueStatus('received'), isFalse);
    });

    test('isVoidedReceiptMap', () {
      expect(
        PaymentSettlementUtils.isVoidedReceiptMap({'voided': true}),
        isTrue,
      );
      expect(
        PaymentSettlementUtils.isVoidedReceiptMap({'voided': false}),
        isFalse,
      );
    });
  });
}
