import 'package:flutter_test/flutter_test.dart';
import 'package:beth/app_version.dart';

void main() {
  test('label and short form', () {
    const v = AppVersion('1.0.0', build: 129, commit: '6742208');
    expect(v.short, '1.0.0+129');
    expect(v.label, '1.0.0 (build 129, 6742208)');
    expect(
      const AppVersion('1.0.0', build: 129).label,
      '1.0.0 (build 129, dev)',
    );
    expect(const AppVersion('1.0.0').short, '1.0.0');
    expect(const AppVersion('1.0.0').label, '1.0.0 (dev)');
  });

  test('fromPlatform reads the platform build number', () {
    // Tests run without the build-time defines.
    final v = AppVersion.fromPlatform('1.2.0', '57');
    expect(v.version, '1.2.0');
    expect(v.build, 57);
    expect(v.commit, isNull);
    expect(AppVersion.fromPlatform('1.2.0', '').build, isNull);
  });

  test('tryParse round-trips the short form', () {
    expect(
      AppVersion.tryParse('1.0.0+129'),
      const AppVersion('1.0.0', build: 129),
    );
    expect(AppVersion.tryParse(' 2.1 '), const AppVersion('2.1'));
    for (final bad in [null, 7, '', 'beta', '1.0.0+', '+5', '1.0.0+x']) {
      expect(AppVersion.tryParse(bad), isNull, reason: '$bad');
    }
  });

  test('sameBuildAs ignores the commit', () {
    const a = AppVersion('1.0.0', build: 129, commit: 'abc1234');
    expect(a.sameBuildAs(const AppVersion('1.0.0', build: 129)), isTrue);
    expect(a.sameBuildAs(const AppVersion('1.0.0', build: 130)), isFalse);
    expect(a.sameBuildAs(const AppVersion('1.0.1', build: 129)), isFalse);
  });
}
