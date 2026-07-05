# Legacy Test Repair Queue

No test procedures remain in the legacy repair queue. The active AUnit runner includes a legacy script audit so historical phase integration scripts cannot silently drift out of the release surface. The historical catalog, compression, encryption, incremental, manifest, remote, restore, scanner, verify, workflow, and ZIP procedures are now called by `tests/src/tests.adb` and run by `./bin/tests`.

Keep this file as the place to document any future test that is temporarily removed from the active release runner.
