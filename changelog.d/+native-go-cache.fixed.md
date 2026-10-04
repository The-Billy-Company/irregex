We key the Go CI cache on the native archives as well as the module, so changing
an archive rebuilds the binding before its tests run. The ARM64 archive diagnostic
uses a fresh Go cache for each compiler posture.
