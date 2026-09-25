void main() {
  final w = <num>[double.infinity];
  try {
    print((w.reduce((a, b) => a + b) / w.length).round());
  } catch (e) {
    print('THROW: $e');
  }
}
