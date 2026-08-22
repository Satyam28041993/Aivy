/// Short commit the build came from, supplied by CI:
/// `--dart-define=AIVY_BUILD_ID=abc1234`.
///
/// Shown on the voice screen. A cached page and a fresh one look identical
/// otherwise, so without this there is no way to tell whether a fix under test
/// is actually the code running on the device.
const kAivyBuildId = String.fromEnvironment(
  'AIVY_BUILD_ID',
  defaultValue: 'local',
);
