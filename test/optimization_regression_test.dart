import 'package:test/test.dart';

import 'package:rank_scan_demo/models.dart';
import 'package:rank_scan_demo/scan_service.dart';
import 'package:rank_scan_demo/utils.dart';

void main() {
  group('stablePathId', () {
    test('same relative path keeps same id across runs', () {
      final a = stablePathId('扫榜/qidian/榜单.json');
      final b = stablePathId('扫榜/qidian/榜单.json');
      expect(a, equals(b));
    });

    test('different paths produce different ids', () {
      final a = stablePathId('扫榜/qidian/榜单.json');
      final b = stablePathId('扫榜/qidian/榜单_2.json');
      expect(a, isNot(equals(b)));
    });
  });

  group('safeFileSegment', () {
    test('removes path traps and windows reserved names', () {
      final s = safeFileSegment('..\\CON.txt ');
      expect(s, isNot(contains('..')));
      expect(s, isNot(contains('CON')));
      expect(s, isNot(endsWith(' ')));
    });
  });

  group('ScanService.testIsDegraded', () {
    test('prefers more valid metric-rich snapshots when row counts are equal', () {
      final old = RankResult(
        query: RankQuery(source: 'qidian', board: '热搜榜'),
        entries: [
          RankEntry(rank: 1, title: 'A', author: 'A', metrics: {'monthticket': 1}),
          RankEntry(rank: 2, title: 'B', author: 'B', metrics: {'monthticket': 2}),
        ],
        fetchedAt: DateTime(2024, 1, 1),
        quality: RankQuality(ok: true, validCount: 2, totalCount: 2),
      );
      final incoming = RankResult(
        query: RankQuery(source: 'qidian', board: '热搜榜'),
        entries: [
          RankEntry(rank: 1, title: 'A', author: 'A', metrics: {}),
          RankEntry(rank: 2, title: 'B', author: 'B', metrics: {}),
        ],
        fetchedAt: DateTime(2024, 1, 2),
        quality: RankQuality(ok: true, validCount: 2, totalCount: 2),
      );
      expect(ScanService.testIsDegraded(old, incoming), isTrue);
    });
  });
}
