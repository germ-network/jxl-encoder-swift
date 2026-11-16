import test from "node:test";

test.todo('pushes the exact version tag before creating a release with verified tag and generated notes');
test.todo('refuses release creation when the tag push fails');
test.todo('refuses release creation when remote tag verification fails');
test.todo('refuses release creation when note generation fails');
test.todo('keeps an existing release unchanged');
test.todo('retries creation after a prior run pushed the tag but failed creation', {
  todo: 'First create failure propagates nonzero and cleans notes; retry succeeds without changing the remote tag.'
});
test.todo('passes prerelease classification for a prerelease version');
